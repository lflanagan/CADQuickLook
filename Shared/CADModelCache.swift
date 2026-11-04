import Compression
import CryptoKit
import Foundation

/// Persistent on-disk cache of processed B-Rep models (STEP, IGES, BREP).
///
/// A large STEP assembly spends seconds in Open CASCADE translation, healing
/// and tessellation; an entry holds the result (display arrays, face/edge
/// tables and the exact B-Rep in OCCT's binary format) and reloads it in a
/// fraction of that. The cache is deliberately conservative with disk space:
///
/// * Only slow loads (> 2 s) of files of at least 2 MB are written, and only
///   entries no larger than a quarter of the limit.
/// * The limit is the user's setting (default 2 GB), capped at 10 % of the
///   volume's opportunistic free space; nothing is written below 10 GB free.
/// * Entries are evicted least-recently-used first (by an explicitly set
///   content access date) and after 30 days idle. Each app version uses its
///   own directory; the app deletes the others at launch.
/// * The directory is excluded from backups (macOS never purges third-party
///   caches, and App Group containers are backed up by Time Machine).
///
/// Entries are named by an HMAC-SHA256 of the source file's contents under a
/// per-install random salt, so the cache never stores or reveals file names.
/// The directory listing is the index; there is no shared index file, so the
/// app and the Quick Look extensions can use it concurrently.
struct CADModelCache: Sendable {
    /// Everything a cache hit needs to rebuild a CADModelAsset.
    struct Entry: Sendable {
        var vertices: [CADVertex]
        var triangles: [CADTriangle]
        var faceRanges: [CADFaceRange]
        var polylinePoints: [CADPoint3D]
        var edges: [CADEdgePolyline]
        var bounds: CADBounds
        var stats: CADModelStats
        /// CADBridgeModelCopyShapeData bytes.
        var shapeData: Data
        /// Wall time of the bridge load that produced the entry.
        var loadSeconds: Double
    }

    enum CacheError: Error {
        case invalid(String)
        case unavailable
    }

    static let formatVersion: UInt32 = 1
    static let cachedExtensions: Set<String> = ["step", "stp", "iges", "igs", "brep"]
    /// Smaller files are never looked up, so they pay nothing.
    static let minimumSourceBytes: Int64 = 2 * 1024 * 1024
    /// Only loads slower than this are worth an entry.
    static let minimumLoadSeconds: Double = 2
    /// No writes while the volume has less opportunistic free space than this.
    static let minimumFreeBytes: Int64 = 10 * gigabyte
    static let maximumIdle: TimeInterval = 30 * 24 * 60 * 60
    static let temporaryFileLifetime: TimeInterval = 60 * 60
    static let gigabyte: Int64 = 1_000_000_000

    /// The ModelCache directory (salt plus one directory per format/app version).
    let root: URL
    /// This version's entries.
    let directory: URL
    private let isEnabledProvider: @Sendable () -> Bool
    private let limitProvider: @Sendable () -> Int64
    private let capacityProvider: @Sendable (URL) -> Int64?

    /// `root` is the ModelCache directory; `versionName` names this build's
    /// entry directory under it. The providers default to the user's settings
    /// and the volume's free space; tests inject their own.
    init(
        root: URL,
        versionName: String,
        isEnabled: @escaping @Sendable () -> Bool = { CADPreferences.modelCacheEnabled },
        limitBytes: @escaping @Sendable () -> Int64 = { Int64(CADPreferences.modelCacheLimitGigabytes) * CADModelCache.gigabyte },
        availableCapacity: @escaping @Sendable (URL) -> Int64? = CADModelCache.opportunisticCapacity
    ) {
        self.root = root
        directory = root.appending(path: versionName, directoryHint: .isDirectory)
        isEnabledProvider = isEnabled
        limitProvider = limitBytes
        capacityProvider = availableCapacity
    }

    /// This process's cache: the App Group container's Library/Caches, or
    /// (main app only, when the group is unavailable in ad-hoc builds) the
    /// app's own caches directory. Nil in an extension without the group.
    static let shared: CADModelCache? = {
        let fileManager = FileManager.default
        let isExtension = Bundle.main.bundleURL.pathExtension == "appex"
        var base: URL?
        if let group = CADPreferences.appGroupIdentifier,
           let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: group) {
            base = container.appending(path: "Library/Caches", directoryHint: .isDirectory)
        } else if !isExtension,
                  let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
                  let identifier = Bundle.main.bundleIdentifier {
            base = caches.appending(path: identifier, directoryHint: .isDirectory)
        }
        guard let base else { return nil }
        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .replacingOccurrences(of: "/", with: "_") ?? "0"
        return CADModelCache(
            root: base.appending(path: "ModelCache", directoryHint: .isDirectory),
            versionName: "\(formatVersion)-\(appVersion)"
        )
    }()

    var isEnabled: Bool { isEnabledProvider() }

    @Sendable static func opportunisticCapacity(_ url: URL) -> Int64? {
        // The cache directory may not exist yet; ask its nearest existing ancestor.
        var candidate = url
        for _ in 0..<8 {
            if let value = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForOpportunisticUsageKey])
                .volumeAvailableCapacityForOpportunisticUsage {
                return value
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    /// The limit in force: the setting, at most 10 % of the free space.
    var effectiveLimitBytes: Int64 {
        let limit = limitProvider()
        guard let free = capacityProvider(directory) else { return limit }
        return max(0, min(limit, free / 10))
    }

    // MARK: Keys

    /// Whether `url` is a format and size the cache handles.
    static func isEligible(_ url: URL) -> Bool {
        guard cachedExtensions.contains(url.pathExtension.lowercased()),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return Int64(size) >= minimumSourceBytes
    }

    /// Everything besides the file's bytes that determines a load's output.
    static func keyMeta(options: CADMeshOptions) -> String {
        let bridge = String(cString: CADBridgeCacheVersion())
        func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
        return "\(bridge)|format=\(formatVersion)|linear=\(bits(options.linearDeflection))"
            + "|angular=\(bits(options.angularDeflectionRadians))|edge=\(bits(options.edgeDeflection))"
            + "|parallel=\(options.parallel)|scale=\(bits(options.linearDeflectionScale))"
    }

    /// The entry key for `url` when the cache is on and the file qualifies, else nil.
    func lookupKey(for url: URL, options: CADMeshOptions) -> String? {
        guard isEnabled, Self.isEligible(url) else { return nil }
        return try? key(for: url, meta: Self.keyMeta(options: options))
    }

    /// Hex HMAC-SHA256 over the file's contents, then `meta`, keyed by the
    /// install's salt. Depends only on the contents, never on the path.
    func key(for url: URL, meta: String) throws -> String {
        let salt = try loadSalt()
        let contents = try Data(contentsOf: url, options: .mappedIfSafe)
        var hmac = HMAC<SHA256>(key: SymmetricKey(data: salt))
        hmac.update(data: contents)
        // The length makes the content/meta boundary unambiguous.
        hmac.update(data: Data("|length=\(contents.count)|\(meta)".utf8))
        return Data(hmac.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    var saltURL: URL { root.appending(path: "salt", directoryHint: .notDirectory) }

    /// The per-install 32-byte salt, created atomically (link(2) of a fully
    /// written 0600 file, so concurrent processes agree on one) if missing.
    func loadSalt() throws -> Data {
        try prepareRoot()
        let url = saltURL
        for _ in 0..<3 {
            if let data = try? Data(contentsOf: url) {
                if data.count == 32 { return data }
                try? FileManager.default.removeItem(at: url) // damaged
            }
            let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let temporary = root.appending(path: ".tmp-salt-\(UUID().uuidString)")
            let handle = try Self.createPrivateFile(at: temporary)
            do {
                try handle.write(contentsOf: salt)
                try handle.synchronize()
                try handle.close()
            } catch {
                unlink(temporary.path)
                throw error
            }
            let linked = link(temporary.path, url.path) == 0
            unlink(temporary.path)
            if linked { return salt }
            // EEXIST: another process created it first; read theirs.
        }
        throw CacheError.unavailable
    }

    // MARK: Reading

    func entryURL(for key: String) -> URL {
        directory.appending(path: "\(key).cqlc", directoryHint: .notDirectory)
    }

    /// The validated entry for `key`, or nil. A damaged entry is deleted.
    /// A hit refreshes the entry's access date for LRU eviction.
    func read(key: String) -> Entry? {
        guard isEnabled else { return nil }
        let url = entryURL(for: key)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        do {
            let entry = try Self.decode(data)
            Self.setAccessDate(Date(), of: url)
            return entry
        } catch {
            remove(key: key)
            return nil
        }
    }

    func remove(key: String) {
        try? FileManager.default.removeItem(at: entryURL(for: key))
    }

    // MARK: Writing

    /// Re-keys the source off the critical path (the file may have changed
    /// during the load) and writes the entry at utility priority.
    func storeInBackground(_ entry: Entry, key: String, source: URL, options: CADMeshOptions) {
        let meta = Self.keyMeta(options: options)
        let cache = self
        Task.detached(priority: .utility) {
            guard (try? cache.key(for: source, meta: meta)) == key else { return }
            cache.store(entry, key: key)
        }
    }

    /// Writes `entry` atomically if the policy allows, then runs eviction.
    /// Returns whether the entry was written.
    @discardableResult
    func store(_ entry: Entry, key: String) -> Bool {
        guard isEnabled else { return false }
        do {
            try prepareDirectory()
            guard let free = capacityProvider(directory), free >= Self.minimumFreeBytes else { return false }
            let limit = max(0, min(limitProvider(), free / 10))
            let encoded = Self.encode(entry)
            guard Int64(encoded.totalLength) <= limit / 4 else { return false }

            let temporary = directory.appending(path: ".tmp-\(UUID().uuidString)", directoryHint: .notDirectory)
            let handle = try Self.createPrivateFile(at: temporary)
            do {
                for chunk in encoded.chunks { try handle.write(contentsOf: chunk) }
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                unlink(temporary.path)
                throw error
            }
            // Content-addressed: a concurrent identical writer's rename is equivalent.
            let destination = entryURL(for: key)
            guard rename(temporary.path, destination.path) == 0 else {
                unlink(temporary.path)
                return false
            }
            Self.setAccessDate(Date(), of: destination)
            Self.excludeFromBackup(root)
            evict()
            return true
        } catch {
            return false
        }
    }

    // MARK: Maintenance

    /// Deletes stale temporary files (> 1 h), entries idle more than 30 days,
    /// then least-recently-used entries until the total fits the limit.
    func evict(now: Date = Date()) {
        guard isEnabled else {
            removeAll()
            return
        }
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentAccessDateKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var entries: [(url: URL, accessed: Date, size: Int64)] = []
        for url in urls {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: keys)
            if name.hasPrefix(".tmp-") {
                let modified = values?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(modified) > Self.temporaryFileLifetime {
                    try? fileManager.removeItem(at: url)
                }
                continue
            }
            guard name.hasSuffix(".cqlc") else { continue }
            let accessed = values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(accessed) > Self.maximumIdle {
                try? fileManager.removeItem(at: url)
                continue
            }
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            entries.append((url, accessed, size))
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        let limit = effectiveLimitBytes
        guard total > limit else { return }
        for entry in entries.sorted(by: { $0.accessed < $1.accessed }) {
            guard total > limit else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Deletes the directories of other format/app versions (the salt stays).
    func removeOtherVersions() {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for url in urls where url.lastPathComponent != directory.lastPathComponent {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Deletes the whole cache, salt included.
    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Allocated bytes of everything under the cache root.
    func size() -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// App launch: drop old versions and run eviction (or delete everything
    /// when the cache is off), on a background utility task.
    static func performLaunchMaintenance() {
        guard let cache = shared else { return }
        Task.detached(priority: .utility) {
            guard cache.isEnabled else {
                cache.removeAll()
                return
            }
            cache.removeOtherVersions()
            cache.evict()
        }
    }

    // MARK: Files

    private func prepareRoot() throws {
        try Self.makePrivateDirectory(root)
        Self.excludeFromBackup(root)
    }

    private func prepareDirectory() throws {
        try prepareRoot()
        try Self.makePrivateDirectory(directory)
    }

    private static func makePrivateDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(url.path, 0o700)
    }

    /// Creates a new file readable only by the user (O_EXCL, mode 0600).
    private static func createPrivateFile(at url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    static func setAccessDate(_ date: Date, of url: URL) {
        var url = url
        var values = URLResourceValues()
        values.contentAccessDate = date
        try? url.setResourceValues(values)
    }

    // MARK: Format
    //
    // All integers little-endian.
    //   Header:  "CQLC" | version u32 | headerLength u32 | sectionCount u32
    //            | sectionCount × (id u32, flags u32, offset u64,
    //                              compressedLength u64, rawLength u64,
    //                              SHA-256 of the stored bytes [32])
    //            | SHA-256 of the header bytes before it [32]
    //   Sections (stored bytes; flags bit 0 = lzfse-compressed)
    //   Footer:  "CQLC" | totalLength u64
    //
    // The header hash protects the raw lengths (which size allocations) and
    // offsets; the section hashes protect the payloads.

    private enum SectionID: UInt32, CaseIterable {
        case meta = 1, vertices, triangles, faceRanges, polylinePoints, edges, shape
    }

    private static let magic: [UInt8] = Array("CQLC".utf8)
    private static let lzfseFlag: UInt32 = 1
    private static let fixedHeaderLength = 16
    private static let sectionEntryLength = 64
    private static let hashLength = 32
    private static let footerLength = 12
    private static var headerLength: Int {
        fixedHeaderLength + SectionID.allCases.count * sectionEntryLength + hashLength
    }

    private struct Layout {
        static let strides: [UInt32] = [
            UInt32(MemoryLayout<CADVertex>.stride),
            UInt32(MemoryLayout<CADTriangle>.stride),
            UInt32(MemoryLayout<CADFaceRange>.stride),
            UInt32(MemoryLayout<CADPoint3D>.stride),
            UInt32(MemoryLayout<CADEdgePolyline>.stride),
            UInt32(MemoryLayout<CADBounds>.size),
            UInt32(MemoryLayout<CADModelStats>.size),
        ]
        static var metaLength: Int {
            strides.count * 4 + 6 * 8 + 8 + MemoryLayout<CADBounds>.size + MemoryLayout<CADModelStats>.size
        }
    }

    struct Encoded {
        var chunks: [Data]
        var totalLength: Int
    }

    static func encode(_ entry: Entry) -> Encoded {
        var meta = Data(capacity: Layout.metaLength)
        for stride in Layout.strides { meta.appendLittleEndian(stride) }
        for count in [entry.vertices.count, entry.triangles.count, entry.faceRanges.count,
                      entry.polylinePoints.count, entry.edges.count, entry.shapeData.count] {
            meta.appendLittleEndian(UInt64(count))
        }
        meta.appendLittleEndian(entry.loadSeconds.bitPattern)
        withUnsafeBytes(of: entry.bounds) { meta.append(contentsOf: $0) }
        withUnsafeBytes(of: entry.stats) { meta.append(contentsOf: $0) }

        var bodies: [(id: SectionID, stored: Data, flags: UInt32, rawLength: Int)] = []
        func add(_ id: SectionID, _ raw: UnsafeRawBufferPointer) {
            let (stored, flags) = compress(raw)
            bodies.append((id, stored, flags, raw.count))
        }
        meta.withUnsafeBytes { add(.meta, $0) }
        entry.vertices.withUnsafeBytes { add(.vertices, $0) }
        entry.triangles.withUnsafeBytes { add(.triangles, $0) }
        entry.faceRanges.withUnsafeBytes { add(.faceRanges, $0) }
        entry.polylinePoints.withUnsafeBytes { add(.polylinePoints, $0) }
        entry.edges.withUnsafeBytes { add(.edges, $0) }
        entry.shapeData.withUnsafeBytes { add(.shape, $0) }

        var header = Data(capacity: headerLength)
        header.append(contentsOf: magic)
        header.appendLittleEndian(formatVersion)
        header.appendLittleEndian(UInt32(headerLength))
        header.appendLittleEndian(UInt32(bodies.count))
        var offset = headerLength
        for body in bodies {
            header.appendLittleEndian(body.id.rawValue)
            header.appendLittleEndian(body.flags)
            header.appendLittleEndian(UInt64(offset))
            header.appendLittleEndian(UInt64(body.stored.count))
            header.appendLittleEndian(UInt64(body.rawLength))
            header.append(contentsOf: SHA256.hash(data: body.stored))
            offset += body.stored.count
        }
        header.append(contentsOf: SHA256.hash(data: header))
        let totalLength = offset + footerLength
        var footer = Data(magic)
        footer.appendLittleEndian(UInt64(totalLength))
        return Encoded(chunks: [header] + bodies.map(\.stored) + [footer], totalLength: totalLength)
    }

    /// lzfse into an exactly sized malloc buffer; stored raw when that
    /// doesn't shrink it.
    private static func compress(_ raw: UnsafeRawBufferPointer) -> (Data, UInt32) {
        guard let source = raw.baseAddress, raw.count > 0 else { return (Data(), 0) }
        guard let destination = malloc(raw.count) else { return (Data(raw), 0) }
        let written = compression_encode_buffer(
            destination.assumingMemoryBound(to: UInt8.self), raw.count,
            source.assumingMemoryBound(to: UInt8.self), raw.count,
            nil, COMPRESSION_LZFSE
        )
        guard written > 0, written < raw.count else {
            free(destination)
            return (Data(raw), 0)
        }
        let shrunk = realloc(destination, written) ?? destination
        return (Data(bytesNoCopy: shrunk, count: written, deallocator: .free), lzfseFlag)
    }

    private struct Section {
        let flags: UInt32
        let offset: Int
        let storedLength: Int
        let rawLength: Int
    }

    static func decode(_ data: Data) throws -> Entry {
        try data.withUnsafeBytes { (file: UnsafeRawBufferPointer) throws -> Entry in
            let length = file.count
            guard length >= headerLength + footerLength else { throw CacheError.invalid("truncated") }
            guard file.elementsEqual(magic, at: length - footerLength),
                  file.littleEndian(UInt64.self, at: length - 8) == UInt64(length) else {
                throw CacheError.invalid("footer")
            }
            guard file.elementsEqual(magic, at: 0),
                  file.littleEndian(UInt32.self, at: 4) == formatVersion,
                  file.littleEndian(UInt32.self, at: 8) == UInt32(headerLength),
                  file.littleEndian(UInt32.self, at: 12) == UInt32(SectionID.allCases.count) else {
                throw CacheError.invalid("header")
            }
            let hashOffset = headerLength - hashLength
            let headerHash = SHA256.hash(data: UnsafeRawBufferPointer(rebasing: file[0..<hashOffset]))
            guard file.elementsEqual(headerHash, at: hashOffset) else { throw CacheError.invalid("header hash") }

            let sectionsEnd = length - footerLength
            var sections: [SectionID: Section] = [:]
            for index in 0..<SectionID.allCases.count {
                let base = fixedHeaderLength + index * sectionEntryLength
                guard let id = SectionID(rawValue: file.littleEndian(UInt32.self, at: base)), sections[id] == nil else {
                    throw CacheError.invalid("section id")
                }
                let flags = file.littleEndian(UInt32.self, at: base + 4)
                let offset = file.littleEndian(UInt64.self, at: base + 8)
                let stored = file.littleEndian(UInt64.self, at: base + 16)
                let raw = file.littleEndian(UInt64.self, at: base + 24)
                guard flags & ~lzfseFlag == 0,
                      offset >= UInt64(headerLength), offset <= UInt64(sectionsEnd),
                      stored <= UInt64(sectionsEnd) - offset,
                      raw <= 1 << 40,
                      flags == lzfseFlag || stored == raw else {
                    throw CacheError.invalid("section bounds")
                }
                let range = Int(offset)..<Int(offset + stored)
                let digest = SHA256.hash(data: UnsafeRawBufferPointer(rebasing: file[range]))
                guard file.elementsEqual(digest, at: base + 32) else { throw CacheError.invalid("section hash") }
                sections[id] = Section(flags: flags, offset: Int(offset), storedLength: Int(stored), rawLength: Int(raw))
            }
            func section(_ id: SectionID) -> Section { sections[id]! } // all ids present: count matched, no duplicates

            // Meta: layout check, counts, load time, bounds, stats.
            let metaSection = section(.meta)
            guard metaSection.rawLength == Layout.metaLength else { throw CacheError.invalid("meta length") }
            var meta = Data(count: metaSection.rawLength)
            try meta.withUnsafeMutableBytes { try decompress(metaSection, in: file, into: $0) }
            return try meta.withUnsafeBytes { (meta: UnsafeRawBufferPointer) throws -> Entry in
                var cursor = 0
                for stride in Layout.strides {
                    guard meta.littleEndian(UInt32.self, at: cursor) == stride else { throw CacheError.invalid("struct layout") }
                    cursor += 4
                }
                var counts: [Int] = []
                for _ in 0..<6 {
                    counts.append(Int(clamping: meta.littleEndian(UInt64.self, at: cursor)))
                    cursor += 8
                }
                let loadSeconds = Double(bitPattern: meta.littleEndian(UInt64.self, at: cursor))
                cursor += 8
                let bounds = meta.loadUnaligned(fromByteOffset: cursor, as: CADBounds.self)
                cursor += MemoryLayout<CADBounds>.size
                let stats = meta.loadUnaligned(fromByteOffset: cursor, as: CADModelStats.self)

                func array<T>(_ id: SectionID, count: Int, as type: T.Type) throws -> [T] {
                    let s = section(id)
                    let (expected, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
                    guard !overflow, expected == s.rawLength else { throw CacheError.invalid("count") }
                    guard count > 0 else { return [] }
                    return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                        try decompress(s, in: file, into: UnsafeMutableRawBufferPointer(buffer))
                        initialized = count
                    }
                }
                let vertices = try array(.vertices, count: counts[0], as: CADVertex.self)
                let triangles = try array(.triangles, count: counts[1], as: CADTriangle.self)
                let faceRanges = try array(.faceRanges, count: counts[2], as: CADFaceRange.self)
                let points = try array(.polylinePoints, count: counts[3], as: CADPoint3D.self)
                let edges = try array(.edges, count: counts[4], as: CADEdgePolyline.self)
                let shapeSection = section(.shape)
                guard shapeSection.rawLength == counts[5], counts[5] > 0 else { throw CacheError.invalid("shape length") }
                var shape = Data(count: counts[5])
                try shape.withUnsafeMutableBytes { try decompress(shapeSection, in: file, into: $0) }

                // Index ranges, so a bad entry can never index out of bounds.
                let triangleCount = UInt64(triangles.count)
                for range in faceRanges where UInt64(range.firstTriangle) + UInt64(range.triangleCount) > triangleCount {
                    throw CacheError.invalid("face range")
                }
                let pointCount = UInt64(points.count)
                for edge in edges where UInt64(edge.firstPoint) + UInt64(edge.pointCount) > pointCount {
                    throw CacheError.invalid("edge range")
                }
                let vertexCount = UInt32(clamping: vertices.count)
                for triangle in triangles where triangle.i0 >= vertexCount || triangle.i1 >= vertexCount || triangle.i2 >= vertexCount {
                    throw CacheError.invalid("triangle index")
                }
                return Entry(
                    vertices: vertices, triangles: triangles, faceRanges: faceRanges,
                    polylinePoints: points, edges: edges, bounds: bounds, stats: stats,
                    shapeData: shape, loadSeconds: loadSeconds
                )
            }
        }
    }

    private static func decompress(_ section: Section, in file: UnsafeRawBufferPointer, into destination: UnsafeMutableRawBufferPointer) throws {
        guard destination.count == section.rawLength else { throw CacheError.invalid("raw length") }
        guard section.rawLength > 0 else { return }
        let source = UnsafeRawBufferPointer(rebasing: file[section.offset..<section.offset + section.storedLength])
        guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else {
            throw CacheError.invalid("empty section")
        }
        if section.flags & lzfseFlag == 0 {
            destination.copyMemory(from: source)
            return
        }
        let written = compression_decode_buffer(
            destinationBase.assumingMemoryBound(to: UInt8.self), destination.count,
            sourceBase.assumingMemoryBound(to: UInt8.self), source.count,
            nil, COMPRESSION_LZFSE
        )
        guard written == destination.count else { throw CacheError.invalid("decompressed length") }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

private extension UnsafeRawBufferPointer {
    func littleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        T(littleEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }

    /// Whether the bytes at `offset` equal `expected` (false when out of range).
    func elementsEqual<S: Sequence>(_ expected: S, at offset: Int) -> Bool where S.Element == UInt8 {
        let bytes = Array(expected)
        guard offset >= 0, offset + bytes.count <= count else { return false }
        return self[offset..<offset + bytes.count].elementsEqual(bytes)
    }
}

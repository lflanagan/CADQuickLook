import Foundation
import simd

/// A 2D curve from a DXF drawing, sampled to a polyline in drawing units.
struct DXFEdge {
    var points: [SIMD2<Double>]
    /// True for CIRCLE/ARC entities (and 2-vertex bulge circles) so the viewer
    /// can report a diameter.
    var isCircular: Bool
    var diameter: Double
    /// Analytic length where the entity has one (lines, arcs, bulge
    /// polylines); polyline length otherwise.
    var length: Double
}

/// Minimal ASCII DXF reader: LINE, CIRCLE, ARC, LWPOLYLINE, POLYLINE/VERTEX,
/// ELLIPSE, SPLINE and INSERT (block references). Text, dimensions and hatches
/// are ignored. Everything is projected onto the XY plane.
struct DXFDrawing {
    private(set) var edges: [DXFEdge] = []
    /// Multiplier from drawing units to millimetres, from $INSUNITS (1 when unset).
    private(set) var unitScaleToMillimeters: Double = 1

    enum ParseError: LocalizedError {
        case unreadable
        case empty
        var errorDescription: String? {
            switch self {
            case .unreadable: "The DXF file could not be read as text."
            case .empty: "The DXF file does not contain any drawable entities."
            }
        }
    }

    private typealias Pair = (code: Int, value: String)
    private struct Entity {
        let type: String
        var pairs: [Pair]
        /// POLYLINE only: its VERTEX records.
        var vertices: [[Pair]] = []

        /// Finite numeric value for a group code (NaN/inf in the file fall back to the default).
        func value(_ code: Int, default fallback: Double = 0) -> Double {
            guard let parsed = pairs.first(where: { $0.code == code }).flatMap({ Double($0.value) }),
                  parsed.isFinite else { return fallback }
            return parsed
        }
        func string(_ code: Int) -> String? { pairs.first { $0.code == code }?.value }
        func values(_ code: Int) -> [Double] {
            pairs.filter { $0.code == code }.compactMap { Double($0.value) }.filter(\.isFinite)
        }
    }
    private struct Block {
        var base: SIMD2<Double>
        var entities: [Entity]
    }

    private var blocks: [String: Block] = [:]

    /// Upper bounds so a malformed or hostile file cannot exhaust memory.
    private static let maximumEdges = 500_000
    private static let maximumPoints = 20_000_000
    private var pointCount = 0

    /// Int conversion that never traps: non-finite values map to the lower bound.
    private static func clampedInt(_ value: Double, _ range: ClosedRange<Int>) -> Int {
        guard value.isFinite else { return range.lowerBound }
        return Int(min(max(value, Double(range.lowerBound)), Double(range.upperBound)))
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ParseError.unreadable
        }
        let pairs = Self.pairs(in: text)
        var index = 0
        var section = ""
        var entities: [Entity] = []

        while index < pairs.count {
            let pair = pairs[index]
            if pair.code == 0, pair.value == "SECTION", index + 1 < pairs.count {
                section = pairs[index + 1].value
                index += 2
                continue
            }
            if pair.code == 0, pair.value == "ENDSEC" {
                section = ""
                index += 1
                continue
            }
            switch section {
            case "HEADER":
                if pair.code == 9, pair.value == "$INSUNITS", index + 1 < pairs.count,
                   let code = Int(pairs[index + 1].value) {
                    unitScaleToMillimeters = Self.unitScale(insunits: code)
                }
                index += 1
            case "BLOCKS":
                if pair.code == 0, pair.value == "BLOCK" {
                    index += 1
                    var name = ""
                    var base = SIMD2<Double>(0, 0)
                    while index < pairs.count, pairs[index].code != 0 {
                        switch pairs[index].code {
                        case 2: name = pairs[index].value
                        case 10: base.x = Double(pairs[index].value) ?? 0
                        case 20: base.y = Double(pairs[index].value) ?? 0
                        default: break
                        }
                        index += 1
                    }
                    var blockEntities: [Entity] = []
                    while index < pairs.count, !(pairs[index].code == 0 && pairs[index].value == "ENDBLK") {
                        if let entity = Self.readEntity(pairs, &index) {
                            blockEntities.append(entity)
                        } else {
                            index += 1
                        }
                    }
                    blocks[name] = Block(base: base, entities: blockEntities)
                } else {
                    index += 1
                }
            case "ENTITIES":
                if let entity = Self.readEntity(pairs, &index) {
                    entities.append(entity)
                } else {
                    index += 1
                }
            default:
                index += 1
            }
        }

        for entity in entities {
            append(entity, transform: .identity, depth: 0)
        }
        guard !edges.isEmpty else { throw ParseError.empty }
    }

    // MARK: - Tokenizing

    private static func pairs(in text: String) -> [Pair] {
        var result: [Pair] = []
        var pendingCode: Int?
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let code = pendingCode {
                result.append((code, trimmed))
                pendingCode = nil
            } else {
                pendingCode = Int(trimmed)
            }
        }
        return result
    }

    /// Reads one entity starting at a `0` pair; POLYLINE consumes its VERTEX
    /// records through SEQEND. Returns nil if `index` is not at an entity start.
    private static func readEntity(_ pairs: [Pair], _ index: inout Int) -> Entity? {
        guard index < pairs.count, pairs[index].code == 0 else { return nil }
        var entity = Entity(type: pairs[index].value, pairs: [])
        index += 1
        while index < pairs.count, pairs[index].code != 0 {
            entity.pairs.append(pairs[index])
            index += 1
        }
        if entity.type == "POLYLINE" {
            while index < pairs.count, pairs[index].code == 0, pairs[index].value == "VERTEX" {
                index += 1
                var vertex: [Pair] = []
                while index < pairs.count, pairs[index].code != 0 {
                    vertex.append(pairs[index])
                    index += 1
                }
                entity.vertices.append(vertex)
            }
            if index < pairs.count, pairs[index].code == 0, pairs[index].value == "SEQEND" {
                index += 1
                while index < pairs.count, pairs[index].code != 0 { index += 1 }
            }
        }
        return entity
    }

    private static func unitScale(insunits: Int) -> Double {
        switch insunits {
        case 1: 25.4            // inches
        case 2: 304.8           // feet
        case 3: 1_609_344       // miles
        case 4: 1               // millimetres
        case 5: 10              // centimetres
        case 6: 1_000           // metres
        case 7: 1_000_000       // kilometres
        case 8: 0.0000254       // microinches
        case 9: 0.0254          // mils
        case 10: 914.4          // yards
        case 11: 1e-7           // angstroms
        case 12: 1e-6           // nanometres
        case 13: 0.001          // microns
        case 14: 100            // decimetres
        case 15: 10_000         // decametres
        case 16: 100_000        // hectometres
        case 17: 1e12           // gigametres
        default: 1
        }
    }

    // MARK: - Entities → edges

    private struct Transform {
        var origin = SIMD2<Double>(0, 0)
        var scale = SIMD2<Double>(1, 1)
        var rotation = 0.0
        var base = SIMD2<Double>(0, 0)
        static let identity = Transform()

        func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
            let scaled = (p - base) * scale
            let c = cos(rotation), s = sin(rotation)
            return origin + SIMD2<Double>(scaled.x * c - scaled.y * s, scaled.x * s + scaled.y * c)
        }
        var lengthScale: Double { sqrt(abs(scale.x * scale.y)) }
        var isUniform: Bool { abs(abs(scale.x) - abs(scale.y)) < 1e-9 }
    }

    private mutating func append(_ entity: Entity, transform: Transform, depth: Int) {
        // Budget against block-reference fan-out (a block inserting itself N times
        // is N^depth entities) and absurd sample counts.
        guard edges.count < Self.maximumEdges, pointCount < Self.maximumPoints else { return }
        // Entities with a flipped extrusion direction (OCS Z = -1) are mirrored in X.
        let mirrored = entity.value(230, default: 1) < 0
        func emit(_ points: [SIMD2<Double>], circular: Bool = false, diameter: Double = 0, length: Double? = nil) {
            guard points.count > 1, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
            var mapped = points
            if mirrored { mapped = mapped.map { SIMD2<Double>(-$0.x, $0.y) } }
            mapped = mapped.map(transform.apply)
            let polylineLength = zip(mapped, mapped.dropFirst()).reduce(0.0) { $0 + simd_length($1.1 - $1.0) }
            let exact = (length.map { $0 * transform.lengthScale }) ?? polylineLength
            guard mapped.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), exact.isFinite else { return }
            let keepCircular = circular && transform.isUniform
            pointCount += mapped.count
            edges.append(DXFEdge(
                points: mapped,
                isCircular: keepCircular,
                diameter: keepCircular ? diameter * transform.lengthScale : 0,
                length: exact
            ))
        }

        switch entity.type {
        case "LINE":
            let a = SIMD2<Double>(entity.value(10), entity.value(20))
            let b = SIMD2<Double>(entity.value(11), entity.value(21))
            emit([a, b], length: simd_length(b - a))

        case "CIRCLE":
            let center = SIMD2<Double>(entity.value(10), entity.value(20))
            let radius = entity.value(40)
            emit(Self.arcPoints(center: center, radius: radius, start: 0, sweep: 2 * .pi),
                 circular: true, diameter: radius * 2, length: 2 * .pi * radius)

        case "ARC":
            let center = SIMD2<Double>(entity.value(10), entity.value(20))
            let radius = entity.value(40)
            let start = entity.value(50) * .pi / 180
            var end = entity.value(51) * .pi / 180
            if end <= start { end += 2 * .pi }
            emit(Self.arcPoints(center: center, radius: radius, start: start, sweep: end - start),
                 circular: true, diameter: radius * 2, length: radius * (end - start))

        case "LWPOLYLINE":
            var vertices: [(SIMD2<Double>, Double)] = []
            var current: SIMD2<Double>?
            for pair in entity.pairs {
                switch pair.code {
                case 10:
                    if let current { vertices.append((current, 0)) }
                    current = SIMD2<Double>(Double(pair.value) ?? 0, 0)
                case 20:
                    current?.y = Double(pair.value) ?? 0
                case 42:
                    if let point = current {
                        vertices.append((point, Double(pair.value) ?? 0))
                        current = nil
                    }
                default: break
                }
            }
            if let current { vertices.append((current, 0)) }
            let closed = (Self.clampedInt(entity.value(70), 0...Int(Int32.max)) & 1) != 0
            appendPolyline(vertices, closed: closed, emit: emit)

        case "POLYLINE":
            let vertices: [(SIMD2<Double>, Double)] = entity.vertices.compactMap { vertex in
                let x = vertex.first { $0.code == 10 }.flatMap { Double($0.value) }
                let y = vertex.first { $0.code == 20 }.flatMap { Double($0.value) }
                let bulge = vertex.first { $0.code == 42 }.flatMap { Double($0.value) } ?? 0
                let flags = vertex.first { $0.code == 70 }.flatMap { Double($0.value) }.map { Self.clampedInt($0, 0...Int(Int32.max)) } ?? 0
                // Skip spline frame control points (bit 4) — the fit vertices (bit 8) follow.
                guard let x, let y, flags & 16 == 0 else { return nil }
                return (SIMD2<Double>(x, y), bulge)
            }
            let closed = (Self.clampedInt(entity.value(70), 0...Int(Int32.max)) & 1) != 0
            appendPolyline(vertices, closed: closed, emit: emit)

        case "ELLIPSE":
            let center = SIMD2<Double>(entity.value(10), entity.value(20))
            let major = SIMD2<Double>(entity.value(11), entity.value(21))
            let ratio = entity.value(40, default: 1)
            let start = entity.value(41)
            var end = entity.value(42, default: 2 * .pi)
            if end <= start { end += 2 * .pi }
            end = min(end, start + 2 * .pi)
            let minor = SIMD2<Double>(-major.y, major.x) * ratio
            let steps = Self.clampedInt(ceil((end - start) / (2 * .pi) * 128), 16...720)
            let points = (0...steps).map { i -> SIMD2<Double> in
                let t = start + (end - start) * Double(i) / Double(steps)
                return center + major * cos(t) + minor * sin(t)
            }
            emit(points)

        case "SPLINE":
            emit(Self.splinePoints(entity))

        case "INSERT":
            guard depth < 8, let name = entity.string(2), let block = blocks[name] else { return }
            var nested = Transform()
            nested.base = block.base
            nested.origin = SIMD2<Double>(entity.value(10), entity.value(20))
            nested.scale = SIMD2<Double>(entity.value(41, default: 1), entity.value(42, default: 1))
            nested.rotation = entity.value(50) * .pi / 180
            // Compose with the enclosing transform by mapping through both.
            let outer = transform
            var composed = Transform()
            composed.origin = outer.apply(nested.origin)
            composed.scale = nested.scale * outer.scale
            composed.rotation = nested.rotation + outer.rotation
            composed.base = block.base
            for child in block.entities {
                append(child, transform: composed, depth: depth + 1)
            }

        default:
            break
        }
    }

    private func appendPolyline(
        _ vertices: [(SIMD2<Double>, Double)],
        closed: Bool,
        emit: ([SIMD2<Double>], Bool, Double, Double?) -> Void
    ) {
        guard vertices.count > 1 else { return }
        // A closed two-vertex polyline with unit bulges is how many exporters write a full circle.
        if closed, vertices.count == 2, abs(abs(vertices[0].1) - 1) < 1e-6, abs(abs(vertices[1].1) - 1) < 1e-6 {
            let a = vertices[0].0, b = vertices[1].0
            let center = (a + b) / 2
            let radius = simd_length(b - a) / 2
            emit(Self.arcPoints(center: center, radius: radius, start: atan2(a.y - center.y, a.x - center.x), sweep: 2 * .pi),
                 true, radius * 2, 2 * .pi * radius)
            return
        }
        var points: [SIMD2<Double>] = [vertices[0].0]
        var length = 0.0
        let count = closed ? vertices.count : vertices.count - 1
        for i in 0..<count {
            let (a, bulge) = vertices[i]
            let b = vertices[(i + 1) % vertices.count].0
            if abs(bulge) < 1e-12 {
                points.append(b)
                length += simd_length(b - a)
            } else {
                let theta = 4 * atan(bulge)
                let chord = simd_length(b - a)
                guard chord > 0 else { continue }
                let radius = chord / (2 * sin(abs(theta) / 2))
                let midpoint = (a + b) / 2
                let normal = SIMD2<Double>(-(b.y - a.y), b.x - a.x) / chord
                let sagitta = abs(bulge) * chord / 2
                let center = midpoint + normal * (radius - sagitta) * (bulge > 0 ? 1 : -1)
                let start = atan2(a.y - center.y, a.x - center.x)
                let arc = Self.arcPoints(center: center, radius: radius, start: start, sweep: theta)
                points.append(contentsOf: arc.dropFirst())
                length += radius * abs(theta)
            }
        }
        emit(points, false, 0, length)
    }

    private static func arcPoints(center: SIMD2<Double>, radius: Double, start: Double, sweep: Double) -> [SIMD2<Double>] {
        guard radius.isFinite, sweep.isFinite, start.isFinite else { return [] }
        let steps = clampedInt(ceil(abs(sweep) / (2 * .pi) * 128), 8...720)
        return (0...steps).map { i in
            let angle = start + sweep * Double(i) / Double(steps)
            return center + SIMD2<Double>(cos(angle), sin(angle)) * radius
        }
    }

    /// Evaluates a NURBS spline from its control points and knots; falls back
    /// to the fit points when no control data is present.
    private static func splinePoints(_ entity: Entity) -> [SIMD2<Double>] {
        let degree = Self.clampedInt(entity.value(71, default: 3), 1...11)
        let knots = entity.values(40)
        let xs = entity.values(10), ys = entity.values(20)
        let control = zip(xs, ys).map { SIMD2<Double>($0, $1) }
        var weights = entity.values(41)
        if weights.count != control.count { weights = Array(repeating: 1, count: control.count) }

        guard control.count > degree, knots.count == control.count + degree + 1 else {
            let fx = entity.values(11), fy = entity.values(21)
            return zip(fx, fy).map { SIMD2<Double>($0, $1) }
        }

        let spans = control.count - degree
        let samples = min(max(16, spans * 12), 20_000)
        let tMin = knots[degree], tMax = knots[control.count]
        return (0...samples).map { i in
            let t = tMin + (tMax - tMin) * Double(i) / Double(samples)
            return deBoor(t: t, degree: degree, knots: knots, control: control, weights: weights)
        }
    }

    private static func deBoor(t: Double, degree: Int, knots: [Double], control: [SIMD2<Double>], weights: [Double]) -> SIMD2<Double> {
        let n = control.count
        var k = degree
        while k < n - 1, t >= knots[k + 1] { k += 1 }
        var d: [SIMD3<Double>] = (0...degree).map { j in
            let index = k - degree + j
            return SIMD3<Double>(control[index].x * weights[index], control[index].y * weights[index], weights[index])
        }
        for r in 1...degree {
            for j in stride(from: degree, through: r, by: -1) {
                let i = k - degree + j
                let denominator = knots[i + degree - r + 1] - knots[i]
                let alpha = denominator > 0 ? (t - knots[i]) / denominator : 0
                d[j] = d[j - 1] * (1 - alpha) + d[j] * alpha
            }
        }
        let w = d[degree].z == 0 ? 1 : d[degree].z
        return SIMD2<Double>(d[degree].x / w, d[degree].y / w)
    }
}

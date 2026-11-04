import Foundation

/// Admits one model import at a time, first come first served. Each import
/// can peak at many gigabytes; opening several large files at once used to
/// run them all concurrently. A waiter whose task is cancelled (its window
/// closed) leaves the queue and throws CancellationError.
///
/// The app uses the shared gate; the Quick Look extensions are separate
/// processes with their own limits.
actor CADImportGate {
    static let shared = CADImportGate()

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isBusy = false
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    /// Runs `body` on the shared gate. `whileWaiting` is called (on the gate)
    /// if the import has to queue behind another one.
    static func run<T: Sendable>(
        whileWaiting: (@Sendable () -> Void)? = nil,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await shared.run(whileWaiting: whileWaiting, body)
    }

    nonisolated func run<T: Sendable>(
        whileWaiting: (@Sendable () -> Void)? = nil,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(whileWaiting: whileWaiting)
        let result: T
        do {
            // Cancelled while the slot was being handed over: don't start.
            try Task.checkCancellation()
            result = try await body()
        } catch {
            await release()
            throw error
        }
        await release()
        return result
    }

    /// Number of queued waiters (tests).
    var waiterCount: Int { waiters.count }
    /// Whether an import holds the slot (tests).
    var isHeld: Bool { isBusy }

    private func acquire(whileWaiting: (@Sendable () -> Void)?) async throws {
        try Task.checkCancellation()
        guard isBusy else {
            isBusy = true
            return
        }
        nextID += 1
        let id = nextID
        whileWaiting?()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // onCancel may already have run (and found nothing to remove).
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Hands the slot straight to the next waiter (it stays busy), or frees it.
    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        // Absent if the waiter was already handed the slot; it then releases
        // the slot itself through run's cancellation check.
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

import Foundation
import TheirCore

@MainActor
protocol ExpenseRepository: AnyObject {
    func load() throws -> [Expense]
    func save(_ draft: ExpenseDraft, editing: URL?) throws -> Expense
    func delete(_ references: [URL]) throws
}

/// The application owns this state; removing the last UI observer never resets it.
@MainActor
final class ExpenseStore {
    private let repository: any ExpenseRepository
    private let channel: ExpenseStateChannel
    private let states: Their.Hub<ExpenseState, Never>
    private(set) var state = ExpenseState()
    private var loadedExpenses: [Expense] = []
    private let deletionDelay: @Sendable (UInt64) async throws -> Void
    private var deletionGeneration = 0
    private var deletionCancellation: Their.WorkCancel?

    init(repository: any ExpenseRepository,
         deletionDelay: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.repository = repository
        self.deletionDelay = deletionDelay
        let channel = ExpenseStateChannel()
        self.channel = channel
        states = Their.Hub<ExpenseState, Never> { report in
            MainActor.assumeIsolated { channel.connect(report) }
        }.shareLatest()
        reload()
    }

    /// Subscribers and state changes are confined to MainActor; cancellation is thread-safe.
    func observe(_ sink: @escaping @Sendable (ExpenseState) -> Void) -> Their.HubCancel {
        states.subscribe { event in
            if case let .value(state) = event { sink(state) }
        }
    }

    deinit { deletionCancellation?() }

    func reload() {
        reload(deletion: state.deletion)
    }

    /// The app owner, rather than a row or a toast, owns the deletion lifecycle.
    @discardableResult
    func beginDeletion(_ reference: URL) -> Bool {
        guard !state.deletion.isCommitting,
              !state.deletion.references.contains(reference),
              loadedExpenses.contains(where: { $0.reference == reference }) else { return false }
        deletionGeneration += 1
        let generation = deletionGeneration
        deletionCancellation?()
        deletionCancellation = nil
        var deletion = state.deletion
        deletion.references.insert(reference)
        deletion.failure = nil
        publish(deletion: deletion)
        // A synchronous Hub observer may have undone or extended the batch.
        guard deletionGeneration == generation else { return true }
        let delay = deletionDelay
        let job = Their.Job<Void, ExpenseFailure>.once(failure: { ExpenseFailure($0) }) { @MainActor [weak self] in
            try await delay(4_000_000_000)
            try Task.checkCancellation()
            guard let self, self.deletionGeneration == generation else { return }
            self.commitDeletion()
        }
        deletionCancellation = job.subscribe { [weak self] event in
            if case let .failure(failure) = event {
                Task { @MainActor [weak self] in
                    guard let self, self.deletionGeneration == generation else { return }
                    self.finishDeletion(failure: failure)
                }
            }
        }
        return true
    }

    func undoDeletion() {
        guard state.deletion.canUndo else { return }
        deletionGeneration += 1
        deletionCancellation?()
        deletionCancellation = nil
        // Reload includes other committed and tentative edits; Undo changes no context.
        reload(deletion: ExpenseDeletionState())
    }

    func clearDeletionFailure() {
        var deletion = state.deletion
        deletion.failure = nil
        publish(deletion: deletion)
    }

    private func commitDeletion() {
        guard state.deletion.canUndo else { return }
        var deletion = state.deletion
        deletion.isCommitting = true
        publish(deletion: deletion)
        do {
            try repository.delete(deletion.references.sorted { $0.absoluteString < $1.absoluteString })
            // Keep known committed facts even if the following read fails.
            loadedExpenses.removeAll { deletion.references.contains($0.reference) }
            finishDeletion(failure: nil)
        } catch {
            finishDeletion(failure: ExpenseFailure(error))
        }
    }

    private func finishDeletion(failure: ExpenseFailure?) {
        deletionCancellation = nil
        var deletion = ExpenseDeletionState()
        deletion.failure = failure
        // Clear the projection and reload atomically: no stale row flashes after commit.
        reload(deletion: deletion)
    }

    private func reload(deletion: ExpenseDeletionState) {
        var next = state
        next.deletion = deletion
        do {
            loadedExpenses = try repository.load()
            next.failure = nil
        } catch {
            next.failure = ExpenseFailure(error)
        }
        next.expenses = loadedExpenses.filter { !deletion.references.contains($0.reference) }
        publish(next)
    }

    private func publish(deletion: ExpenseDeletionState) {
        var next = state
        next.deletion = deletion
        next.expenses = loadedExpenses.filter { !deletion.references.contains($0.reference) }
        publish(next)
    }

    private func publish(_ next: ExpenseState) {
        guard next != state else { return }
        state = next
        channel.send(next)
    }

    /// Each command creates one fresh, cancellable job. IO runs outside Hub evolution.
    func perform(_ command: ExpenseCommand) -> Their.Job<ExpenseMutation, ExpenseFailure> {
        .once(failure: { ExpenseFailure($0) }) { @MainActor [self] in
            // Cancelling before the actor turn starts must not write to the store.
            try Task.checkCancellation()
            let mutation: ExpenseMutation
            switch command {
            case let .save(draft, reference):
                mutation = .saved(try repository.save(draft, editing: reference))
            case let .delete(reference):
                try repository.delete([reference])
                mutation = .deleted(reference)
            }
            // Publish the committed result even if the editor has since gone away.
            reload()
            return mutation
        }
    }
}

/// Hub shares observation, while this source keeps the owner's latest value between lifecycles.
private final class ExpenseStateChannel: Sendable {
    private struct Storage: Sendable {
        var latest = ExpenseState()
        var report: Their.WorkReport<ExpenseState, Never>?
        var generation = 0
    }

    private let lock = Their.Lock(Storage())

    @MainActor
    func connect(_ report: @escaping Their.WorkReport<ExpenseState, Never>) -> Their.WorkCancel {
        let (generation, latest) = lock.withLock { storage in
            storage.generation += 1
            storage.report = report
            return (storage.generation, storage.latest)
        }
        report(.value(latest))
        return { [self] in
            let retired = lock.withLock { storage -> Their.WorkReport<ExpenseState, Never>? in
                guard storage.generation == generation else { return nil }
                let retired = storage.report
                storage.report = nil
                return retired
            }
            withExtendedLifetime(retired) {}
        }
    }

    @MainActor
    func send(_ state: ExpenseState) {
        let report = lock.withLock { storage in
            storage.latest = state
            return storage.report
        }
        report?(.value(state))
    }
}

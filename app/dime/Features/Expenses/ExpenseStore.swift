import Foundation
import TheirCore

@MainActor
protocol ExpenseRepository: AnyObject {
    func load() throws -> [Expense]
    func save(_ draft: ExpenseDraft, editing: URL?) throws -> Expense
    func delete(_ references: [URL]) throws
}

/// Desk owns the snapshot and bindings; the application owns IO and Undo policy.
@MainActor
final class ExpenseStore {
    private let repository: any ExpenseRepository
    private let desk: Their.Desk<ExpenseDeskState>
    private let states: Their.Hub<ExpenseState, Never>
    var state: ExpenseState { desk.current.snapshot }
    private let deletionDelay: @Sendable (UInt64) async throws -> Void
    // Domain fence before irreversible IO, including reentrant Undo during publish.
    private var deletionGeneration = 0

    init(repository: any ExpenseRepository,
         deletionDelay: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.repository = repository
        self.deletionDelay = deletionDelay
        let desk = Their.Desk(ExpenseDeskState())
        self.desk = desk
        states = desk.changes.evolve(initial: ExpenseState?.none) { previous, model -> ExpenseState? in
            guard previous != model.snapshot else { return nil }
            previous = model.snapshot
            return model.snapshot
        }.shareLatest()
        reload()
    }

    /// All this feature's Desk inputs are delivered on MainActor; cancellation is thread-safe.
    func observe(_ sink: @escaping @Sendable (ExpenseState) -> Void) -> Their.HubCancel {
        states.subscribe { event in
            if case let .value(state) = event { sink(state) }
        }
    }

    func reload() {
        reload(deletion: state.deletion)
    }

    /// The app owner, rather than a row or a toast, owns the deletion lifecycle.
    @discardableResult
    func beginDeletion(_ reference: URL) -> Bool {
        guard !state.deletion.isCommitting,
              !state.deletion.references.contains(reference),
              desk.current.loadedExpenses.contains(where: { $0.reference == reference }) else { return false }
        deletionGeneration += 1
        let generation = deletionGeneration
        desk.unbind("deletion")
        var deletion = state.deletion
        deletion.references.insert(reference)
        deletion.failure = nil
        publish(deletion: deletion)
        // A synchronous observer may have undone or extended the batch.
        guard deletionGeneration == generation else { return true }
        let delay = deletionDelay
        // Report on the feature's actor too: Job.once does not inherit the
        // operation's actor for delivery, which could race synchronous UI commands.
        let job = Their.Job<Void, ExpenseFailure> { [weak self] report in
            let task = Task { @MainActor [weak self] in
                do {
                    try await delay(4_000_000_000)
                    try Task.checkCancellation()
                    guard let self, self.deletionGeneration == generation else { return }
                    self.commitDeletion()
                    report(.value(()))
                    report(.finished)
                } catch {
                    report(.failure(ExpenseFailure(error)))
                }
            }
            return { task.cancel() }
        }
        desk.bind(job, id: "deletion") { model, event in
            if case let .failure(failure) = event {
                // A delay failure only changes the projection; IO stays outside reducers.
                model.snapshot.deletion = ExpenseDeletionState()
                model.snapshot.deletion.failure = failure
                model.project()
            }
        }
        return true
    }

    func undoDeletion() {
        guard state.deletion.canUndo else { return }
        deletionGeneration += 1
        desk.unbind("deletion")
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
            let references = deletion.references
            desk.update { model in model.loadedExpenses.removeAll { references.contains($0.reference) } }
            finishDeletion(failure: nil)
        } catch {
            finishDeletion(failure: ExpenseFailure(error))
        }
    }

    private func finishDeletion(failure: ExpenseFailure?) {
        var deletion = ExpenseDeletionState()
        deletion.failure = failure
        // Clear the projection and reload atomically: no stale row flashes after commit.
        reload(deletion: deletion)
    }

    private func reload(deletion: ExpenseDeletionState) {
        let loaded: [Expense]?
        let failure: ExpenseFailure?
        do {
            loaded = try repository.load()
            failure = nil
        } catch {
            loaded = nil
            failure = ExpenseFailure(error)
        }
        desk.update { model in
            if let loaded { model.loadedExpenses = loaded }
            model.snapshot.failure = failure
            model.snapshot.deletion = deletion
            model.project()
        }
    }

    private func publish(deletion: ExpenseDeletionState) {
        desk.update { model in
            model.snapshot.deletion = deletion
            model.project()
        }
    }

    /// Each command creates one fresh, cancellable Job. IO runs outside Desk reducers.
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

/// Cached database facts and their transient UI projection form one value snapshot.
private struct ExpenseDeskState: Sendable {
    var loadedExpenses: [Expense] = []
    var snapshot = ExpenseState()

    mutating func project() {
        snapshot.expenses = loadedExpenses.filter { !snapshot.deletion.references.contains($0.reference) }
    }
}

import Foundation
import TheirCore

@MainActor
protocol ExpenseRepository: AnyObject {
    func delete(_ references: [URL]) throws
    func load() throws -> [Expense]
    func save(_ draft: ExpenseDraft, editing: URL?) throws -> Expense
}

/// One fixed Desk reducer owns the snapshot; the application owns IO and Undo policy.
@MainActor
final class ExpenseStore {
    private let deletionDelay: @Sendable (UInt64) async throws -> Void
    // Domain fence before irreversible IO, including reentrant Undo during publish.
    private var deletionGeneration = 0
    private let desk: Their.Desk<ExpenseDeskState, ExpenseEvent>
    private let repository: any ExpenseRepository
    var state: ExpenseState { desk.current.snapshot }
    private let states: Their.Hub<ExpenseState, Never>

    init(repository: any ExpenseRepository,
         deletionDelay: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.repository = repository
        self.deletionDelay = deletionDelay
        let desk = Their.Desk<ExpenseDeskState, ExpenseEvent>(ExpenseDeskState()) { model, event in
            Self.reduce(&model, event)
        }
        self.desk = desk
        states = desk.changes.evolve(initial: ExpenseState?.none) { previous, model -> ExpenseState? in
            guard previous != model.snapshot else { return nil }
            previous = model.snapshot
            return model.snapshot
        }.shareLatest()
        reload()
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
        desk.send(.deletionRequested(reference))
        // A synchronous observer may have undone or extended the batch.
        guard deletionGeneration == generation else { return true }
        let delay = deletionDelay
        // Report on the feature's actor too: Job.once does not inherit the
        // operation's actor for delivery, which could race synchronous commands.
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
        desk.bind(job, id: "deletion") { event in
            if case .failure(let failure) = event { return .deletionDelayFailed(failure) }
            return nil
        }
        return true
    }

    func clearDeletionFailure() {
        desk.send(.deletionFailureCleared)
    }

    private func commitDeletion() {
        guard state.deletion.canUndo else { return }
        let references = state.deletion.references
        desk.send(.deletionCommitStarted)
        do {
            try repository.delete(references.sorted { $0.absoluteString < $1.absoluteString })
            // Keep known committed facts even if the following read fails.
            desk.send(.deletionCommitted(references))
            finishDeletion(failure: nil)
        } catch {
            finishDeletion(failure: ExpenseFailure(error))
        }
    }

    private func finishDeletion(failure: ExpenseFailure?) {
        // Clear the projection and reload atomically: no stale row flashes after commit.
        desk.send(.deletionFinished(refresh: readExpenses(), failure: failure))
    }

    /// All this feature's Desk inputs are delivered on MainActor; cancellation is thread-safe.
    func observe(_ sink: @escaping @Sendable (ExpenseState) -> Void) -> Their.HubCancel {
        states.subscribe { event in
            if case .value(let state) = event { sink(state) }
        }
    }

    /// Each command creates one fresh, cancellable Job. IO runs outside Desk reducers.
    func perform(_ command: ExpenseCommand) -> Their.Job<ExpenseMutation, ExpenseFailure> {
        .once(failure: { ExpenseFailure($0) }) { @MainActor [self] in
            // Cancelling before the actor turn starts must not write to the store.
            try Task.checkCancellation()
            let mutation: ExpenseMutation
            switch command {
            case .save(let draft, let reference):
                mutation = .saved(try repository.save(draft, editing: reference))
            case .delete(let reference):
                try repository.delete([reference])
                mutation = .deleted(reference)
            }
            // Publish the committed result even if the editor has since gone away.
            reload()
            return mutation
        }
    }

    private func readExpenses() -> Result<[Expense], ExpenseFailure> {
        do { return .success(try repository.load()) }
        catch { return .failure(ExpenseFailure(error)) }
    }

    private nonisolated static func reduce(_ model: inout ExpenseDeskState, _ event: ExpenseEvent) {
        switch event {
        case .deletionCommitStarted:
            model.snapshot.deletion.isCommitting = true
        case .deletionCommitted(let references):
            model.loadedExpenses.removeAll { references.contains($0.reference) }
        case .deletionDelayFailed(let failure):
            model.snapshot.deletion = ExpenseDeletionState()
            model.snapshot.deletion.failure = failure
        case .deletionFailureCleared:
            model.snapshot.deletion.failure = nil
        case .deletionFinished(let refresh, let failure):
            model.snapshot.deletion = ExpenseDeletionState()
            model.snapshot.deletion.failure = failure
            model.refresh(refresh)
        case .deletionRequested(let reference):
            model.snapshot.deletion.references.insert(reference)
            model.snapshot.deletion.failure = nil
        case .deletionUndone(let refresh):
            model.snapshot.deletion = ExpenseDeletionState()
            model.refresh(refresh)
        case .refreshed(let refresh):
            model.refresh(refresh)
        }
        model.project()
    }

    func reload() {
        desk.send(.refreshed(readExpenses()))
    }

    func undoDeletion() {
        guard state.deletion.canUndo else { return }
        deletionGeneration += 1
        desk.unbind("deletion")
        // Reload includes other committed and tentative edits; Undo changes no context.
        desk.send(.deletionUndone(readExpenses()))
    }
}

/// Cached database facts and their transient projection form one value snapshot.
private struct ExpenseDeskState: Sendable {
    var loadedExpenses: [Expense] = []
    var snapshot = ExpenseState()

    mutating func project() {
        snapshot.expenses = loadedExpenses.filter { !snapshot.deletion.references.contains($0.reference) }
    }

    mutating func refresh(_ result: Result<[Expense], ExpenseFailure>) {
        switch result {
        case .failure(let failure):
            snapshot.failure = failure
        case .success(let expenses):
            loadedExpenses = expenses
            snapshot.failure = nil
        }
    }
}

private enum ExpenseEvent: Sendable {
    case deletionCommitStarted
    case deletionCommitted(Set<URL>)
    case deletionDelayFailed(ExpenseFailure)
    case deletionFailureCleared
    case deletionFinished(refresh: Result<[Expense], ExpenseFailure>, failure: ExpenseFailure?)
    case deletionRequested(URL)
    case deletionUndone(Result<[Expense], ExpenseFailure>)
    case refreshed(Result<[Expense], ExpenseFailure>)
}

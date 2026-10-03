import Foundation
import TheirCore

@MainActor
protocol ExpenseRepository: AnyObject {
    func catchUpRecurrences(excluding references: Set<URL>) throws -> ExpenseRecurrenceCommit
    func delete(_ references: [URL]) throws
    func load() throws -> [Expense]
    func save(_ draft: ExpenseDraft, editing: URL?) throws -> Expense
    func stopRecurrence(_ reference: URL) throws -> Expense
}

/// One fixed Desk reducer owns the snapshot; the application owns IO and Undo policy.
@MainActor
final class ExpenseStore {
    private let deletionDelay: @Sendable (UInt64) async throws -> Void
    // Domain fence before irreversible IO, including reentrant Undo during publish.
    private var deletionGeneration = 0
    private let desk: Their.Desk<ExpenseDeskState, ExpenseEvent>
#if DEBUG
    /// Deterministic seam before irreversible recurrence IO, absent from release builds.
    var recurrencePreparationForTests: @Sendable () async throws -> Void = {}
    var recurrenceTaskFinishedForTests: @Sendable () -> Void = {}
#endif
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

    /// Cancels owned work; committed rows and persisted recurrence settings survive.
    func cancelRecurrences() {
        for (operation, token) in desk.current.recurrenceOperations {
            guard desk.current.recurrenceOperations[operation] == token else { continue }
            desk.unbind(operation.bindingID)
            desk.send(.recurrenceEnded(operation, token, failure: nil))
        }
        // Also clear starts queued by a reentrant observer but not yet reduced.
        desk.send(.recurrencesCancelled)
    }

    @discardableResult
    func catchUpRecurrences() -> Bool {
        startRecurrence(.catchUp)
    }

    func clearDeletionFailure() {
        desk.send(.deletionFailureCleared)
    }

    func clearRecurrenceFailure() {
        desk.send(.recurrenceFailureCleared)
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

    private func execute(_ command: ExpenseCommand) throws -> ExpenseMutation {
        try Task.checkCancellation()
        let mutation: ExpenseMutation
        switch command {
        case .catchUpRecurrences:
            mutation = .recurrencesAdvanced(try repository.catchUpRecurrences(excluding: state.deletion.references))
        case .delete(let reference):
            try repository.delete([reference])
            mutation = .deleted(reference)
        case .save(let draft, let reference):
            mutation = .saved(try repository.save(draft, editing: reference))
        case .stopRecurrence(let reference):
            let current = desk.current.resolve(reference)
            guard !state.deletion.references.contains(current) else { throw ExpenseFailure.notFound }
            mutation = .recurrenceStopped(try repository.stopRecurrence(current))
        }
        // A refresh failure cannot discard known committed facts. IO is outside the reducer.
        desk.send(.mutationCommitted(mutation, refresh: readExpenses()))
        return mutation
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
            try execute(command)
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
        case .mutationCommitted(let mutation, let refresh):
            model.apply(mutation)
            model.refresh(refresh)
        case .recurrenceEnded(let operation, let token, let failure):
            guard model.recurrenceOperations[operation] == token else { return }
            model.recurrenceOperations[operation] = nil
            if let failure {
                model.snapshot.recurrence.failedOperation = operation
                model.snapshot.recurrence.failure = failure
            }
        case .recurrenceFailureCleared:
            model.snapshot.recurrence.failedOperation = nil
            model.snapshot.recurrence.failure = nil
        case .recurrenceStarted(let operation, let token):
            model.recurrenceOperations[operation] = token
            if model.snapshot.recurrence.failedOperation == operation {
                model.snapshot.recurrence.failedOperation = nil
                model.snapshot.recurrence.failure = nil
            }
        case .recurrencesCancelled:
            model.recurrenceOperations.removeAll()
        case .refreshed(let refresh):
            model.refresh(refresh)
        }
        model.project()
    }

    func reload() {
        desk.send(.refreshed(readExpenses()))
    }

    func retryRecurrence() {
        guard let operation = state.recurrence.failedOperation else { return }
        startRecurrence(operation)
    }

    @discardableResult
    private func startRecurrence(_ operation: ExpenseRecurrenceOperation) -> Bool {
        guard desk.current.recurrenceOperations[operation] == nil else { return false }
        let token = UUID()
        desk.send(.recurrenceStarted(operation, token))
        // A reentrant send can be queued. Claim the reduced token on the actor turn,
        // rather than treating desk.current immediately after send as an acknowledgement.
#if DEBUG
        let preparation = recurrencePreparationForTests
        let finished = recurrenceTaskFinishedForTests
#endif
        let job = Their.Job<ExpenseMutation, ExpenseFailure> { [weak self] report in
            let task = Task { @MainActor [weak self] in
#if DEBUG
                defer { finished() }
#endif
                guard self?.desk.current.recurrenceOperations[operation] == token else {
                    report(.finished)
                    return
                }
                do {
#if DEBUG
                    try await preparation()
#endif
                    try Task.checkCancellation()
                    guard let self, self.desk.current.recurrenceOperations[operation] == token else {
                        report(.finished)
                        return
                    }
                    let mutation = try self.execute(operation.command)
                    report(.value(mutation))
                    report(.finished)
                } catch {
                    report(.failure(ExpenseFailure(error)))
                }
            }
            return { task.cancel() }
        }
        desk.bind(job, id: operation.bindingID) { event in
            switch event {
            case .failure(let failure): return .recurrenceEnded(operation, token, failure: failure)
            case .value: return .recurrenceEnded(operation, token, failure: nil)
            case .finished: return nil
            }
        }
        return true
    }

    /// Stopping a series persists through restart; it does not remove logged occurrences.
    @discardableResult
    func stopRecurrence(_ reference: URL) -> Bool {
        startRecurrence(.stop(reference))
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
    var recurrenceOperations: [ExpenseRecurrenceOperation: UUID] = [:]
    var snapshot = ExpenseState()
    // Old heads can still be referenced by an already queued UI command in this lifetime.
    var successors: [URL: URL] = [:]

    mutating func apply(_ mutation: ExpenseMutation) {
        switch mutation {
        case .deleted(let reference):
            loadedExpenses.removeAll { $0.reference == reference }
        case .recurrencesAdvanced(let commit):
            replace(commit.expenses)
            successors.merge(commit.successors) { _, current in current }
        case .recurrenceStopped(let expense), .saved(let expense):
            replace([expense])
        }
    }

    mutating func project() {
        snapshot.recurrence.operations = Set(recurrenceOperations.keys)
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

    private mutating func replace(_ expenses: [Expense]) {
        let references = Set(expenses.map(\.reference))
        loadedExpenses.removeAll { references.contains($0.reference) }
        loadedExpenses.append(contentsOf: expenses)
        loadedExpenses.sort {
            if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return $0.reference.absoluteString < $1.reference.absoluteString
        }
    }

    func resolve(_ reference: URL) -> URL {
        var current = reference
        var visited = Set<URL>()
        while let next = successors[current], visited.insert(current).inserted {
            current = next
        }
        return current
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
    case mutationCommitted(ExpenseMutation, refresh: Result<[Expense], ExpenseFailure>)
    case recurrenceEnded(ExpenseRecurrenceOperation, UUID, failure: ExpenseFailure?)
    case recurrenceFailureCleared
    case recurrencesCancelled
    case recurrenceStarted(ExpenseRecurrenceOperation, UUID)
    case refreshed(Result<[Expense], ExpenseFailure>)
}

import Foundation
import TheirCore

@MainActor
protocol ExpenseRepository: AnyObject {
    func load() throws -> [Expense]
    func save(_ draft: ExpenseDraft, editing: URL?) throws -> Expense
    func delete(_ reference: URL) throws
}

/// The application owns this state; removing the last UI observer never resets it.
@MainActor
final class ExpenseStore {
    private let repository: any ExpenseRepository
    private let channel: ExpenseStateChannel
    private let states: Their.Hub<ExpenseState, Never>
    private(set) var state = ExpenseState()

    init(repository: any ExpenseRepository) {
        self.repository = repository
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

    func reload() {
        var next = state
        do {
            next.expenses = try repository.load()
            next.failure = nil
        } catch {
            next.failure = ExpenseFailure(error)
        }
        guard next != state else { return }
        state = next
        channel.send(next)
    }

    /// Each command creates one fresh, cancellable job. IO runs outside Hub evolution.
    func perform(_ command: ExpenseCommand) -> Their.Job<ExpenseMutation, ExpenseFailure> {
        .once(failure: ExpenseFailure.init) { @MainActor [self] in
            // Cancelling before the actor turn starts must not write to the store.
            try Task.checkCancellation()
            let mutation: ExpenseMutation
            switch command {
            case let .save(draft, reference):
                mutation = .saved(try repository.save(draft, editing: reference))
            case let .delete(reference):
                try repository.delete(reference)
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

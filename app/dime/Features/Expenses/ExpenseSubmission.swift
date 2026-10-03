import Combine
import Foundation
import TheirCore

/// A fixed Desk reducer owns editor status; this adapter publishes on MainActor.
@MainActor
final class ExpenseSubmission: ObservableObject {
    private let desk: Their.Desk<Status, Event>
    var isSaving: Bool { desk.current == .saving }
    private var observation: Their.HubCancel?
    @Published private(set) var status: Status = .idle

    private enum Event: Sendable {
        case cancelled
        case saveFailed(String)
        case saveStarted
        case saveSucceeded
    }

    enum Status: Equatable, Sendable {
        case failed(String)
        case idle
        case saved
        case saving
    }

    init() {
        desk = Their.Desk(.idle) { status, event in
            Self.reduce(&status, event)
        }
        observation = desk.changes.subscribe { [weak self] _ in
            Task { @MainActor [weak self] in self?.publishCurrent() }
        }
    }

    deinit { observation?() }

    func cancel() {
        desk.unbind("submission")
        desk.send(.cancelled)
        publishCurrent()
    }

    private func publishCurrent() {
        // Read after entering the actor: an earlier queued callback cannot
        // overwrite a cancellation or a newer submission with its old snapshot.
        let current = desk.current
        if status != current {
            status = current
            // @Published calls observers before assigning: reconcile a reentrant cancel.
            if status != desk.current { publishCurrent() }
        }
    }

    private nonisolated static func reduce(_ status: inout Status, _ event: Event) {
        switch event {
        case .cancelled: status = .idle
        case .saveFailed(let message): status = .failed(message)
        case .saveStarted: status = .saving
        case .saveSucceeded: status = .saved
        }
    }

    func submit(_ command: ExpenseCommand, to store: ExpenseStore) {
        guard !isSaving else { return }
        desk.send(.saveStarted)
        desk.bind(store.perform(command), id: "submission") { event in
            switch event {
            case .value: return .saveSucceeded
            case .failure(let failure): return .saveFailed(failure.localizedDescription)
            case .finished: return nil
            }
        }
        // Install cancellation before a synchronous Combine observer can dismiss us.
        publishCurrent()
    }
}

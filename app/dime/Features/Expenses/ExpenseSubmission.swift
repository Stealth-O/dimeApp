import Combine
import Foundation
import TheirCore

/// Desk owns the editor's state and Job binding; this adapter publishes on MainActor.
@MainActor
final class ExpenseSubmission: ObservableObject {
    enum Status: Equatable, Sendable {
        case idle, saving, saved, failed(String)
    }

    @Published private(set) var status: Status = .idle
    var isSaving: Bool { desk.current == .saving }
    private let desk = Their.Desk<Status>(.idle)
    private var observation: Their.HubCancel?

    init() {
        observation = desk.changes.subscribe { [weak self] _ in
            Task { @MainActor [weak self] in self?.publishCurrent() }
        }
    }

    deinit { observation?() }

    func submit(_ command: ExpenseCommand, to store: ExpenseStore) {
        guard !isSaving else { return }
        desk.update { $0 = .saving }
        desk.bind(store.perform(command), id: "submission") { state, event in
            switch event {
            case .value: state = .saved
            case let .failure(failure): state = .failed(failure.localizedDescription)
            case .finished: break
            }
        }
        // Install cancellation before a synchronous Combine observer can dismiss us.
        publishCurrent()
    }

    func cancel() {
        desk.unbind("submission")
        desk.update { $0 = .idle }
        publishCurrent()
    }

    private func publishCurrent() {
        // Read after entering the actor: an earlier queued UI callback cannot
        // overwrite a cancellation or a newer submission with its old snapshot.
        let current = desk.current
        if status != current {
            status = current
            // @Published calls observers before assigning: reconcile a reentrant cancel.
            if status != desk.current { publishCurrent() }
        }
    }
}

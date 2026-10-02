import Combine
import Foundation
import TheirCore

/// The editor owns the subscription. A dismissed editor cannot receive a late UI result.
@MainActor
final class ExpenseSubmission: ObservableObject {
    enum Status: Equatable {
        case idle, saving, saved, failed(String)
    }

    @Published private(set) var status: Status = .idle
    var isSaving: Bool { status == .saving }
    private var generation = 0
    private var subscription: Their.WorkCancel?

    deinit { subscription?() }

    func submit(_ command: ExpenseCommand, to store: ExpenseStore) {
        guard !isSaving else { return }
        generation += 1
        let token = generation
        status = .saving
        subscription = store.perform(command).subscribe { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, generation == token else { return }
                switch event {
                case .value:
                    status = .saved
                    subscription = nil
                case let .failure(failure):
                    status = .failed(failure.localizedDescription)
                    subscription = nil
                case .finished:
                    break
                }
            }
        }
    }

    func cancel() {
        generation += 1
        subscription?()
        subscription = nil
        status = .idle
    }
}

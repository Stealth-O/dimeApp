import Foundation

/// CoreData stays behind the repository. Jobs and hubs carry immutable values.
struct Expense: Equatable, Sendable {
    let amount: Double
    let category: URL?
    let date: Date?
    let income: Bool
    let note: String
    let recurringCoefficient: Int
    let recurringType: Int
    let reference: URL

    init(reference: URL, note: String, amount: Double, date: Date?, category: URL?,
         income: Bool, recurringType: Int, recurringCoefficient: Int) {
        self.amount = amount
        self.category = category
        self.date = date
        self.income = income
        self.note = note
        self.recurringCoefficient = recurringCoefficient
        self.recurringType = recurringType
        self.reference = reference
    }
}

struct ExpenseDraft: Equatable, Sendable {
    var amount: Double
    var category: URL?
    var date: Date
    var income: Bool
    var note: String
    var recurringCoefficient: Int
    var recurringType: Int

    init(note: String, amount: Double, date: Date, category: URL?, income: Bool,
         recurringType: Int, recurringCoefficient: Int) {
        self.amount = amount
        self.category = category
        self.date = date
        self.income = income
        self.note = note
        self.recurringCoefficient = recurringCoefficient
        self.recurringType = recurringType
    }
}

struct ExpenseState: Equatable, Sendable {
    var deletion = ExpenseDeletionState()
    var expenses: [Expense] = []
    var failure: ExpenseFailure?
    var importState = ExpenseImportState()
    var recurrence = ExpenseRecurrenceState()
}

/// Pending rows are hidden from app projections, but remain in SQLite until commit.
/// A new distinct row restarts the shared four-second window; Undo restores the batch.
struct ExpenseDeletionState: Equatable, Sendable {
    var canUndo: Bool { !references.isEmpty && !isCommitting }
    var failure: ExpenseFailure?
    var isCommitting = false
    var references: Set<URL> = []
}

/// Committed rows plus the successor of each advanced series head.
struct ExpenseRecurrenceCommit: Equatable, Sendable {
    var expenses: [Expense] = []
    var successors: [URL: URL] = [:]
}

enum ExpenseRecurrenceOperation: Hashable, Sendable {
    case catchUp
    case stop(URL)

    var bindingID: String {
        switch self {
        case .catchUp: return "recurrence.catchUp"
        case .stop(let reference): return "recurrence.stop.\(reference.absoluteString)"
        }
    }

    var command: ExpenseCommand {
        switch self {
        case .catchUp: return .catchUpRecurrences
        case .stop(let reference): return .stopRecurrence(reference)
        }
    }
}

struct ExpenseRecurrenceState: Equatable, Sendable {
    var failedOperation: ExpenseRecurrenceOperation?
    var failure: ExpenseFailure?
    var isRunning: Bool { !operations.isEmpty }
    var operations: Set<ExpenseRecurrenceOperation> = []
}

enum ExpenseFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidAmount
    case invalidRecurrence
    case notFound
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .invalidAmount: return "Enter a non-zero amount."
        case .invalidRecurrence: return "Choose a valid recurrence interval."
        case .notFound: return "This expense or category no longer exists."
        case .persistence: return "Couldn't save this expense. Please try again."
        }
    }

    init(_ error: any Error) {
        self = (error as? ExpenseFailure) ?? .persistence(error.localizedDescription)
    }
}

enum ExpenseCommand: Sendable {
    case catchUpRecurrences
    case delete(URL)
    case save(ExpenseDraft, editing: URL?)
    case stopRecurrence(URL)
}

enum ExpenseMutation: Equatable, Sendable {
    case deleted(URL)
    case imported([Expense])
    case recurrencesAdvanced(ExpenseRecurrenceCommit)
    case recurrenceStopped(Expense)
    case saved(Expense)
}

enum ExpenseTotals {
    /// Matches Dime's inclusive budget dates and exclusion of income/future entries.
    static func spent(_ expenses: [Expense], from start: Date, through end: Date, category: URL? = nil) -> Double {
        expenses.reduce(0) { total, expense in
            guard !expense.income, let date = expense.date, date >= start, date <= end,
                  category == nil || expense.category == category else { return total }
            return total + expense.amount
        }
    }
}

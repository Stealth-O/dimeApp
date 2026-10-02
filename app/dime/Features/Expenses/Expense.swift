import Foundation

/// CoreData stays behind the repository. Jobs and hubs carry immutable values.
struct Expense: Equatable, Sendable {
    let reference: URL
    let note: String
    let amount: Double
    let date: Date?
    let category: URL?
    let income: Bool
    let recurringType: Int
    let recurringCoefficient: Int
}

struct ExpenseDraft: Equatable, Sendable {
    var note: String
    var amount: Double
    var date: Date
    var category: URL?
    var income: Bool
    var recurringType: Int
    var recurringCoefficient: Int
}

struct ExpenseState: Equatable, Sendable {
    var expenses: [Expense] = []
    var failure: ExpenseFailure?
}

enum ExpenseFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidAmount
    case invalidRecurrence
    case notFound
    case persistence(String)

    init(_ error: any Error) {
        self = (error as? ExpenseFailure) ?? .persistence(error.localizedDescription)
    }

    var errorDescription: String? {
        switch self {
        case .invalidAmount: return "Enter a non-zero amount."
        case .invalidRecurrence: return "Choose a valid recurrence interval."
        case .notFound: return "This expense or category no longer exists."
        case .persistence: return "Couldn't save this expense. Please try again."
        }
    }
}

enum ExpenseCommand: Sendable {
    case save(ExpenseDraft, editing: URL?)
    case delete(URL)
}

enum ExpenseMutation: Equatable, Sendable {
    case saved(Expense)
    case deleted(URL)
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

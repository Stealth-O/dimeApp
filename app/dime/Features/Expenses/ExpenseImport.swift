import Foundation
import TheirCore

/// Values captured by the wizard; no managed objects leave their context.
struct ExpenseImportCategory: Equatable, Sendable {
    let income: Bool
    let reference: URL
}

struct ExpenseImportColumns: Equatable, Sendable {
    let amount: Int
    let category: Int
    let date: Int

    var indices: [Int] { [category, note, date, amount] }
    let note: Int

    init(category: Int, note: Int, date: Int, amount: Int) {
        self.amount = amount
        self.category = category
        self.date = date
        self.note = note
    }
}

enum ExpenseImportFailure: Error, Equatable, Sendable, LocalizedError {
    case cancelled
    case emptyFile
    case invalidAmount(row: Int)
    case invalidCategory(row: Int)
    case invalidColumns
    case invalidDate(row: Int)
    case invalidRow(row: Int)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Import cancelled. Nothing was saved."
        case .emptyFile: return "The file contains no transactions."
        case .invalidAmount(let row): return "Row \(row): enter a finite, non-zero amount without currency symbols."
        case .invalidCategory(let row): return "Row \(row): link an existing category before importing."
        case .invalidColumns: return "Choose four different columns for category, note, date and amount."
        case .invalidDate(let row): return "Row \(row): the date does not match the chosen format."
        case .invalidRow(let row): return "Row \(row): a chosen column is missing."
        case .persistence: return "Couldn't save the import. Nothing was saved. Please try again."
        }
    }

    init(_ error: any Error) {
        if error is CancellationError { self = .cancelled }
        else { self = (error as? Self) ?? .persistence(error.localizedDescription) }
    }
}

enum ExpenseImportOutput: Sendable {
    case committed(Int)
    case progress(ExpenseImportProgress)
}

struct ExpenseImportProgress: Equatable, Sendable {

    let phase: Phase
    let preparedRows: Int
    let totalRows: Int
    enum Phase: Equatable, Sendable {
        case preparing
        case saving
    }
}

struct ExpenseImportRequest: Equatable, Sendable {
    let categories: [String: ExpenseImportCategory]
    let columns: ExpenseImportColumns
    let dateFormat: String
    var localeIdentifier = Locale.current.identifier
    let rows: [[String]]

    func draft(at index: Int, formatter: DateFormatter) throws -> ExpenseDraft {
        let row = rows[index]
        let number = index + 1
        guard columns.indices.allSatisfy({ row.indices.contains($0) }) else {
            throw ExpenseImportFailure.invalidRow(row: number)
        }
        guard let category = categories[row[columns.category]] else {
            throw ExpenseImportFailure.invalidCategory(row: number)
        }
        guard let date = formatter.date(from: row[columns.date]) else {
            throw ExpenseImportFailure.invalidDate(row: number)
        }
        guard let amount = Double(row[columns.amount]), amount.isFinite, amount != 0 else {
            throw ExpenseImportFailure.invalidAmount(row: number)
        }
        return ExpenseDraft(note: row[columns.note], amount: abs(amount), date: date,
            category: category.reference, income: category.income, recurringType: 0, recurringCoefficient: 1)
    }

    func validate() throws {
        guard !rows.isEmpty else { throw ExpenseImportFailure.emptyFile }
        guard columns.indices.allSatisfy({ $0 >= 0 }), Set(columns.indices).count == 4 else {
            throw ExpenseImportFailure.invalidColumns
        }
        guard !dateFormat.isEmpty else { throw ExpenseImportFailure.invalidDate(row: 1) }
    }
}

struct ExpenseImportState: Equatable, Sendable {

    var canCancel: Bool { status == .running && phase == .preparing }
    var canRetry: Bool {
        switch status {
        case .cancelled, .failed: return true
        case .cancelling, .idle, .running, .succeeded: return false
        }
    }
    var isRunning: Bool { status == .running || status == .cancelling }
    var phase = ExpenseImportProgress.Phase.preparing
    var preparedRows = 0
    var status = Status.idle
    var totalRows = 0
    enum Status: Equatable, Sendable {
        case cancelled
        case cancelling
        case failed(ExpenseImportFailure)
        case idle
        case running
        case succeeded(Int)
    }
}

/// Cancellation is checked on the CoreData queue, where Task-local cancellation
/// is unavailable. Once save is claimed, cancellation cannot undo the transaction.
final class ExpenseImportControl: Sendable {

    private let phase = Their.Lock(Phase.preparing)

    func beginCommit() throws {
        try phase.withLock { value in
            if value == .cancelled { throw CancellationError() }
            value = .saving
        }
    }

    func cancel() {
        phase.withLock { value in
            if value == .preparing { value = .cancelled }
        }
    }

    func checkCancellation() throws {
        try phase.withLock { value in
            if value == .cancelled { throw CancellationError() }
        }
    }
    private enum Phase: Sendable {
        case cancelled
        case preparing
        case saving
    }
}

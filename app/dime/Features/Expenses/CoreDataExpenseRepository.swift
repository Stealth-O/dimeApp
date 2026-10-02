import CoreData
import Foundation

@MainActor
final class CoreDataExpenseRepository: ExpenseRepository {
    private let viewContext: NSManagedObjectContext
    private let writer: NSManagedObjectContext
    private let didCommit: () -> Void

    init(context: NSManagedObjectContext, didCommit: @escaping () -> Void = {}) {
        precondition(context.concurrencyType == .mainQueueConcurrencyType)
        viewContext = context
        writer = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        writer.persistentStoreCoordinator = context.persistentStoreCoordinator
        self.didCommit = didCommit
    }

    func load() throws -> [Expense] {
        let request = Transaction.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        // Include tentative legacy changes, such as the list's undoable deletion.
        return try viewContext.fetch(request).map(Self.snapshot).sorted { lhs, rhs in
            if lhs.date != rhs.date { return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast) }
            return lhs.reference.absoluteString < rhs.reference.absoluteString
        }
    }

    func save(_ draft: ExpenseDraft, editing reference: URL?) throws -> Expense {
        guard draft.amount.isFinite, draft.amount != 0 else { throw ExpenseFailure.invalidAmount }
        guard (0...3).contains(draft.recurringType), draft.recurringType == 0 ||
                (1...Int(Int16.max) / 7).contains(draft.recurringCoefficient) else {
            throw ExpenseFailure.invalidRecurrence
        }
        writer.reset()
        defer { writer.reset() }

        let category: Category?
        if let reference = draft.category {
            category = try existing(reference, as: Category.self)
        } else {
            category = nil
        }
        let transaction: Transaction
        if let reference {
            transaction = try existing(reference, as: Transaction.self)
        } else {
            transaction = Transaction(context: writer)
            transaction.id = UUID()
        }
        transaction.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? category?.wrappedName ?? "" : draft.note.trimmingCharacters(in: .whitespaces)
        transaction.income = draft.income
        if let category { transaction.category = category }
        transaction.amount = draft.amount
        transaction.date = draft.date
        let calendar = Calendar(identifier: .gregorian)
        transaction.day = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: draft.date) ?? draft.date
        transaction.month = calendar.date(from: calendar.dateComponents([.month, .year], from: draft.date)) ?? draft.date
        if draft.recurringType > 0 {
            transaction.onceRecurring = true
            transaction.recurringType = Int16(draft.recurringType)
            transaction.recurringCoefficient = Int16(draft.recurringCoefficient)
            expandRecurrence(transaction)
        } else if reference != nil {
            transaction.onceRecurring = false
            transaction.recurringType = 0
            transaction.recurringCoefficient = Int16(clamping: draft.recurringCoefficient)
        }
        try commit()
        return Self.snapshot(transaction)
    }

    func delete(_ reference: URL) throws {
        writer.reset()
        defer { writer.reset() }
        writer.delete(try existing(reference, as: Transaction.self))
        try commit()
    }

    private func existing<T: NSManagedObject>(_ reference: URL, as type: T.Type) throws -> T {
        guard let id = writer.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: reference),
              let object = try writer.existingObject(with: id) as? T, !object.isDeleted else {
            throw ExpenseFailure.notFound
        }
        return object
    }

    @MainActor
    private final class SaveNotification {
        var value: Notification?
    }

    private func commit() throws {
        let captured = SaveNotification()
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave,
                                                              object: writer, queue: nil) { notification in
            MainActor.assumeIsolated { captured.value = notification }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try writer.save()
        if let notification = captured.value {
            viewContext.mergeChanges(fromContextDidSave: notification)
            viewContext.processPendingChanges()
        }
        didCommit()
    }

    static func snapshot(_ transaction: Transaction) -> Expense {
        Expense(reference: transaction.objectID.uriRepresentation(), note: transaction.wrappedNote,
                amount: transaction.amount, date: transaction.date,
                category: transaction.category?.objectID.uriRepresentation(), income: transaction.income,
                recurringType: Int(transaction.recurringType), recurringCoefficient: Int(transaction.recurringCoefficient))
    }

    /// Preserve the editor's existing catch-up behavior, but commit all occurrences atomically.
    private func expandRecurrence(_ transaction: Transaction) {
        let today = Calendar.current.startOfDay(for: Date.now)
        guard transaction.nextTransactionDate <= today else { return }
        var date = transaction.nextTransactionDate
        while date <= today {
            let next = Transaction(context: writer)
            next.note = transaction.wrappedNote
            next.category = transaction.category
            next.amount = transaction.amount
            next.income = transaction.income
            next.date = date
            next.day = date
            next.id = UUID()
            let calendar = Calendar(identifier: .gregorian)
            next.month = calendar.date(from: calendar.dateComponents([.month, .year], from: date))!
            next.onceRecurring = true
            let component: Calendar.Component = transaction.recurringType == 3 ? .month : .day
            let coefficient = Int(transaction.recurringCoefficient) * (transaction.recurringType == 2 ? 7 : 1)
            let following = Calendar.current.date(byAdding: component, value: coefficient, to: date)!
            if following > today {
                next.recurringType = transaction.recurringType
                next.recurringCoefficient = transaction.recurringCoefficient
            }
            date = following
        }
        transaction.recurringType = 0
    }
}

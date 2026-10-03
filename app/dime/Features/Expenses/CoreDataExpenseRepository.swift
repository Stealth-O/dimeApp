import CoreData
import Foundation
import TheirCore

@MainActor
final class CoreDataExpenseRepository: ExpenseRepository {
    private let calendar: @Sendable () -> Calendar
    private let didCommit: () -> Void
    private let now: @Sendable () -> Date
    private let viewContext: NSManagedObjectContext
    private let writer: NSManagedObjectContext

    init(context: NSManagedObjectContext, calendar: @escaping @Sendable () -> Calendar = { .current },
         now: @escaping @Sendable () -> Date = { .now }, didCommit: @escaping () -> Void = {}) {
        precondition(context.concurrencyType == .mainQueueConcurrencyType)
        self.calendar = calendar
        self.didCommit = didCommit
        self.now = now
        viewContext = context
        writer = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        writer.persistentStoreCoordinator = context.persistentStoreCoordinator
    }

    /// Advance persisted heads once, atomically, leaving pending deletion/edit rows alone.
    func catchUpRecurrences(excluding references: Set<URL>) throws -> ExpenseRecurrenceCommit {
        writer.reset()
        defer { writer.reset() }
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "recurringType > 0")
        let transactions = try writer.fetch(request).sorted {
            $0.objectID.uriRepresentation().absoluteString < $1.objectID.uriRepresentation().absoluteString
        }
        let tentative = viewContext.updatedObjects.union(viewContext.deletedObjects)
            .compactMap { ($0 as? Transaction)?.objectID.uriRepresentation() }
        let excluded = references.union(tentative)
        let currentCalendar = calendar()
        let currentDate = now()
        var changed: [Transaction] = []
        var successors: [(Transaction, Transaction)] = []
        for transaction in transactions where !excluded.contains(transaction.objectID.uriRepresentation()) {
            try Task.checkCancellation()
            if let head = try expandRecurrence(transaction, through: currentDate, calendar: currentCalendar, changed: &changed) {
                successors.append((transaction, head))
            }
        }
        guard writer.hasChanges else { return ExpenseRecurrenceCommit() }
        try commit()
        return ExpenseRecurrenceCommit(expenses: changed.map(Self.snapshot), successors: Dictionary(uniqueKeysWithValues:
            successors.map { ($0.0.objectID.uriRepresentation(), $0.1.objectID.uriRepresentation()) }))
    }

    private func commit() throws {
        // The Apple callback records synchronously under the library lock. No actor assertion
        // or asynchronous merge is needed, so unrelated unsaved view-context edits survive.
        let captured = SaveNotification()
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave,
                                                              object: writer, queue: nil) { notification in
            captured.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try Task.checkCancellation()
        try writer.save()
        if let notification = captured.read() {
            viewContext.mergeChanges(fromContextDidSave: notification)
            viewContext.processPendingChanges()
        }
        didCommit()
    }

    func delete(_ references: [URL]) throws {
        guard !references.isEmpty else { return }
        writer.reset()
        defer { writer.reset() }
        var seen = Set<URL>()
        for reference in references where seen.insert(reference).inserted {
            writer.delete(try existing(reference, as: Transaction.self))
        }
        // The batch either commits in full or leaves both SQLite and the UI unchanged.
        try commit()
    }

    private func existing<T: NSManagedObject>(_ reference: URL, as type: T.Type) throws -> T {
        // CoreData raises an Objective-C exception for a non-CoreData URI.
        guard reference.scheme == "x-coredata", reference.host != nil,
              let id = writer.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: reference),
              let object = try writer.existingObject(with: id) as? T, !object.isDeleted else {
            throw ExpenseFailure.notFound
        }
        return object
    }

    @discardableResult
    private func expandRecurrence(_ transaction: Transaction, through date: Date, calendar: Calendar,
                                  changed: inout [Transaction]) throws -> Transaction? {
        let dates = try ExpenseRecurrence.dates(after: transaction.day ?? transaction.date ?? date,
            type: Int(transaction.recurringType), coefficient: Int(transaction.recurringCoefficient),
            through: date, calendar: calendar)
        guard !dates.isEmpty else { return nil }
        let type = transaction.recurringType
        let coefficient = transaction.recurringCoefficient
        var head: Transaction?
        for date in dates {
            try Task.checkCancellation()
            let next = Transaction(context: writer)
            next.note = transaction.wrappedNote
            next.category = transaction.category
            next.amount = transaction.amount
            next.income = transaction.income
            next.date = date
            next.day = date
            next.id = UUID()
            var monthCalendar = Calendar(identifier: .gregorian)
            monthCalendar.timeZone = calendar.timeZone
            next.month = monthCalendar.date(from: monthCalendar.dateComponents([.month, .year], from: date)) ?? date
            next.onceRecurring = true
            changed.append(next)
            head = next
        }
        head?.recurringType = type
        head?.recurringCoefficient = coefficient
        transaction.recurringType = 0
        changed.append(transaction)
        return head
    }

    func load() throws -> [Expense] {
        let request = Transaction.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        // Retain unrelated tentative legacy edits; deletion previews belong to ExpenseStore.
        return try viewContext.fetch(request).map(Self.snapshot).sorted { lhs, rhs in
            if lhs.date != rhs.date { return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast) }
            return lhs.reference.absoluteString < rhs.reference.absoluteString
        }
    }

    func save(_ draft: ExpenseDraft, editing reference: URL?) throws -> Expense {
        guard draft.amount.isFinite, draft.amount != 0 else { throw ExpenseFailure.invalidAmount }
        guard (0...3).contains(draft.recurringType), draft.recurringType == 0 ||
                (1...Int(Int16.max)).contains(draft.recurringCoefficient) else {
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
        var monthCalendar = Calendar(identifier: .gregorian)
        let currentCalendar = calendar()
        monthCalendar.timeZone = currentCalendar.timeZone
        transaction.day = currentCalendar.startOfDay(for: draft.date)
        transaction.month = monthCalendar.date(from: monthCalendar.dateComponents([.month, .year], from: draft.date)) ?? draft.date
        if draft.recurringType > 0 {
            transaction.onceRecurring = true
            transaction.recurringType = Int16(draft.recurringType)
            transaction.recurringCoefficient = Int16(draft.recurringCoefficient)
            var changed: [Transaction] = []
            try expandRecurrence(transaction, through: now(), calendar: currentCalendar, changed: &changed)
        } else if reference != nil {
            transaction.onceRecurring = false
            transaction.recurringType = 0
            transaction.recurringCoefficient = Int16(clamping: draft.recurringCoefficient)
        }
        try commit()
        return Self.snapshot(transaction)
    }

    static func snapshot(_ transaction: Transaction) -> Expense {
        Expense(reference: transaction.objectID.uriRepresentation(), note: transaction.wrappedNote,
                amount: transaction.amount, date: transaction.date,
                category: transaction.category?.objectID.uriRepresentation(), income: transaction.income,
                recurringType: Int(transaction.recurringType), recurringCoefficient: Int(transaction.recurringCoefficient))
    }

    func stopRecurrence(_ reference: URL) throws -> Expense {
        writer.reset()
        defer { writer.reset() }
        let transaction = try existing(reference, as: Transaction.self)
        if transaction.recurringType != 0 {
            transaction.recurringType = 0
            try commit()
        }
        return Self.snapshot(transaction)
    }
}

/// Thin, synchronous Apple notification boundary; every access uses Their.Lock.
private final class SaveNotification: Sendable {
    private let value = Their.Lock<Notification?>(nil)

    func read() -> Notification? {
        value.withLock { $0 }
    }

    func record(_ notification: Notification) {
        value.withLock { $0 = notification }
    }
}

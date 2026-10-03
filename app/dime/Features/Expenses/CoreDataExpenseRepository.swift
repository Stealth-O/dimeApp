import CoreData
import Foundation
import TheirCore

@MainActor
final class CoreDataExpenseRepository: ExpenseRepository {
    private let calendar: @Sendable () -> Calendar
    private let didCommit: () -> Void
#if DEBUG
    /// Synchronous private-queue seam to exercise cancellation immediately before save.
    var importBeforeCommitForTests: @Sendable () throws -> Void = {}
#endif
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

    /// Stage on a private queue and commit the entire file once. The legacy context
    /// never owns tentative imported rows or saves unrelated edits on their behalf.
    func importExpenses(_ request: ExpenseImportRequest, control: ExpenseImportControl,
                        progress: @escaping @Sendable (ExpenseImportProgress) -> Void) async throws -> [Expense] {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = viewContext.persistentStoreCoordinator
        let currentCalendar = calendar()
#if DEBUG
        let beforeCommit = importBeforeCommitForTests
#endif
        return try await withTaskCancellationHandler {
            let expenses = try await context.perform(schedule: .enqueued) {
                defer { context.reset() }
                try control.checkCancellation()
                try request.validate()
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: request.localeIdentifier)
                formatter.timeZone = currentCalendar.timeZone
                formatter.dateFormat = request.dateFormat
                formatter.isLenient = false
                var monthCalendar = Calendar(identifier: .gregorian)
                monthCalendar.timeZone = currentCalendar.timeZone
                var transactions: [Transaction] = []
                var categories: [URL: Category] = [:]
                var categoryRows: [URL: Int] = [:]
                progress(ExpenseImportProgress(phase: .preparing, preparedRows: 0, totalRows: request.rows.count))
                for index in request.rows.indices {
                    try control.checkCancellation()
                    let draft = try request.draft(at: index, formatter: formatter)
                    guard let reference = draft.category else {
                        throw ExpenseImportFailure.invalidCategory(row: index + 1)
                    }
                    let category: Category
                    if let cached = categories[reference] { category = cached }
                    else {
                        guard reference.scheme == "x-coredata", reference.host != nil,
                              let id = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: reference),
                              let existing = try context.existingObject(with: id) as? Category, !existing.isDeleted else {
                            throw ExpenseImportFailure.invalidCategory(row: index + 1)
                        }
                        category = existing
                        categories[reference] = existing
                    }
                    if categoryRows[reference] == nil { categoryRows[reference] = index + 1 }
                    let transaction = Transaction(context: context)
                    transaction.id = UUID()
                    transaction.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? category.wrappedName : draft.note.trimmingCharacters(in: .whitespaces)
                    transaction.amount = draft.amount
                    transaction.category = category
                    transaction.date = draft.date
                    transaction.day = currentCalendar.startOfDay(for: draft.date)
                    transaction.income = draft.income
                    transaction.month = monthCalendar.date(from: monthCalendar.dateComponents([.month, .year], from: draft.date)) ?? draft.date
                    transaction.onceRecurring = false
                    transaction.recurringCoefficient = 1
                    transaction.recurringType = 0
                    transactions.append(transaction)
                    // Bounded notifications, rather than one UI task per row.
                    if (index + 1).isMultiple(of: 128) || index == request.rows.count - 1 {
                        progress(ExpenseImportProgress(phase: .preparing, preparedRows: index + 1, totalRows: request.rows.count))
                    }
                }
                // Import never edits category attributes. Merge only their live-version
                // conflicts, retaining persisted changes; deletion remains an atomic error.
                let mergePolicy = ExpenseImportMergePolicy(categoryRows: categoryRows)
                context.mergePolicy = mergePolicy
#if DEBUG
                try beforeCommit()
#endif
                try control.beginCommit()
                progress(ExpenseImportProgress(phase: .saving, preparedRows: request.rows.count, totalRows: request.rows.count))
                do { try context.save() }
                catch {
                    // CoreData's Objective-C error bridge erases our domain error type.
                    if let failure = mergePolicy.failure { throw failure }
                    throw error
                }
                return transactions.map(Self.snapshot)
            }
            // CoreData's documented remote-save boundary accepts immutable URI arrays;
            // no private-context managed objects or save notifications cross queues.
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [
                NSInsertedObjectsKey: expenses.map(\.reference),
                NSUpdatedObjectsKey: Array(Set(expenses.compactMap(\.category)))
            ], into: [viewContext])
            viewContext.processPendingChanges()
            didCommit()
            return expenses
        } onCancel: {
            control.cancel()
        }
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

    nonisolated static func snapshot(_ transaction: Transaction) -> Expense {
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

/// Only live category revisions may merge during an insert-only import.
/// Native property merging owns relationship reconciliation; deleted categories
/// and conflicts involving any other entity fail the entire transaction.
private final class ExpenseImportMergePolicy: NSMergePolicy {
    private let categoryRows: [URL: Int]
    private(set) var failure: ExpenseImportFailure?

    init(categoryRows: [URL: Int]) {
        self.categoryRows = categoryRows
        super.init(merge: .mergeByPropertyStoreTrumpMergePolicyType)
    }

    override func resolve(optimisticLockingConflicts list: [NSMergeConflict]) throws {
        for conflict in list {
            guard let category = conflict.sourceObject as? Category,
                  let row = categoryRows[category.objectID.uriRepresentation()] else {
                let failure = ExpenseImportFailure.persistence("Concurrent change outside imported categories")
                self.failure = failure
                throw failure
            }
            guard conflict.newVersionNumber > 0 else {
                let failure = ExpenseImportFailure.invalidCategory(row: row)
                self.failure = failure
                throw failure
            }
        }
        try super.resolve(optimisticLockingConflicts: list)
    }
}

import CoreData
import XCTest
import TheirCore
import TheirCoreTesting
@testable import dime

final class ExpenseTests: XCTestCase {
    @MainActor
    func testSQLiteAddEditDeleteAndRestartUpdateListAndBudgets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("expenses.sqlite")
        var fixture = try Fixture(url: url)
        let category = fixture.category("Food")
        let other = fixture.category("Travel")
        try fixture.container.viewContext.save()
        let from = Calendar.current.startOfDay(for: Date.now)
        var draft = ExpenseDraft(note: "  Lunch  ", amount: 12.5, date: from,
                                 category: category.objectID.uriRepresentation(), income: false,
                                 recurringType: 0, recurringCoefficient: 1)
        let first = try await mutation(fixture.store, .save(draft, editing: nil))
        guard case let .saved(expense) = first else { return XCTFail("Expected saved expense") }
        XCTAssertEqual(fixture.store.state.expenses.map(\.note), ["Lunch"])
        XCTAssertEqual(100 - spent(fixture.store, from: from), 87.5)
        XCTAssertEqual(spent(fixture.store, from: from, category: other.objectID.uriRepresentation()), 0)

        draft.note = "Edited lunch"
        draft.amount = 25
        _ = try await mutation(fixture.store, .save(draft, editing: expense.reference))
        XCTAssertEqual(fixture.store.state.expenses.count, 1)
        XCTAssertEqual(fixture.store.state.expenses.first?.note, "Edited lunch")
        XCTAssertEqual(100 - spent(fixture.store, from: from), 75)
        XCTAssertEqual(category.transactions?.count, 1, "Merge updates existing CoreData relationships")
        try fixture.close()

        fixture = try Fixture(url: url)
        XCTAssertEqual(fixture.store.state.expenses.count, 1)
        XCTAssertEqual(fixture.store.state.expenses.first?.reference, expense.reference)
        XCTAssertEqual(fixture.store.state.expenses.first?.amount, 25)
        XCTAssertEqual(100 - spent(fixture.store, from: from), 75)
        _ = try await mutation(fixture.store, .delete(expense.reference))
        XCTAssertTrue(fixture.store.state.expenses.isEmpty)
        XCTAssertEqual(100 - spent(fixture.store, from: from), 100)
        try fixture.close()

        fixture = try Fixture(url: url)
        XCTAssertTrue(fixture.store.state.expenses.isEmpty, "Deletion must survive reopening SQLite")
        try fixture.close()
    }

    @MainActor
    func testBudgetsExcludeIncomeFutureOtherCategoryAndBeforeStart() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let category = fixture.category("Food")
        let other = fixture.category("Travel")
        try fixture.container.viewContext.save()
        let now = Date.now
        let start = now.addingTimeInterval(-100)
        let categoryURL = category.objectID.uriRepresentation()
        for (date, income, reference, amount) in [(start, false, categoryURL, 10.0),
                                                 (now, false, categoryURL, 15),
                                                 (now, true, categoryURL, 100),
                                                 (now.addingTimeInterval(1), false, categoryURL, 40),
                                                 (start.addingTimeInterval(-1), false, categoryURL, 50),
                                                 (now, false, other.objectID.uriRepresentation(), 20)] {
            let draft = ExpenseDraft(note: "", amount: amount, date: date, category: reference,
                                     income: income, recurringType: 0, recurringCoefficient: 1)
            _ = try await mutation(fixture.store, .save(draft, editing: nil))
        }
        XCTAssertEqual(ExpenseTotals.spent(fixture.store.state.expenses, from: start, through: now), 45)
        XCTAssertEqual(ExpenseTotals.spent(fixture.store.state.expenses, from: start, through: now, category: categoryURL), 25)
    }

    @MainActor
    func testReadsLegacyCoreDataRowsWithoutChangingTheirIdentityOrSchema() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let context = fixture.container.viewContext
        let category = fixture.category("Legacy")
        let transaction = Transaction(context: context)
        transaction.id = UUID()
        transaction.note = "Written through upstream CoreData API"
        transaction.amount = 42
        transaction.date = Date.now
        transaction.category = category
        try context.save()
        fixture.store.reload()
        let reference = transaction.objectID.uriRepresentation()
        XCTAssertEqual(fixture.store.state.expenses.first?.reference, reference)
        let draft = ExpenseDraft(note: "", amount: 20, date: transaction.wrappedDate,
                                 category: category.objectID.uriRepresentation(), income: false,
                                 recurringType: 0, recurringCoefficient: 1)
        _ = try await mutation(fixture.store, .save(draft, editing: reference))
        XCTAssertEqual(transaction.note, "Legacy")
        XCTAssertEqual(transaction.amount, 20, "Original fetched object observes committed edit")
        XCTAssertEqual(transaction.objectID.uriRepresentation(), reference)
    }

    @MainActor
    func testInvalidEditLeavesPersistedAndVisibleExpenseUnchanged() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        var draft = ExpenseDraft(note: "Original", amount: 10, date: Date.now, category: nil,
                                 income: false, recurringType: 0, recurringCoefficient: 1)
        guard case let .saved(expense) = try await mutation(fixture.store, .save(draft, editing: nil)) else {
            return XCTFail("Expected saved expense")
        }
        draft.note = "Must not be written"
        draft.amount = .nan
        do {
            _ = try await mutation(fixture.store, .save(draft, editing: expense.reference))
            XCTFail("Expected invalid amount")
        } catch {
            XCTAssertEqual(error as? ExpenseFailure, .invalidAmount)
        }
        XCTAssertEqual(fixture.store.state.expenses.first?.note, "Original")
        XCTAssertEqual(fixture.store.state.expenses.first?.amount, 10)
        XCTAssertFalse(fixture.container.viewContext.hasChanges)
    }

    @MainActor
    func testActualCoreDataSaveFailureDoesNotLeakChangesIntoTheUIOrSQLite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("readonly.sqlite")
        var fixture = try Fixture(url: url)
        var draft = ExpenseDraft(note: "Original", amount: 10, date: Date.now, category: nil,
                                 income: false, recurringType: 0, recurringCoefficient: 1)
        guard case let .saved(expense) = try await mutation(fixture.store, .save(draft, editing: nil)) else {
            return XCTFail("Expected saved expense")
        }
        try fixture.close()
        fixture = try Fixture(url: url, readOnly: true)
        draft.note = "Failed edit"
        draft.amount = 30
        do {
            _ = try await mutation(fixture.store, .save(draft, editing: expense.reference))
            XCTFail("Expected read-only SQLite failure")
        } catch {
            guard let failure = error as? ExpenseFailure, case .persistence = failure else { return XCTFail("Expected storage failure") }
        }
        XCTAssertEqual(fixture.store.state.expenses.first?.note, "Original")
        XCTAssertEqual(fixture.store.state.expenses.first?.amount, 10)
        XCTAssertFalse(fixture.container.viewContext.hasChanges)
        try fixture.close()
        fixture = try Fixture(url: url)
        XCTAssertEqual(fixture.store.state.expenses.first?.amount, 10)
        try fixture.close()
    }

    @MainActor
    func testSavingAnExpenseDoesNotCommitALegacyUndoableDeletion() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let draft = sampleDraft()
        guard case let .saved(expense) = try await mutation(fixture.store, .save(draft, editing: nil)) else {
            return XCTFail("Expected saved expense")
        }
        let context = fixture.container.viewContext
        let id = context.persistentStoreCoordinator!.managedObjectID(forURIRepresentation: expense.reference)!
        context.delete(try context.existingObject(with: id))
        fixture.store.reload()
        XCTAssertTrue(fixture.store.state.expenses.isEmpty)
        _ = try await mutation(fixture.store, .save(draft, editing: nil))
        XCTAssertEqual(fixture.store.state.expenses.count, 1)
        context.rollback()
        fixture.store.reload()
        XCTAssertEqual(fixture.store.state.expenses.count, 2, "Undo must restore the original without losing the committed expense")
    }

    @MainActor
    func testRecurringEditorCatchUpIsSavedWithTheExpense() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let today = Calendar.current.startOfDay(for: Date.now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let draft = ExpenseDraft(note: "Daily", amount: 5, date: yesterday, category: nil,
                                 income: false, recurringType: 1, recurringCoefficient: 1)
        _ = try await mutation(fixture.store, .save(draft, editing: nil))
        XCTAssertEqual(fixture.store.state.expenses.count, 2)
        XCTAssertEqual(fixture.store.state.expenses.filter { $0.recurringType == 1 }.count, 1)
        XCTAssertEqual(ExpenseTotals.spent(fixture.store.state.expenses, from: yesterday, through: Date.now), 10)
    }

    @MainActor
    func testHubSharesUpdatesAndOwnerKeepsStateWithNoObservers() async throws {
        let repository = FakeRepository()
        let store = ExpenseStore(repository: repository)
        let first = Their.TestEventRecorder<ExpenseState>()
        let second = Their.TestEventRecorder<ExpenseState>()
        let cancelFirst = store.observe(first.append)
        let cancelSecond = store.observe(second.append)
        XCTAssertEqual(first.events, [ExpenseState()])
        XCTAssertEqual(second.events, [ExpenseState()])
        _ = try await mutation(store, .save(sampleDraft(), editing: nil))
        XCTAssertEqual(first.last, second.last)
        cancelFirst()
        cancelSecond()
        _ = try await mutation(store, .save(sampleDraft(), editing: nil))
        let late = Their.TestEventRecorder<ExpenseState>()
        let cancelLate = store.observe(late.append)
        defer { cancelLate() }
        XCTAssertEqual(late.events, [store.state])
        XCTAssertEqual(late.last?.expenses.count, 2)
        XCTAssertEqual(first.count, 2, "Detached UI must receive no further updates")
    }

    @MainActor
    func testCancellationBeforeActorTurnDoesNotWriteOrDeliver() async throws {
        let repository = FakeRepository()
        let store = ExpenseStore(repository: repository)
        let recorder = Their.TestEventRecorder<Their.JobEvent<ExpenseMutation, ExpenseFailure>>()
        let cancel = store.perform(.save(sampleDraft(), editing: nil)).subscribe(recorder.append)
        cancel()
        await Task.yield()
        XCTAssertEqual(repository.saveCount, 0)
        XCTAssertEqual(recorder.count, 0)
        XCTAssertTrue(store.state.expenses.isEmpty)
    }

    @MainActor
    func testPersistenceFailureIsReportedAndFreshJobCanRetry() async throws {
        let repository = FakeRepository()
        repository.failSave = true
        let store = ExpenseStore(repository: repository)
        do {
            _ = try await mutation(store, .save(sampleDraft(), editing: nil))
            XCTFail("Expected storage failure")
        } catch {
            XCTAssertEqual(error as? ExpenseFailure, .persistence("Disk unavailable"))
        }
        XCTAssertTrue(store.state.expenses.isEmpty)
        repository.failSave = false
        _ = try await mutation(store, .save(sampleDraft(), editing: nil))
        XCTAssertEqual(store.state.expenses.count, 1)
    }

    @MainActor
    func testEditorRejectsDuplicateSubmissionAndCancelsDismissedWork() async throws {
        let repository = FakeRepository()
        let store = ExpenseStore(repository: repository)
        let editor = ExpenseSubmission()
        let settled = expectation(description: "Editor observes save result")
        let observation = editor.$status.sink { status in
            if status == .saved { settled.fulfill() }
        }
        defer { observation.cancel() }
        editor.submit(.save(sampleDraft(), editing: nil), to: store)
        editor.submit(.save(sampleDraft(), editing: nil), to: store)
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(repository.saveCount, 1)
        editor.submit(.save(sampleDraft(), editing: nil), to: store)
        editor.cancel()
        await Task.yield()
        XCTAssertEqual(editor.status, .idle)
        XCTAssertEqual(repository.saveCount, 1)
    }

    @MainActor
    private func mutation(_ store: ExpenseStore, _ command: ExpenseCommand) async throws -> ExpenseMutation {
        for await event in store.perform(command).stream() {
            switch event {
            case let .value(result): return result
            case let .failure(failure): throw failure
            case .finished: break
            }
        }
        throw ExpenseFailure.persistence("Job ended without a result")
    }

    @MainActor
    private func spent(_ store: ExpenseStore, from start: Date, category: URL? = nil) -> Double {
        ExpenseTotals.spent(store.state.expenses, from: start, through: Date.now, category: category)
    }

    private func sampleDraft() -> ExpenseDraft {
        ExpenseDraft(note: "Test", amount: 10, date: Date.now, category: nil,
                     income: false, recurringType: 0, recurringCoefficient: 1)
    }
}

@MainActor
private final class Fixture {
    let container: NSPersistentContainer
    let store: ExpenseStore

    init(url: URL? = nil, readOnly: Bool = false) throws {
        // Reuse the app's exact model instead of registering competing class/entity descriptions.
        container = NSPersistentContainer(name: "MainModel", managedObjectModel: DataController.shared.container.managedObjectModel)
        let description = NSPersistentStoreDescription()
        description.type = url == nil ? NSInMemoryStoreType : NSSQLiteStoreType
        description.url = url
        if readOnly { description.setOption(true as NSNumber, forKey: NSReadOnlyPersistentStoreOption) }
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        store = ExpenseStore(repository: CoreDataExpenseRepository(context: container.viewContext))
    }

    func category(_ name: String) -> dime.Category {
        let category = dime.Category(context: container.viewContext)
        category.id = UUID()
        category.name = name
        return category
    }

    func close() throws {
        container.viewContext.reset()
        for persistentStore in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(persistentStore)
        }
    }
}

@MainActor
private final class FakeRepository: ExpenseRepository {
    var records: [Expense] = []
    var failSave = false
    var saveCount = 0

    func load() throws -> [Expense] { records }
    func save(_ draft: ExpenseDraft, editing: URL?) throws -> Expense {
        if failSave { throw ExpenseFailure.persistence("Disk unavailable") }
        saveCount += 1
        let record = Expense(reference: editing ?? URL(string: "test://expense/\(UUID())")!, note: draft.note,
                             amount: draft.amount, date: draft.date, category: draft.category,
                             income: draft.income, recurringType: draft.recurringType,
                             recurringCoefficient: draft.recurringCoefficient)
        records.removeAll { $0.reference == record.reference }
        records.append(record)
        return record
    }
    func delete(_ reference: URL) throws { records.removeAll { $0.reference == reference } }
}

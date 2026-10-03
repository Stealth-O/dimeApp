import CoreData
@testable
import dime
import Foundation
import TheirCore
import TheirCoreTesting
import XCTest

final class ImportTests: XCTestCase {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @MainActor
    private func completed(_ store: ExpenseStore, request: ExpenseImportRequest) async throws -> ExpenseImportState {
        let events = Their.TestEventRecorder<ExpenseState>()
        let recording = Their.Lock(false)
        let cancel = store.observe { state in
            if recording.withLock({ $0 }) { events.append(state) }
        }
        defer { cancel() }
        // A Hub replays the previous terminal snapshot at subscription. Wait only
        // for transitions caused by this fresh request, rather than that replay.
        recording.withLock { $0 = true }
        XCTAssertTrue(store.startImport(request))
        let state = try await events.waitForEvent { !$0.importState.isRunning && $0.importState.status != .idle }
        return state.importState
    }

    private static func request(reference: URL = URL(string: "test://category")!, count: Int = 3) -> ExpenseImportRequest {
        ExpenseImportRequest(categories: ["Food": ExpenseImportCategory(income: false, reference: reference)],
            columns: ExpenseImportColumns(category: 0, note: 1, date: 2, amount: 3), dateFormat: "yyyy-MM-dd",
            localeIdentifier: "en_US_POSIX", rows: (0..<count).map { ["Food", "Row \($0)", "2024-01-31", "-5"] })
    }

    @MainActor
    func testCancellationBeforeTheWorkerStartsAndRetryDoNotDuplicateRows() async throws {
        try await Their.stress(timeout: .seconds(3)) { @MainActor in
            let repository = ImportRepository()
            let store = ExpenseStore(repository: repository)
            let finished = Their.TestCountRecorder()
            store.importTaskFinishedForTests = { _ = finished.increment() }
            XCTAssertTrue(store.startImport(Self.request()))
            store.cancelImport()
            XCTAssertFalse(store.startImport(Self.request()))
            try await finished.waitForCount(1)
            XCTAssertEqual(store.state.importState.status, .cancelled)
            XCTAssertEqual(repository.importCount, 0)
            XCTAssertTrue(repository.records.isEmpty)
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe { events.append($0) }
            defer { cancel() }
            store.retryImport()
            _ = try await events.waitForEvent { $0.importState.status == .succeeded(3) }
            XCTAssertEqual(repository.importCount, 1)
            XCTAssertEqual(repository.records.count, 3)
            store.retryImport()
            XCTAssertEqual(repository.importCount, 1)
        }
    }

    @MainActor
    func testCancellationDuringPreparationWaitsForAcknowledgementThenRetries() async throws {
        try await Their.stress(timeout: .seconds(3)) { @MainActor in
            let repository = ImportRepository()
            let gate = Their.TestSignal()
            repository.gate = gate
            let store = ExpenseStore(repository: repository)
            let finished = Their.TestCountRecorder()
            store.importTaskFinishedForTests = { _ = finished.increment() }
            store.startImport(Self.request())
            try await repository.entries.waitForCount(1)
            store.cancelImport()
            XCTAssertEqual(store.state.importState.status, .cancelling)
            store.retryImport()
            XCTAssertFalse(store.startImport(Self.request()))
            try await finished.waitForCount(1)
            XCTAssertEqual(store.state.importState.status, .cancelled)
            XCTAssertEqual(repository.importCount, 1)
            XCTAssertTrue(repository.records.isEmpty)
            repository.gate = nil
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe { events.append($0) }
            defer { cancel() }
            store.retryImport()
            _ = try await events.waitForEvent { $0.importState.status == .succeeded(3) }
            XCTAssertEqual(repository.importCount, 2)
            XCTAssertEqual(repository.records.count, 3)
        }
    }

    @MainActor
    func testCancellationDuringTheCommitStillPublishesSuccessAndCannotRetryIt() async throws {
        try await Their.stress(timeout: .seconds(3)) { @MainActor in
            let repository = ImportRepository()
            let store = ExpenseStore(repository: repository)
            repository.didImport = { [weak store] in store?.cancelImport() }
            let state = try await self.completed(store, request: Self.request())
            XCTAssertEqual(state.status, .succeeded(3))
            XCTAssertFalse(state.canRetry)
            XCTAssertEqual(store.state.expenses.count, 3)
            store.retryImport()
            XCTAssertEqual(repository.importCount, 1)
        }
    }

    @MainActor
    func testCommittedFactsSurviveARefreshFailure() async throws {
        try await Their.stress(timeout: .seconds(3)) { @MainActor in
            let repository = ImportRepository()
            let store = ExpenseStore(repository: repository)
            repository.didImport = { repository.failLoad = true }
            let state = try await self.completed(store, request: Self.request())
            XCTAssertEqual(state.status, .succeeded(3))
            XCTAssertEqual(store.state.expenses.count, 3)
            XCTAssertNotNil(store.state.failure)
            store.retryImport()
            XCTAssertEqual(repository.importCount, 1)
            repository.failLoad = false
            store.reload()
            XCTAssertNil(store.state.failure)
            XCTAssertEqual(store.state.expenses.count, 3)
        }
    }

    @MainActor
    func testFailureRetainsTheExactRequestForOneFreshRetry() async throws {
        try await Their.stress(timeout: .seconds(3)) { @MainActor in
            let repository = ImportRepository()
            repository.failImport = true
            let store = ExpenseStore(repository: repository)
            var request = Self.request()
            request = ExpenseImportRequest(categories: request.categories, columns: request.columns,
                dateFormat: request.dateFormat, localeIdentifier: request.localeIdentifier,
                rows: [["Food", "Captured input", "2024-01-31", "5"]])
            let state = try await self.completed(store, request: request)
            XCTAssertEqual(state.status, .failed(.persistence("Disk unavailable")))
            XCTAssertTrue(store.state.expenses.isEmpty)
            repository.failImport = false
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe { events.append($0) }
            defer { cancel() }
            store.retryImport()
            _ = try await events.waitForEvent { $0.importState.status == .succeeded(1) }
            XCTAssertEqual(repository.requests, [request, request])
            XCTAssertEqual(store.state.expenses.first?.note, "Captured input")
            XCTAssertEqual(repository.importCount, 2)
        }
    }

    @MainActor
    func testImportRunsWithoutObserversAndLateObservationReplaysCurrentState() async throws {
        try await Their.stress(timeout: .seconds(3)) { @MainActor in
            let repository = ImportRepository()
            let store = ExpenseStore(repository: repository)
            let finished = Their.TestCountRecorder()
            store.importTaskFinishedForTests = { _ = finished.increment() }
            store.startImport(Self.request())
            try await finished.waitForCount(1)
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe { events.append($0) }
            defer { cancel() }
            XCTAssertEqual(events.events, [store.state])
            XCTAssertEqual(events.last?.importState.status, .succeeded(3))
        }
    }

    @MainActor
    func testOwnerReleaseCancelsPreparationAndDoesNotRetainTheStore() async throws {
        try await Their.stress(timeout: .seconds(3)) { @MainActor in
            let repository = ImportRepository()
            repository.gate = Their.TestSignal()
            var store: ExpenseStore? = ExpenseStore(repository: repository)
            weak var released = store
            let finished = Their.TestCountRecorder()
            store!.importTaskFinishedForTests = { _ = finished.increment() }
            store!.startImport(Self.request())
            try await repository.entries.waitForCount(1)
            store = nil
            XCTAssertNil(released)
            try await finished.waitForCount(1)
            XCTAssertTrue(repository.records.isEmpty)
            XCTAssertEqual(repository.importCount, 1)
        }
    }

    func testParsingRejectsMissingColumnsInvalidValuesAndUnmatchedCategories() async throws {
        try await Their.stress(timeout: .seconds(3)) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = Self.utc.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            let base = Self.request(count: 1)
            for (row, failure) in [
                (["Food", "Short"], ExpenseImportFailure.invalidRow(row: 1)),
                (["Unknown", "Note", "2024-01-31", "5"], .invalidCategory(row: 1)),
                (["Food", "Note", "not-a-date", "5"], .invalidDate(row: 1)),
                (["Food", "Note", "2024-01-31", "NaN"], .invalidAmount(row: 1)),
                (["Food", "Note", "2024-01-31", "inf"], .invalidAmount(row: 1)),
                (["Food", "Note", "2024-01-31", "0"], .invalidAmount(row: 1)),
                (["Food", "Note", "2024-01-31", "$5"], .invalidAmount(row: 1))
            ] {
                let request = ExpenseImportRequest(categories: base.categories, columns: base.columns,
                    dateFormat: base.dateFormat, rows: [row])
                XCTAssertThrowsError(try request.draft(at: 0, formatter: formatter)) {
                    XCTAssertEqual($0 as? ExpenseImportFailure, failure)
                }
            }
        }
    }

    @MainActor
    func testReentrantCompletionCanStartAnotherImportWithoutClearingItsQueuedState() async throws {
        try await Their.stress(timeout: .seconds(3)) { @MainActor in
            let repository = ImportRepository()
            let store = ExpenseStore(repository: repository)
            let once = Their.Lock(false)
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe { state in
                events.append(state)
                guard state.importState.status == .succeeded(1), once.withLock({ value in
                    guard !value else { return false }; value = true; return true
                }) else { return }
                MainActor.assumeIsolated {
                    store.startImport(Self.request(count: 2))
                    store.clearImport()
                }
            }
            defer { cancel() }
            store.startImport(Self.request(count: 1))
            _ = try await events.waitForEvent { $0.importState.status == .succeeded(2) }
            XCTAssertEqual(repository.importCount, 2)
            XCTAssertEqual(store.state.expenses.count, 3)
            XCTAssertEqual(store.state.importState.totalRows, 2)
        }
    }

    @MainActor
    func testReentrantQueuedStartAndCancellationDoNotReachTheRepository() async throws {
        try await Their.stress(timeout: .seconds(3)) { @MainActor in
            let repository = ImportRepository()
            let store = ExpenseStore(repository: repository)
            let once = Their.Lock(false)
            let finished = Their.TestCountRecorder()
            store.importTaskFinishedForTests = { _ = finished.increment() }
            let cancel = store.observe { state in
                guard state.expenses.count == 1, once.withLock({ value in
                    guard !value else { return false }; value = true; return true
                }) else { return }
                MainActor.assumeIsolated {
                    store.startImport(Self.request())
                    store.cancelImport()
                }
            }
            defer { cancel() }
            repository.records = [ImportRepository.expense(note: "Original")]
            store.reload()
            try await finished.waitForCount(1)
            XCTAssertEqual(store.state.importState.status, .cancelled)
            XCTAssertEqual(repository.importCount, 0)
            XCTAssertEqual(store.state.expenses.map(\.note), ["Original"])
        }
    }

    @MainActor
    func testRepeatedSubmissionIsCoalescedAndProgressCannotOverwriteCompletion() async throws {
        try await Their.stress(timeout: .seconds(3)) { @MainActor in
            let repository = ImportRepository()
            repository.gate = Their.TestSignal()
            let store = ExpenseStore(repository: repository)
            let finished = Their.TestCountRecorder()
            store.importTaskFinishedForTests = { _ = finished.increment() }
            XCTAssertTrue(store.startImport(Self.request()))
            XCTAssertFalse(store.startImport(Self.request(count: 1)))
            try await repository.entries.waitForCount(1)
            repository.gate!.signal()
            try await finished.waitForCount(1)
            XCTAssertEqual(repository.importCount, 1)
            XCTAssertEqual(store.state.importState.status, .succeeded(3))
            XCTAssertEqual(store.state.importState.preparedRows, 3)
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe { events.append($0) }
            defer { cancel() }
            store.reload()
            XCTAssertEqual(store.state.importState.status, .succeeded(3))
        }
    }

    func testRequestValidationRejectsEmptyFilesAndRepeatedOrNegativeColumns() async throws {
        try await Their.stress {
            let base = Self.request()
            for columns in [ExpenseImportColumns(category: 0, note: 0, date: 2, amount: 3),
                            ExpenseImportColumns(category: -1, note: 1, date: 2, amount: 3)] {
                let request = ExpenseImportRequest(categories: base.categories, columns: columns,
                    dateFormat: base.dateFormat, rows: base.rows)
                XCTAssertThrowsError(try request.validate()) { XCTAssertEqual($0 as? ExpenseImportFailure, .invalidColumns) }
            }
            XCTAssertThrowsError(try Self.request(count: 0).validate()) {
                XCTAssertEqual($0 as? ExpenseImportFailure, .emptyFile)
            }
        }
    }

    @MainActor
    func testSQLiteAllRowsCommitOncePreserveFieldsBudgetsAndSurviveReopen() async throws {
        try await Their.stress(count: 10, timeout: .seconds(10)) { @MainActor in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("import.sqlite")
            let fixture = try ImportFixture(url: url)
            let food = try fixture.category("Food")
            let salary = try fixture.category("Salary", income: true)
            let request = ExpenseImportRequest(categories: [
                "Food": ExpenseImportCategory(income: false, reference: food),
                "Salary": ExpenseImportCategory(income: true, reference: salary)
            ], columns: ExpenseImportColumns(category: 0, note: 1, date: 2, amount: 3), dateFormat: "yyyy-MM-dd",
               localeIdentifier: "en_US_POSIX", rows: [
                ["Food", "  Lunch  ", "2024-01-31", "-5"],
                ["Salary", "Pay", "2024-02-01", "100"],
                ["Food", "   ", "2024-02-02", "7"]
            ])
            let state = try await self.completed(fixture.store, request: request)
            XCTAssertEqual(state.status, .succeeded(3))
            XCTAssertEqual(fixture.commits.count, 1)
            XCTAssertFalse(fixture.container.viewContext.hasChanges)
            let records = fixture.store.state.expenses
            XCTAssertEqual(records.map(\.note), ["Food", "Pay", "Lunch"])
            XCTAssertEqual(records.map(\.amount), [7, 100, 5])
            XCTAssertEqual(records.map(\.income), [false, true, false])
            XCTAssertTrue(records.allSatisfy { $0.recurringType == 0 && $0.recurringCoefficient == 1 })
            XCTAssertEqual(ExpenseTotals.spent(records, from: .distantPast, through: .distantFuture), 12)
            for record in records {
                let transaction = try fixture.transaction(record.reference)
                let date = try XCTUnwrap(record.date)
                XCTAssertEqual(transaction.day, Self.utc.startOfDay(for: date))
                XCTAssertEqual(transaction.month, Self.utc.date(from: Self.utc.dateComponents([.month, .year], from: date)))
                XCTAssertFalse(transaction.onceRecurring)
                XCTAssertNotNil(transaction.id)
            }
            try fixture.close()
            let reopened = try ImportFixture(url: url)
            XCTAssertEqual(reopened.store.state.expenses, records)
            XCTAssertEqual(reopened.store.state.importState.status, .idle)
            try reopened.close()
        }
    }

    @MainActor
    func testSQLiteCancellationAfterSaveClaimCannotUndoTheAtomicCommit() async throws {
        try await Their.stress(count: 10, timeout: .seconds(10)) { @MainActor in
            let fixture = try ImportFixture()
            defer { try? fixture.close() }
            let category = try fixture.category("Food")
            let control = ExpenseImportControl()
            let expenses = try await fixture.repository.importExpenses(Self.request(reference: category), control: control) { progress in
                if progress.phase == .saving { control.cancel() }
            }
            XCTAssertEqual(expenses.count, 3)
            XCTAssertEqual(fixture.commits.count, 1)
            XCTAssertEqual(try fixture.container.viewContext.count(for: Transaction.fetchRequest()), 3)
            XCTAssertFalse(fixture.container.viewContext.hasChanges)
        }
    }

    @MainActor
    func testSQLiteCancellationAfterStagingAllRowsSavesNothingAndAllowsRetry() async throws {
        try await Their.stress(count: 10, timeout: .seconds(10)) { @MainActor in
            let fixture = try ImportFixture()
            defer { try? fixture.close() }
            let category = try fixture.category("Food")
            let gate = BlockingImportGate()
            fixture.repository.importBeforeCommitForTests = { try gate.wait() }
            let finished = Their.TestCountRecorder()
            fixture.store.importTaskFinishedForTests = { _ = finished.increment() }
            let progress = Their.TestEventRecorder<ExpenseState>()
            let cancelProgress = fixture.store.observe { progress.append($0) }
            defer { cancelProgress() }
            fixture.store.startImport(Self.request(reference: category, count: 256))
            try await gate.entered.wait()
            defer { gate.open() }
            _ = try await progress.waitForEvent { $0.importState.preparedRows == 256 }
            XCTAssertEqual(fixture.store.state.importState.status, .running)
            XCTAssertTrue(fixture.store.state.importState.canCancel)
            XCTAssertTrue(fixture.store.state.expenses.isEmpty)
            XCTAssertFalse(fixture.container.viewContext.hasChanges)
            XCTAssertEqual(fixture.commits.count, 0)
            fixture.store.cancelImport()
            XCTAssertFalse(fixture.store.startImport(Self.request(reference: category)))
            gate.open()
            try await finished.waitForCount(1)
            XCTAssertEqual(fixture.store.state.importState.status, .cancelled)
            XCTAssertTrue(fixture.store.state.expenses.isEmpty)
            XCTAssertEqual(try fixture.container.viewContext.count(for: Transaction.fetchRequest()), 0)
            fixture.repository.importBeforeCommitForTests = {}
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = fixture.store.observe { events.append($0) }
            defer { cancel() }
            fixture.store.retryImport()
            _ = try await events.waitForEvent { $0.importState.status == .succeeded(256) }
            XCTAssertEqual(fixture.store.state.expenses.count, 256)
            XCTAssertEqual(fixture.commits.count, 1)
        }
    }

    @MainActor
    func testSQLiteCategoryDeletionDuringPreparationFailsTheEntireImport() async throws {
        try await Their.stress(count: 10, timeout: .seconds(10)) { @MainActor in
            let fixture = try ImportFixture()
            defer { try? fixture.close() }
            let category = try fixture.category("Food")
            let gate = BlockingImportGate()
            fixture.repository.importBeforeCommitForTests = { try gate.wait() }
            let finished = Their.TestCountRecorder()
            fixture.store.importTaskFinishedForTests = { _ = finished.increment() }
            fixture.store.startImport(Self.request(reference: category, count: 128))
            try await gate.entered.wait()
            defer { gate.open() }
            let id = try XCTUnwrap(fixture.container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: category))
            let deleted = try fixture.container.viewContext.existingObject(with: id)
            fixture.container.viewContext.delete(deleted)
            try fixture.container.viewContext.save()
            gate.open()
            try await finished.waitForCount(1)
            XCTAssertEqual(fixture.store.state.importState.status, .failed(.invalidCategory(row: 1)))
            XCTAssertTrue(fixture.store.state.expenses.isEmpty)
            XCTAssertEqual(try fixture.container.viewContext.count(for: Transaction.fetchRequest()), 0)
            XCTAssertEqual(fixture.commits.count, 0)
        }
    }

    @MainActor
    func testSQLiteConcurrentEditorSaveSurvivesThePendingImport() async throws {
        try await Their.stress(count: 10, timeout: .seconds(10)) { @MainActor in
            let fixture = try ImportFixture()
            defer { try? fixture.close() }
            let category = try fixture.category("Food")
            let gate = BlockingImportGate()
            fixture.repository.importBeforeCommitForTests = { try gate.wait() }
            let finished = Their.TestCountRecorder()
            fixture.store.importTaskFinishedForTests = { _ = finished.increment() }
            fixture.store.startImport(Self.request(reference: category, count: 128))
            try await gate.entered.wait()
            defer { gate.open() }
            let draft = ExpenseDraft(note: "Concurrent Save", amount: 9,
                date: Date(timeIntervalSince1970: 0), category: category,
                income: false, recurringType: 0, recurringCoefficient: 1)
            for await event in fixture.store.perform(.save(draft, editing: nil)).stream() {
                if case .failure(let failure) = event { throw failure }
            }
            XCTAssertTrue(fixture.store.state.importState.isRunning)
            XCTAssertEqual(fixture.store.state.expenses.map(\.note), ["Concurrent Save"])
            let id = try XCTUnwrap(fixture.container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: category))
            let changed = try XCTUnwrap(try fixture.container.viewContext.existingObject(with: id) as? dime.Category)
            changed.name = "Renamed during import"
            try fixture.container.viewContext.save()
            gate.open()
            try await finished.waitForCount(1)
            XCTAssertEqual(fixture.store.state.importState.status, .succeeded(128))
            XCTAssertEqual(fixture.store.state.expenses.count, 129)
            XCTAssertEqual(fixture.store.state.expenses.filter { $0.note == "Concurrent Save" }.count, 1)
            XCTAssertEqual(fixture.commits.count, 2)
            XCTAssertFalse(fixture.container.viewContext.hasChanges)
            XCTAssertEqual(changed.name, "Renamed during import")
            XCTAssertTrue(fixture.store.state.expenses.allSatisfy { $0.category == category })
        }
    }

    @MainActor
    func testSQLiteImportPreservesUndoAndUnrelatedTentativeChanges() async throws {
        try await Their.stress(count: 10, timeout: .seconds(10)) { @MainActor in
            let deadline = Their.TestSignal()
            let fixture = try ImportFixture(deletionDelay: { _ in try await deadline.wait() })
            defer { try? fixture.close() }
            let category = try fixture.category("Food")
            _ = try await self.completed(fixture.store, request: Self.request(reference: category, count: 1))
            let original = try XCTUnwrap(fixture.store.state.expenses.first)
            XCTAssertTrue(fixture.store.beginDeletion(original.reference))
            let id = try XCTUnwrap(fixture.container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: category))
            let tentative = try XCTUnwrap(try fixture.container.viewContext.existingObject(with: id) as? dime.Category)
            tentative.name = "Tentative name"
            let state = try await self.completed(fixture.store, request: Self.request(reference: category, count: 3))
            XCTAssertEqual(state.status, .succeeded(3))
            XCTAssertTrue(fixture.store.state.deletion.canUndo)
            XCTAssertEqual(fixture.store.state.expenses.count, 3)
            XCTAssertEqual(tentative.name, "Tentative name")
            XCTAssertTrue(fixture.container.viewContext.hasChanges)
            fixture.store.undoDeletion()
            XCTAssertEqual(fixture.store.state.expenses.count, 4)
            XCTAssertEqual(tentative.name, "Tentative name")
            XCTAssertEqual(fixture.commits.count, 2)
        }
    }

    @MainActor
    func testSQLiteInvalidLastRowRollsBackAllStagedRowsAndPreservesExistingData() async throws {
        try await Their.stress(count: 10, timeout: .seconds(10)) { @MainActor in
            let fixture = try ImportFixture()
            defer { try? fixture.close() }
            let category = try fixture.category("Food")
            _ = try await self.completed(fixture.store, request: Self.request(reference: category, count: 1))
            let original = fixture.store.state.expenses
            let valid = Self.request(reference: category, count: 128)
            var rows = valid.rows
            rows.append(["Food", "Bad", "invalid", "5"])
            let request = ExpenseImportRequest(categories: valid.categories, columns: valid.columns,
                dateFormat: valid.dateFormat, rows: rows)
            let state = try await self.completed(fixture.store, request: request)
            XCTAssertEqual(state.status, .failed(.invalidDate(row: 129)))
            XCTAssertEqual(fixture.commits.count, 1)
            XCTAssertEqual(fixture.store.state.expenses, original)
            XCTAssertFalse(fixture.container.viewContext.hasChanges)
            XCTAssertEqual(try fixture.container.viewContext.count(for: Transaction.fetchRequest()), 1)
            let success = try await self.completed(fixture.store, request: valid)
            XCTAssertEqual(success.status, .succeeded(128))
            XCTAssertEqual(fixture.store.state.expenses.count, 129)
            XCTAssertEqual(fixture.commits.count, 2)
        }
    }

    @MainActor
    func testSQLiteLargeImportPreparesOffMainThreadAndUsesBoundedProgress() async throws {
        try await Their.stress(count: 2, timeout: .seconds(20)) { @MainActor in
            let fixture = try ImportFixture()
            defer { try? fixture.close() }
            let category = try fixture.category("Food")
            let progress = Their.TestEventRecorder<ExpenseImportProgress>()
            let threads = Their.TestEventRecorder<Bool>()
            let control = ExpenseImportControl()
            let request = Self.request(reference: category, count: 5_000)
            let expenses = try await fixture.repository.importExpenses(request, control: control) { value in
                progress.append(value)
                threads.append(Thread.isMainThread)
            }
            XCTAssertEqual(expenses.count, 5_000)
            XCTAssertEqual(fixture.commits.count, 1)
            XCTAssertEqual(progress.events.first?.preparedRows, 0)
            XCTAssertEqual(progress.events.last?.phase, .saving)
            XCTAssertEqual(progress.events.last?.preparedRows, 5_000)
            XCTAssertLessThan(progress.events.count, 45)
            XCTAssertTrue(threads.events.allSatisfy { !$0 })
            XCTAssertEqual(progress.events.map(\.preparedRows), progress.events.map(\.preparedRows).sorted())
            XCTAssertEqual(try fixture.container.viewContext.count(for: Transaction.fetchRequest()), 5_000)
        }
    }

    @MainActor
    func testSQLiteMissingCategoryFailsAtomicallyRatherThanSavingOrphanRows() async throws {
        try await Their.stress(count: 10, timeout: .seconds(10)) { @MainActor in
            let fixture = try ImportFixture()
            defer { try? fixture.close() }
            let category = try fixture.category("Food")
            let base = Self.request(reference: category, count: 1)
            let request = ExpenseImportRequest(categories: ["Food": base.categories["Food"]!,
                "Gone": ExpenseImportCategory(income: false, reference: URL(string: "test://invalid")!)],
                columns: base.columns, dateFormat: base.dateFormat,
                rows: [base.rows[0], ["Gone", "Bad", "2024-01-31", "7"]])
            let state = try await self.completed(fixture.store, request: request)
            XCTAssertEqual(state.status, .failed(.invalidCategory(row: 2)))
            XCTAssertTrue(fixture.store.state.expenses.isEmpty)
            XCTAssertEqual(fixture.commits.count, 0)
        }
    }

    @MainActor
    func testSQLiteReadOnlyFailureAndReopenLeaveNoPartialImport() async throws {
        try await Their.stress(count: 10, timeout: .seconds(10)) { @MainActor in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("readonly.sqlite")
            let original = try ImportFixture(url: url)
            let category = try original.category("Food")
            try original.close()
            let readOnly = try ImportFixture(url: url, readOnly: true)
            let state = try await self.completed(readOnly.store, request: Self.request(reference: category, count: 128))
            guard case .failed(.persistence) = state.status else { return XCTFail("Expected read-only store failure") }
            XCTAssertTrue(readOnly.store.state.expenses.isEmpty)
            XCTAssertEqual(readOnly.commits.count, 0)
            XCTAssertFalse(readOnly.container.viewContext.hasChanges)
            try readOnly.close()
            let reopened = try ImportFixture(url: url)
            let success = try await self.completed(reopened.store, request: Self.request(reference: category, count: 128))
            XCTAssertEqual(success.status, .succeeded(128))
            XCTAssertEqual(reopened.store.state.expenses.count, 128)
            try reopened.close()
        }
    }
}

/// The gate blocks only the disposable private CoreData queue. Tests acknowledge
/// staging on MainActor before releasing it; no sleep or absence timeout is used.
private final class BlockingImportGate: Sendable {
    let entered = Their.TestSignal()
    private let release = DispatchSemaphore(value: 0)

    func open() { release.signal() }

    func wait() throws {
        entered.signal()
        release.wait()
    }
}

@MainActor
private final class ImportFixture {
    let commits = Their.TestCountRecorder()
    let container: NSPersistentContainer
    private let ownedDirectory: URL?
    let repository: CoreDataExpenseRepository
    let store: ExpenseStore

    init(url: URL? = nil, readOnly: Bool = false,
         deletionDelay: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) throws {
        container = NSPersistentContainer(name: "MainModel", managedObjectModel: DataController.shared.container.managedObjectModel)
        let description = NSPersistentStoreDescription()
        description.type = NSSQLiteStoreType
        if let url {
            ownedDirectory = nil
            description.url = url
        } else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ownedDirectory = directory
            description.url = directory.appendingPathComponent("import.sqlite")
        }
        description.shouldAddStoreAsynchronously = false
        if readOnly { description.setOption(true as NSNumber, forKey: NSReadOnlyPersistentStoreOption) }
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        let calendar = ImportTests.utcForFixture
        let commits = commits
        repository = CoreDataExpenseRepository(context: container.viewContext, calendar: { calendar },
            didCommit: { _ = commits.increment() })
        store = ExpenseStore(repository: repository, deletionDelay: deletionDelay)
    }

    func category(_ name: String, income: Bool = false) throws -> URL {
        let category = dime.Category(context: container.viewContext)
        category.id = UUID()
        category.name = name
        category.income = income
        try container.viewContext.save()
        return category.objectID.uriRepresentation()
    }

    func close() throws {
        container.viewContext.reset()
        for persistentStore in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(persistentStore)
        }
        if let ownedDirectory { try FileManager.default.removeItem(at: ownedDirectory) }
    }

    func transaction(_ reference: URL) throws -> Transaction {
        let id = try XCTUnwrap(container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: reference))
        return try XCTUnwrap(try container.viewContext.existingObject(with: id) as? Transaction)
    }
}

extension ImportTests {
    fileprivate static var utcForFixture: Calendar { utc }
}

@MainActor
private final class ImportRepository: ExpenseRepository {
    var didImport: () -> Void = {}
    let entries = Their.TestCountRecorder()
    var failImport = false
    var failLoad = false
    var gate: Their.TestSignal?
    var importCount = 0
    var records: [Expense] = []
    var requests: [ExpenseImportRequest] = []

    func catchUpRecurrences(excluding references: Set<URL>) throws -> ExpenseRecurrenceCommit { ExpenseRecurrenceCommit() }

    func delete(_ references: [URL]) throws { records.removeAll { references.contains($0.reference) } }

    static func expense(note: String) -> Expense {
        Expense(reference: URL(string: "test://expense/\(UUID())")!, note: note, amount: 5,
            date: Date(timeIntervalSince1970: 0), category: nil, income: false, recurringType: 0, recurringCoefficient: 1)
    }

    func importExpenses(_ request: ExpenseImportRequest, control: ExpenseImportControl,
                        progress: @escaping @Sendable (ExpenseImportProgress) -> Void) async throws -> [Expense] {
        importCount += 1
        requests.append(request)
        _ = entries.increment()
        progress(ExpenseImportProgress(phase: .preparing, preparedRows: 0, totalRows: request.rows.count))
        if let gate { try await gate.wait() }
        try control.checkCancellation()
        if failImport { throw ExpenseImportFailure.persistence("Disk unavailable") }
        let expenses = request.rows.map { Self.expense(note: $0[1]) }
        progress(ExpenseImportProgress(phase: .preparing, preparedRows: expenses.count, totalRows: expenses.count))
        try control.beginCommit()
        records.append(contentsOf: expenses)
        didImport()
        return expenses
    }

    func load() throws -> [Expense] {
        if failLoad { throw ExpenseFailure.persistence("Read unavailable") }
        return records
    }

    func save(_ draft: ExpenseDraft, editing: URL?) throws -> Expense { throw ExpenseFailure.persistence("Unused save") }

    func stopRecurrence(_ reference: URL) throws -> Expense { throw ExpenseFailure.persistence("Unused stop") }
}

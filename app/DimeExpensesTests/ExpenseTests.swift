import CoreData
@testable
import dime
import TheirCore
import TheirCoreTesting
import XCTest

final class ExpenseTests: XCTestCase {
    @MainActor
    private func mutation(_ store: ExpenseStore, _ command: ExpenseCommand) async throws -> ExpenseMutation {
        for await event in store.perform(command).stream() {
            switch event {
            case .value(let result): return result
            case .failure(let failure): throw failure
            case .finished: break
            }
        }
        throw ExpenseFailure.persistence("Job ended without a result")
    }

    private func sampleDraft() -> ExpenseDraft {
        ExpenseDraft(note: "Test", amount: 10, date: Date.now, category: nil,
                     income: false, recurringType: 0, recurringCoefficient: 1)
    }

    @MainActor
    private func saved(_ store: ExpenseStore, note: String = "Test", amount: Double = 10) async throws -> Expense {
        var draft = sampleDraft()
        draft.note = note
        draft.amount = amount
        guard case .saved(let expense) = try await mutation(store, .save(draft, editing: nil)) else {
            throw ExpenseFailure.persistence("Expected saved expense")
        }
        return expense
    }

    @MainActor
    private func spent(_ store: ExpenseStore, from start: Date, category: URL? = nil) -> Double {
        ExpenseTotals.spent(store.state.expenses, from: start, through: Date.now, category: category)
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
        guard case .saved(let expense) = try await mutation(fixture.store, .save(draft, editing: nil)) else {
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
    func testAppOwnerCommitsWithNoUIObserversAndReplaysOnlyCurrentState() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let delay = ManualDeletionDelay()
            let repository = FakeRepository()
            let committed = Their.TestSignal()
            repository.didDelete = { committed.signal() }
            let store = ExpenseStore(repository: repository, deletionDelay: delay.sleep)
            let expense = try await self.saved(store)
            let first = Their.TestEventRecorder<ExpenseState>()
            let second = Their.TestEventRecorder<ExpenseState>()
            let cancelFirst = store.observe(first.append)
            let cancelSecond = store.observe(second.append)
            store.beginDeletion(expense.reference)
            try await delay.requests.waitForEventCount(1)
            XCTAssertEqual(first.last, second.last)
            cancelFirst()
            cancelSecond()
            delay.expire(0)
            try await committed.wait()
            let late = Their.TestEventRecorder<ExpenseState>()
            let cancelLate = store.observe(late.append)
            defer { cancelLate() }
            XCTAssertEqual(late.events, [store.state])
            XCTAssertTrue(late.last!.expenses.isEmpty)
            XCTAssertFalse(late.last!.deletion.canUndo)
            XCTAssertTrue(first.last!.deletion.canUndo, "Detached observers must receive no commit callback")
        }
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
    func testCommittedDeletionDoesNotResurrectCachedRowsWhenReloadFails() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let delay = ManualDeletionDelay()
            let repository = FakeRepository()
            let store = ExpenseStore(repository: repository, deletionDelay: delay.sleep)
            let expense = try await self.saved(store)
            let recorder = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe(recorder.append)
            defer { cancel() }
            repository.didDelete = { repository.failLoad = true }
            defer { repository.didDelete = {} }
            store.beginDeletion(expense.reference)
            try await delay.requests.waitForEventCount(1)
            delay.expire(0)
            try await recorder.waitForEvent { $0.deletion.references.isEmpty && $0.failure != nil }
            XCTAssertTrue(store.state.expenses.isEmpty)
            XCTAssertEqual(store.state.failure, .persistence("Read unavailable"))
            XCTAssertNil(store.state.deletion.failure, "The deletion committed successfully; only the refresh failed")
            XCTAssertEqual(repository.deletedBatches, [[expense.reference]])
            repository.failLoad = false
            store.reload()
            XCTAssertTrue(store.state.expenses.isEmpty)
            XCTAssertNil(store.state.failure)
        }
    }

    @MainActor
    func testDeadlineDeletesTheWholeBatchAndSQLiteReopenPreservesIt() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("delete.sqlite")
            let delay = ManualDeletionDelay()
            var fixture = try Fixture(url: url, deletionDelay: delay.sleep)
            defer { try? fixture.close() }
            let first = try await self.saved(fixture.store, note: "First", amount: 10)
            let second = try await self.saved(fixture.store, note: "Second", amount: 20)
            let recorder = Their.TestEventRecorder<ExpenseState>()
            let cancel = fixture.store.observe(recorder.append)
            defer { cancel() }
            fixture.store.beginDeletion(first.reference)
            try await delay.requests.waitForEventCount(1)
            fixture.store.beginDeletion(second.reference)
            try await delay.requests.waitForEventCount(2)
            XCTAssertEqual(delay.requests.events.map(\.nanoseconds), [4_000_000_000, 4_000_000_000])
            XCTAssertTrue(fixture.store.state.expenses.isEmpty)
            delay.expire(1)
            try await recorder.waitForEvent { $0.deletion.references.isEmpty && $0.expenses.isEmpty }
            let committedIndex = recorder.events.firstIndex { $0.deletion.isCommitting }!
            XCTAssertTrue(recorder.events[committedIndex...].allSatisfy { $0.expenses.isEmpty }, "Commit must never replay the cached deleted rows")
            XCTAssertFalse(fixture.container.viewContext.hasChanges)
            try fixture.close()
            fixture = try Fixture(url: url)
            XCTAssertTrue(fixture.store.state.expenses.isEmpty)
            XCTAssertEqual(self.spent(fixture.store, from: .distantPast), 0)
        }
    }

    @MainActor
    func testDeletionFailureRestoresWholeBatchAndFreshWindowCanRetry() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let delay = ManualDeletionDelay()
            let repository = FakeRepository()
            let store = ExpenseStore(repository: repository, deletionDelay: delay.sleep)
            let first = try await self.saved(store, note: "First", amount: 10)
            let second = try await self.saved(store, note: "Second", amount: 20)
            let recorder = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe(recorder.append)
            defer { cancel() }
            repository.failDelete = true
            store.beginDeletion(first.reference)
            try await delay.requests.waitForEventCount(1)
            store.beginDeletion(second.reference)
            try await delay.requests.waitForEventCount(2)
            delay.expire(1)
            try await recorder.waitForEvent { $0.deletion.failure != nil }
            XCTAssertEqual(store.state.deletion.failure, .persistence("Disk unavailable"))
            XCTAssertFalse(store.state.deletion.canUndo)
            XCTAssertEqual(store.state.expenses.count, 2)
            XCTAssertEqual(self.spent(store, from: .distantPast), 30)
            XCTAssertTrue(repository.deletedBatches.isEmpty)
            store.clearDeletionFailure()
            XCTAssertNil(store.state.deletion.failure)
            repository.failDelete = false
            store.beginDeletion(first.reference)
            try await delay.requests.waitForEventCount(3)
            store.beginDeletion(second.reference)
            try await delay.requests.waitForEventCount(4)
            delay.expire(3)
            try await recorder.waitForEvent { $0.deletion.references.isEmpty && $0.expenses.isEmpty }
            XCTAssertEqual(repository.deletedBatches.count, 1)
            XCTAssertEqual(Set(repository.deletedBatches[0]), [first.reference, second.reference])
        }
    }

    @MainActor
    func testDeskDelayFailureRestoresTheLatestProjectionWithoutWriting() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let gate = Their.TestSignal()
            let repository = FakeRepository()
            let store = ExpenseStore(repository: repository, deletionDelay: { _ in
                try await gate.wait()
                throw ExpenseFailure.persistence("Timer unavailable")
            })
            let original = try await self.saved(store, note: "Original", amount: 12)
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe(events.append)
            defer { cancel() }
            store.beginDeletion(original.reference)
            _ = try await self.saved(store, note: "Added during Undo", amount: 7)
            gate.signal()
            try await events.waitForEvent { $0.deletion.failure != nil }
            XCTAssertEqual(Set(store.state.expenses.map(\.note)), ["Original", "Added during Undo"])
            XCTAssertEqual(store.state.deletion.failure, .persistence("Timer unavailable"))
            XCTAssertTrue(store.state.deletion.references.isEmpty)
            XCTAssertTrue(repository.deletedBatches.isEmpty)
            store.clearDeletionFailure()
            XCTAssertNil(store.state.deletion.failure)
        }
    }

    @MainActor
    func testDeskRefreshFailureRetainsCachedExpensesAndRecoveryReplacesThem() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let repository = FakeRepository()
            let store = ExpenseStore(repository: repository)
            let original = try await self.saved(store, note: "Cached expense", amount: 12)
            let snapshots = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe(snapshots.append)
            defer { cancel() }
            repository.failLoad = true
            store.reload()
            XCTAssertEqual(store.state.expenses, [original])
            XCTAssertEqual(store.state.failure, .persistence("Read unavailable"))
            XCTAssertEqual(snapshots.count, 2)
            let replacement = Expense(reference: URL(string: "test://expense/reloaded")!,
                                      note: "Reloaded expense", amount: 25, date: original.date,
                                      category: original.category, income: false,
                                      recurringType: 0, recurringCoefficient: 1)
            repository.records = [replacement]
            repository.failLoad = false
            store.reload()
            XCTAssertEqual(store.state.expenses, [replacement])
            XCTAssertNil(store.state.failure)
            XCTAssertEqual(snapshots.count, 3)
            store.reload()
            XCTAssertEqual(snapshots.count, 3, "An unchanged projection must not be published twice")
            XCTAssertEqual(repository.saveCount, 1)
            XCTAssertTrue(repository.deletedBatches.isEmpty)
        }
    }

    @MainActor
    func testDistinctDeletesRestartWindowAndUndoRestoresEntireBatch() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let delay = ManualDeletionDelay()
            let repository = FakeRepository()
            let store = ExpenseStore(repository: repository, deletionDelay: delay.sleep)
            let first = try await self.saved(store, note: "First", amount: 10)
            let second = try await self.saved(store, note: "Second", amount: 20)
            XCTAssertTrue(store.beginDeletion(first.reference))
            try await delay.requests.waitForEventCount(1)
            XCTAssertFalse(store.beginDeletion(first.reference), "Duplicate deletion must not restart the deadline")
            XCTAssertEqual(delay.requests.count, 1)
            XCTAssertTrue(store.beginDeletion(second.reference))
            try await delay.requests.waitForEventCount(2)
            try await delay.completions.waitForCount(1)
            XCTAssertEqual(store.state.deletion.references, [first.reference, second.reference])
            XCTAssertTrue(store.state.expenses.isEmpty)
            XCTAssertTrue(repository.deletedBatches.isEmpty)
            delay.expire(0) // The retired deadline cannot affect the current window.
            store.undoDeletion()
            store.undoDeletion()
            try await delay.completions.waitForCount(2)
            XCTAssertEqual(Set(store.state.expenses.map(\.note)), ["First", "Second"])
            XCTAssertTrue(repository.deletedBatches.isEmpty)
        }
    }

    @MainActor
    func testEditingAndReloadingPendingRowKeepsItHiddenUntilUndo() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let delay = ManualDeletionDelay()
            let store = ExpenseStore(repository: FakeRepository(), deletionDelay: delay.sleep)
            let expense = try await self.saved(store, amount: 10)
            store.beginDeletion(expense.reference)
            try await delay.requests.waitForEventCount(1)
            var draft = self.sampleDraft()
            draft.note = "Concurrent edit"
            draft.amount = 25
            _ = try await self.mutation(store, .save(draft, editing: expense.reference))
            store.reload()
            XCTAssertTrue(store.state.expenses.isEmpty)
            store.undoDeletion()
            try await delay.completions.waitForCount(1)
            XCTAssertEqual(store.state.expenses.first?.amount, 25)
            XCTAssertEqual(store.state.expenses.first?.note, "Concurrent edit")
        }
    }

    @MainActor
    func testEditorCancelledBySavingObserverDoesNotStartPersistenceAndCanRetry() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let repository = FakeRepository()
            let store = ExpenseStore(repository: repository)
            let editor = ExpenseSubmission()
            let statuses = Their.TestEventRecorder<ExpenseSubmission.Status>()
            var cancelled = false
            let observation = editor.$status.sink { status in
                statuses.append(status)
                if status == .saving && !cancelled {
                    cancelled = true
                    editor.cancel()
                }
            }
            defer { observation.cancel() }
            var draft = self.sampleDraft()
            draft.note = "Cancelled before IO"
            editor.submit(.save(draft, editing: nil), to: store)
            XCTAssertEqual(editor.status, .idle)
            XCTAssertFalse(editor.isSaving)
            draft.note = "Fresh retry"
            editor.submit(.save(draft, editing: nil), to: store)
            try await statuses.waitForEvent { $0 == .saved }
            XCTAssertEqual(repository.saveCount, 1)
            XCTAssertEqual(store.state.expenses.map(\.note), ["Fresh retry"])
        }
    }

    @MainActor
    func testEditorFailureRetryAndCancellationFollowOneStatusSequence() async throws {
        try await Their.stress(timeout: .seconds(3)) { @MainActor in
            let repository = FakeRepository()
            repository.failSave = true
            let store = ExpenseStore(repository: repository)
            let editor = ExpenseSubmission()
            let statuses = Their.TestEventRecorder<ExpenseSubmission.Status>()
            let observation = editor.$status.sink { statuses.append($0) }
            defer { observation.cancel() }
            var draft = self.sampleDraft()
            draft.note = "Failed attempt"
            editor.submit(.save(draft, editing: nil), to: store)
            XCTAssertTrue(editor.isSaving)
            try await statuses.waitForEvent { if case .failed = $0 { return true }; return false }
            let message = ExpenseFailure.persistence("Disk unavailable").localizedDescription
            XCTAssertEqual(editor.status, .failed(message))
            XCTAssertFalse(editor.isSaving)
            XCTAssertEqual(repository.saveCount, 0)
            XCTAssertTrue(store.state.expenses.isEmpty)
            repository.failSave = false
            draft.note = "Fresh retry"
            editor.submit(.save(draft, editing: nil), to: store)
            try await statuses.waitForEvent { $0 == .saved }
            XCTAssertEqual(editor.status, .saved)
            XCTAssertEqual(repository.saveCount, 1)
            XCTAssertEqual(store.state.expenses.map(\.note), ["Fresh retry"])
            editor.cancel()
            XCTAssertEqual(editor.status, .idle)
            XCTAssertFalse(editor.isSaving)
            XCTAssertEqual(statuses.events, [.idle, .saving, .failed(message), .saving, .saved, .idle])
            XCTAssertEqual(repository.saveCount, 1, "Cancelling editor status cannot undo a committed save")
        }
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
    func testEditorReplacementDuringCommitPublishesOnlyTheCurrentSubmission() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let repository = FakeRepository()
            let store = ExpenseStore(repository: repository)
            let editor = ExpenseSubmission()
            let statuses = Their.TestEventRecorder<ExpenseSubmission.Status>()
            let observation = editor.$status.sink { statuses.append($0) }
            defer { observation.cancel() }
            let draft = self.sampleDraft()
            repository.didSave = { [weak editor, weak store, weak repository] in
                guard repository?.saveCount == 1, let editor, let store else { return }
                editor.cancel()
                editor.submit(.save(draft, editing: nil), to: store)
            }
            editor.submit(.save(draft, editing: nil), to: store)
            try await statuses.waitForEvent { $0 == .saved }
            XCTAssertEqual(repository.saveCount, 2)
            XCTAssertEqual(store.state.expenses.count, 2, "Cancellation cannot undo an already committed save")
            XCTAssertEqual(statuses.events, [.idle, .saving, .idle, .saving, .saved])
        }
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
    func testInvalidEditLeavesPersistedAndVisibleExpenseUnchanged() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        var draft = ExpenseDraft(note: "Original", amount: 10, date: Date.now, category: nil,
                                 income: false, recurringType: 0, recurringCoefficient: 1)
        guard case .saved(let expense) = try await mutation(fixture.store, .save(draft, editing: nil)) else {
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
    func testInvalidMemberCannotPartiallyCommitTheDeletionBatch() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let fixture = try Fixture()
            defer { try? fixture.close() }
            let expense = try await self.saved(fixture.store)
            var commits = 0
            let repository = CoreDataExpenseRepository(context: fixture.container.viewContext) { commits += 1 }
            XCTAssertThrowsError(try repository.delete([expense.reference, URL(string: "missing://expense")!])) { error in
                XCTAssertEqual(error as? ExpenseFailure, .notFound)
            }
            fixture.store.reload()
            XCTAssertEqual(fixture.store.state.expenses, [expense])
            XCTAssertEqual(commits, 0)
            XCTAssertFalse(fixture.container.viewContext.hasChanges)
        }
    }

    @MainActor
    func testOwnerReleaseCancelsPendingTimerAndLeavesPersistedExpense() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let delay = ManualDeletionDelay()
            let repository = FakeRepository()
            var store: ExpenseStore? = ExpenseStore(repository: repository, deletionDelay: delay.sleep)
            let expense = try await self.saved(store!)
            store!.beginDeletion(expense.reference)
            try await delay.requests.waitForEventCount(1)
            weak var weakStore = store
            store = nil
            try await delay.completions.waitForCount(1)
            XCTAssertNil(weakStore)
            XCTAssertEqual(repository.records, [expense])
            XCTAssertTrue(repository.deletedBatches.isEmpty)
        }
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
    func testRealReadOnlySQLiteDeletionFailureRestoresVisibleRows() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("readonly-delete.sqlite")
            var fixture = try Fixture(url: url)
            defer { try? fixture.close() }
            let expense = try await self.saved(fixture.store, amount: 12)
            try fixture.close()
            let delay = ManualDeletionDelay()
            fixture = try Fixture(url: url, readOnly: true, deletionDelay: delay.sleep)
            let recorder = Their.TestEventRecorder<ExpenseState>()
            let cancel = fixture.store.observe(recorder.append)
            defer { cancel() }
            fixture.store.beginDeletion(expense.reference)
            try await delay.requests.waitForEventCount(1)
            delay.expire(0)
            try await recorder.waitForEvent { $0.deletion.failure != nil }
            guard case .persistence = fixture.store.state.deletion.failure else { return XCTFail("Expected SQLite failure") }
            XCTAssertEqual(fixture.store.state.expenses, [expense])
            XCTAssertEqual(self.spent(fixture.store, from: .distantPast), 12)
            XCTAssertFalse(fixture.container.viewContext.hasChanges)
            try fixture.close()
            fixture = try Fixture(url: url)
            XCTAssertEqual(fixture.store.state.expenses, [expense])
        }
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
    func testReentrantUndoDuringDeskPublishDoesNotStartADeadline() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let delay = ManualDeletionDelay()
            let store = ExpenseStore(repository: FakeRepository(), deletionDelay: delay.sleep)
            let original = try await self.saved(store, note: "Original", amount: 12)
            let cancel = store.observe { [weak store] snapshot in
                if snapshot.deletion.canUndo {
                    MainActor.assumeIsolated { store?.undoDeletion() }
                }
            }
            defer { cancel() }
            XCTAssertTrue(store.beginDeletion(original.reference))
            XCTAssertEqual(store.state.expenses.map(\.reference), [original.reference])
            XCTAssertFalse(store.state.deletion.canUndo)
            XCTAssertTrue(delay.requests.events.isEmpty)
        }
    }

    @MainActor
    func testRestartBeforeDeadlineRetainsTheTentativeDeletion() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("tentative.sqlite")
            let delay = ManualDeletionDelay()
            var fixture: Fixture? = try Fixture(url: url, deletionDelay: delay.sleep)
            let expense = try await self.saved(fixture!.store)
            fixture!.store.beginDeletion(expense.reference)
            try await delay.requests.waitForEventCount(1)
            XCTAssertTrue(fixture!.store.state.expenses.isEmpty)
            try fixture!.close()
            fixture = nil
            try await delay.completions.waitForCount(1)
            let reopened = try Fixture(url: url)
            defer { try? reopened.close() }
            XCTAssertEqual(reopened.store.state.expenses, [expense], "Only completed deletion commits survive process termination")
        }
    }

    @MainActor
    func testSavingAnExpenseDoesNotCommitALegacyUndoableDeletion() async throws {
        let fixture = try Fixture()
        defer { try? fixture.close() }
        let draft = sampleDraft()
        guard case .saved(let expense) = try await mutation(fixture.store, .save(draft, editing: nil)) else {
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
        guard case .saved(let expense) = first else { return XCTFail("Expected saved expense") }
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
    func testUndoKeepsNewCommittedExpenseAndUnrelatedUnsavedCategoryEdit() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let delay = ManualDeletionDelay()
            let fixture = try Fixture(deletionDelay: delay.sleep)
            defer { try? fixture.close() }
            let category = fixture.category("Food")
            try fixture.container.viewContext.save()
            let original = try await self.saved(fixture.store, note: "Original", amount: 12)
            XCTAssertTrue(fixture.store.beginDeletion(original.reference))
            try await delay.requests.waitForEventCount(1)
            XCTAssertTrue(fixture.store.state.expenses.isEmpty)
            XCTAssertEqual(self.spent(fixture.store, from: .distantPast), 0)

            _ = try await self.saved(fixture.store, note: "New expense", amount: 7)
            category.name = "Unsaved category edit"
            fixture.store.reload()
            fixture.store.undoDeletion()
            try await delay.completions.waitForCount(1)
            XCTAssertEqual(Set(fixture.store.state.expenses.map(\.note)), ["Original", "New expense"])
            XCTAssertEqual(self.spent(fixture.store, from: .distantPast), 19)
            XCTAssertEqual(category.name, "Unsaved category edit")
            XCTAssertTrue(fixture.container.viewContext.hasChanges, "Undo must not save or roll back another feature")
            XCTAssertFalse(fixture.store.state.deletion.canUndo)
        }
    }

    @MainActor
    func testUndoWinsWhenDeadlineWakesBeforeItsActorTurn() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let delay = ManualDeletionDelay()
            let repository = FakeRepository()
            let store = ExpenseStore(repository: repository, deletionDelay: delay.sleep)
            let expense = try await self.saved(store)
            let recorder = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe(recorder.append)
            defer { cancel() }
            store.beginDeletion(expense.reference)
            try await delay.requests.waitForEventCount(1)
            delay.expire(0)
            store.undoDeletion() // No suspension: the deadline's MainActor turn has not run.
            try await delay.completions.waitForCount(1)
            XCTAssertEqual(store.state.expenses, [expense])
            XCTAssertTrue(repository.deletedBatches.isEmpty)
            store.beginDeletion(expense.reference)
            try await delay.requests.waitForEventCount(2)
            delay.expire(1)
            try await recorder.waitForEvent { $0.deletion.references.isEmpty && $0.expenses.isEmpty }
            XCTAssertEqual(repository.deletedBatches, [[expense.reference]], "Only the fresh lifecycle may commit")
            store.undoDeletion()
            XCTAssertTrue(store.state.expenses.isEmpty, "Undo after a completed commit is a no-op")
        }
    }
}

@MainActor
private final class Fixture {
    let container: NSPersistentContainer
    let store: ExpenseStore

    init(url: URL? = nil, readOnly: Bool = false,
         deletionDelay: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) throws {
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
        store = ExpenseStore(repository: CoreDataExpenseRepository(context: container.viewContext), deletionDelay: deletionDelay)
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
    var deletedBatches: [[URL]] = []
    var didDelete: () -> Void = {}
    var didSave: () -> Void = {}
    var failDelete = false
    var failLoad = false
    var failSave = false
    var records: [Expense] = []
    var saveCount = 0

    func catchUpRecurrences(excluding references: Set<URL>) throws -> ExpenseRecurrenceCommit {
        ExpenseRecurrenceCommit()
    }

    func delete(_ references: [URL]) throws {
        if failDelete { throw ExpenseFailure.persistence("Disk unavailable") }
        deletedBatches.append(references)
        records.removeAll { references.contains($0.reference) }
        didDelete()
    }

    func load() throws -> [Expense] {
        if failLoad { throw ExpenseFailure.persistence("Read unavailable") }
        return records
    }

    func save(_ draft: ExpenseDraft, editing: URL?) throws -> Expense {
        if failSave { throw ExpenseFailure.persistence("Disk unavailable") }
        saveCount += 1
        let record = Expense(reference: editing ?? URL(string: "test://expense/\(UUID())")!, note: draft.note,
                             amount: draft.amount, date: draft.date, category: draft.category,
                             income: draft.income, recurringType: draft.recurringType,
                             recurringCoefficient: draft.recurringCoefficient)
        records.removeAll { $0.reference == record.reference }
        records.append(record)
        didSave()
        return record
    }

    func stopRecurrence(_ reference: URL) throws -> Expense {
        guard let record = records.first(where: { $0.reference == reference }) else { throw ExpenseFailure.notFound }
        return record
    }

}

/// Deterministic deadlines: tests release a specific request instead of sleeping or polling.
@MainActor
private final class ManualDeletionDelay {
    let completions = Their.TestCountRecorder()
    let requests = Their.TestEventRecorder<Request>()

    func expire(_ index: Int) {
        requests.events[index].gate.signal()
    }

    func sleep(_ nanoseconds: UInt64) async throws {
        let request = Request(gate: Their.TestSignal(), nanoseconds: nanoseconds)
        requests.append(request)
        defer { _ = completions.increment() }
        try await request.gate.wait()
    }

    struct Request: Sendable {
        let gate: Their.TestSignal
        let nanoseconds: UInt64
    }
}

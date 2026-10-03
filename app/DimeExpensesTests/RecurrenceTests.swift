import CoreData
@testable
import dime
import Foundation
import TheirCore
import TheirCoreTesting
import XCTest

final class RecurrenceTests: XCTestCase {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(_ value: String, calendar: Calendar = utc) -> Date {
        let parts = value.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    @MainActor
    private func mutation(_ store: ExpenseStore, _ command: ExpenseCommand) async throws -> ExpenseMutation {
        for await event in store.perform(command).stream() {
            switch event {
            case .failure(let failure): throw failure
            case .finished: break
            case .value(let mutation): return mutation
            }
        }
        throw ExpenseFailure.persistence("Job ended without a result")
    }

    func testCalendarDailyAndWeeklyIntervalsIncludeTodayAndSkipTheOriginal() async throws {
        try await Their.stress {
            let anchor = Self.date("2024-01-01")
            let now = Self.date("2024-01-07").addingTimeInterval(43_200)
            XCTAssertEqual(try ExpenseRecurrence.dates(after: anchor, type: 1, coefficient: 2,
                through: now, calendar: Self.utc), ["2024-01-03", "2024-01-05", "2024-01-07"].map { Self.date($0) })
            XCTAssertEqual(try ExpenseRecurrence.dates(after: anchor, type: 2, coefficient: 2,
                through: Self.date("2024-02-01"), calendar: Self.utc), ["2024-01-15", "2024-01-29"].map { Self.date($0) })
        }
    }

    func testCalendarDayAndWeekAdvanceByLocalDatesAcrossBothDSTBoundaries() async throws {
        try await Their.stress {
            var calendar = Self.utc
            calendar.timeZone = TimeZone(identifier: "Europe/Athens")!
            for (start, end, middle, hours) in [
                ("2024-03-30", "2024-04-01", "2024-03-31", 23.0),
                ("2024-10-26", "2024-10-28", "2024-10-27", 25.0)
            ] {
                let dates = try ExpenseRecurrence.dates(after: Self.date(start, calendar: calendar), type: 1,
                    coefficient: 1, through: Self.date(end, calendar: calendar), calendar: calendar)
                XCTAssertEqual(dates, [Self.date(middle, calendar: calendar), Self.date(end, calendar: calendar)])
                XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), hours * 3_600)
                XCTAssertEqual(try ExpenseRecurrence.next(after: Self.date(start, calendar: calendar), type: 2,
                    coefficient: 1, calendar: calendar), calendar.date(byAdding: .day, value: 7, to: Self.date(start, calendar: calendar)))
                XCTAssertTrue(dates.allSatisfy { calendar.component(.hour, from: $0) == 0 })
            }
        }
    }

    func testCalendarFutureAndNonRecurringInputsProduceNoOccurrences() async throws {
        try await Their.stress {
            for (anchor, today, type, coefficient) in [
                ("2024-01-01", "2024-01-01", 1, 1),
                ("2024-01-02", "2024-01-01", 1, 1),
                ("2024-01-01", "2024-01-02", 2, 1),
                ("2024-01-01", "2024-01-31", 3, 1),
                ("2024-01-01", "2024-12-31", 0, 0)
            ] {
                XCTAssertEqual(try ExpenseRecurrence.dates(after: Self.date(anchor), type: type,
                    coefficient: coefficient, through: Self.date(today), calendar: Self.utc), [])
            }
        }
    }

    func testCalendarInvalidIntervalsFailAndTheLargestPersistedCoefficientDoesNotOverflow() async throws {
        try await Their.stress {
            for type in [-1, 1, 2, 3, 4] {
                for coefficient in [-1, 0, 1, Int(Int16.max) + 1] where !(1...3).contains(type) || coefficient != 1 {
                    XCTAssertThrowsError(try ExpenseRecurrence.next(after: Self.date("2024-01-01"), type: type,
                        coefficient: coefficient, calendar: Self.utc)) { error in
                        XCTAssertEqual(error as? ExpenseFailure, .invalidRecurrence)
                    }
                }
            }
            for type in 1...3 {
                XCTAssertGreaterThan(try ExpenseRecurrence.next(after: Self.date("2024-01-01"), type: type,
                    coefficient: Int(Int16.max), calendar: Self.utc), Self.date("2024-01-01"))
            }
        }
    }

    func testCalendarMonthlyIntervalsRetainRollingMonthEndBehavior() async throws {
        try await Their.stress {
            for (anchor, end, expected) in [
                ("2023-01-31", "2023-03-31", ["2023-02-28", "2023-03-28"]),
                ("2024-01-31", "2024-03-31", ["2024-02-29", "2024-03-29"]),
                ("2024-11-30", "2025-01-30", ["2024-12-30", "2025-01-30"])
            ] {
                XCTAssertEqual(try ExpenseRecurrence.dates(after: Self.date(anchor), type: 3, coefficient: 1,
                    through: Self.date(end), calendar: Self.utc), expected.map { Self.date($0) })
            }
            XCTAssertEqual(try ExpenseRecurrence.dates(after: Self.date("2024-01-31"), type: 3, coefficient: 2,
                through: Self.date("2024-07-31"), calendar: Self.utc), ["2024-03-31", "2024-05-31", "2024-07-31"].map { Self.date($0) })
        }
    }

    @MainActor
    func testCancelAfterCommitKeepsTheFactsAndNoLongerStopsTheSeries() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let repository = RecurrenceRepository()
            let original = repository.records[0]
            let store = ExpenseStore(repository: repository)
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe { events.append($0) }
            defer { cancel() }
            store.catchUpRecurrences()
            _ = try await events.waitForEvent { !$0.recurrence.isRunning && $0.expenses.count == 2 }
            let committed = store.state.expenses
            store.cancelRecurrences()
            XCTAssertEqual(store.state.expenses, committed)
            XCTAssertEqual(repository.catchUpCount, 1)
            XCTAssertEqual(repository.stopCount, 0)
            XCTAssertEqual(committed.filter { $0.recurringType > 0 }.count, 1)
            XCTAssertEqual(committed.first { $0.reference == original.reference }?.recurringType, 0)
        }
    }

    @MainActor
    func testCancellationBeforeIOAndRepeatedStartUseOnlyTheFreshLifecycle() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let repository = RecurrenceRepository()
            let store = ExpenseStore(repository: repository)
            let gate = RecurrenceGate()
            store.recurrencePreparationForTests = { try await gate.wait() }
            let original = store.state.expenses
            XCTAssertTrue(store.catchUpRecurrences())
            XCTAssertFalse(store.catchUpRecurrences())
            try await gate.entries.waitForCount(1)
            store.cancelRecurrences()
            try await gate.completions.waitForCount(1)
            XCTAssertFalse(store.state.recurrence.isRunning)
            XCTAssertEqual(store.state.expenses, original)
            XCTAssertEqual(repository.catchUpCount, 0)
            store.recurrencePreparationForTests = {}
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe { events.append($0) }
            defer { cancel() }
            store.catchUpRecurrences()
            _ = try await events.waitForEvent { !$0.recurrence.isRunning && $0.expenses.count == 2 }
            XCTAssertEqual(repository.catchUpCount, 1)
            XCTAssertNil(store.state.recurrence.failure)
        }
    }

    @MainActor
    func testCancellationDuringACommitKeepsNewFactsAndDoesNotRollBackTheDatabase() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let repository = RecurrenceRepository()
            let store = ExpenseStore(repository: repository)
            let finished = Their.TestCountRecorder()
            store.recurrenceTaskFinishedForTests = { _ = finished.increment() }
            repository.didCatchUp = { [weak store] in store?.cancelRecurrences() }
            store.catchUpRecurrences()
            try await finished.waitForCount(1)
            XCTAssertEqual(repository.catchUpCount, 1)
            XCTAssertFalse(store.state.recurrence.isRunning)
            XCTAssertNil(store.state.recurrence.failure)
            XCTAssertEqual(store.state.expenses.count, 2)
            XCTAssertEqual(store.state.expenses, try repository.load())
            XCTAssertEqual(store.state.expenses.filter { $0.recurringType > 0 }.count, 1)
        }
    }

    @MainActor
    func testCatchUpAndStopSurviveSQLiteReopenWithoutDuplicates() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("recurrence.sqlite")
            let clock = RecurrenceClock(Self.date("2024-01-04"))
            var fixture = try RecurrenceFixture(clock: clock, url: url)
            let original = try fixture.seed(date: Self.date("2024-01-01"))
            _ = try await self.mutation(fixture.store, .catchUpRecurrences)
            let first = fixture.store.state.expenses
            XCTAssertEqual(first.count, 4)
            let head = try XCTUnwrap(first.first { $0.recurringType > 0 })
            XCTAssertEqual(head.date, Self.date("2024-01-04"))
            XCTAssertEqual(first.first { $0.reference == original.reference }?.recurringType, 0)
            try fixture.close()
            fixture = try RecurrenceFixture(clock: clock, url: url)
            _ = try await self.mutation(fixture.store, .catchUpRecurrences)
            XCTAssertEqual(fixture.store.state.expenses, first)
            XCTAssertEqual(fixture.commits.count, 0, "A repeated check does not write or notify widgets")
            _ = try await self.mutation(fixture.store, .stopRecurrence(head.reference))
            let stopped = fixture.store.state.expenses
            XCTAssertEqual(stopped.count, 4)
            XCTAssertTrue(stopped.allSatisfy { $0.recurringType == 0 })
            XCTAssertEqual(Set(stopped.map(\.reference)), Set(first.map(\.reference)))
            try fixture.close()
            clock.set(Self.date("2024-01-10"))
            fixture = try RecurrenceFixture(clock: clock, url: url)
            _ = try await self.mutation(fixture.store, .catchUpRecurrences)
            XCTAssertEqual(fixture.store.state.expenses, stopped)
            XCTAssertEqual(fixture.commits.count, 0)
            try fixture.close()
        }
    }

    @MainActor
    func testCatchUpCommitsWithNoObserversAndLateObservationGetsOnlyTheCurrentSnapshot() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let fixture = try RecurrenceFixture(clock: RecurrenceClock(Self.date("2024-01-03")))
            defer { try? fixture.close() }
            _ = try fixture.seed(date: Self.date("2024-01-01"))
            fixture.store.catchUpRecurrences()
            try await fixture.commits.waitForCount(1)
            XCTAssertFalse(fixture.store.state.recurrence.isRunning)
            XCTAssertEqual(fixture.store.state.expenses.count, 3)
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = fixture.store.observe { events.append($0) }
            defer { cancel() }
            XCTAssertEqual(events.events, [fixture.store.state])
        }
    }

    @MainActor
    func testCatchUpFailureRetryAndStopFailureHaveExplicitDeskTransitions() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let repository = RecurrenceRepository()
            let original = repository.records[0]
            repository.failCatchUp = true
            let store = ExpenseStore(repository: repository)
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = store.observe { events.append($0) }
            defer { cancel() }
            store.catchUpRecurrences()
            _ = try await events.waitForEvent { $0.recurrence.failure != nil }
            XCTAssertEqual(store.state.expenses, [original])
            XCTAssertEqual(store.state.recurrence.failedOperation, .catchUp)
            XCTAssertFalse(store.state.recurrence.isRunning)
            repository.failCatchUp = false
            store.retryRecurrence()
            _ = try await events.waitForEvent { !$0.recurrence.isRunning && $0.expenses.count == 2 }
            XCTAssertEqual(repository.catchUpCount, 2)
            XCTAssertNil(store.state.recurrence.failure)
            repository.failStop = true
            store.stopRecurrence(original.reference)
            _ = try await events.waitForEvent { $0.recurrence.failedOperation == .stop(original.reference) }
            XCTAssertEqual(store.state.expenses.filter { $0.recurringType > 0 }.count, 1)
            repository.failStop = false
            store.retryRecurrence()
            _ = try await events.waitForEvent { !$0.recurrence.isRunning && $0.expenses.allSatisfy { $0.recurringType == 0 } }
            XCTAssertEqual(repository.stopCount, 2)
            XCTAssertNil(store.state.recurrence.failure)
            store.clearRecurrenceFailure()
            store.retryRecurrence()
            XCTAssertFalse(store.state.recurrence.isRunning)
        }
    }

    @MainActor
    func testCatchUpPreservesUnsavedCategoryAndSkipsATentativeTransactionEdit() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let fixture = try RecurrenceFixture(clock: RecurrenceClock(Self.date("2024-01-03")))
            defer { try? fixture.close() }
            let category = fixture.category("Food")
            let original = try fixture.seed(date: Self.date("2024-01-01"), category: category)
            category.name = "Unsaved name"
            let object = try fixture.transaction(original.reference)
            object.note = "Tentative note"
            _ = try await self.mutation(fixture.store, .catchUpRecurrences)
            XCTAssertEqual(fixture.store.state.expenses.count, 1)
            XCTAssertEqual(fixture.commits.count, 0)
            XCTAssertEqual(object.recurringType, 1)
            XCTAssertEqual(object.note, "Tentative note")
            fixture.container.viewContext.refresh(object, mergeChanges: false)
            _ = try await self.mutation(fixture.store, .catchUpRecurrences)
            XCTAssertEqual(fixture.store.state.expenses.count, 3)
            XCTAssertEqual(category.name, "Unsaved name")
            XCTAssertTrue(fixture.container.viewContext.hasChanges)
            XCTAssertEqual(category.transactions?.count, 3)
            XCTAssertTrue(fixture.store.state.expenses.allSatisfy { $0.category == category.objectID.uriRepresentation() })
            let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            reader.persistentStoreCoordinator = fixture.container.persistentStoreCoordinator
            let persisted = try XCTUnwrap(try reader.existingObject(with: category.objectID) as? dime.Category)
            XCTAssertEqual(persisted.name, "Food")
        }
    }

    @MainActor
    func testCommittedCatchUpAndStopRemainVisibleWhenRefreshFails() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let repository = RecurrenceRepository()
            let original = repository.records[0]
            let store = ExpenseStore(repository: repository)
            repository.failLoad = true
            _ = try await self.mutation(store, .catchUpRecurrences)
            XCTAssertEqual(store.state.expenses.count, 2)
            XCTAssertNotNil(store.state.failure)
            _ = try await self.mutation(store, .stopRecurrence(original.reference))
            XCTAssertEqual(store.state.expenses.count, 2)
            XCTAssertTrue(store.state.expenses.allSatisfy { $0.recurringType == 0 })
            repository.failLoad = false
            store.reload()
            XCTAssertNil(store.state.failure)
            XCTAssertEqual(store.state.expenses, try repository.load())
        }
    }

    @MainActor
    func testEditorAndRuntimeUseTheSameMonthlyCatchUp() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let clock = RecurrenceClock(Self.date("2024-03-31"))
            let editor = try RecurrenceFixture(clock: clock)
            let runtime = try RecurrenceFixture(clock: clock)
            defer { try? editor.close(); try? runtime.close() }
            let draft = ExpenseDraft(note: "Rent", amount: 5, date: Self.date("2024-01-31"), category: nil,
                income: false, recurringType: 3, recurringCoefficient: 1)
            _ = try await self.mutation(editor.store, .save(draft, editing: nil))
            _ = try runtime.seed(date: draft.date, type: 3, note: draft.note)
            _ = try await self.mutation(runtime.store, .catchUpRecurrences)
            XCTAssertEqual(editor.store.state.expenses.map(\.date), runtime.store.state.expenses.map(\.date))
            XCTAssertEqual(editor.store.state.expenses.map(\.recurringType), runtime.store.state.expenses.map(\.recurringType))
            XCTAssertEqual(editor.store.state.expenses.filter { $0.recurringType == 3 }.count, 1)
            XCTAssertEqual(editor.commits.count, 1, "The editor and all its occurrences save atomically")
        }
    }

    @MainActor
    func testInvalidPersistedIntervalAbortsTheWholeBatchAndCanBeStopped() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            for (type, coefficient) in [(1, 0), (1, -1), (4, 1)] {
                let fixture = try RecurrenceFixture(clock: RecurrenceClock(Self.date("2024-01-03")))
                defer { try? fixture.close() }
                _ = try fixture.seed(date: Self.date("2024-01-01"), note: "Valid")
                let invalid = try fixture.seed(date: Self.date("2024-01-01"), type: type, coefficient: coefficient, note: "Invalid")
                let original = fixture.store.state.expenses
                do {
                    _ = try await self.mutation(fixture.store, .catchUpRecurrences)
                    XCTFail("Expected invalid persisted recurrence")
                } catch {
                    XCTAssertEqual(error as? ExpenseFailure, .invalidRecurrence)
                }
                XCTAssertEqual(fixture.store.state.expenses, original)
                XCTAssertEqual(fixture.commits.count, 0)
                XCTAssertFalse(fixture.container.viewContext.hasChanges)
                _ = try await self.mutation(fixture.store, .stopRecurrence(invalid.reference))
                _ = try await self.mutation(fixture.store, .catchUpRecurrences)
                XCTAssertEqual(fixture.store.state.expenses.count, 4)
                XCTAssertEqual(fixture.store.state.expenses.filter { $0.recurringType > 0 }.count, 1)
            }
        }
    }

    @MainActor
    func testOwnerReleaseCancelsPreparationWithoutRetainingTheOwnerOrWriting() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let repository = RecurrenceRepository()
            let gate = RecurrenceGate()
            var owner: ExpenseStore? = ExpenseStore(repository: repository)
            weak var released = owner
            defer { released = nil }
            owner?.recurrencePreparationForTests = { try await gate.wait() }
            owner?.catchUpRecurrences()
            try await gate.entries.waitForCount(1)
            owner = nil
            XCTAssertNil(released)
            try await gate.completions.waitForCount(1)
            XCTAssertEqual(repository.catchUpCount, 0)
            XCTAssertEqual(repository.records.count, 1)
        }
    }

    @MainActor
    func testPendingDeletionSkipsARecurringHeadUntilUndoAndRejectsStop() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let delay = RecurrenceGate()
            let fixture = try RecurrenceFixture(clock: RecurrenceClock(Self.date("2024-01-03")), deletionDelay: { _ in try await delay.wait() })
            defer { try? fixture.close() }
            let original = try fixture.seed(date: Self.date("2024-01-01"))
            fixture.store.beginDeletion(original.reference)
            try await delay.entries.waitForCount(1)
            _ = try await self.mutation(fixture.store, .catchUpRecurrences)
            XCTAssertTrue(fixture.store.state.expenses.isEmpty)
            XCTAssertEqual(fixture.commits.count, 0)
            do {
                _ = try await self.mutation(fixture.store, .stopRecurrence(original.reference))
                XCTFail("Pending deletion is not a live recurrence target")
            } catch { XCTAssertEqual(error as? ExpenseFailure, .notFound) }
            fixture.store.undoDeletion()
            try await delay.completions.waitForCount(1)
            _ = try await self.mutation(fixture.store, .catchUpRecurrences)
            XCTAssertEqual(fixture.store.state.expenses.count, 3)
            XCTAssertFalse(fixture.store.state.deletion.canUndo)
        }
    }

    @MainActor
    func testReadOnlySQLiteCatchUpAndStopFailWithoutPartialChanges() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("readonly.sqlite")
            let clock = RecurrenceClock(Self.date("2024-01-03"))
            var fixture = try RecurrenceFixture(clock: clock, url: url)
            let original = try fixture.seed(date: Self.date("2024-01-01"))
            try fixture.close()
            fixture = try RecurrenceFixture(clock: clock, url: url, readOnly: true)
            for command in [ExpenseCommand.catchUpRecurrences, .stopRecurrence(original.reference)] {
                do {
                    _ = try await self.mutation(fixture.store, command)
                    XCTFail("Expected read-only save failure")
                } catch {
                    guard let failure = error as? ExpenseFailure, case .persistence = failure else { return XCTFail("Expected persistence failure") }
                }
                XCTAssertEqual(fixture.store.state.expenses, [original])
                XCTAssertFalse(fixture.container.viewContext.hasChanges)
            }
            XCTAssertEqual(fixture.commits.count, 0)
            try fixture.close()
            fixture = try RecurrenceFixture(clock: clock, url: url)
            XCTAssertEqual(fixture.store.state.expenses, [original])
            _ = try await self.mutation(fixture.store, .catchUpRecurrences)
            XCTAssertEqual(fixture.store.state.expenses.count, 3)
            try fixture.close()
        }
    }

    @MainActor
    func testReentrantCancellationDuringPublishDoesNotBeginPreparationOrWrite() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let repository = RecurrenceRepository()
            let store = ExpenseStore(repository: repository)
            let gate = RecurrenceGate()
            store.recurrencePreparationForTests = { try await gate.wait() }
            let finished = Their.TestCountRecorder()
            store.recurrenceTaskFinishedForTests = { _ = finished.increment() }
            let cancel = store.observe { [weak store] state in
                // Deliberately reentrant test-only probe: owner events are MainActor delivery.
                if state.recurrence.isRunning { MainActor.assumeIsolated { store?.cancelRecurrences() } }
            }
            XCTAssertTrue(store.catchUpRecurrences())
            XCTAssertFalse(store.state.recurrence.isRunning)
            try await finished.waitForCount(1)
            XCTAssertEqual(gate.entries.count, 0, "The cancelled token never begins preparation")
            XCTAssertEqual(repository.catchUpCount, 0)
            cancel()
        }
    }

    @MainActor
    func testReentrantStartFromAnObserverCompletesAndBothOrdersStopTheSeries() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let repository = RecurrenceRepository()
            let original = repository.records[0]
            let store = ExpenseStore(repository: repository)
            let started = Their.Lock(false)
            let events = Their.TestEventRecorder<ExpenseState>()
            let observer = store.observe { [weak store] state in
                events.append(state)
                guard state.recurrence.operations.contains(.catchUp), started.withLock({ value in
                    guard !value else { return false }
                    value = true
                    return true
                }) else { return }
                // The nested start is queued behind the current Desk reduction.
                MainActor.assumeIsolated { _ = store?.stopRecurrence(original.reference) }
            }
            defer { observer() }
            store.catchUpRecurrences()
            _ = try await events.waitForEvent { !$0.recurrence.isRunning && $0.expenses.allSatisfy { $0.recurringType == 0 } }
            XCTAssertEqual(repository.catchUpCount, 1)
            XCTAssertEqual(repository.stopCount, 1)
            XCTAssertNil(store.state.recurrence.failure)
        }
    }

    @MainActor
    func testReentrantStartThenCancelClearsQueuedStartsBeforeEitherCanWrite() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let repository = RecurrenceRepository()
            let original = repository.records[0]
            let store = ExpenseStore(repository: repository)
            let started = Their.Lock(false)
            let finished = Their.TestCountRecorder()
            store.recurrenceTaskFinishedForTests = { _ = finished.increment() }
            let observer = store.observe { [weak store] state in
                guard state.recurrence.operations.contains(.catchUp), started.withLock({ value in
                    guard !value else { return false }
                    value = true
                    return true
                }) else { return }
                MainActor.assumeIsolated {
                    store?.stopRecurrence(original.reference)
                    store?.cancelRecurrences()
                }
            }
            defer { observer() }
            store.catchUpRecurrences()
            try await finished.waitForCount(2)
            XCTAssertFalse(store.state.recurrence.isRunning)
            XCTAssertEqual(store.state.expenses, [original])
            XCTAssertEqual(repository.catchUpCount, 0)
            XCTAssertEqual(repository.stopCount, 0)
        }
    }

    @MainActor
    func testStopBeforeCatchUpIOPreventsOccurrencesAndCancellationBeforeStopPreservesTheSeries() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let fixture = try RecurrenceFixture(clock: RecurrenceClock(Self.date("2024-01-03")))
            defer { try? fixture.close() }
            let original = try fixture.seed(date: Self.date("2024-01-01"))
            let gate = RecurrenceGate()
            fixture.store.recurrencePreparationForTests = { try await gate.wait() }
            fixture.store.stopRecurrence(original.reference)
            try await gate.entries.waitForCount(1)
            fixture.store.cancelRecurrences()
            try await gate.completions.waitForCount(1)
            XCTAssertEqual(fixture.commits.count, 0)
            XCTAssertEqual(fixture.store.state.expenses, [original])
            fixture.store.catchUpRecurrences()
            try await gate.entries.waitForCount(2)
            _ = try await self.mutation(fixture.store, .stopRecurrence(original.reference))
            gate.signal.signal()
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = fixture.store.observe { events.append($0) }
            defer { cancel() }
            _ = try await events.waitForEvent { !$0.recurrence.isRunning }
            XCTAssertEqual(fixture.store.state.expenses.count, 1)
            XCTAssertEqual(fixture.store.state.expenses.first?.recurringType, 0)
            XCTAssertEqual(fixture.commits.count, 1)
        }
    }

    @MainActor
    func testStopFailureSurvivesAnIndependentCatchUpAndRetryTargetsTheNewHead() async throws {
        try await Their.stress(timeout: .seconds(2)) { @MainActor in
            let repository = RecurrenceRepository()
            repository.failStop = true
            let original = repository.records[0]
            let store = ExpenseStore(repository: repository)
            let events = Their.TestEventRecorder<ExpenseState>()
            let observer = store.observe { events.append($0) }
            defer { observer() }
            store.stopRecurrence(original.reference)
            _ = try await events.waitForEvent { $0.recurrence.failure != nil }
            store.catchUpRecurrences()
            _ = try await events.waitForEvent { !$0.recurrence.isRunning && $0.expenses.count == 2 }
            XCTAssertEqual(store.state.recurrence.failedOperation, .stop(original.reference))
            XCTAssertEqual(store.state.recurrence.failure, .persistence("Disk unavailable"))
            repository.failStop = false
            store.retryRecurrence()
            _ = try await events.waitForEvent { !$0.recurrence.isRunning && $0.expenses.allSatisfy { $0.recurringType == 0 } }
            XCTAssertEqual(repository.stopCount, 2)
            XCTAssertNil(store.state.recurrence.failure)
        }
    }

    @MainActor
    func testStoppingAnOldHeadFollowsMultipleCommittedSuccessors() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let clock = RecurrenceClock(Self.date("2024-01-02"))
            let fixture = try RecurrenceFixture(clock: clock)
            defer { try? fixture.close() }
            let original = try fixture.seed(date: Self.date("2024-01-01"))
            _ = try await self.mutation(fixture.store, .catchUpRecurrences)
            clock.set(Self.date("2024-01-04"))
            _ = try await self.mutation(fixture.store, .catchUpRecurrences)
            let current = try XCTUnwrap(fixture.store.state.expenses.first { $0.recurringType > 0 })
            guard case .recurrenceStopped(let stopped) = try await self.mutation(fixture.store, .stopRecurrence(original.reference)) else {
                return XCTFail("Expected stopped recurrence")
            }
            XCTAssertEqual(stopped.reference, current.reference)
            XCTAssertEqual(fixture.store.state.expenses.count, 4)
            XCTAssertTrue(fixture.store.state.expenses.allSatisfy { $0.recurringType == 0 })
            let commits = fixture.commits.count
            _ = try await self.mutation(fixture.store, .stopRecurrence(original.reference))
            XCTAssertEqual(fixture.commits.count, commits, "Stopping an already stopped head is a no-op")
            clock.set(Self.date("2024-01-10"))
            _ = try await self.mutation(fixture.store, .catchUpRecurrences)
            XCTAssertEqual(fixture.store.state.expenses.count, 4)
        }
    }

    @MainActor
    func testStoppingAnUnknownReferenceReportsFailureWithoutWriting() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let fixture = try RecurrenceFixture(clock: RecurrenceClock(Self.date("2024-01-03")))
            defer { try? fixture.close() }
            let original = try fixture.seed(date: Self.date("2024-01-01"))
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = fixture.store.observe { events.append($0) }
            defer { cancel() }
            fixture.store.stopRecurrence(URL(string: "invalid://expense")!)
            _ = try await events.waitForEvent { $0.recurrence.failure == .notFound }
            XCTAssertFalse(fixture.store.state.recurrence.isRunning)
            XCTAssertEqual(fixture.store.state.expenses, [original])
            XCTAssertEqual(fixture.commits.count, 0)
        }
    }

    @MainActor
    func testThreePersistedSeriesAdvanceAtomicallyAndKeepTheirFieldsAndBudgetTotals() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let clock = RecurrenceClock(Self.date("2024-03-31"))
            let fixture = try RecurrenceFixture(clock: clock)
            defer { try? fixture.close() }
            let category = fixture.category("Food")
            let cases = [(1, 2, "Daily"), (2, 2, "Weekly"), (3, 1, "Monthly")]
            var expected: [String: [Date]] = [:]
            for (type, coefficient, note) in cases {
                let anchor = Self.date("2024-01-31")
                expected[note] = [anchor] + (try ExpenseRecurrence.dates(after: anchor, type: type,
                    coefficient: coefficient, through: clock.read(), calendar: Self.utc))
                _ = try fixture.seed(date: anchor, type: type, coefficient: coefficient, note: note, category: category,
                    income: note == "Weekly")
            }
            guard case .recurrencesAdvanced(let commit) = try await self.mutation(fixture.store, .catchUpRecurrences) else {
                return XCTFail("Expected committed recurrence facts")
            }
            XCTAssertEqual(commit.successors.count, 3)
            XCTAssertEqual(fixture.commits.count, 1, "All heads and occurrences save in one transaction")
            for (type, coefficient, note) in cases {
                let records = fixture.store.state.expenses.filter { $0.note == note }
                XCTAssertEqual(records.compactMap(\.date).sorted(), expected[note])
                let head = try XCTUnwrap(records.first { $0.recurringType > 0 })
                XCTAssertEqual(head.recurringType, type)
                XCTAssertEqual(head.recurringCoefficient, coefficient)
                XCTAssertEqual(records.filter { $0.recurringType > 0 }.count, 1)
                XCTAssertTrue(records.allSatisfy { $0.amount == 5 && $0.category == category.objectID.uriRepresentation() })
                XCTAssertTrue(records.allSatisfy { $0.income == (note == "Weekly") })
                for record in records {
                    let transaction = try fixture.transaction(record.reference)
                    XCTAssertTrue(transaction.onceRecurring)
                    XCTAssertEqual(transaction.day, transaction.date)
                    XCTAssertEqual(Self.utc.component(.day, from: try XCTUnwrap(transaction.month)), 1)
                }
            }
            let total = (try XCTUnwrap(expected["Daily"]).count + (try XCTUnwrap(expected["Monthly"])).count) * 5
            XCTAssertEqual(ExpenseTotals.spent(fixture.store.state.expenses, from: .distantPast,
                through: clock.read(), category: category.objectID.uriRepresentation()), Double(total))
            let persisted = fixture.store.state.expenses
            _ = try await self.mutation(fixture.store, .catchUpRecurrences)
            XCTAssertEqual(fixture.store.state.expenses, persisted)
            XCTAssertEqual(fixture.commits.count, 1)
        }
    }

    @MainActor
    func testTwoIndependentStopsAreBothOwnedAndDoNotReplaceEachOther() async throws {
        try await Their.stress(count: 10, timeout: .seconds(5)) { @MainActor in
            let fixture = try RecurrenceFixture(clock: RecurrenceClock(Self.date("2024-01-01")))
            defer { try? fixture.close() }
            let first = try fixture.seed(date: Self.date("2024-01-01"), note: "First")
            let second = try fixture.seed(date: Self.date("2024-01-01"), note: "Second")
            let events = Their.TestEventRecorder<ExpenseState>()
            let cancel = fixture.store.observe { events.append($0) }
            defer { cancel() }
            XCTAssertTrue(fixture.store.stopRecurrence(first.reference))
            XCTAssertTrue(fixture.store.stopRecurrence(second.reference))
            XCTAssertFalse(fixture.store.stopRecurrence(first.reference))
            XCTAssertEqual(fixture.store.state.recurrence.operations.count, 2)
            _ = try await events.waitForEvent { !$0.recurrence.isRunning }
            XCTAssertEqual(fixture.store.state.expenses.count, 2)
            XCTAssertTrue(fixture.store.state.expenses.allSatisfy { $0.recurringType == 0 })
            XCTAssertEqual(fixture.commits.count, 2)
        }
    }
}

private final class RecurrenceClock: Sendable {
    private let value: Their.Lock<Date>

    init(_ value: Date) {
        self.value = Their.Lock(value)
    }

    func read() -> Date {
        value.withLock { $0 }
    }

    func set(_ date: Date) {
        value.withLock { $0 = date }
    }
}

@MainActor
private final class RecurrenceFixture {
    let commits = Their.TestCountRecorder()
    let container: NSPersistentContainer
    let store: ExpenseStore

    init(clock: RecurrenceClock, url: URL? = nil, readOnly: Bool = false,
         deletionDelay: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) throws {
        container = NSPersistentContainer(name: "MainModel", managedObjectModel: DataController.shared.container.managedObjectModel)
        let description = NSPersistentStoreDescription()
        description.type = url == nil ? NSInMemoryStoreType : NSSQLiteStoreType
        description.url = url
        description.shouldAddStoreAsynchronously = false
        if readOnly { description.setOption(true as NSNumber, forKey: NSReadOnlyPersistentStoreOption) }
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let currentCalendar = calendar
        let commits = commits
        let repository = CoreDataExpenseRepository(context: container.viewContext, calendar: { currentCalendar },
            now: { clock.read() }, didCommit: { _ = commits.increment() })
        store = ExpenseStore(repository: repository, deletionDelay: deletionDelay)
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

    func seed(date: Date, type: Int = 1, coefficient: Int = 1, note: String = "Daily", category: dime.Category? = nil, income: Bool = false) throws -> Expense {
        let transaction = Transaction(context: container.viewContext)
        transaction.id = UUID()
        transaction.note = note
        transaction.amount = 5
        transaction.income = income
        transaction.date = date
        transaction.day = date
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        transaction.month = calendar.date(from: calendar.dateComponents([.month, .year], from: date))
        transaction.category = category
        transaction.onceRecurring = true
        transaction.recurringType = Int16(type)
        transaction.recurringCoefficient = Int16(coefficient)
        try container.viewContext.save()
        store.reload()
        return CoreDataExpenseRepository.snapshot(transaction)
    }

    func transaction(_ reference: URL) throws -> Transaction {
        let id = try XCTUnwrap(container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: reference))
        return try XCTUnwrap(try container.viewContext.existingObject(with: id) as? Transaction)
    }
}

private final class RecurrenceGate: Sendable {
    let completions = Their.TestCountRecorder()
    let entries = Their.TestCountRecorder()
    let signal = Their.TestSignal()

    func wait() async throws {
        _ = entries.increment()
        defer { _ = completions.increment() }
        try await signal.wait()
    }
}

@MainActor
private final class RecurrenceRepository: ExpenseRepository {
    var catchUpCount = 0
    var didCatchUp: () -> Void = {}
    var failCatchUp = false
    var failLoad = false
    var failStop = false
    var records = [Expense(reference: URL(string: "test://original")!, note: "Daily", amount: 5,
        date: Date(timeIntervalSince1970: 0), category: nil, income: false, recurringType: 1, recurringCoefficient: 1)]
    var stopCount = 0

    func catchUpRecurrences(excluding references: Set<URL>) throws -> ExpenseRecurrenceCommit {
        catchUpCount += 1
        if failCatchUp { throw ExpenseFailure.persistence("Disk unavailable") }
        guard let original = records.first(where: { $0.recurringType > 0 && !references.contains($0.reference) }) else {
            return ExpenseRecurrenceCommit()
        }
        let retired = Expense(reference: original.reference, note: original.note, amount: original.amount, date: original.date,
            category: original.category, income: original.income, recurringType: 0, recurringCoefficient: original.recurringCoefficient)
        let head = Expense(reference: URL(string: "test://successor")!, note: original.note, amount: original.amount,
            date: Date(timeIntervalSince1970: 86_400), category: original.category, income: original.income,
            recurringType: 1, recurringCoefficient: 1)
        records = [retired, head]
        didCatchUp()
        return ExpenseRecurrenceCommit(expenses: records, successors: [original.reference: head.reference])
    }

    func delete(_ references: [URL]) throws {
        records.removeAll { references.contains($0.reference) }
    }

    func importExpenses(_ request: ExpenseImportRequest, control: ExpenseImportControl,
                        progress: @escaping @Sendable (ExpenseImportProgress) -> Void) async throws -> [Expense] {
        throw ExpenseImportFailure.persistence("Unused import")
    }

    func load() throws -> [Expense] {
        if failLoad { throw ExpenseFailure.persistence("Read unavailable") }
        return records.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    func save(_ draft: ExpenseDraft, editing: URL?) throws -> Expense {
        throw ExpenseFailure.persistence("Unused save")
    }

    func stopRecurrence(_ reference: URL) throws -> Expense {
        stopCount += 1
        if failStop { throw ExpenseFailure.persistence("Disk unavailable") }
        guard let index = records.firstIndex(where: { $0.reference == reference }) else { throw ExpenseFailure.notFound }
        let original = records[index]
        let stopped = Expense(reference: original.reference, note: original.note, amount: original.amount, date: original.date,
            category: original.category, income: original.income, recurringType: 0, recurringCoefficient: original.recurringCoefficient)
        records[index] = stopped
        return stopped
    }
}

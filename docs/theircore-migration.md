# Dime → TheirCore: expenses, live budgets, Undo, recurrence and import

This fork is a working migration of Dime, with the upstream UI and CoreData model retained. It is not yet a rewrite of every feature.

Baseline: `rafsoh/dimeApp` main at `0463cb8caba237de781ae02e70a2ec82ae900c67`. The baseline builds with Xcode 26.6 for the iOS 26.5 simulator. TheirCore is pinned to **0.3.0**, commit `122b8efbea284735e1bc094e328f8a28d3004806`. The seven pre-existing Swift package versions remain unchanged. The upstream GPL-3.0 license remains in place.

## Implemented routes

The transaction editor submits an immutable draft to a fresh `Their.Job`: add, edit or delete → commit to CoreData → publish an expense snapshot → update the list and primary budget cards → reopen the same SQLite store.

List deletion now has an application-owned Undo lifecycle: swipe or confirmation → hide selected rows and update totals → allow Undo for four seconds → commit the entire pending batch in one isolated CoreData save. A VoiceOver Delete action opens the same confirmation without requiring a gesture.

Main-app recurrence checks now run a fresh, application-owned Job: appearance, foreground or completed sync → catch up persisted series heads → commit all due occurrences atomically → publish current facts. Context-menu, swipe and confirmation stop actions submit the same stop command; they preserve logged history. The retained HomeView alert presents recurrence errors and retries the failed command.

CSV import now sends captured row/category values to an application-owned Job: prepare on a private CoreData queue → report progress → save the entire file once → merge and publish committed facts. Cancellation before the save claim saves no rows; failure/retry and the commit boundary are visible in the expense Desk. The retained wizard presents this state.

- `Expense.swift`: immutable expense/draft values, commands, typed failures, deletion/recurrence/import state and pure budget arithmetic. Budget dates are inclusive; income and future transactions are excluded.
- `ExpenseStore.swift`: `Their.Desk<ExpenseDeskState, ExpenseEvent>` owns the cached database facts, projected snapshot and named deletion, recurrence catch-up, per-reference stop and import Job bindings. One fixed pure reducer handles every domain event; bindings map operation outcomes into typed events. `changes` provides latest replay, while an evolved projection suppresses duplicate UI states. Dropping every UI observer does not erase the owner's state or stop its pending commit.
- `ExpenseImport.swift`: immutable request, progress and result values; typed row errors; import state and a lock-protected cancellation/save claim for the private CoreData queue.
- `ExpenseRecurrence.swift`: one calendar calculation shared by editor catch-up, runtime catch-up and main-app next-date projection. It receives an explicit calendar and date, validates stored intervals, widens weekly arithmetic before multiplying and checks cancellation while collecting due dates.
- `CoreDataExpenseRepository.swift`: CoreData objects stay inside the adapter. Writes use a separate context, then merge successful commits into the existing UI context. Batch deletion either commits every selected record or none. Failed writes do not leave optimistic changes in the UI or save unrelated tentative edits.
- `ExpenseSubmission.swift`: a `Their.Desk<Status, Event>` with one fixed pure reducer owns saving/success/failure and the named `"submission"` binding. It blocks duplicate submission and cancels on dismissal. The Combine adapter enters MainActor and reads current state there, so queued older callbacks cannot overwrite a newer submission or cancellation. Cancellation is installed before publishing saving, including reentrant dismissal from a Combine observer.
- `DataController`: a temporary bridge enters MainActor and publishes the current Desk projection to existing SwiftUI views, with no unsafe actor assumption. It reloads the snapshot after legacy context changes. Its visibility helper masks pending deletion references in retained CoreData lists, log totals and log graphs.
- `LogView` / `HomeView`: list rows and confirmation delegate deletion to the owner. The toast only presents the owner's Undo state; it no longer saves or rolls back the shared context. Failed deletion restores the rows and presents an error. Recurrence stop delegates to the owner; failures preserve the record and can retry from the retained alert.
- `ImportDataView`: capture URI/value input, render owner progress and acknowledged outcomes, cancel preparation or retry the exact request; no per-row legacy saves or unconditional success.
- `BudgetView`: primary budget numbers and the main budget graph consume current expense state, including the deletion preview, instead of keeping a total calculated only on appearance.

The existing fetched CoreData objects still render the transaction list. Categories, object identities, relationships and the `.xcdatamodeld` files are unchanged. The new repository supports legacy rows, including rows without a UUID, through stable CoreData object URI references.

## Deletion contract

| Event | Result |
| --- | --- |
| Delete one row | Hide it immediately from the log and primary budget projection; start a four-second deadline |
| Delete another distinct row before expiry | Add it to the batch and restart the shared window; a duplicate request does not restart it |
| Tap Undo before commit starts | Cancel the deadline and reveal the entire batch, including any intervening edits; preserve other committed expenses and unrelated unsaved context changes |
| Deadline expires | Close Undo, delete the batch in one writer save, merge the commit and publish current state without replaying stale cached rows |
| Lookup or save fails | Commit nothing, reveal the batch and expose a typed deletion failure; a fresh deletion can retry |
| Refresh fails after a successful delete | Keep the known deletion in the cached projection and report the read failure; do not resurrect deleted rows |
| UI observers detach | The application owner continues its deadline; a later observer receives only current state |
| Application terminates before the commit | Pending references are transient, so the SQLite records remain on the next launch |

Undo changes only the pending deletion projection. It does not call `viewContext.rollback()` or `viewContext.save()`. The four-second window is application policy implemented with an injectable delay inside a fresh Job; it does not require a new TheirCore operator.

## Decisions learned from the application

| Problem | Decision | Evidence |
| --- | --- | --- |
| Shared observation must survive UI detach/reattach | Retain a Desk in the application owner; UI observers subscribe to its changes | Shared observers and zero-observer/reconnect tests |
| An editor must not change a managed object while it is still a draft | Send value commands; commit in an isolated CoreData context | Invalid edit and real read-only SQLite failure tests |
| Saving or undoing one feature must preserve another feature's edits | Merge committed changes without saving the legacy view context; Undo removes only the owner's pending mask | Pending legacy deletion compatibility test; new save and unsaved category edit during Undo test |
| A UI toast must not own persistence or cancellation | Keep the deadline as a named Desk binding; retain an application generation/cancellation fence immediately before database IO | Distinct deletion, wake-before-actor-turn, owner release and zero-observer commit stress tests |
| A deletion batch must not leave partial effects | Resolve and delete all references in the isolated writer before one save | Invalid second reference and real read-only SQLite deletion tests |
| Job cancellation cannot undo a completed database commit | Check cancellation before IO; publish committed facts even if an editor has gone away or refresh fails; suppress late editor results | Cancellation, editor lifecycle and post-delete reload failure tests |
| A budget amount must change when an expense changes | Compute totals from the current projected snapshot | CRUD, date/category/income filtering, Undo and SQLite reopen tests |
| An unsigned fork cannot create the upstream CloudKit monitor | Use an explicit local debug mode, including a non-listening sync monitor | Initial runner crash reproduced; local simulator run succeeds |

IO is outside Desk reducers and Hub evolution. The small CRUD and recurrence CoreData operations run on MainActor, matching the legacy app's confinement. CSV row validation and staging now run on a private CoreData queue; the app explicitly chooses that execution context. TheirCore supplies lifecycle and cancellation and remains scheduleless. Very large recurrence backlogs still need a measured performance migration. The retained CSV selection/column wizard still reads and splits the source file in memory.

## Typed Desk events

TheirCore 0.3.0 fixes one reducer at Desk construction. Dime has two desks: the expense owner and the editor. All their owned state changes enter through typed events; there are no `desk.update` calls or per-binding mutable-state callbacks. Queued bound events keep the core's generation fence, so a replaced or cancelled source cannot apply a result still waiting for reduction. An event already claimed may finish; cancelling cannot undo a committed database write.

For the minimal vocabulary: a **Job** performs one separately owned operation, a **Hub** shares observations, and a **Desk** owns state. **State** describes the current situation; an **Event** describes a request or result; the fixed **reducer** defines its state transition. The editor's Job commits a command, the expense Desk receives the refreshed facts, and its snapshot Hub feeds the retained adapters. A deletion Job owns the application's four-second deadline and reports a timer failure as an event.

The expense reducer handles the following events. Each transition finishes by rebuilding the visible projection from the current cached facts and pending deletion references.

| Domain event | State transition |
| --- | --- |
| `mutationCommitted(mutation, refresh)` | Apply known committed rows/deletions and recurrence successors, then apply the read result; keep committed facts if that read fails |
| `refreshed(.success(expenses))` | Replace cached facts and clear the read failure; preserve the pending batch |
| `refreshed(.failure(error))` | Keep cached facts and expose the read failure; preserve the pending batch |
| `deletionRequested(reference)` | Add the reference, clear the deletion failure and hide pending rows |
| `deletionCommitStarted` | Close Undo by setting the committing flag |
| `deletionCommitted(references)` | Remove known committed deletions from the cache, so a later failed read cannot resurrect them |
| `deletionFinished(refresh, failure)` | Clear the pending batch, record the deletion outcome and apply the read result atomically |
| `deletionUndone(refresh)` | Clear the pending batch and apply the latest read result atomically |
| `deletionDelayFailed(failure)` | Clear the pending batch, expose the timer failure and restore the latest cached rows |
| `deletionFailureCleared` | Clear the deletion failure |

Events describe domain actions and read results; they do not carry replacement deletion states or state-mutating closures. Database reads return `Result<[Expense], ExpenseFailure>` outside the reducer. The reducer only consumes those immutable facts. A delay value or successful terminal maps to nil because the deadline's IO route already published its domain events; a delay failure maps to `deletionDelayFailed`.

The editor reducer maps `saveStarted → saving`, `saveSucceeded → saved`, `saveFailed(message) → failed(message)` and `cancelled → idle`. `submit` and `cancel` send these events; the Job binding maps a value or failure and ignores `.finished`. Duplicate submission, cancellation before IO and reconciliation of reentrant Combine observers retain their previous behavior.

The existing `ExpenseStateChannel`, manual editor generation and editor Job cancel slot remain removed. CoreData adapters, the transient deletion projection and Undo policy belong to the application. The application's deletion generation remains an IO fence: a synchronous observer can undo or extend a batch before its deadline is installed. Desk's queued-event fence governs state reduction and does not substitute for a check before irreversible IO.

The deadline uses an explicit `Their.Job` producer whose Task and reports both run on MainActor. `Job.once` confines only its operation when that closure is annotated; its report after the await may run on another executor. The explicit producer preserves this feature's synchronous actor-confined command behavior. The editor accepts generic Job delivery and bridges current state to MainActor safely. The existing derived Hub only filters repeated output projections; it cannot mutate the Desk's model.

The 0.3 migration adds explicit domain events and centralizes transitions: `ExpenseStore.swift` is 181 → 198 lines, and `ExpenseSubmission.swift` is 55 → 77. This stage improves visibility of the state rules rather than reducing line count. It adds no scheduler to TheirCore and makes no SwiftUI architecture change.

## Recurrence contract

`ExpenseCommand.catchUpRecurrences` and `stopRecurrence(reference)` use the same effect boundary as editor commands. Automatic calls bind fresh Jobs to the expense Desk: one catch-up binding coalesces overlapping checks, and each stop reference has its own binding so independent stops cannot cancel each other. `ExpenseRecurrenceState` exposes running operations, the last failed operation and its typed failure. Tokens, committed successor links and cached rows stay in `ExpenseDeskState`; only the fixed reducer changes them.

| Request or outcome | Contract |
| --- | --- |
| Catch up | Read persisted active heads; skip the pending Undo references and transactions with tentative view-context edits; create every due occurrence and retire old heads in one writer save |
| Daily / weekly / monthly boundary | The original row is already logged. Advance from its stored day, falling back to its date; include dates through the start of today, including today itself. Weeks use calendar days, rather than fixed seconds |
| End of month | Preserve Dime's rolling behavior: 31 January 2023 → 28 February → 28 March; leap-year January → 29 February → 29 March. It does not re-anchor every occurrence to the original day |
| Repeated check or restart | The last generated occurrence carries the interval; the old head is inactive. A check with no due dates performs no save and no widget reload |
| Invalid persisted interval | Fail atomically with `invalidRecurrence`, rather than loop or overflow; the invalid head can still be stopped |
| Stop | Set the active head's recurrence type to zero in the isolated writer; retain record identity, fields, `onceRecurring` and all logged history. Repeating a completed stop is a no-op |
| Stop with an already advanced local reference | Resolve its committed successors, including multiple advances during this owner's lifetime, then stop the current head |
| Cancel owned Jobs | Unbind current work and clear queued start tokens. Before IO, check both Task cancellation and the reduced operation token; a completed database commit remains visible |
| Lookup or save fails | Publish the typed operation failure, preserve existing rows and save nothing. Retry uses the exact failed catch-up or stop command |
| Another operation starts after failure | Preserve an independent operation's failure and retry reference; starting its own retry clears that failure |
| Refresh fails after commit | Apply immutable committed row facts and successor links first; keep them and expose the read failure, instead of reverting to stale rows |
| UI observers detach / owner releases | The retained owner continues without UI observers; a late observer receives current state. Releasing the owner cancels outstanding work and does not retain it through a preparation wait |

A `recurrenceStarted(operation, token)` event may be queued when requested from a synchronous observer. The IO adapter claims that token on its MainActor turn, rather than reading `current` immediately after `send` as an acknowledgement. `recurrenceEnded` retires only its matching token; `recurrencesCancelled` also clears starts queued behind an observer. `mutationCommitted` always publishes database facts, including when cancellation happened during the commit. This distinction keeps Desk's state fencing separate from the check before irreversible IO.

The calendar and date are injected into the repository and captured once per catch-up batch. The existing foreground, appearance and sync triggers remain application policy; there is no new scheduler or persistent timer in TheirCore. The synchronous CoreData save callback is recorded under `Their.Lock` and merged on the feature actor, replacing the adapter's previous `MainActor.assumeIsolated`. Test-only preparation and completion seams are behind `#if DEBUG` and absent from Release.

This feature uses the published TheirCore 0.3.0 API without changing the library. The expense owner grows from 198 to 355 lines as it adds explicit recurrence lifecycle and successor routing. Declaration sorting in retained DataController/views preserves existing initializer signatures. A SwiftSyntax token comparison confirms that unrelated method/property bodies and all 29 existing test scenarios retain their code; the functional changes in those retained adapters are the recurrence calls and error/retry presentation.

Successor links are transient routing for commands already queued in this process. This stage adds no persistent series identity and does not verify simultaneous CloudKit recurrence processing on different devices. There is no CoreData schema migration.

## CSV import contract

The existing wizard captures `ExpenseImportRequest`: string rows, four column indices, date format/locale and category URI/income values. It sends that request to the same retained `ExpenseStore` as CRUD and recurrence. No `NSManagedObject` crosses into a Job or Desk. The fixed expense reducer owns `ExpenseImportState`, the active token and the exact retry request.

One fresh Job emits `progress` values and a terminal `committed(count)` value or typed failure. Preparation reports every 128 rows, plus the initial and final boundaries. A MainActor bridge delivers reports; late/out-of-order progress cannot decrease the prepared count or overwrite a terminal outcome. A named Desk binding owns the Job. No extra TheirCore primitive or scheduler is introduced.

| Request or outcome | Contract |
| --- | --- |
| Start | Reset progress and status through `importStarted`; coalesce a repeated submission while an operation is active |
| Prepare | Validate column mapping and every row, resolve persisted categories and create non-recurring rows in a private writer context; the view context and SQLite see none of these tentative rows |
| Progress | Report rows prepared, not rows saved. The final preparation count is not an acknowledgement of commit |
| Invalid row | Stop at the first invalid row, expose its one-based data-row number and discard all staged rows; preserve existing records |
| Save | Claim the commit under `Their.Lock`, then save the entire file once. Preserve note/category/income/date/day/month behavior, positive amount normalization and unique record identities |
| Cancel before the save claim | Cancel the Task and the private-queue control, discard staging and finish as cancelled. Keep the operation active until its worker acknowledges the outcome |
| Cancel after the save claim | Allow the irreversible save to finish. A successful commit is published as success and cannot be retried; a real save error remains a failure |
| Retry | After cancellation or failure, use the captured request in one fresh Job. Starting during cancellation is blocked, and success clears the retry input |
| Commit/merge | Return immutable snapshots and merge inserted/category URI arrays into the legacy context using CoreData's remote-save API; never save unrelated tentative view-context edits |
| Refresh failure after commit | Apply known committed rows and expose the read failure. Retain import success rather than offering a duplicate retry |
| No observers / owner release | The app owner continues without UI observers. Releasing the owner cancels preparation without retaining it through the database await; a save already claimed can still finish |
| Restart | Persisted rows survive. Import progress and retry input are transient and start idle after relaunch |

`importCancellationRequested` is also an event when a synchronous observer queued a start that has not reduced yet. The reducer applies that cancellation after the queued start; IO claims the reduced token on its actor turn. Completion uses `importFinished(token, result, refresh)` directly so unbinding cannot hide committed database facts. This event retires only its matching lifecycle and applies the known rows before a possibly failed read. Progress continues to use the bound Job's generation fence.

A paused private context initially exposed an optimistic-lock conflict when an editor saved another row in the same category. The import adapter now permits native property merging only for live categories it referenced: persisted category properties win, while imported rows and concurrent expense rows survive. Deleted categories and conflicts involving other entities fail atomically. This policy is local to the insert-only import context; existing CRUD/recurrence writer policies are unchanged. CoreData's Objective-C error bridge erases the policy's domain error, so the adapter retains that exact failure on the private queue and rethrows it after a failed save. The underlying property behavior follows [Apple's store-trump merge policy](https://developer.apple.com/documentation/coredata/nsmergebypropertystoretrumpmergepolicy); native conflict resolution still owns relationships. Tests verify concurrent expense creation, a persisted category rename and category deletion during preparation.

The screen renders owner state, exposes Cancel during preparation and Try Again / Review Import after failure or cancellation. Its previous unconditional delayed success is removed; success and confetti follow only a completed database commit. Existing file/category-selection UI remains in place. Category creation during the selection wizard is separate from the expense transaction. The parser retains Dime's simple comma-separated format; quoted commas and multiline CSV fields are outside this migration. Ragged rows are rejected before the wizard indexes their columns. Both the request and staging remain proportional to file size in memory.

Retry protection applies to one owner's acknowledged lifecycle. Deliberately importing a file again is a new import; this stage adds no persistent file receipt/idempotency ledger or cross-device duplicate policy. It changes neither the CoreData model nor the published TheirCore 0.3.0 package pin. The Swift declaration reorder preserves retained initializer signatures; a SwiftSyntax token comparison shows 58 unchanged view members and functional changes confined to the import body, import command and ragged-row guard.

## Run and verify

Open `app/dime.xcodeproj`, select the shared `dime` scheme and an iOS simulator. The debug scheme enables `DIME_LOCAL_STORE=1`: a separate `DimeLocal.sqlite` store, with CloudKit disabled. The normal release path retains the upstream CloudKit configuration; this stage does not verify iCloud sync.

```sh
xcodebuild -project app/dime.xcodeproj -scheme dime \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO test

xcodebuild -project app/dime.xcodeproj -scheme dime -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
```

`DimeExpensesTests` covers SQLite CRUD/reopen, legacy rows, real save failure, budget filtering, recurrence catch-up from the editor, shared/reconnected observation, cancellation, retry and duplicate submission. The fixtures reuse the app's exact managed object model.

Before the CSV stage, verified on 2026-10-03 with Xcode 26.6 and the iPhone 17 / iOS 26.5 simulator, using the exact published TheirCore 0.3.0 pin: **56 tests passed**, including the **12 deletion/Undo tests** and **six Desk integration scenarios**, and the migrated Release build succeeded. The two 0.3 scenarios run 50 iterations each under `Their.stress`: a failed refresh retains cached expenses before recovery replaces them, with unchanged projections suppressed; an editor follows the exact idle/saving/failure/saving/saved/idle sequence through failure, retry and cancellation after commit. All 29 expense/Undo/Desk scenarios from the previous stage retain their behavior; declaration order and switch patterns follow the repository rules. The changed production files and the new recurrence tests introduce no compiler warnings; pre-existing build-script and upstream diagnostics remain. The seven other package pins remain byte-for-byte identical. The new tests run under `Their.stress` with explicit deadline gates and event/count recorders, without sleeps or polling: 50 iterations per owner-only scenario and 10 per CoreData integration scenario. They cover batch expiry, timer replacement, cancellation races, concurrent edits, unrelated unsaved changes, failure/retry, zero observers, owner release, process restart and refresh failure after commit. Four additional owner-only Desk stress scenarios cover timer failure with an intervening save, reentrant Undo before a deadline starts, editor replacement during a committed save, and dismissal by a synchronous saving observer followed by a fresh retry.

The earlier local-store UI smoke test created a Food expense named "TheirCore smoke" for €12 and an overall weekly budget of €100. Cancelling an edit kept the original record. Saving an edit to €25 changed the budget from €88 / 12% spent to €75 / 25% spent, including its graph. Relaunching preserved both values. Deleting through the editor emptied the log and restored €100 / 0% spent; another relaunch preserved the deletion and restored budget.

The 2026-10-03 UI smoke test used a disposable Food expense named "Undo route smoke" for €13 and the existing €100 weekly budget. The row's VoiceOver Delete action opened the confirmation; Cancel kept the record. Confirming hid the row and showed the Undo toast. Tapping Undo restored the record and €87 / 13% spent. A second deletion immediately showed €100 / 0% spent while the toast was still visible on the Budget tab. After expiry, the log was empty and the toast disappeared. Relaunching preserved the empty log and €100 / 0% spent. The native automation tool could not reproduce the swipe gesture, so the manual check used the accessible confirmation route; the retained swipe handler delegates to the same owner. A separate editor-delete smoke check also passed.

The earlier Desk verification repeated this route in the final 0.2.0 build with a disposable Food expense named "Desk Undo smoke" for €13. Saving and relaunching preserved the record and €87 / 13% spent. The accessible Delete confirmation hid the row and exposed Undo; tapping Undo restored the record and budget. A second deletion showed €100 / 0% while Undo remained visible. After expiry the toast disappeared; relaunching preserved an empty log and €100 / 0%. The swipe gesture itself remains outside the native automation check described above.

The recurrence stage adds **27 tests**, all under `Their.stress`: 50 iterations for the calendar and owner-only cases, 10 for CoreData integration cases. They cover daily/weekly/monthly intervals, coefficients, month ends and both DST transitions; atomic multi-series field/budget preservation; SQLite reopen and real read-only failures; invalid legacy intervals; no observers and owner release; pre-IO, reentrant and during-commit cancellation; queued starts; independent stop bindings and failures; old-head successor routing; failed refreshes; and coexistence with Undo and tentative edits. The final full test run uses a separate DerivedData directory and a newly created iPhone 17 / iOS 26.5 simulator: 56 tests pass. A prior rerun in the reused build/test environment inconsistently reported the old fixture assertion; its cause has not been established. The final verification uses the fresh run, with no business-layer changes to obtain it. The Release simulator build also passes in the separate DerivedData directory, and all 56 tests pass again with `test-without-building` on the same isolated simulator after that build. The temporary verification simulator was removed after these checks. The seven other pins, TheirCore 0.3.0 pin and CoreData model remain unchanged.

The 0.3.0 and recurrence verification uses integration tests and the Release simulator build; the manual interface checks above were performed on the previous releases.

The CSV stage adds **22 tests**, all under `Their.stress`: 50 iterations for parser/owner-only cases, 10 for SQLite integration and two for the 5,000-row batch. The full suite passes with **78 tests**. After converting every import integration fixture to a real disposable SQLite file, all 22 import tests pass again. They verify bounded progress off the main thread, visibility of preparation without persisted rows, cancellation before and after the save claim, duplicate/reentrant starts, cancellation acknowledgement before retry, exact input retry, no observers and owner release, real read-only failure, malformed/invalid rows, atomic rollback with existing records, restart, Undo, unrelated tentative edits, concurrent editor creation, category rename/deletion and failed refresh after a known commit. Deterministic signals and a private-queue staging gate establish lifecycle boundaries without sleeps or polling.

The migrated Release simulator build passes. `Package.resolved` and the CoreData model are byte-for-byte unchanged; SwiftSyntax confirms every previous test member is unchanged apart from the added import method on each fake repository. The new production/import-test files introduce no compiler warnings; retained upstream/build-script diagnostics remain. Verification uses Xcode 26.6, iOS 26.5, a separate `ImportDD` directory and an isolated iPhone 17. The temporary simulator is removed after verification. The screen wiring is compiled and the owner/repository routes are exercised through integration tests; this stage does not add a manual CSV-interface smoke check.

For a CLI debug launch, pass `SIMCTL_CHILD_DIME_LOCAL_STORE=1` to `xcrun simctl launch`. A signed build using CloudKit needs the fork owner's signing, app-group and CloudKit configuration rather than the upstream developer's identifiers.

## Remaining migration boundaries

1. Category management, budget creation, detailed historical budget screens, insights and templates still use legacy routines. CSV expense import now delegates to the expense owner. Main-app recurrence catch-up and stop now delegate to the expense owner; legacy creators still write through DataController before requesting the shared catch-up route. Screens outside the migrated log and primary budget projections may keep showing persisted rows during the transient Undo window.
2. App Intents retain legacy creation, and standalone widget/intent extension targets retain the original DataController recurrence path behind the compilation flag. The main app enables the migrated slice with `DIME_THEIRCORE_EXPENSES`; extension targets do not yet consume it. They observe persisted data after deletion commits, rather than the main app's transient preview.
3. CloudKit sync, push notifications, physical-device signing and widgets were not exercised as part of the local expense routes.

Continue with complete user scenarios. Promote a shared recipe or a new TheirCore primitive only after another implemented feature demonstrates the same need.

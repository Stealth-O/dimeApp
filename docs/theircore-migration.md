# Dime → TheirCore: expenses, live budgets and Undo

This fork is a working migration of Dime, with the upstream UI and CoreData model retained. It is not yet a rewrite of every feature.

Baseline: `rafsoh/dimeApp` main at `0463cb8caba237de781ae02e70a2ec82ae900c67`. The baseline builds with Xcode 26.6 for the iOS 26.5 simulator. TheirCore is pinned to **0.3.0**, commit `122b8efbea284735e1bc094e328f8a28d3004806`. The seven pre-existing Swift package versions remain unchanged. The upstream GPL-3.0 license remains in place.

## Implemented routes

The transaction editor submits an immutable draft to a fresh `Their.Job`: add, edit or delete → commit to CoreData → publish an expense snapshot → update the list and primary budget cards → reopen the same SQLite store.

List deletion now has an application-owned Undo lifecycle: swipe or confirmation → hide selected rows and update totals → allow Undo for four seconds → commit the entire pending batch in one isolated CoreData save. A VoiceOver Delete action opens the same confirmation without requiring a gesture.

- `Expense.swift`: immutable expense/draft values, commands, typed failures, deletion state and pure budget arithmetic. Budget dates are inclusive; income and future transactions are excluded.
- `ExpenseStore.swift`: `Their.Desk<ExpenseDeskState, ExpenseEvent>` owns the cached database facts, projected snapshot and named `"deletion"` Job binding. One fixed pure reducer handles every domain event; the binding only maps delay errors into events. `changes` provides latest replay, while an evolved projection suppresses duplicate UI states. Dropping every UI observer does not erase the owner's state or stop its pending commit.
- `CoreDataExpenseRepository.swift`: CoreData objects stay inside the adapter. Writes use a separate context, then merge successful commits into the existing UI context. Batch deletion either commits every selected record or none. Failed writes do not leave optimistic changes in the UI or save unrelated tentative edits.
- `ExpenseSubmission.swift`: a `Their.Desk<Status, Event>` with one fixed pure reducer owns saving/success/failure and the named `"submission"` binding. It blocks duplicate submission and cancels on dismissal. The Combine adapter enters MainActor and reads current state there, so queued older callbacks cannot overwrite a newer submission or cancellation. Cancellation is installed before publishing saving, including reentrant dismissal from a Combine observer.
- `DataController`: a temporary bridge enters MainActor and publishes the current Desk projection to existing SwiftUI views, with no unsafe actor assumption. It reloads the snapshot after legacy context changes. Its visibility helper masks pending deletion references in retained CoreData lists, log totals and log graphs.
- `LogView` / `HomeView`: list rows and confirmation delegate deletion to the owner. The toast only presents the owner's Undo state; it no longer saves or rolls back the shared context. Failed deletion restores the rows and presents an error.
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

IO is outside Desk reducers and Hub evolution. The current small CoreData operations run on MainActor, matching the legacy app's confinement. TheirCore supplies lifecycle and cancellation; it does not move database work onto a background queue. Large imports and recurrence batches need a separate measured migration.

## Typed Desk events

TheirCore 0.3.0 fixes one reducer at Desk construction. Dime has two desks: the expense owner and the editor. All their owned state changes enter through typed events; there are no `desk.update` calls or per-binding mutable-state callbacks. Queued bound events keep the core's generation fence, so a replaced or cancelled source cannot apply a result still waiting for reduction. An event already claimed may finish; cancelling cannot undo a committed database write.

For the minimal vocabulary: a **Job** performs one separately owned operation, a **Hub** shares observations, and a **Desk** owns state. **State** describes the current situation; an **Event** describes a request or result; the fixed **reducer** defines its state transition. The editor's Job commits a command, the expense Desk receives the refreshed facts, and its snapshot Hub feeds the retained adapters. A deletion Job owns the application's four-second deadline and reports a timer failure as an event.

The expense reducer handles the following events. Each transition finishes by rebuilding the visible projection from the current cached facts and pending deletion references.

| Domain event | State transition |
| --- | --- |
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

Verified on 2026-10-03 with Xcode 26.6 and the iPhone 17 / iOS 26.5 simulator, using the exact published TheirCore 0.3.0 pin: **29 tests passed**, including the **12 deletion/Undo tests** and **six Desk integration scenarios**, and the migrated Release build succeeded. The two 0.3 scenarios run 50 iterations each under `Their.stress`: a failed refresh retains cached expenses before recovery replaces them, with unchanged projections suppressed; an editor follows the exact idle/saving/failure/saving/saved/idle sequence through failure, retry and cancellation after commit. All 27 pre-existing test scenarios retain their behavior; declaration order and switch patterns follow the repository rules. The changed production files introduce no compiler warnings. The seven other package pins remain byte-for-byte identical. The new tests run under `Their.stress` with explicit deadline gates and event/count recorders, without sleeps or polling: 50 iterations per owner-only scenario and 10 per CoreData integration scenario. They cover batch expiry, timer replacement, cancellation races, concurrent edits, unrelated unsaved changes, failure/retry, zero observers, owner release, process restart and refresh failure after commit. Four additional owner-only Desk stress scenarios cover timer failure with an intervening save, reentrant Undo before a deadline starts, editor replacement during a committed save, and dismissal by a synchronous saving observer followed by a fresh retry.

The earlier local-store UI smoke test created a Food expense named "TheirCore smoke" for €12 and an overall weekly budget of €100. Cancelling an edit kept the original record. Saving an edit to €25 changed the budget from €88 / 12% spent to €75 / 25% spent, including its graph. Relaunching preserved both values. Deleting through the editor emptied the log and restored €100 / 0% spent; another relaunch preserved the deletion and restored budget.

The 2026-10-03 UI smoke test used a disposable Food expense named "Undo route smoke" for €13 and the existing €100 weekly budget. The row's VoiceOver Delete action opened the confirmation; Cancel kept the record. Confirming hid the row and showed the Undo toast. Tapping Undo restored the record and €87 / 13% spent. A second deletion immediately showed €100 / 0% spent while the toast was still visible on the Budget tab. After expiry, the log was empty and the toast disappeared. Relaunching preserved the empty log and €100 / 0% spent. The native automation tool could not reproduce the swipe gesture, so the manual check used the accessible confirmation route; the retained swipe handler delegates to the same owner. A separate editor-delete smoke check also passed.

The earlier Desk verification repeated this route in the final 0.2.0 build with a disposable Food expense named "Desk Undo smoke" for €13. Saving and relaunching preserved the record and €87 / 13% spent. The accessible Delete confirmation hid the row and exposed Undo; tapping Undo restored the record and budget. A second deletion showed €100 / 0% while Undo remained visible. After expiry the toast disappeared; relaunching preserved an empty log and €100 / 0%. The swipe gesture itself remains outside the native automation check described above.

The 0.3.0 verification uses integration tests and the Release simulator build; the manual interface checks above were performed on the previous releases.

For a CLI debug launch, pass `SIMCTL_CHILD_DIME_LOCAL_STORE=1` to `xcrun simctl launch`. A signed build using CloudKit needs the fork owner's signing, app-group and CloudKit configuration rather than the upstream developer's identifiers.

## Remaining migration boundaries

1. Recurrence scheduling and stopping recurrence, category management, budget creation, detailed historical budget screens, insights, templates and import still use legacy routines. Editor recurrence catch-up is preserved inside its isolated commit; the legacy recurrence runtime has not yet been replaced. Screens outside the migrated log and primary budget projections may keep showing persisted rows during the transient Undo window.
2. App Intents and widget/intent extensions retain the original DataController path. The main app enables the migrated slice with `DIME_THEIRCORE_EXPENSES`; extension targets do not yet consume it. They observe persisted data after deletion commits, rather than the main app's transient preview.
3. CloudKit sync, push notifications, physical-device signing and widgets were not exercised as part of the local expense routes.

Continue with complete user scenarios. Promote a shared recipe or a new TheirCore primitive only after another implemented feature demonstrates the same need.

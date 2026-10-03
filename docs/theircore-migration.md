# Dime → TheirCore: expenses, live budgets and Undo

This fork is a working migration of Dime, with the upstream UI and CoreData model retained. It is not yet a rewrite of every feature.

Baseline: `rafsoh/dimeApp` main at `0463cb8caba237de781ae02e70a2ec82ae900c67`. The baseline builds with Xcode 26.6 for the iOS 26.5 simulator. TheirCore is pinned to **0.1.1**, commit `842af650e65fcc0dadb8f7dbb80f2693c21c09c1`. The seven pre-existing Swift package versions remain unchanged. The upstream GPL-3.0 license remains in place.

## Implemented routes

The transaction editor submits an immutable draft to a fresh `Their.Job`: add, edit or delete → commit to CoreData → publish an expense snapshot → update the list and primary budget cards → reopen the same SQLite store.

List deletion now has an application-owned Undo lifecycle: swipe or confirmation → hide selected rows and update totals → allow Undo for four seconds → commit the entire pending batch in one isolated CoreData save. A VoiceOver Delete action opens the same confirmation without requiring a gesture.

- `Expense.swift`: immutable expense/draft values, commands, typed failures, deletion state and pure budget arithmetic. Budget dates are inclusive; income and future transactions are excluded.
- `ExpenseStore.swift`: the application owns the latest snapshot, pending deletion references and one cancellable deadline Job. A `Their.Hub` shares observation and replays the latest value. Dropping every UI observer does not erase the owner's state or stop its pending commit.
- `CoreDataExpenseRepository.swift`: CoreData objects stay inside the adapter. Writes use a separate context, then merge successful commits into the existing UI context. Batch deletion either commits every selected record or none. Failed writes do not leave optimistic changes in the UI or save unrelated tentative edits.
- `ExpenseSubmission.swift`: the editor owns a Job subscription, blocks duplicate submission, exposes saving/success/failure, and fences queued UI results when the editor disappears.
- `DataController`: a temporary bridge publishes Hub snapshots to existing SwiftUI views and reloads the snapshot after legacy context changes. Its visibility helper masks pending deletion references in retained CoreData lists, log totals and log graphs.
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
| Shared observation must survive UI detach/reattach | Keep the latest snapshot in the application owner; use Hub for the subscription lifecycle | Shared observers and zero-observer/reconnect tests |
| An editor must not change a managed object while it is still a draft | Send value commands; commit in an isolated CoreData context | Invalid edit and real read-only SQLite failure tests |
| Saving or undoing one feature must preserve another feature's edits | Merge committed changes without saving the legacy view context; Undo removes only the owner's pending mask | Pending legacy deletion compatibility test; new save and unsaved category edit during Undo test |
| A UI toast must not own persistence or cancellation | Keep the deadline subscription in ExpenseStore; fence retired deadlines with a generation and cancellation check | Distinct deletion, wake-before-actor-turn, owner release and zero-observer commit stress tests |
| A deletion batch must not leave partial effects | Resolve and delete all references in the isolated writer before one save | Invalid second reference and real read-only SQLite deletion tests |
| Job cancellation cannot undo a completed database commit | Check cancellation before IO; publish committed facts even if an editor has gone away or refresh fails; suppress late editor results | Cancellation, editor lifecycle and post-delete reload failure tests |
| A budget amount must change when an expense changes | Compute totals from the current projected snapshot | CRUD, date/category/income filtering, Undo and SQLite reopen tests |
| An unsigned fork cannot create the upstream CloudKit monitor | Use an explicit local debug mode, including a non-listening sync monitor | Initial runner crash reproduced; local simulator run succeeds |

IO is outside Hub evolution. The current small CoreData operations run on MainActor, matching the legacy app's confinement. TheirCore supplies lifecycle and cancellation; it does not move database work onto a background queue. Large imports and recurrence batches need a separate measured migration.

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

Verified on 2026-10-03 with Xcode 26.6 and the iPhone 17 / iOS 26.5 simulator: **23 tests passed**, including **12 new deletion/Undo tests**, and the migrated Release build succeeded. The new tests run under `Their.stress` with explicit deadline gates and event/count recorders, without sleeps or polling: 50 iterations per owner-only scenario and 10 per CoreData integration scenario. They cover batch expiry, timer replacement, cancellation races, concurrent edits, unrelated unsaved changes, failure/retry, zero observers, owner release, process restart and refresh failure after commit.

The earlier local-store UI smoke test created a Food expense named "TheirCore smoke" for €12 and an overall weekly budget of €100. Cancelling an edit kept the original record. Saving an edit to €25 changed the budget from €88 / 12% spent to €75 / 25% spent, including its graph. Relaunching preserved both values. Deleting through the editor emptied the log and restored €100 / 0% spent; another relaunch preserved the deletion and restored budget.

The 2026-10-03 UI smoke test used a disposable Food expense named "Undo route smoke" for €13 and the existing €100 weekly budget. The row's VoiceOver Delete action opened the confirmation; Cancel kept the record. Confirming hid the row and showed the Undo toast. Tapping Undo restored the record and €87 / 13% spent. A second deletion immediately showed €100 / 0% spent while the toast was still visible on the Budget tab. After expiry, the log was empty and the toast disappeared. Relaunching preserved the empty log and €100 / 0% spent. The native automation tool could not reproduce the swipe gesture, so the manual check used the accessible confirmation route; the retained swipe handler delegates to the same owner. A separate editor-delete smoke check also passed.

For a CLI debug launch, pass `SIMCTL_CHILD_DIME_LOCAL_STORE=1` to `xcrun simctl launch`. A signed build using CloudKit needs the fork owner's signing, app-group and CloudKit configuration rather than the upstream developer's identifiers.

## Remaining migration boundaries

1. Recurrence scheduling and stopping recurrence, category management, budget creation, detailed historical budget screens, insights, templates and import still use legacy routines. Editor recurrence catch-up is preserved inside its isolated commit; the legacy recurrence runtime has not yet been replaced. Screens outside the migrated log and primary budget projections may keep showing persisted rows during the transient Undo window.
2. App Intents and widget/intent extensions retain the original DataController path. The main app enables the migrated slice with `DIME_THEIRCORE_EXPENSES`; extension targets do not yet consume it. They observe persisted data after deletion commits, rather than the main app's transient preview.
3. CloudKit sync, push notifications, physical-device signing and widgets were not exercised as part of the local expense routes.

Continue with complete user scenarios. Promote a shared recipe or a new TheirCore primitive only after another implemented feature demonstrates the same need.

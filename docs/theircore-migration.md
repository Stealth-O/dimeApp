# Dime → TheirCore: first expense route

This fork is a working migration of Dime, with the upstream UI and CoreData model retained. It is not yet a rewrite of every feature.

Baseline: `rafsoh/dimeApp` main at `0463cb8caba237de781ae02e70a2ec82ae900c67`. The baseline builds with Xcode 26.6 for the iOS 26.5 simulator. TheirCore is pinned to **0.1.1**, commit `842af650e65fcc0dadb8f7dbb80f2693c21c09c1`. The seven pre-existing Swift package versions remain unchanged. The upstream GPL-3.0 license remains in place.

## Implemented route

The transaction editor submits an immutable draft to a fresh `Their.Job`: add, edit or delete → commit to CoreData → publish an expense snapshot → update the list and primary budget cards → reopen the same SQLite store.

- `Expense.swift`: immutable expense/draft values, commands, typed failures and pure budget arithmetic. Budget dates are inclusive; income and future transactions are excluded.
- `ExpenseStore.swift`: the application owns the latest snapshot. A `Their.Hub` shares observation and replays the latest value. Dropping every UI observer does not erase the owner's state.
- `CoreDataExpenseRepository.swift`: CoreData objects stay inside the adapter. Writes use a separate context, then merge successful commits into the existing UI context. Failed writes do not leave optimistic changes in the UI. A new expense does not accidentally commit another view's pending undoable deletion.
- `ExpenseSubmission.swift`: the editor owns a Job subscription, blocks duplicate submission, exposes saving/success/failure, and fences queued UI results when the editor disappears.
- `DataController`: a temporary bridge publishes Hub snapshots to existing SwiftUI views and reloads the snapshot after legacy context changes.
- `BudgetView`: primary budget numbers and the main budget graph consume current expense state instead of keeping a total calculated only on appearance.

The existing fetched CoreData objects still render the transaction list. Categories, object identities, relationships and the `.xcdatamodeld` files are unchanged. The new repository supports legacy rows, including rows without a UUID, through stable CoreData object URI references.

## Decisions learned from the application

| Problem | Decision | Evidence |
| --- | --- | --- |
| Shared observation must survive UI detach/reattach | Keep the latest snapshot in the application owner; use Hub for the subscription lifecycle | Shared observers and zero-observer/reconnect test |
| An editor must not change a managed object while it is still a draft | Send value commands; commit in an isolated CoreData context | Invalid edit and real read-only SQLite failure tests |
| Saving one feature must preserve another feature's pending Undo | Merge committed changes without saving the legacy view context | Pending deletion / save / rollback test |
| Job cancellation cannot undo a completed database commit | Check cancellation before IO; always refresh owner state after a successful commit; suppress late editor results | Cancellation and editor lifecycle tests |
| A budget amount must change when an expense changes | Compute totals from the current snapshot | CRUD, date/category/income filtering and reopen tests |
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

`DimeExpensesTests` covers SQLite CRUD/reopen, legacy rows, real save failure, budget filtering, recurrence catch-up from the editor, pending Undo, shared/reconnected observation, cancellation, retry and duplicate submission. The fixtures reuse the app's exact managed object model.

Verified on 2026-10-02 with Xcode 26.6 and the iPhone 17 / iOS 26.5 simulator: **11 tests passed**, and both the upstream baseline build and the migrated Release build succeeded.

The manual local-store UI smoke test created a Food expense named "TheirCore smoke" for €12 and an overall weekly budget of €100. Cancelling an edit kept the original record. Saving an edit to €25 changed the budget from €88 / 12% spent to €75 / 25% spent, including its graph. Relaunching preserved both values. Deleting through the editor emptied the log and restored €100 / 0% spent; another relaunch preserved the deletion and restored budget.

For a CLI debug launch, pass `SIMCTL_CHILD_DIME_LOCAL_STORE=1` to `xcrun simctl launch`. A signed build using CloudKit needs the fork owner's signing, app-group and CloudKit configuration rather than the upstream developer's identifiers.

## Remaining migration boundaries

1. List swipe deletion, delayed deletion and Undo still use the legacy transaction manager. Move these together so the user-visible Undo interval remains intact.
2. Recurrence scheduling, category management, budget creation, detailed historical budget screens, insights, templates and import still use legacy routines. Editor recurrence catch-up is preserved inside its isolated commit; the legacy recurrence runtime has not yet been replaced.
3. App Intents and widget/intent extensions retain the original DataController path. The main app enables the migrated slice with `DIME_THEIRCORE_EXPENSES`; extension targets do not yet consume it.
4. CloudKit sync, push notifications, physical-device signing and widgets were not exercised as part of the local expense route.

Continue with complete user scenarios. Promote a shared recipe or a new TheirCore primitive only after another implemented feature demonstrates the same need.

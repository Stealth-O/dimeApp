# Dime

> **TheirCore migration fork:** the expense editor, live budgets, undoable list deletion, main-app recurrence catch-up/stop and atomic CSV import use [TheirCore 0.5.0](https://github.com/Stealth-O/TheirCore/tree/0.5.0). Expense state and named Job bindings use `Their.Box` with typed events and one fixed reducer per Box. The original UI, CoreData schema and GPL-3.0 license are retained. The shared debug scheme runs with an isolated local store. See [migration notes, checks and remaining boundaries](docs/theircore-migration.md).


<p align="center">
  <img src="./docs/assets/hero.png" width="451" style="max-width: 100%; height: auto;" />
</p>

Dime is a 100% free, open-source personal finance tracker built with iOS design guidelines in mind. [Download Dime on the App Store.](https://apps.apple.com/sg/app/dime-budget-expense-tracker/id1635280255)

## App Preview

<p align="center">
  <img src="./docs/assets/3.png" height="300" /> 
  <img src="./docs/assets/4.png" height="300" /> 
  <img src="./docs/assets/5.png" height="300" />
  <img src="./docs/assets/6.png" height="300" />
</p>
<p align="center">
  <img src="./docs/assets/7.png" height="300" />
  <img src="./docs/assets/8.png" height="300" />
  <img src="./docs/assets/9.png" height="300" />
</p>

## Why You’ll Love Dime

- 100% free forever, with no paywall or ads.
- Beautifully iOS-centric design, with simplicity at its core.
- Insightful expenditure breakdowns over various time periods.
- Create budgets based on expense categories and stick to them.
- Create recurring expenses with custom time frames.
- Sync your expenses, categories and budgets with other devices via iCloud.
- Custom reminders to input your expenses.
- Biometric authentication to protect your data.
- Home screen quick actions make capturing new expenses a breeze.
- A gorgeous night theme for dark mode fanatics.
- Informative home and lock screen widgets keep you updated at a glance.

## How to help

- Please feel free to raise [issues](https://github.com/rarfell/dimeApp/issues) for any inquiries, suggestions for improvements, or bugs you encounter.
- You're welcome to fork the repository and propose changes through a pull request, although the decision to merge it rests with the project maintainers.
- To follow along with app updates, follow [@budgetwithdime](https://x.com/budgetwithdime) on X / Twitter
- If you would like to discuss with the contributors, feel free to drop [Rafael](https://x.com/rarfell) or [Jeffrey](https://x.com/jefcodes) a DM!

## How to build

### Required

- Xcode

### Build Steps

- Clone this project either via Xcode or terminal:
  `git clone --branch codex/theircore-expenses https://github.com/Stealth-O/dimeApp.git`
- Open `app/dime.xcodeproj` in Xcode, select the shared `dime` scheme and an iOS simulator.
- Resolve packages using the committed `Package.resolved` versions. TheirCore is pinned to 0.3.0.
- The debug scheme uses a separate local store. See the [migration notes](docs/theircore-migration.md) for test commands and signed CloudKit builds.

## Third party dependencies

- [TheirCore](https://github.com/Stealth-O/TheirCore/tree/0.5.0)
- [Alamofire](https://github.com/Alamofire/Alamofire)
- [CloudKitSyncMonitor](https://github.com/ggruen/CloudKitSyncMonitor)
- [ConfettiSwiftUI](https://github.com/simibac/ConfettiSwiftUI)
- [CrookedText](https://github.com/duemunk/CrookedText)
- [SwiftUI Introspect](https://github.com/siteline/swiftui-introspect)
- [IsScrolling](https://github.com/fatbobman/IsScrolling)
- [Popovers](https://github.com/aheze/Popovers/)
- ScrollViewStyle
- STools

## Licence

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

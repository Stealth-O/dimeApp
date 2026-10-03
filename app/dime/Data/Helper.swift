//
//  Helper.swift
//  dime
//
//  Created by Rafael Soh on 13/8/22.
//

import Foundation

extension Transaction {

    var nextTransactionDate: Date {
        guard recurringType > 0 else { return date ?? Date.now }
#if DIME_THEIRCORE_EXPENSES
        return (try? ExpenseRecurrence.next(after: day ?? date ?? Date.now, type: Int(recurringType),
            coefficient: Int(recurringCoefficient), calendar: .current)) ?? date ?? Date.now
#else
        // Extensions retain the legacy path, with bounded invalid-input handling.
        guard (1...3).contains(recurringType), recurringCoefficient > 0 else { return date ?? Date.now }
        let component: Calendar.Component = recurringType == 3 ? .month : .day
        let coefficient = Int(recurringCoefficient) * (recurringType == 2 ? 7 : 1)
        return Calendar.current.date(byAdding: component, value: coefficient, to: day ?? date ?? Date.now) ?? date ?? Date.now
#endif
    }
    var wrappedAmount: Double {
        amount
    }

    var wrappedCategoryName: String {
        category?.wrappedName ?? ""
    }

    var wrappedColour: String {
        category?.wrappedColour ?? ""
    }

    var wrappedDate: Date {
        date ?? Date.now
    }

    var wrappedNote: String {
        note ?? ""
    }

}

extension TemplateTransaction {
    var wrappedAmount: Double {
        amount
    }

    var wrappedColour: String {
        category?.wrappedColour ?? ""
    }

    var wrappedEmoji: String {
        category?.wrappedEmoji ?? ""
    }

    var wrappedNote: String {
        note ?? ""
    }
}

extension Category {

    var allTransactions: [Transaction] {
        let set = transactions as? Set<Transaction> ?? []
        return set.sorted {
            $0.wrappedDate < $1.wrappedDate
        }
    }

    var fullName: String {
        wrappedEmoji + "  " + wrappedName
    }

    var transactionCount: Int {
        transactions?.count ?? 0
    }
    var wrappedColour: String {
        colour ?? "#FFFFFF"
    }

    var wrappedDate: Date {
        dateCreated ?? Date.now
    }

    var wrappedEmoji: String {
        emoji ?? "😄️"
    }

    var wrappedName: String {
        name ?? ""
    }
}

public extension Budget {

    var endDate: Date {
        if type == 1 {
            return Calendar.current.date(byAdding: .day, value: 1, to: startDate ?? Date.now)!
        } else if type == 2 {
            return Calendar.current.date(byAdding: .day, value: 7, to: startDate ?? Date.now)!
        } else if type == 3 {
            return Calendar.current.date(byAdding: .month, value: 1, to: startDate ?? Date.now)!
        } else if type == 4 {
            return Calendar.current.date(byAdding: .year, value: 1, to: startDate ?? Date.now)!
        }
        return startDate ?? Date.now
    }

    var fullName: String {
        return wrappedEmoji + " " + wrappedName
    }
    var wrappedColour: String {
        category?.wrappedColour ?? "#FFFFFF"
    }

    var wrappedDate: Date {
        return startDate ?? Date.now
    }

    var wrappedEmoji: String {
        category?.wrappedEmoji ?? ""
    }

    var wrappedName: String {
        category?.wrappedName ?? ""
    }
}

public extension MainBudget {

    var endDate: Date {
        if type == 1 {
            return Calendar.current.date(byAdding: .day, value: 1, to: startDate ?? Date.now)!
        } else if type == 2 {
            return Calendar.current.date(byAdding: .day, value: 7, to: startDate ?? Date.now)!
        } else if type == 3 {
            return Calendar.current.date(byAdding: .month, value: 1, to: startDate ?? Date.now)!
        } else if type == 4 {
            return Calendar.current.date(byAdding: .year, value: 1, to: startDate ?? Date.now)!
        }

        return startDate ?? Date.now
    }
    var wrappedDate: Date {
        return startDate ?? Date.now
    }
}

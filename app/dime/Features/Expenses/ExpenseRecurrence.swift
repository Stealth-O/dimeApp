import Foundation

/// Dime advances from the previous occurrence, including a clamped month end.
/// The original row is already logged; only dates after it and through today are due.
enum ExpenseRecurrence {
    static func dates(after anchor: Date, type: Int, coefficient: Int,
                      through now: Date, calendar: Calendar) throws -> [Date] {
        guard type != 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        var date = try next(after: anchor, type: type, coefficient: coefficient, calendar: calendar)
        var dates: [Date] = []
        while date <= today {
            try Task.checkCancellation()
            dates.append(date)
            date = try next(after: date, type: type, coefficient: coefficient, calendar: calendar)
        }
        return dates
    }

    static func next(after anchor: Date, type: Int, coefficient: Int, calendar: Calendar) throws -> Date {
        guard (1...3).contains(type), (1...Int(Int16.max)).contains(coefficient) else {
            throw ExpenseFailure.invalidRecurrence
        }
        let start = calendar.startOfDay(for: anchor)
        // Widen before multiplying: persisted Int16 weekly intervals must not overflow.
        let interval = coefficient * (type == 2 ? 7 : 1)
        let component: Calendar.Component = type == 3 ? .month : .day
        guard let date = calendar.date(byAdding: component, value: interval, to: start), date > start else {
            throw ExpenseFailure.invalidRecurrence
        }
        return calendar.startOfDay(for: date)
    }
}

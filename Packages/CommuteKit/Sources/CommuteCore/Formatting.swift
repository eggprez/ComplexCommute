import Foundation

extension TimeInterval {
    /// "8 min", "1 hr 12 min"
    public var shortDuration: String {
        Duration.seconds(max(60, self)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

extension Date {
    /// "3:44": the time without its AM or PM, for columns of times where the half of the day goes without saying.
    public var clockTime: String {
        let calendar = Calendar.current
        return formatted(date: .omitted, time: .shortened)
            .replacingOccurrences(of: calendar.amSymbol, with: "")
            .replacingOccurrences(of: calendar.pmSymbol, with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

extension ArriveByProgress {
    /// "4 min early", "12 min late", "on the minute".
    public var deltaDescription: String {
        switch delta {
        case ..<(-30): "\((-delta).shortDuration) early"
        case 30...: "\(delta.shortDuration) late"
        default: "on the minute"
        }
    }
}

extension Double {
    /// Metres as the road signs would put it: "400 ft", "1.2 mi".
    public var roadDistance: String {
        Measurement(value: self, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

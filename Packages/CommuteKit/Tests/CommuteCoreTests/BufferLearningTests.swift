import Foundation
import Testing
@testable import CommuteCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A connection planned with `buffer` minutes in hand that the rider reached `slip` minutes later than planned.
private func record(buffer: Double, slip: Double, station: String = "Metropark", approach: ConnectionApproach = .drive,
                    day: Double = 0, missed: Bool = false) -> ConnectionRecord {
    let plannedArrival = t0 + day * 86_400
    let departure = plannedArrival + buffer * 60
    return ConnectionRecord(date: plannedArrival, approach: approach, stationID: "f:\(station)", stationName: station,
                            plannedArrival: plannedArrival, actualArrival: plannedArrival + slip * 60,
                            plannedDeparture: departure, actualDeparture: departure, isObserved: true, wasMissed: missed)
}

@Suite struct BufferLearningTests {
    @Test func timeInHandIsWhatIsLeftOfThePlannedBuffer() {
        let sample = record(buffer: 3, slip: 2)
        #expect(sample.plannedBuffer == 180)
        #expect(sample.timeInHand == 60)
        #expect(sample.bufferUsed == 120)
    }

    @Test func aLateVehicleHandsTheBufferBack() {
        var sample = record(buffer: 3, slip: 4)
        #expect(sample.timeInHand == -60) // the train would have gone without them
        sample.actualDeparture += 300     // but it ran five minutes late
        #expect(sample.timeInHand == 240)
        #expect(sample.bufferUsed == -60) // needing less buffer than the plan allowed
    }

    @Test func theSafeBufferCoversFourConnectionsInFive() throws {
        // Slips of 1, 1, 2, 4 and 9 minutes: 80% of them are covered by four minutes.
        let records = [1.0, 1, 2, 4, 9].enumerated().map { record(buffer: 3, slip: $1, day: Double($0)) }
        let stats = try #require(BufferLearning.stats(for: records))
        #expect(stats.sampleCount == 5)
        #expect(stats.safeBufferMinutes == 4)
        #expect(stats.isConfident)
        // Three minutes planned less an average slip of 3.4 leaves 24 seconds owing.
        #expect(stats.averageTimeInHand == -24)
        #expect(stats.shortestTimeInHand == -6 * 60)
    }

    @Test func roundsUpSoTheBufferIsNeverHalfAMinuteShort() {
        let records = (0..<5).map { record(buffer: 3, slip: 2.5, day: Double($0)) }
        #expect(BufferLearning.stats(for: records)?.safeBufferMinutes == 3)
    }

    @Test func aRiderWhoIsAlwaysEarlyNeedsNoBuffer() throws {
        let records = (0..<5).map { record(buffer: 3, slip: -2, day: Double($0)) }
        let stats = try #require(BufferLearning.stats(for: records))
        #expect(stats.safeBufferMinutes == 0)
        #expect(stats.averageTimeInHand == 300)
    }

    @Test func groupsByStationAndHowThePlatformIsReached() throws {
        let records = [
            record(buffer: 3, slip: 1, station: "Metropark", approach: .drive, day: 0),
            record(buffer: 3, slip: 5, station: "Metropark", approach: .drive, day: 1),
            record(buffer: 3, slip: 0, station: "Metropark", approach: .walk, day: 2),
            record(buffer: 2, slip: 1, station: "Secaucus", approach: .change, day: 3),
        ]
        let groups = BufferLearning.groups(from: records)
        #expect(groups.count == 3)
        #expect(groups.first?.stationName == "Secaucus") // most recent first
        let driving = try #require(groups.first { $0.stationName == "Metropark" && $0.approach == .drive })
        #expect(driving.stats.sampleCount == 2)
        #expect(!driving.stats.isConfident)
    }

    @Test func holdsTheSuggestionBackUntilThereIsEnoughHistory() {
        let few = (0..<4).map { record(buffer: 3, slip: 2, day: Double($0)) }
        #expect(BufferLearning.suggestedBufferMinutes(from: few) == nil)
        #expect(BufferLearning.suggestedBufferMinutes(from: few + [record(buffer: 3, slip: 2, day: 5)]) == 2)
    }

    @Test func missesCountAndPushTheBufferUp() throws {
        // A miss records no time in hand at all: the whole planned buffer went, and it still wasn't enough.
        let missed = (0..<2).map { day -> ConnectionRecord in
            var sample = record(buffer: 3, slip: 3, day: Double(day), missed: true)
            sample.actualArrival = sample.actualDeparture
            return sample
        }
        let stats = try #require(BufferLearning.stats(for: (2..<5).map { record(buffer: 3, slip: 0, day: Double($0)) } + missed))
        #expect(stats.missCount == 2)
        #expect(stats.safeBufferMinutes == 3)
    }

    @Test func percentilePicksTheNearestRank() {
        #expect(BufferLearning.percentile([], 0.8) == 0)
        #expect(BufferLearning.percentile([60], 0.8) == 60)
        #expect(BufferLearning.percentile([10, 20, 30, 40, 50], 0.8) == 40)
        #expect(BufferLearning.percentile([10, 20, 30, 40], 0.8) == 40)
        #expect(BufferLearning.percentile([50, 10, 30], 0.5) == 30)
    }
}

@Suite struct ArriveByTests {
    @Test func bandsFollowTheFiveAndTenMinuteMarks() {
        func standing(_ minutesLate: Double) -> ArrivalStanding {
            ArriveByProgress(target: t0, projectedArrival: t0 + minutesLate * 60).standing
        }
        #expect(standing(-20) == .ahead)
        #expect(standing(-5.01) == .ahead)
        #expect(standing(-5) == .onTime)
        #expect(standing(0) == .onTime)
        #expect(standing(5) == .onTime)
        #expect(standing(5.01) == .slipping)
        #expect(standing(10) == .slipping)
        #expect(standing(10.01) == .late)
        #expect(standing(60) == .late)
    }

    @Test func positionPutsTheTargetInTheMiddleAndClampsAtTheEnds() {
        #expect(ArriveByProgress(target: t0, projectedArrival: t0).position == 0.5)
        #expect(ArriveByProgress(target: t0, projectedArrival: t0 + 1_800).position == 1)
        #expect(ArriveByProgress(target: t0, projectedArrival: t0 - 1_800).position == 0)
        #expect(ArriveByProgress(target: t0, projectedArrival: t0 - 3_600).position == 0)
        #expect(ArriveByProgress(target: t0, projectedArrival: t0 + 900).position == 0.75)
    }

    @Test func theBandsTileTheBarAndEachHoldsItsOwnArrivals() {
        let spans = ArrivalStanding.allCases.map(ArriveByProgress.span(of:))
        #expect(spans.first?.lowerBound == 0)
        #expect(spans.last?.upperBound == 1)
        #expect(zip(spans, spans.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        for delta in [-1_200.0, -60, 0, 299, 420, 1_500] {
            let progress = ArriveByProgress(target: t0, projectedArrival: t0 + delta)
            #expect(ArriveByProgress.span(of: progress.standing).contains(progress.position))
        }
    }

    @Test func aTimeOfDayComesRoundAgainTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let nine = TimeOfDay(minutes: 9 * 60)
        let morning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 7, minute: 30))!
        #expect(nine.next(after: morning, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 9))!)

        let afternoon = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 14))!
        #expect(nine.next(after: afternoon, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 9))!)
    }

    @Test func aTimeOfDaySurvivesADateRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_800_012_345)
        let time = TimeOfDay(date)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        #expect(time.hour == parts.hour)
        #expect(time.minute == parts.minute)
    }
}

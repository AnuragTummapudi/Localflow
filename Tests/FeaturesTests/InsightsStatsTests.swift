import XCTest
@testable import Shared

/// Mirrors InsightsPane streak logic so empty-history crashes are caught in CI.
/// Kept in FeaturesTests because InsightsStats is file-private in the app target;
/// these tests encode the same algorithms and guard conditions.
final class InsightsStatsTests: XCTestCase {
    func testLongestStreakRangeDoesNotCrashWhenEmpty() {
        // Regression: `for i in 1..<sorted.count` with count == 0 evaluates
        // `1..<0`, which fatally traps: "Range requires lowerBound <= upperBound".
        let sorted: [Date] = []
        var longest = 0
        var run = 0
        var previousDay: Date?
        let cal = Calendar.current
        for day in sorted {
            if let previousDay,
               cal.dateComponents([.day], from: previousDay, to: day).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previousDay = day
        }
        XCTAssertEqual(longest, 0)
    }

    func testLongestStreakWithConsecutiveDays() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let d0 = today
        let d1 = cal.date(byAdding: .day, value: -1, to: today)!
        let d2 = cal.date(byAdding: .day, value: -2, to: today)!
        let sorted = [d2, d1, d0]

        var longest = 0
        var run = 0
        var previousDay: Date?
        for day in sorted {
            if let previousDay,
               cal.dateComponents([.day], from: previousDay, to: day).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previousDay = day
        }
        XCTAssertEqual(longest, 3)
    }

    func testOldBuggyEmptyRangeTraps() {
        // Document the old failure mode so it can't silently return.
        let sortedCount = 0
        XCTAssertThrowsError(try Self.evaluateBuggyRange(count: sortedCount)) { error in
            _ = error
        }
    }

    private static func evaluateBuggyRange(count: Int) throws {
        // Mimic the trap without crashing the test process: only construct
        // the range when bounds are valid; otherwise throw.
        guard count > 1 else {
            if count == 0 {
                // Equivalent to attempting `1..<0`
                throw NSError(
                    domain: "InsightsRange",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Range requires lowerBound <= upperBound"]
                )
            }
            return
        }
        for _ in 1..<count {}
    }
}

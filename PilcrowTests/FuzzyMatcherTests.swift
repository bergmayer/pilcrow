import XCTest
@testable import Pilcrow

final class FuzzyMatcherTests: XCTestCase {

    func test_match_returnsNilWhenCharactersAreOutOfOrder() {
        XCTAssertNil(FuzzyMatcher.match(Array("zab"), in: Array("alphabet")))
    }

    func test_match_returnsScoreForSubsequence() {
        XCTAssertNotNil(FuzzyMatcher.match(Array("abc"), in: Array("alphabetic")))
    }

    func test_match_emptyQueryReturnsScore() {
        XCTAssertEqual(FuzzyMatcher.match([], in: Array("anything")), 1)
    }

    func test_match_consecutiveLettersOutscoreNonBoundarySpread() {
        // Both targets are pure letters (no boundary bonuses past position
        // 0), so the consecutive-letters streak is the only differentiator.
        let consecutive = FuzzyMatcher.match(Array("save"), in: Array("save"))
        let spread      = FuzzyMatcher.match(Array("save"), in: Array("sxaxvxexmore"))
        XCTAssertNotNil(consecutive)
        XCTAssertNotNil(spread)
        XCTAssertGreaterThan(consecutive!, spread!)
    }

    func test_match_wordBoundariesScoreHigher() {
        let boundary  = FuzzyMatcher.match(Array("ot"), in: Array("open_tab"))
        let internal_ = FuzzyMatcher.match(Array("ot"), in: Array("crockpot"))
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(internal_)
        XCTAssertGreaterThan(boundary!, internal_!)
    }

    func test_match_shorterTargetWinsTiebreaker() {
        let short = FuzzyMatcher.match(Array("ab"), in: Array("ab"))
        let long  = FuzzyMatcher.match(Array("ab"), in: Array("abxxxxxxxxx"))
        XCTAssertNotNil(short)
        XCTAssertNotNil(long)
        XCTAssertGreaterThan(short!, long!)
    }
}

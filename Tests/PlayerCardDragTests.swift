import UIKit
import XCTest
@testable import LosslessPlayer

/// The pull moves the full-width card straight down with the finger, as in
/// Music; the system zoom it replaced shrank the page while it was pulled.
@MainActor final class PlayerCardDragTests: XCTestCase {
    private func card() -> (UIView, PlayerCardDrag) {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let card = UIView(frame: host.bounds)
        host.addSubview(card)
        return (card, PlayerCardDrag(card: card))
    }

    func testPullMovesTheWholeCardDownWithoutShrinking() {
        let (card, drag) = card()
        drag.update(translation: 120)
        XCTAssertEqual(card.frame, CGRect(x: 0, y: 120, width: 390, height: 844))
        XCTAssertGreaterThan(card.layer.cornerRadius, 0)
        drag.update(translation: 300)
        XCTAssertEqual(card.frame, CGRect(x: 0, y: 300, width: 390, height: 844))
    }

    func testPushingAboveTheRestingPositionKeepsTheCardInPlace() {
        let (card, drag) = card()
        drag.update(translation: -80)
        XCTAssertEqual(card.frame, CGRect(x: 0, y: 0, width: 390, height: 844))
        XCTAssertEqual(card.layer.cornerRadius, 0)
    }

    func testShortSlowReleaseSpringsBackAndLongOrFastReleaseCloses() {
        let (card, drag) = card()
        drag.update(translation: 100)
        XCTAssertFalse(drag.end(translation: 100, velocity: 50))
        XCTAssertEqual(card.transform, .identity, "the spring targets the resting position")
        XCTAssertTrue(drag.end(translation: 260, velocity: 0))
        XCTAssertTrue(drag.end(translation: 60, velocity: 1200), "a flick closes")
        XCTAssertFalse(drag.end(translation: 400, velocity: -600), "flicking back up keeps it open")
    }

    /// A slow release closes only past a quarter of the card's height
    /// (211 pt on an 844 pt screen); a quick flick closes from anywhere.
    func testSlowReleaseClosesOnlyPastAQuarterOfTheCard() {
        XCTAssertFalse(PlayerCardDrag.closes(offset: 160, velocity: 500, height: 844))
        XCTAssertFalse(PlayerCardDrag.closes(offset: 210, velocity: 0, height: 844))
        XCTAssertTrue(PlayerCardDrag.closes(offset: 212, velocity: 0, height: 844))
        XCTAssertFalse(PlayerCardDrag.closes(offset: 40, velocity: 900, height: 844))
        XCTAssertTrue(PlayerCardDrag.closes(offset: 40, velocity: 901, height: 844))
    }
}

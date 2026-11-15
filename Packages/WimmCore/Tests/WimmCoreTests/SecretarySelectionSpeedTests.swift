import Foundation
import XCTest
@testable import WimmSecretary

/// The fast paths of block selection must give exactly what the plain definitions give.
final class SecretarySelectionSpeedTests: XCTestCase {
    private func reference(_ text: String) -> Set<String> {
        let stop: Set<String> = ["только", "потом", "который", "которые", "потому", "сейчас", "запись", "заметка", "transcript", "source", "document", "refined", "current", "fallback"]
        return Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 && !stop.contains($0) })
    }

    func testTermsMatchCharacterDefinitionOnMixedText() {
        let samples = [
            "Маяк, ЛОДКА и сад — план «на завтра»… №12 ²³ café NAÏVE Straße 2026-11-15\r\nСтрока\n",
            "Ёжик ёжик ЁЖИК; транскрипция source document потому который",
            "[S12]: ../recordings/Wimm_2026-10-30_12-00-05.meta.json\n[S13]: x",
            "Эмодзи 🦔 ежа и й (и\u{0306}) с диакритикой, 한국어 текст", // not simple: reference path
            "e\u{301}cole école ÉCOLE", "İstanbul ΣΟΦΙΑ σοφια", "", "   ", "abcd", "abc",
        ]
        for text in samples { XCTAssertEqual(SecretaryPacket.terms(text), reference(text), text) }
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВЁЖЯabcxyzXYZ0123456789 .,;:—-–«»\"'()[]\n\r\t№…ßàéÏ²")
        for _ in 0..<500 {
            let text = String((0..<Int.random(in: 0...120, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            XCTAssertEqual(SecretaryPacket.terms(text), reference(text), text)
        }
    }

    func testCitationsAreFoundWithoutLowercasingWholeBlocks() {
        let blocks = SecretaryPacket.blocks("# Doc\n\nAbout [S7] here.\n\nOther [s70] and [S8 ].\n\n[S7]: ../recordings/a.meta.json\n")
        let chosen = SecretaryPacket.select(blocks: blocks, sourceIDs: ["S7"], terms: [], limit: 10_000)
        XCTAssertTrue(chosen.contains { $0.text.contains("About [S7]") })
        XCTAssertFalse(chosen.contains { $0.text.hasPrefix("[S7]:") }, "definitions are never context")
    }
}

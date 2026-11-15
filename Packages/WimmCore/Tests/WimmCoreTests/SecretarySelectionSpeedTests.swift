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

    /// The byte path must answer exactly as the two string checks it replaces, and
    /// step aside for anything that is not one scalar per character.
    func testPlainByteSearchAgreesWithStringSearch() {
        let pieces = ["а", "Б", "ё", "Ё", "й", "e", "E", "é", "É", "ß", "SS", "ss", "µ", "μ", " ", "\n", "\r\n", "\r",
                      "e\u{301}", "и\u{306}", "—", "№", "x", "Ж", "ж", ".", "İ", "i", "ґ"]
        var generator = SystemRandomNumberGenerator()
        func random(_ length: ClosedRange<Int>) -> String {
            (0..<Int.random(in: length, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
        }
        var fast = 0
        for _ in 0..<20_000 {
            let text = random(0...12), query = random(1...3)
            guard SecretaryPacket.isPlain(text), let bytes = SecretaryPacket.plainNeedle(query) else { continue }
            fast += 1
            let found = SecretaryPacket.containsBytes(text.lowercased(), bytes)
            XCTAssertEqual(found, text.range(of: query, options: .caseInsensitive) != nil, "\(text.debugDescription) / \(query.debugDescription)")
            XCTAssertEqual(found, text.lowercased().contains(query.lowercased()), "\(text.debugDescription) / \(query.debugDescription)")
        }
        XCTAssertGreaterThan(fast, 500)
        XCTAssertNil(SecretaryPacket.plainNeedle(""))
        XCTAssertFalse(SecretaryPacket.isPlain("stra\u{DF}e"))
        XCTAssertFalse(SecretaryPacket.isPlain("a\r\nb"))
    }
}

import XCTest
import WimmDomain
@testable import WimmInfrastructure

/// Synthetic names only.
final class PseudonymSuspectsTests: XCTestCase {
    private func surfaces(_ text: String, ignoring: Set<String> = []) -> [String] {
        PseudonymSuspects.find(inMasked: text, ignoring: ignoring).map(\.surface)
    }

    func testWhatMaskingLeftBehindIsListedAndTokensAreNot() throws {
        let masha = PseudonymFilter.DictionaryTerm(canonical: "Маша", forms: ["Маши", "Машей"], kind: .person)
        let (masked, _) = try PseudonymFilter(dictionary: [masha]).mask(
            "Вчера с Машей и Оксаной Беловой обсуждали «Танец дня». Маши не было в Бремене, письмо на masha@example.org.")
        XCTAssertFalse(masked.contains("Маш"))
        let found = PseudonymSuspects.find(inMasked: masked)
        XCTAssertEqual(found.map(\.surface), ["Оксаной Беловой", "Танец дня", "Бремене"])
        XCTAssertEqual(found.map(\.reason), [.name, .quotedName, .name])
    }

    func testSentenceStartsGermanNounsAndCommonAcronymsAreQuiet() {
        XCTAssertEqual(surfaces("Завтра позвоню. Вложенный бланк не заполнен. Der Antrag ist fertig, OCR и PDF готовы."), [])
        // Two capitalized words open a sentence: still a name.
        XCTAssertEqual(surfaces("Оксана Белова попросила ответить."), ["Оксана Белова"])
        // After a source ref a new sentence starts.
        XCTAssertEqual(surfaces("Проверить позже. [W07] Возможная проверка."), [])
    }

    func testAcronymsOrganizationsNumbersAndQuotedSpeech() {
        let text = "Требования TK и BHI; счёт от Holzmann Bau GmbH, Steuer-ID 12345678901. Он спросил: «Как быть честным?»"
        let found = PseudonymSuspects.find(inMasked: text)
        XCTAssertEqual(found.map(\.surface), ["TK", "BHI", "Holzmann Bau GmbH", "12345678901"])
        XCTAssertEqual(found.map(\.reason), [.acronym, .acronym, .organization, .longNumber])
    }

    func testRepeatsAreCountedAndDismissedOnesStayHidden() {
        let text = "Говорил с Оксаной. Потом снова с Оксаной и с Ингой."
        let found = PseudonymSuspects.find(inMasked: text)
        XCTAssertEqual(found.map(\.surface), ["Оксаной", "Ингой"])
        XCTAssertEqual(found.first?.count, 2)
        XCTAssertEqual(surfaces(text, ignoring: ["оксаной"]), ["Ингой"])
    }

    func testTokenStandsInForANameSoTheNextWordIsMidSentence() {
        XCTAssertEqual(surfaces("⟦P41⟧ Белова приедет."), ["Белова"])
        XCTAssertEqual(surfaces("⟦P41⟧ и ⟦O7⟧ согласились."), [])
    }

    func testContextSectionHeadersAreNotNoteText() {
        XCTAssertEqual(surfaces("[MAIN_TEXT lang=ru source=TXT]\nПисьмо от Инги.\n[ATTACHMENT_1_OCR page=1]\nСчёт BHI."), ["Инги", "BHI"])
    }

    func testCaseFormGuesses() {
        XCTAssertEqual(Set(PseudonymSuspects.caseFormGuesses("Оксана")), ["Оксаны", "Оксане", "Оксану", "Оксаной"])
        XCTAssertTrue(PseudonymSuspects.caseFormGuesses("Михаил").contains("Михаилом"))
        XCTAssertTrue(PseudonymSuspects.caseFormGuesses("Мария").contains("Марией"))
        XCTAssertEqual(PseudonymSuspects.caseFormGuesses("Петренко"), [])
        XCTAssertEqual(PseudonymSuspects.caseFormGuesses("Holzmann"), [])
        XCTAssertEqual(PseudonymSuspects.caseFormGuesses("Оксана Белова"), [])
    }
}

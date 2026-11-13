import XCTest
@testable import WimmDomain

final class TransliterationTests: XCTestCase {
    func testTransliteration() {
        XCTAssertEqual("Медиториум".transliterated(), "Meditorium")
        XCTAssertEqual("Привет, Мир!".transliterated(), "Privet, Mir!")
        XCTAssertEqual("Тест 123".transliterated(), "Test 123")
    }

    func testSlugGeneration() {
        XCTAssertEqual("Медиториум CTO".toSlug(), "meditorium-cto")
        XCTAssertEqual("Treatwell Partnership".toSlug(), "treatwell-partnership")
        XCTAssertEqual("Очень / Длинный _ Заголовок".toSlug(), "ochen-dlinnyy-zagolovok")
        XCTAssertEqual("".toSlug(), "uncategorized")
        XCTAssertEqual("!!!".toSlug(), "uncategorized")
        XCTAssertEqual("Учет карманных денег от папы".toSlug(), "uchet-karmannykh-deneg-ot-papy")
    }
}

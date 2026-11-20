import XCTest
@testable import WimmStudio

final class ShouldersDossierTextTests: XCTestCase {
    func testKeepsTheWordsAndDropsTheMachinery() {
        let markdown = """
        <a id="work"></a>
        ## Работа

        Встреча с Анной в кафе [S12] [S13], подробнее [в истории](wimm/history.md) → [раздел](#history).
        Ссылка <https://example.com/x> и [U4](../notes/u4.md) ![скриншот](images/a.png).
        Данные: \(String(repeating: "A", count: ShouldersDossierText.unspeakableRun)) конец  .

        ---

        ```
        [S1]: recordings/a.meta.json
        ```

        [S12]: ../recordings/n12.meta.json
        [S13]: ../recordings/n13.meta.json
        """
        XCTAssertEqual(ShouldersDossierText.plain(markdown), """
        ## Работа

        Встреча с Анной в кафе, подробнее в истории.
        Ссылка и.
        Данные: конец.

        ```
        [S1]: recordings/a.meta.json
        ```
        """)
    }

    func testPlainProseIsUnchanged() {
        let prose = "Решил ехать в Гамбург.\n\nБилет ещё не куплен."
        XCTAssertEqual(ShouldersDossierText.plain(prose), prose)
    }
}

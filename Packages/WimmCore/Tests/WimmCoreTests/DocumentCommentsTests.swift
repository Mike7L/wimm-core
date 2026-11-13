import XCTest
@testable import WimmInfrastructure

final class DocumentCommentsTests: XCTestCase {
    func testQuoteResolvesExactlyAndPrefersTheOccurrenceWithMatchingContext() {
        let text = "Утро: кофе. Вечер: кофе с молоком."
        let second = (text as NSString).range(of: "кофе", options: .backwards)
        let selector = TextQuoteSelector(selecting: second, in: text)
        XCTAssertEqual(selector.quote, "кофе")
        XCTAssertEqual(selector.resolve(in: text), second)
        // Text added before the quote does not move the anchor to the first one.
        let edited = "Новое начало. " + text
        XCTAssertEqual(selector.resolve(in: edited), (edited as NSString).range(of: "кофе", options: .backwards))
    }

    func testRenderedQuoteIsFoundInMarkdownSource() throws {
        let source = "Я **очень** люблю [горы](https://example.com) и\nморе."
        let selector = TextQuoteSelector(quote: "очень люблю горы и море", prefix: "Я ", suffix: ".")
        let range = try XCTUnwrap(selector.resolve(in: source))
        XCTAssertEqual((source as NSString).substring(with: range), "очень** люблю [горы](https://example.com) и\nморе")
    }

    func testMissingQuoteIsDetached() {
        XCTAssertNil(TextQuoteSelector(quote: "нет такого", prefix: "", suffix: "").resolve(in: "Совсем другой текст"))
        XCTAssertNil(TextQuoteSelector(quote: "  ", prefix: "", suffix: "").resolve(in: "  "))
    }

    func testFoldAppliesRepliesStatusesAndReopensOnOwnerReply() {
        let root = DocumentCommentRecord(id: "c-1", kind: .comment, doc: "docs/me.md", author: "owner", at: "t", text: "Почему так?", quote: "x")
        let other = DocumentCommentRecord(id: "c-2", kind: .reaction, doc: "docs/other.md", author: "owner", at: "t", quote: "y", reaction: "👍", intent: "agree")
        let answer = DocumentCommentRecord(id: "r-1", kind: .reply, doc: "docs/me.md", author: "secretary", at: "t", text: "Потому что", replyTo: "c-1", status: "answered")
        var threads = DocumentCommentThread.fold([root, other, answer], doc: "docs/me.md")
        XCTAssertEqual(threads.map(\.id), ["c-1"])
        XCTAssertEqual(threads.first?.status, .answered)
        let followUp = DocumentCommentRecord(id: "r-2", kind: .reply, doc: "docs/me.md", author: "owner", at: "t", text: "Не так", replyTo: "c-1")
        threads = DocumentCommentThread.fold([root, answer, followUp])
        XCTAssertEqual(threads.first?.status, .open)
        XCTAssertEqual(threads.first?.replies.count, 2)
        let done = DocumentCommentRecord(id: "s-1", kind: .status, doc: "docs/me.md", author: "secretary", at: "t", replyTo: "c-1", status: "applied")
        let orphan = DocumentCommentRecord(id: "s-2", kind: .status, doc: "docs/me.md", author: "owner", at: "t", replyTo: "c-9", status: "dropped")
        XCTAssertEqual(DocumentCommentThread.fold([root, answer, followUp, done, orphan]).first?.status, .applied)
    }

    func testLocationUsesWorkspaceSecretaryFolderOrSiblingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let plain = DocumentCommentLocation(document: root.appendingPathComponent("docs/me.md"))
        XCTAssertEqual(plain.fileURL.lastPathComponent, "me.threads.jsonl")
        XCTAssertEqual(plain.doc, "me.md")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("secretary"), withIntermediateDirectories: true)
        let workspace = DocumentCommentLocation(document: root.appendingPathComponent("docs/me.md"))
        XCTAssertEqual(workspace.fileURL.standardizedFileURL.path, root.appendingPathComponent("secretary/threads.jsonl").standardizedFileURL.path)
        XCTAssertEqual(workspace.doc, "docs/me.md")
    }

    func testStoreAppendsLinesAndSkipsGarbage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = DocumentCommentLocation(fileURL: root.appendingPathComponent("threads.jsonl"), doc: "me.md")
        let store = DocumentCommentStore(location: location)
        let selector = TextQuoteSelector(quote: "горы", prefix: "", suffix: "")
        let reaction = store.newRoot(kind: .reaction, selector: selector, section: "travel", heading: "Путешествия", text: nil, reaction: .unclear)
        try await store.append(reaction)
        // An agent left a broken, newline-less line.
        let handle = try FileHandle(forWritingTo: location.fileURL)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{not json".utf8)); try handle.close()
        let reply = store.newReply(to: reaction.id, text: "Переписал проще", author: DocumentCommentAuthor.secretary, status: .applied)
        try await store.append(reply)
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.skippedLines, 1)
        let thread = try XCTUnwrap(snapshot.threads.first)
        XCTAssertEqual(thread.root.reaction, "❓")
        XCTAssertEqual(thread.root.intent, "unclear")
        XCTAssertEqual(thread.status, .applied)
        let raw = try String(contentsOf: location.fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"reply_to\""))
        XCTAssertEqual(raw.split(separator: "\n").count, 3)
    }

    func testThreadLandsInItsSectionAndDetachesWhenTextIsGone() throws {
        let text = "# Я\n\n<a id=\"work\"></a>\n## Работа\n\nПишу **код** каждый день.\n\n## Дом\n\nПишу код каждый день тоже.\n"
        let doc = PersonalDocument(text: text)
        let work = try XCTUnwrap(doc.blocks.first { $0.markdown.hasPrefix("Пишу **") })
        XCTAssertEqual(doc.section(of: work)?.id, "work")
        XCTAssertEqual(doc.section(of: work)?.heading, "Работа")
        let root = DocumentCommentRecord(id: "c-1", kind: .comment, doc: "me.md", author: "owner", at: "t",
                                         section: "Дом", quote: "код каждый день", prefix: "Пишу ", suffix: " тоже")
        let thread = DocumentCommentThread(root: root, replies: [], status: .open)
        XCTAssertEqual(doc.block(for: thread)?.markdown, "Пишу код каждый день тоже.")
        XCTAssertNil(PersonalDocument(text: "# Я\n\nДругое.").block(for: thread))
    }

    private func editedThread(quote: String, prefix: String = "", suffix: String = "",
                              section: String? = "work", heading: String? = "Работа") -> DocumentCommentThread {
        DocumentCommentThread(root: DocumentCommentRecord(
            id: "edited", kind: .comment, doc: "me.md", author: "owner", at: "t",
            text: "Уточнение", section: section, heading: heading,
            quote: quote, prefix: prefix, suffix: suffix), replies: [], status: .open)
    }

    func testEditedQuoteStaysBesideItsParagraphWithoutInventingAnExactRange() throws {
        let thread = editedThread(quote: "Фотографии пляжа, заката и столиков с видом на море сделаны для макета сайта.")
        let paragraph = "Фотографии пляжа и столиков с видом на море сделаны для макета сайта Strandbistro 33."
        let doc = PersonalDocument(text: "<a id=\"work\"></a>\n## Работа\n\n\(paragraph)\n\nСовсем другой абзац.")
        XCTAssertEqual(doc.block(for: thread)?.markdown, paragraph)
        // The UI shows a card here, not a tint over words the owner never selected.
        XCTAssertNil(thread.selector.resolve(in: paragraph))
    }

    func testChangedShortQuoteCanRecoverFromSurroundingContext() {
        let thread = editedThread(quote: "год не указан", prefix: "Летом поехал в еврейский лагерь. ",
                                  suffix: " Затем вернулся домой учиться.")
        let paragraph = "Летом поехал в еврейский лагерь. Это было в 1998 году. Затем вернулся домой учиться."
        XCTAssertEqual(PersonalDocument(text: "## Работа\n\n\(paragraph)").block(for: thread)?.markdown, paragraph)
    }

    func testEditedParagraphCanMoveToAnotherSection() {
        let thread = editedThread(quote: "Самостоятельное развитие Wimm и других проектов, применение ИИ в компаниях.")
        let paragraph = "Самостоятельное развитие Wimm и других проектов, а также применение ИИ в компаниях."
        XCTAssertEqual(PersonalDocument(text: "## Планы\n\n\(paragraph)").block(for: thread)?.markdown, paragraph)
    }

    func testAmbiguousEditedParagraphsRemainDetached() {
        let thread = editedThread(quote: "Фотографии пляжа и столиков сделаны для макета сайта.")
        let doc = PersonalDocument(text: "## Работа\n\nФотографии пляжа и столиков сделаны для нового макета сайта.\n\nФотографии пляжа и столиков сделаны для старого макета сайта.")
        XCTAssertNil(doc.block(for: thread))
    }

    func testShortGenericQuoteAndSectionAloneCannotReattach() {
        let doc = PersonalDocument(text: "## Работа\n\nТеперь пишу код каждый день и делаю новый сайт.")
        XCTAssertNil(doc.block(for: editedThread(quote: "пишу сайт")))
        XCTAssertNil(doc.block(for: editedThread(quote: "Совсем другой старый текст удалён полностью.")))
    }

    func testExactQuoteStillWinsOverApproximateParagraph() {
        let quote = "Фотографии пляжа и столиков сделаны для макета сайта."
        let doc = PersonalDocument(text: "## Работа\n\nФотографии пляжа и столиков сделаны для нового макета сайта.\n\n\(quote)")
        XCTAssertEqual(doc.block(for: editedThread(quote: quote))?.markdown, quote)
    }

    func testOwnerCorrectionCanAnchorAfterOriginalQuestionWasRemoved() {
        let thread = DocumentCommentThread(root: DocumentCommentRecord(
            id: "correction", kind: .comment, doc: "me.md", author: "owner", at: "t",
            text: "Самостоятельное развитие Wimm и других проектов. И/или применение ИИ в компаниях",
            quote: "Куда двигаться дальше после окончания сезона?"), replies: [], status: .applied)
        let paragraph = "Выбрано самостоятельное развитие Wimm и других проектов и применение ИИ в компаниях."
        XCTAssertEqual(PersonalDocument(text: "## Планы\n\n\(paragraph)").block(for: thread)?.markdown, paragraph)
    }

    func testSecretaryReplyAloneCannotMoveThreadToUnrelatedParagraph() {
        var thread = editedThread(quote: "Этот старый текст теперь полностью удалён.")
        thread.replies = [DocumentCommentRecord(id: "reply", kind: .reply, doc: "me.md", author: "secretary",
            at: "t", text: "Самостоятельное развитие Wimm и других проектов", replyTo: thread.id)]
        XCTAssertNil(PersonalDocument(text: "Самостоятельное развитие Wimm и других проектов.").block(for: thread))
    }

    func testSpecificParagraphPreferredOverLargeOverviewRepeatingCorrection() {
        let thread = editedThread(quote: "Самостоятельное развитие Wimm и других проектов, применение ИИ в компаниях.")
        let paragraph = "Самостоятельное развитие Wimm и других проектов, а также применение ИИ в компаниях."
        let overview = paragraph + " " + (0..<50).map { "дополнение\($0)" }.joined(separator: " ")
        let doc = PersonalDocument(text: "## Сводка\n\n\(overview)\n\n## Планы\n\n\(paragraph)")
        XCTAssertEqual(doc.block(for: thread)?.markdown, paragraph)
    }
}

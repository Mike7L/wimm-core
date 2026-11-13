import XCTest
import WimmDomain
@testable import WimmInfrastructure

/// All data here is synthetic: published test IBANs and card numbers,
/// example.org addresses, invented names and streets.
final class PseudonymFilterTests: XCTestCase {
    private let masha = PseudonymFilter.DictionaryTerm(
        canonical: "Маша", forms: ["Маши", "Машей", "Машу"], kind: .person,
        caseForms: ["dat": "Маше"])
    private let acme = PseudonymFilter.DictionaryTerm(canonical: "Акме Лаб", kind: .org)

    /// Seeded so a failing property case can be replayed.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func session(seed: UInt64 = 1) -> PseudonymSession {
        var rng = SplitMix64(state: seed)
        return PseudonymSession { rng.next() }
    }

    /// Token numbers are random per request; goldens compare the order of
    /// first appearance instead (`⟦P3⟧ ⟦E7⟧ ⟦P3⟧` → `⟦P#1⟧ ⟦E#1⟧ ⟦P#1⟧`).
    private func normalized(_ masked: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"⟦([A-Z])(\d+)"#)
        let ns = masked as NSString
        var ordinals: [String: Int] = [:]
        var perKind: [String: Int] = [:]
        var output = ""
        var cursor = 0
        for match in regex.matches(in: masked, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let kind = ns.substring(with: match.range(at: 1))
            let id = ns.substring(with: match.range)
            if ordinals[id] == nil {
                perKind[kind, default: 0] += 1
                ordinals[id] = perKind[kind]
            }
            output += "⟦\(kind)#\(ordinals[id]!)"
            cursor = NSMaxRange(match.range)
        }
        return output + ns.substring(from: cursor)
    }

    private func golden(_ input: String, _ expected: String, dictionary: [PseudonymFilter.DictionaryTerm] = [],
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let filter = PseudonymFilter(dictionary: dictionary)
        let masked = try filter.mask(input, session: session())
        XCTAssertEqual(normalized(masked), expected, file: file, line: line)
        XCTAssertNoThrow(try filter.assertClean(masked), file: file, line: line)
    }

    // MARK: Goldens

    func testGoldenGermanLetter() throws {
        try golden(
            """
            Sehr geehrte Frau Beispiel,
            bitte überweisen Sie 120,50 Euro auf DE89 3704 0044 0532 0130 00 bis 01.11.2026.
            Rückfragen an buchhaltung@example.org oder +49 30 12345678.
            Musterverwaltung GmbH, Musterstraße 12, 10115 Berlin
            """,
            """
            Sehr geehrte Frau Beispiel,
            bitte überweisen Sie 120,50 Euro auf ⟦I#1⟧ bis 01.11.2026.
            Rückfragen an ⟦E#1⟧ oder ⟦T#1⟧.
            Musterverwaltung GmbH, ⟦A#1⟧, ⟦A#2⟧
            """)
    }

    func testGoldenRussianVoiceNoteWithDictionary() throws {
        try golden(
            "Созвонился с Машей из Акме Лаб. Маша просила передать маше привет; машина сломалась. Её телефон 8 912 345-67-89.",
            "Созвонился с ⟦P#1:f1⟧ из ⟦O#1⟧. ⟦P#1⟧ просила передать ⟦P#1:f2⟧ привет; машина сломалась. Её телефон ⟦T#1⟧.",
            dictionary: [masha, acme])
    }

    func testGoldenIBANBodyIsNotACardOrPhone() throws {
        // The German IBAN body is 18 digits; Luhn and phone shapes inside it must not win.
        try golden("IBAN: DE89370400440532013000 0151 23456789", "IBAN: ⟦I#1⟧ ⟦T#1⟧")
        try golden("Kontonummer DE89 3704 0044 0532 0130 00, danke", "Kontonummer ⟦I#1⟧, danke")
        let detections = PseudonymFilter().detect(in: "DE89 3704 0044 0532 0130 00")
        XCTAssertEqual(detections.map(\.kind), [.iban])
    }

    func testGoldenAdjacentIdentifiersAreAllFound() throws {
        try golden("DE89 3704 0044 0532 0130 00 GB82 WEST 1234 5698 7654 32", "⟦I#1⟧ ⟦I#2⟧")
        try golden("Karte 4111 1111 1111 1111 und 4111 1111 1111 1111", "Karte ⟦C#1⟧ und ⟦C#1⟧")
    }

    func testGoldenAddresses() throws {
        try golden("Wir wohnen in der Berliner Straße 5a, 60311 Frankfurt am Main.",
                   "Wir wohnen in der ⟦A#1⟧, ⟦A#2⟧.")
        try golden("Paket an Lindenstr. 3, D-80331 München", "Paket an ⟦A#1⟧, ⟦A#2⟧")
    }

    func testNegativesStayLiteral() throws {
        let filter = PseudonymFilter(dictionary: [masha])
        let texts = [
            "Die Rechnung über 10000 Euro kam am 2026-10-19 12:30 an.",
            "Order 12345, invoice 2024-001, version 3.14.159",
            "Машина стоит у Машиного дома",
            "Note id 3f2c9a1e-1b2d-4c5e-9f00-123456789012",
        ]
        for text in texts {
            XCTAssertEqual(filter.detect(in: text).map(\.kind), [], text)
        }
        // Over-masking errs safe: a bad IBAN checksum or a Luhn-failing 16-digit
        // number is no IBAN or card, but its leading groups still read as a phone.
        XCTAssertEqual(filter.detect(in: "DE00 3704 0044 0532 0130 00 ist keine gültige IBAN").map(\.kind), [.phone])
        XCTAssertEqual(filter.detect(in: "Номер заказа 4111 1111 1111 1112").map(\.kind), [.phone])
    }

    func testValidators() {
        XCTAssertTrue(PseudonymFilter.isValidIBAN("DE89 3704 0044 0532 0130 00"))
        XCTAssertTrue(PseudonymFilter.isValidIBAN("GB82WEST12345698765432"))
        XCTAssertFalse(PseudonymFilter.isValidIBAN("DE88 3704 0044 0532 0130 00"))
        XCTAssertTrue(PseudonymFilter.isValidCard("4111 1111 1111 1111"))
        XCTAssertFalse(PseudonymFilter.isValidCard("4111 1111 1111 1112"))
        XCTAssertFalse(PseudonymFilter.isPlausiblePhone("2026-10-19 12"))
    }

    // MARK: Map and unmask

    func testSameValueSameTokenAndRandomNumbering() throws {
        let filter = PseudonymFilter()
        let text = "a@example.org, b@example.org, a@example.org"
        let first = try filter.mask(text, session: session(seed: 1))
        let parts = first.components(separatedBy: ", ")
        XCTAssertEqual(parts[0], parts[2])
        XCTAssertNotEqual(parts[0], parts[1])
        let numbering = Set((1...20).map { try! filter.mask("a@example.org", session: session(seed: $0)) })
        XCTAssertGreaterThan(numbering.count, 1, "token numbers must not be stable across requests")
    }

    func testUnmaskCanonicalFormsAndCases() throws {
        let filter = PseudonymFilter(dictionary: [masha, acme])
        let s = session()
        let masked = try filter.mask("С Машей и Маши из Акме Лаб", session: s)
        let map = s.map
        let p = try XCTUnwrap(map.entries.first { $0.value.kind == .person }?.key)
        let o = try XCTUnwrap(map.entries.first { $0.value.kind == .org }?.key)
        XCTAssertEqual(try PseudonymFilter.unmask(masked, map: map), "С Машей и Маши из Акме Лаб")
        XCTAssertEqual(try PseudonymFilter.unmask("Встреча с ⟦\(p)⟧", map: map), "Встреча с Маша")
        XCTAssertEqual(try PseudonymFilter.unmask("Позвонить ⟦\(p):dat⟧", map: map), "Позвонить Маше")
        XCTAssertEqual(try PseudonymFilter.unmask("Без ⟦\(p):gen⟧", map: map), "Без Маша", "no stored case → canonical")
        XCTAssertEqual(try PseudonymFilter.unmask("⟦\(p)|f:dat⟧ из ⟦\(o):gen⟧", map: map), "Маше из Акме Лаб")
        XCTAssertEqual(map.counts, ["P": 1, "O": 1])
    }

    func testInboundGuardRejectsUnknownAndMalformedTokens() throws {
        let filter = PseudonymFilter(dictionary: [masha])
        let s = session()
        _ = try filter.mask("Маша", session: s)
        let p = try XCTUnwrap(s.map.entries.keys.first)
        let unknown = p == "P999" ? "P998" : "P999"
        XCTAssertThrowsError(try PseudonymFilter.unmask("⟦\(unknown)⟧", map: s.map)) {
            XCTAssertEqual($0 as? PseudonymizationError, .unknownToken("⟦\(unknown)⟧"))
        }
        for bad in ["⟦\(p)", "\(p)⟧", "⟦p3⟧", "⟦\(p):DAT⟧", "⟦\(p):f9⟧", "⟦ \(p) ⟧", "⟦\(p)⟧⟧"] {
            XCTAssertThrowsError(try PseudonymFilter.unmask("x \(bad) y", map: s.map), bad) {
                guard case .malformedToken = $0 as? PseudonymizationError else { return XCTFail("\(bad): \($0)") }
            }
        }
    }

    func testOutboundGuardAndDelimiterRefusal() {
        let filter = PseudonymFilter()
        XCTAssertThrowsError(try filter.assertClean("still has a@example.org")) {
            XCTAssertEqual($0 as? PseudonymizationError, .outboundLeak(kinds: ["E"]))
        }
        XCTAssertThrowsError(try filter.mask("already ⟦P1⟧ here", session: session())) {
            XCTAssertEqual($0 as? PseudonymizationError, .inputContainsTokenDelimiters)
        }
    }

    // MARK: Payload (egress copy)

    func testPayloadMasksJSONValuesAndRestoresTheAnswer() throws {
        let user = try LLMJSONClient.noteCardInputJSON(
            noteId: "note-1", transcript: "Маша:\nпочта masha@example.org", localHypothesis: nil,
            lang: "ru", glossary: nil)
        let payload = try PseudonymizedPayload.mask(
            user: user, filter: PseudonymFilter(dictionary: [masha]), session: session())
        XCTAssertFalse(payload.user.contains("Маша"))
        XCTAssertFalse(payload.user.contains("example.org"))
        XCTAssertTrue(payload.user.contains("\"schema\""), "keys are untouched")
        let p = try XCTUnwrap(payload.map.entries.first { $0.value.kind == .person }?.key)
        let e = try XCTUnwrap(payload.map.entries.first { $0.value.kind == .email }?.key)
        let answer = "```json\n{\"title\": \"Письмо от ⟦\(p)⟧\", \"summary\": \"Ответить ⟦\(p):dat⟧ на ⟦\(e)⟧ \\\"срочно\\\"\"}\n```"
        let restored = try payload.unmask(response: answer)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(restored.utf8)) as? [String: String])
        XCTAssertEqual(object["title"], "Письмо от Маша")
        XCTAssertEqual(object["summary"], "Ответить Маше на masha@example.org \"срочно\"")
        XCTAssertThrowsError(try payload.unmask(response: "{\"title\": \"⟦P0⟧\"}"))
    }

    func testPlainTextPayload() throws {
        let payload = try PseudonymizedPayload.mask(
            user: "INSTRUCTION: summarize\n\nCONTEXT:\nCall +49 30 12345678", filter: PseudonymFilter(), session: session())
        XCTAssertFalse(payload.user.contains("12345678"))
        XCTAssertEqual(try payload.unmask(response: payload.user), "INSTRUCTION: summarize\n\nCONTEXT:\nCall +49 30 12345678")
    }

    // MARK: Property

    /// `unmask(mask(x)) == x` when the model echoes the masked text, and no
    /// planted identifier survives into the masked copy.
    func testRoundTripProperty() throws {
        let filter = PseudonymFilter(dictionary: [masha, acme])
        let words = ["и", "встреча", "завтра", "Termin", "bitte", "the", "note", "42", "3.5", "2026-10-19",
                     "Машина", "маш", "Lindenweg", "(скобки)", "«кавычки»", "€", "😀", "Straße"]
        let secrets = ["Маша", "МАШЕЙ", "маши", "Машу", "Акме Лаб", "anna.test@example.org", "x_y+z@sub.example.co",
                       "DE89 3704 0044 0532 0130 00", "GB82WEST12345698765432", "+49 30 12345678",
                       "0151 23456789", "+7 (912) 345-67-89", "4111 1111 1111 1111", "Musterstraße 12",
                       "Berliner Straße 5a", "10115 Berlin", "60311 Frankfurt am Main"]
        let separators = [" ", ", ", "\n", ". ", "; ", " — "]
        // PSEUDONYM_PROPERTY_ITERATIONS / _SEED widen the search locally.
        let env = ProcessInfo.processInfo.environment
        let iterations = env["PSEUDONYM_PROPERTY_ITERATIONS"].flatMap(Int.init) ?? 400
        var rng = SplitMix64(state: env["PSEUDONYM_PROPERTY_SEED"].flatMap(UInt64.init) ?? 20261019)
        for iteration in 0..<iterations {
            var parts: [String] = []
            var planted: [String] = []
            for _ in 0..<Int.random(in: 1...14, using: &rng) {
                if Int.random(in: 0..<3, using: &rng) == 0 {
                    let secret = secrets.randomElement(using: &rng)!
                    planted.append(secret)
                    parts.append(secret)
                } else {
                    parts.append(words.randomElement(using: &rng)!)
                }
                parts.append(separators.randomElement(using: &rng)!)
            }
            let text = parts.joined()
            let s = session(seed: UInt64(iteration))
            let masked = try filter.mask(text, session: s)
            XCTAssertNoThrow(try filter.assertClean(masked), "iteration \(iteration): \(text)")
            for secret in planted {
                let wholeToken = try NSRegularExpression(
                    pattern: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: secret) + #"(?![\p{L}\p{N}])"#,
                    options: [.caseInsensitive])
                XCTAssertNil(wholeToken.firstMatch(in: masked, range: NSRange(location: 0, length: (masked as NSString).length)),
                             "iteration \(iteration) leaked \(secret)")
            }
            XCTAssertEqual(try PseudonymFilter.unmask(masked, map: s.map), text, "iteration \(iteration)")
            let payload = try PseudonymizedPayload.mask(
                user: try LLMJSONClient.noteCardInputJSON(noteId: "n", transcript: text, localHypothesis: nil, lang: nil, glossary: nil),
                filter: filter, session: session(seed: UInt64(iteration)))
            let restored = try payload.unmask(response: payload.user)
            let note = (PseudonymizedPayload.jsonObject(restored) as? [String: Any])?["note"] as? [String: Any]
            XCTAssertEqual(note?["text"] as? String, text, "iteration \(iteration) JSON")
        }
    }

    // MARK: Map archive and private mode

    func testMapArchiveIsAddressedByHash() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = PseudonymMapArchive(directory: folder)
        let s = session()
        _ = try PseudonymFilter().mask("a@example.org", session: s)
        let sha = try archive.archive(s.map)
        XCTAssertEqual(sha, try s.map.sha256())
        XCTAssertEqual(try archive.map(sha256: sha), s.map)
        XCTAssertEqual(try archive.archive(s.map), sha)
    }

    func testPrivateModeIsOffByDefaultAndGuardsCloudEgress() async throws {
        unsetenv("WIMM_PRIVATE_MODE")
        XCTAssertFalse(PrivateMode.isEnabled)
        XCTAssertNoThrow(try PrivateMode.checkCloudEgress(provider: "gemini"))

        setenv("WIMM_PRIVATE_MODE", "1", 1)
        defer { unsetenv("WIMM_PRIVATE_MODE") }
        XCTAssertThrowsError(try PrivateMode.refuseCloudAudio(provider: "gemini"))
        do {
            _ = try await LLMTransport.shared.makeGeminiRequest(model: "m", timeout: 1, apiKey: "k")
            XCTFail("an unmarked cloud request must be refused in private mode")
        } catch let error as PseudonymizationError {
            guard case .cloudRequestRefused = error else { return XCTFail("\(error)") }
        }
        let marked = try await PrivateMode.withPseudonymizedEgress {
            try await LLMTransport.shared.makeGeminiRequest(model: "m", timeout: 1, apiKey: "k")
        }
        XCTAssertEqual(marked.httpMethod, "POST")
        do {
            _ = try await GeminiTranscriptionAdapter(apiKey: "k").transcribeFile(at: URL(fileURLWithPath: "/nonexistent.m4a"))
            XCTFail("cloud audio must refuse in private mode")
        } catch let error as PseudonymizationError {
            guard case .cloudRequestRefused = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Preview

    func testPreviewShowsWhatEgressWouldSendWithLegendAndVerdict() async throws {
        let client = LLMJSONClient(
            model: "gemini-test", tracer: nil, transcriptionGlossary: nil, personalGlossaryStore: nil,
            privateMode: false, pseudonymDictionary: [masha], pseudonymMapArchive: nil)
        let preview = try await client.previewPrivateEgress(
            noteId: "n1", transcript: "Маша прислала DE89 3704 0044 0532 0130 00 и masha@example.org", lang: "ru")
        XCTAssertTrue(preview.wouldSend)
        XCTAssertNil(preview.refusal)
        XCTAssertFalse(preview.maskedUser.contains("Маша"))
        XCTAssertFalse(preview.maskedUser.contains("example.org"))
        XCTAssertTrue(preview.system.contains("Copy every placeholder exactly"))
        XCTAssertEqual(Set(preview.legend.map(\.detector)), [.dictionary, .iban, .email])
        XCTAssertEqual(preview.legend.first { $0.detector == .iban }?.value, "DE89 3704 0044 0532 0130 00")
        XCTAssertTrue(preview.maskedNoteText.hasPrefix("⟦P"))
        XCTAssertEqual(preview.dictionaryTerms, 1)

        let refused = try await client.previewPrivateEgress(noteId: "n2", transcript: "already ⟦P1⟧", lang: nil)
        XCTAssertFalse(refused.wouldSend)
        XCTAssertNotNil(refused.refusal)
    }

    func testDirectGeminiTextCallsRefuseInPrivateMode() async throws {
        setenv("WIMM_PRIVATE_MODE", "1", 1)
        defer { unsetenv("WIMM_PRIVATE_MODE") }
        do {
            _ = try await GeminiTextGeneration(apiKey: "k", modelName: "m", errorDomain: "test")(prompt: "Маша")
            XCTFail("direct Gemini text generation must be refused in private mode")
        } catch let error as PseudonymizationError {
            guard case .cloudRequestRefused = error else { return XCTFail("\(error)") }
        }
    }
}

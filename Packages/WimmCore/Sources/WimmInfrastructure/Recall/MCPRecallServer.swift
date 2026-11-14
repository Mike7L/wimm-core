import CryptoKit
import Foundation
import WimmDomain

/// A minimal Model Context Protocol server (JSON-RPC 2.0, one message per
/// line on stdio) that lets an outside agent — Claude Code, Claude Desktop,
/// any MCP client — answer basic questions from the library: find notes,
/// list recent ones, read one in full, and save discussion as a new Markdown
/// note. Existing note text is never edited through this server.
public struct MCPRecallServer: Sendable {
    public static let serverName = "wimm"
    public static let defaultProtocolVersion = "2025-06-18"
    static let maxNoteChars = 20_000

    private let library: @Sendable () async -> RecallLibrary
    private let version: String
    private let now: @Sendable () -> Date
    private let isPrivate: @Sendable () -> Bool
    /// Dates without a zone — arguments and rendered times — are read in it.
    private let timeZone: TimeZone
    private let marks: AgentMarkStore
    private let queue: RetranscriptionQueue
    private let retranscriptionModel: @Sendable () -> String
    /// Makes sure a `drain-queue` worker is running (the CLI spawns one).
    private let startRetranscriptionWorker: @Sendable () -> Void
    /// Cap on every listing page (`WIMM_MCP_PAGE_LIMIT`). A secretary run sets
    /// it: a 50-note page is ~9k tokens that ride along in every later turn.
    private let pageLimit: Int?
    private let readLog: URL?
    private let reviewContext: SecretaryCompletion.ReviewContext?
    private let allowedTools: Set<String>?
    private let noteDirectory: @Sendable () -> URL
    public static let toolsEnvironmentKey = "WIMM_MCP_TOOLS"
    public static let readLogEnvironmentKey = "WIMM_SECRETARY_READ_LOG"

    public static let pageLimitEnvironmentKey = "WIMM_MCP_PAGE_LIMIT"

    public static func pageLimit(from environment: [String: String]) -> Int? {
        environment[pageLimitEnvironmentKey].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil }
    }

    public init(
        version: String = "1.0",
        now: @escaping @Sendable () -> Date = Date.init,
        timeZone: TimeZone = .current,
        isPrivate: @escaping @Sendable () -> Bool = { PrivateMode.isEnabled },
        marks: AgentMarkStore = AgentMarkStore(),
        queue: RetranscriptionQueue = RetranscriptionQueue(),
        retranscriptionModel: @escaping @Sendable () -> String = { Config.transcribeModel },
        startRetranscriptionWorker: @escaping @Sendable () -> Void = {},
        pageLimit: Int? = nil,
        readLog: URL? = nil,
        reviewConfiguration: String? = nil,
        allowedTools: Set<String>? = nil,
        noteDirectory: @escaping @Sendable () -> URL = { FileStore.recordingsDirectory() },
        library: @escaping @Sendable () async -> RecallLibrary
    ) {
        self.allowedTools = allowedTools
        self.noteDirectory = noteDirectory
        self.readLog = readLog
        self.reviewContext = reviewConfiguration.flatMap { try? JSONDecoder().decode(SecretaryCompletion.ReviewContext.self, from: Data($0.utf8)) }
        self.pageLimit = pageLimit
        self.version = version
        self.now = now
        self.isPrivate = isPrivate
        self.timeZone = timeZone
        self.marks = marks
        self.queue = queue
        self.retranscriptionModel = retranscriptionModel
        self.startRetranscriptionWorker = startRetranscriptionWorker
        self.library = library
    }

    /// Serves until stdin closes. Logs must go to stderr — stdout is the
    /// protocol channel, and one stray line breaks the client.
    public func serveStdio() async {
        while let line = readLine(strippingNewline: true) {
            guard let reply = await handle(line: line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }

    /// One incoming line → the reply line, or nil for notifications.
    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications (no id) never get a reply.
        guard let id else { return nil }

        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": params["protocolVersion"] as? String ?? Self.defaultProtocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.serverName, "version": version],
                "instructions": Self.instructions,
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": Self.tools(pageLimit: pageLimit).filter { tool in
                let name = tool["name"] as? String ?? ""
                // Capability probes explicitly request the run's tools. Normal
                // library clients do not see a tool they cannot use.
                if name == "secretary_review_document", reviewContext == nil,
                   allowedTools?.contains(name) != true { return false }
                return allowedTools?.contains(name) ?? true
            }]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            result = await callTool(name: name, arguments: arguments)
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    // MARK: - Tools

    static let instructions = """
        Wimm is the user's personal voice/file note library. Use search_notes to find what \
        the user said or wrote about something, recent_notes for "what did I record \
        today/this week", changed_notes to catch up on everything edited, transcribed \
        or analyzed since your last pass, and get_note to read one note in full. A note's \
        date is when it was captured (recording start, or the file's own date for an \
        import); "updated" is when its file or metadata last changed. Times are the \
        Mac's local time unless they carry an offset. Answer only from note text, quote \
        it, and cite the note id and date. Say so when nothing matches.

        Wimm also keeps an agent's bookkeeping: mark_notes records a status \
        (applied / pending / noise / failed) and your own source reference per note, \
        set_pass_boundary remembers where a pass ended (changed_notes since: \
        "last_pass" starts there), marked_notes lists notes by mark. Marks live outside \
        the notes, so marking never counts as a change. request_retranscription queues \
        a fresh transcription of audio notes; a new transcript then shows up in \
        changed_notes (changes: transcript), the replaced one stays readable in get_note.

        When the user asks to save the discussion in Wimm, create_note stores a new \
        Markdown note without a model call. It never updates an existing note. \
        Saving a note does not mark sources or advance the secretary pass boundary.
        """

    static let dateHelp = "YYYY-MM-DD, YYYY-MM-DDTHH:MM[:SS] in local time, or ISO 8601 with a zone"

    static var tools: [[String: Any]] { tools(pageLimit: nil) }

    /// A listing's `limit` property; under a page cap it says so and carries `maximum`.
    static func limitProperty(default fallback: Int, max upper: Int, pageLimit: Int?) -> [String: Any] {
        guard let pageLimit, pageLimit < upper else {
            return ["type": "integer", "description": "Max results (default \(fallback), max \(upper))"]
        }
        return ["type": "integer", "maximum": pageLimit,
                "description": "Max results (default \(min(fallback, pageLimit)), max \(pageLimit) in this session — page with the cursor/offset)"]
    }

    static func tools(pageLimit: Int?) -> [[String: Any]] { [
        [
            "name": "secretary_review_document",
            "description": "Read the final document edits, with old text and new text plus context. Only available in a configured secretary run. Read every page after the last edit; Wimm records supplied coverage, not semantic correctness. Page numbers start at 0.",
            "inputSchema": ["type": "object", "properties": ["page": ["type": "integer", "minimum": 0]], "required": ["page"]],
        ],
        [
            "name": "search_notes",
            "description": "Full-text search over all notes (transcripts, titles, summaries, attachment text). Every word of the query must occur in a note (word endings are ignored, so \"подписка\" finds \"подписку\"); Russian and English both work. Try a synonym when nothing matches. Returns best matches with a snippet and a facts line (duration, speech, chars, device, updated).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Words to look for"],
                    "since": ["type": "string", "description": "Only notes recorded on/after this time (\(dateHelp))"],
                    "until": ["type": "string", "description": "Only notes recorded before this time (\(dateHelp))"],
                    "updated_since": ["type": "string", "description": "Only notes whose file or metadata changed on/after this time — finds re-transcribed and re-analyzed notes (\(dateHelp))"],
                    "limit": limitProperty(default: 10, max: 50, pageLimit: pageLimit),
                    "offset": ["type": "integer", "description": "Skip this many best matches (for the next page)"],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "recent_notes",
            "description": "Newest notes first by capture date, optionally within a time window. Use for 'what did I record today / yesterday / this week'. Each note has a facts line: duration, speech (speech / no_speech / skipped:<reason> / failed), chars of transcript, device, updated.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "days": ["type": "integer", "description": "Only the last N days (1 = since this time yesterday)"],
                    "since": ["type": "string", "description": "Only notes recorded on/after this time (\(dateHelp))"],
                    "until": ["type": "string", "description": "Only notes recorded before this time (\(dateHelp))"],
                    "updated_since": ["type": "string", "description": "Only notes whose file or metadata changed on/after this time (\(dateHelp))"],
                    "include_empty": ["type": "boolean", "description": "false hides silent, skipped, failed and textless recordings (default true)"],
                    "limit": limitProperty(default: 20, max: 100, pageLimit: pageLimit),
                    "offset": ["type": "integer", "description": "Skip this many newest notes (for the next page)"],
                ],
            ],
        ],
        [
            "name": "changed_notes",
            "x-wimm-queue-receipts": 1,
            "description": "Notes whose text, transcript, analysis, attachments or metadata changed at or after a moment — old notes included — oldest change first. Page with the returned next_cursor until remaining is 0; keep the last cursor (or as_of) as the start of your next pass, or store it with set_pass_boundary. Change times come from file and sidecar modification times on this Mac, so a sync or status write also counts as a change; each note says what changed (changes: transcript / analysis / edited / sync / metadata — read from the timestamps the pipeline stamps, a hint rather than a diff) and, when you marked it, whether its text or analysis changed since your mark.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "since": ["type": "string", "description": "Changed on/after this moment (YYYY-MM-DD or ISO 8601), or \"last_pass\" for the boundary stored with set_pass_boundary. A cursor remembers it, so later pages need only the cursor. Omit on the first page to list the whole library"],
                    "cursor": ["type": "string", "description": "next_cursor of the previous page"],
                    "skip_unchanged_marked": ["type": "boolean", "description": "true hides notes you marked whose text and analysis are unchanged since the mark — a sync or metadata write alone does not bring them back (default false)"],
                    "marked_changes": ["type": "string", "description": "Comma list of change kinds (transcript, analysis, edited, sync, metadata). A note you already marked is listed only if one of these changed since `since`; unmarked notes are always listed. E.g. \"transcript,edited\" skips marked notes that were only re-analyzed or synced"],
                    "order": ["type": "string", "enum": ["oldest_first", "newest_first"], "description": "oldest_first (default) or newest_first — the most recent changes first, for a pass that may stop part-way (marks keep what is done). Pass the same order with every cursor"],
                    "limit": limitProperty(default: 50, max: 200, pageLimit: pageLimit),
                ],
            ],
        ],
        [
            "name": "get_note",
            "x-wimm-read-receipts": 1,
            "x-wimm-text-coverage": 1,
            "x-wimm-image-evidence": 1,
            "x-wimm-document-layout": 1,
            "description": "Read a note's provenance, ASR diagnostics, all labeled text variants and image evidence: literal OCR, native observations, barcodes, detected-data candidates, optional MLX drafts and recorded history. Image descriptions are model observations, not user statements. Default display may truncate or normalize duplicates; use full: true for every distinct variant without truncation and a complete coverage receipt. Diagnostics do not establish factual accuracy.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": noteRefHelp],
                    "full": ["type": "boolean", "description": "Return every distinct text variant without display truncation. Required for complete secretary read receipts; default false."],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name":"get_note_image",
            "description":"Supply one original image or PDF page owned by a note, optionally a crop. First read get_note(full:true) for the numbered visual-source roster and unverified geometry. crop uses normalized bottom-left coordinates on the oriented page. This sends image content to the agent; refused in private mode. Receipt attests supplied pixels, not factual accuracy. No free file paths accepted.",
            "inputSchema":["type":"object","properties":[
                "id":["type":"string","description":noteRefHelp],
                "image_index":["type":"integer","minimum":1,"description":"1-based visual-source index from get_note"],
                "page":["type":"integer","minimum":1,"description":"1-based PDF page; images only accept 1"],
                "crop":["type":"object","properties":Dictionary(uniqueKeysWithValues:["x","y","width","height"].map { ($0,["type":"number"] as [String:Any]) }),"required":["x","y","width","height"],"additionalProperties":false]
            ],"required":["id","image_index"],"additionalProperties":false]
        ],
        [
            "name": "request_retranscription",
            "description": "Queue a fresh transcription of audio notes (empty, failed, looped or no-speech transcripts), or of the audio attachments of a text note (Evernote imports keep their recordings as attachments; each one is its own queue entry and its text is written back onto that attachment). Runs in the background, one note at a time, and survives this session ending. The new transcript replaces the current one, which stays readable in get_note as an earlier transcript; a no-speech verdict never replaces existing text. When done the note shows up in changed_notes with changes: transcript, and get_note / retranscription_queue show the outcome. Costs a cloud call per note unless model is parakeet:ultra (on-device); in private mode only parakeet:ultra is accepted.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ids": ["type": "array", "items": ["type": "string"], "description": "Notes to retranscribe (max 200): \(noteRefHelp)"],
                    "model": ["type": "string", "description": "Transcription model, e.g. gemini-3-flash-preview or parakeet:ultra (default: the model chosen in Wimm Settings)"],
                    "analyze": ["type": "boolean", "description": "Re-run the note analysis (title, summary, refined text) after a transcript with speech (default true)"],
                    "reason": ["type": "string", "description": "Why — kept with the request"],
                ],
                "required": ["ids"],
            ],
        ],
        [
            "name": "retranscription_queue",
            "description": "Retranscription requests and their outcome, newest first: queued, running, done (speech with old → new word counts / no_speech) or failed.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "state": ["type": "string", "enum": ["queued", "running", "done", "failed"], "description": "Only requests in this state"],
                    "limit": ["type": "integer", "description": "Max results (default 50, max 500)"],
                ],
            ],
        ],
        [
            "name": "mark_notes",
            "description": "Record your processing status on notes: applied (built into your knowledge base), pending, noise, failed — or clear to remove the mark. Stored in Wimm outside the notes, so a mark never changes a note's sha256 or brings it into changed_notes. Each mark keeps a fingerprint of the note's text and analysis, so later listings can tell you whether the note changed since.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "marks": [
                        "type": "array",
                        "description": "Up to 500 marks",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string", "description": noteRefHelp],
                                "status": ["type": "string", "enum": ["applied", "pending", "noise", "failed", "clear"]],
                                "source": ["type": "string", "description": "Your reference, e.g. S1157 (max 64 chars)"],
                                "comment": ["type": "string", "description": "Short note (max 500 chars)"],
                            ],
                            "required": ["id", "status"],
                        ],
                    ],
                ],
                "required": ["marks"],
            ],
        ],
        [
            "name": "marked_notes",
            "description": "Notes you marked, newest mark first, with status, source, and whether the text or analysis changed since the mark.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "status": ["type": "string", "enum": ["applied", "pending", "noise", "failed"], "description": "Only this status"],
                    "source": ["type": "string", "description": "Only this source reference"],
                    "changed_since_mark": ["type": "boolean", "description": "true: only notes whose text or analysis changed after the mark"],
                    "limit": limitProperty(default: 50, max: 500, pageLimit: pageLimit),
                    "offset": ["type": "integer", "description": "Skip this many (for the next page)"],
                ],
            ],
        ],
        [
            "name": "set_pass_boundary",
            "description": "Remember where your pass ended: the as_of (or the last next_cursor) of the changed_notes walk you finished. changed_notes since: \"last_pass\" then starts there; changed_notes and marked_notes show it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "as_of": ["type": "string", "description": "The moment the pass covers up to (\(dateHelp)); usually as_of from changed_notes"],
                    "cursor": ["type": "string", "description": "Alternatively the last next_cursor: its change time becomes the boundary"],
                    "comment": ["type": "string", "description": "Short note, e.g. the pass number"],
                ],
            ],
        ],
        [
            "name": "create_note",
            "description": "Save a new Markdown note from the discussion when the user asks to save it in Wimm. Creates a .md file in the ordinary note library; preserves the Markdown verbatim. Does not edit existing notes or run paid analysis. Returns the note id and file path. Each call creates a new note; do not retry blindly after an uncertain result. Unavailable in private mode or restricted secretary sessions.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Note title (non-empty, up to 1,000 UTF-8 bytes)"],
                    "markdown": ["type": "string", "description": "Complete Markdown body (non-empty, up to 1,000,000 UTF-8 bytes)"],
                ],
                "required": ["title", "markdown"],
                "additionalProperties": false,
            ],
        ],
    ] }

    /// Tools that stay available in private mode: their replies carry no note text.
    static let privateModeTools: Set<String> = ["request_retranscription", "retranscription_queue"]

    static let noteRefHelp = "note id, an unambiguous prefix of it, or the note's file name (Wimm_2026-10-13_01-08-40_BD002026.m4a, its .meta.json, or the name without extension)"

    func callTool(name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            if let allowedTools, !allowedTools.contains(name) { throw ToolError("Tool is disabled for this MCP session: \(name)") }
            // The agent on the other end is usually a cloud model, so this is
            // egress of raw note text. Private mode masks every cloud request
            // Wimm makes; it fails closed here rather than hand out unmasked text.
            // The retranscription tools print ids, file names and outcomes, never
            // note text; requestRetranscription refuses cloud models itself.
            if isPrivate(), !Self.privateModeTools.contains(name) {
                throw ToolError("Wimm is in private mode: note text is not shared with agents. Turn private mode off in Wimm to use this tool.")
            }
            let text: String
            switch name {
            case "get_note_image":
                guard let id = arguments["id"] as? String,let note = NoteRecall.find(await library(),reference:id) else { throw ToolError("No single note matches this reference") }
                let assets = NoteVisualSource.assets(for:URL(fileURLWithPath:note.filePath))
                let index = int(arguments["image_index"]) ?? 0, page = int(arguments["page"]) ?? 1
                guard index > 0,index <= assets.count,page > 0 else { throw ToolError("Invalid visual-source index or page") }
                if arguments["page"] != nil, int(arguments["page"]) == nil { throw ToolError("page must be an integer") }
                var crop: CGRect?
                if arguments["crop"] != nil, !(arguments["crop"] is [String:Any]) { throw ToolError("crop must be an object") }
                if let value = arguments["crop"] as? [String:Any] {
                    guard let x = value["x"] as? Double,let y = value["y"] as? Double,
                          let w = value["width"] as? Double,let h = value["height"] as? Double else { throw ToolError("crop requires x,y,width,height numbers") }
                    crop = CGRect(x:x,y:y,width:w,height:h)
                }
                let exported = try NoteVisualSource.export(assets[index-1],page:page,crop:crop)
                let data = try JSONSerialization.data(withJSONObject:exported.receipt,options:[.sortedKeys])
                if let readLog {
                    let path = readLog.appendingPathExtension("visual")
                    try AgentStateLock.withLock(in:path.deletingLastPathComponent(),name:path.lastPathComponent) {
                        if !FileManager.default.fileExists(atPath:path.path) { try Data().write(to:path,options:.atomic) }
                        let file = try FileHandle(forWritingTo:path);defer { try? file.close() };try file.seekToEnd();try file.write(contentsOf:data+Data([10]))
                    }
                }
                return ["content":[["type":"text","text":String(decoding:data,as:UTF8.self)],
                    ["type":"image","mimeType":"image/jpeg","data":exported.data.base64EncodedString()]]]
            case "create_note":
                guard let title = arguments["title"] as? String,
                      let markdown = arguments["markdown"] as? String else {
                    throw ToolError("title and markdown are required strings")
                }
                let file = try MarkdownNoteCapture.save(title: title, markdown: markdown,
                                                        directory: noteDirectory(), date: now())
                text = "Created Markdown note.\nid: \(file.stableUUID.uuidString)\nfile: \(file.path)"
            case "secretary_review_document":
                guard let reviewContext else { throw ToolError("Document review is only available in a configured secretary run.") }
                guard let page = arguments["page"] as? Int else { throw ToolError("page is required (integer, starting at 0)") }
                text = try SecretaryCompletion.review(reviewContext, page: page)
            case "search_notes":
                let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { throw ToolError("query is required") }
                let since = try date(arguments["since"], name: "since")
                let until = try date(arguments["until"], name: "until")
                let updatedSince = try date(arguments["updated_since"], name: "updated_since")
                let limit = page(arguments["limit"], default: 10, max: 50)
                let offset = max(0, int(arguments["offset"]) ?? 0)
                let page = NoteRecall.searchPage(
                    await library(), query: query, since: since, until: until,
                    updatedSince: updatedSince, offset: offset, limit: limit)
                text = page.hits.isEmpty
                    ? (page.total == 0 ? "No notes match \"\(query)\"." : "No more matches: \(page.total) in all.")
                    : "\(page.total) note(s) match \"\(query)\"\(range(offset, page.hits.count, page.total)):\n\n"
                        + page.hits.map { line(for: $0.note, detail: $0.snippet) }.joined(separator: "\n\n")
            case "recent_notes":
                var since = try date(arguments["since"], name: "since")
                if let days = int(arguments["days"]), days > 0 {
                    let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
                    since = max(since ?? cutoff, cutoff)
                }
                let until = try date(arguments["until"], name: "until")
                let updatedSince = try date(arguments["updated_since"], name: "updated_since")
                let includeEmpty = bool(arguments["include_empty"]) ?? true
                let limit = page(arguments["limit"], default: 20, max: 100)
                let offset = max(0, int(arguments["offset"]) ?? 0)
                let page = NoteRecall.recentPage(
                    await library(), since: since, until: until,
                    updatedSince: updatedSince, includeEmpty: includeEmpty, offset: offset, limit: limit)
                text = page.notes.isEmpty
                    ? (page.total == 0 ? "No notes in that window." : "No more notes: \(page.total) in that window.")
                    : "\(page.total) note(s) in that window\(range(offset, page.notes.count, page.total)):\n\n"
                        + page.notes.map { line(for: $0, detail: preview(of: $0)) }.joined(separator: "\n\n")
            case "changed_notes":
                var since: Date?
                let lastPass = marks.pass()
                if (arguments["since"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() == "last_pass" {
                    guard let lastPass else {
                        throw ToolError("No pass boundary is stored yet; set one with set_pass_boundary.")
                    }
                    since = lastPass.asOf
                } else {
                    since = try date(arguments["since"], name: "since")
                }
                var cursor: NoteRecall.ChangeCursor?
                if let raw = (arguments["cursor"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
                    guard let parsed = NoteRecall.ChangeCursor(token: raw) else {
                        throw ToolError("cursor is not one this server returned: \"\(raw)\".")
                    }
                    cursor = parsed
                    // An explicit since still wins; a cursor alone keeps its walk's.
                    since = since ?? parsed.since
                }
                let limit = page(arguments["limit"], default: 50, max: 200)
                // Taken before the load, so a change landing during it is still
                // at or after the next pass's `since`.
                let asOf = now()
                let allMarks = marks.marks()
                let wanted = Set((arguments["marked_changes"] as? String ?? "")
                    .split(separator: ",").compactMap { NoteChangeKind(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) })
                let skipUnchanged = bool(arguments["skip_unchanged_marked"]) == true
                var include: ((String) -> Bool)?
                if skipUnchanged || (!wanted.isEmpty && since != nil) {
                    include = { path in
                        let url = URL(fileURLWithPath: path)
                        guard let mark = allMarks[url.lastPathComponent] else { return true }
                        if skipUnchanged, Self.sinceMark(mark, NoteFingerprint.read(forRecordingURL: url)) == nil { return false }
                        if !wanted.isEmpty, let since {
                            return !wanted.isDisjoint(with: NoteChangeKind.kinds(forRecordingURL: url, since: since))
                        }
                        return true
                    }
                }
                let page = NoteRecall.changed(await library(), since: since, after: cursor, limit: limit,
                                               newestFirst: (arguments["order"] as? String) == "newest_first", include: include)
                var head = [
                    "total: \(page.total)",
                    "returned: \(page.notes.count)",
                    "remaining: \(page.remaining)",
                    "as_of: \(Self.iso(asOf))",
                ]
                if let next = page.next
                    ?? cursor.map({ NoteRecall.ChangeCursor(updated: $0.updated, id: $0.id, since: since) }) {
                    head.append("next_cursor: \(next.token)")
                }
                if let lastPass { head.append("last_pass: \(describe(lastPass))") }
                let queued = queue.entries()
                text = head.joined(separator: "\n") + "\n\n"
                    + (page.notes.isEmpty
                        ? "No changed notes."
                        : page.notes.map { note in
                            let url = URL(fileURLWithPath: note.filePath)
                            var extra: [String] = []
                            if let since {
                                extra.append("changes: " + NoteChangeKind.kinds(forRecordingURL: url, since: since)
                                    .map(\.rawValue).joined(separator: ", "))
                            }
                            if let mark = allMarks[url.lastPathComponent] {
                                extra.append(markLine(mark, url: url))
                            }
                            if let request = queued.last(where: { $0.file == note.filePath || $0.parentFile == note.filePath }) {
                                extra.append("retranscription: " + describe(request))
                            }
                            return line(for: note, detail: preview(of: note), showUpdated: true, extra: extra)
                        }.joined(separator: "\n\n"))
                if let readLog {
                    let policy = (arguments["since"] as? String) == "last_pass" && skipUnchanged
                        && wanted == Set([NoteChangeKind.transcript, .edited])
                        && (arguments["order"] as? String) == "newest_first"
                    try SecretaryCompletion.append(SecretaryCompletion.QueueReceipt(initial: cursor == nil, policy: policy,
                        returned: page.notes.count, remaining: page.remaining), to: readLog.appendingPathExtension("queue"))
                }
            case "get_note":
                let id = arguments["id"] as? String ?? ""
                guard let note = NoteRecall.find(await library(), reference: id) else {
                    throw ToolError("No single note matches \"\(id)\".")
                }
                let read = readNote(note, full: arguments["full"] as? Bool ?? false)
                if let readLog, let receipt = read.receipt { try receipt.append(to: readLog) }
                text = read.text
            case "request_retranscription":
                text = try await requestRetranscription(arguments)
            case "retranscription_queue":
                let state = (arguments["state"] as? String).flatMap(RetranscriptionQueue.Entry.State.init(rawValue:))
                let limit = clamp(arguments["limit"], default: 50, max: 500)
                let all = queue.entries().filter { state == nil || $0.state == state }
                let shown = all.reversed().prefix(limit)
                text = all.isEmpty
                    ? "No retranscription requests\(state.map { " in state \($0.rawValue)" } ?? "")."
                    : "\(all.count) request(s)\(state.map { " in state \($0.rawValue)" } ?? ""):\n\n"
                        + shown.map { "[\($0.noteId)] \(URL(fileURLWithPath: $0.file).lastPathComponent) · \($0.model)\n  \(describe($0))" }
                            .joined(separator: "\n")
            case "mark_notes":
                text = try await markNotes(arguments)
            case "marked_notes":
                text = try await markedNotes(arguments)
            case "set_pass_boundary":
                var asOf = try date(arguments["as_of"], name: "as_of")
                let rawCursor = (arguments["cursor"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                if !rawCursor.isEmpty {
                    guard let parsed = NoteRecall.ChangeCursor(token: rawCursor) else {
                        throw ToolError("cursor is not one this server returned: \"\(rawCursor)\".")
                    }
                    if asOf == nil { asOf = parsed.updated }
                }
                guard let asOf else { throw ToolError("Give as_of or cursor.") }
                let pass = AgentMarkStore.PassBoundary(
                    asOf: asOf, cursor: rawCursor.isEmpty ? nil : rawCursor,
                    comment: Self.trimmed(arguments["comment"], max: 500), setAt: now())
                try marks.setPass(pass)
                text = "Pass boundary stored: \(describe(pass)). changed_notes with since: \"last_pass\" starts there."
            default:
                throw ToolError("Unknown tool: \(name)")
            }
            return ["content": [["type": "text", "text": text]]]
        } catch {
            let message = (error as? ToolError)?.message ?? error.localizedDescription
            return ["content": [["type": "text", "text": message]], "isError": true]
        }
    }

    // MARK: - Rendering

    private func line(for note: RecallNote, detail: String, showUpdated: Bool = false, extra: [String] = []) -> String {
        var header = "[\(note.id)] \(format(note.date)) · \(note.kind)"
        if showUpdated, let updated = note.updated { header += " · updated \(Self.iso(updated))" }
        if let title = note.title { header += " · \(title)" }
        let facts = facts(of: note)
        if !facts.isEmpty { header += "\n  " + facts }
        for line in extra { header += "\n  " + line }
        return detail.isEmpty ? header : header + "\n  " + detail
    }

    /// `duration: 4101 s (68 min) · speech: speech · chars: 312 · device: iPhone · updated: …`
    private func facts(of note: RecallNote) -> String {
        var parts: [String] = []
        if let duration = note.duration { parts.append("duration: \(Self.seconds(duration))") }
        if let speech = note.speech { parts.append("speech: \(speech)") }
        if let chars = note.chars { parts.append("chars: \(chars)") }
        if let device = note.device { parts.append("device: \(device)") }
        if let updated = note.updated { parts.append("updated: \(format(updated, seconds: true))") }
        return parts.joined(separator: " · ")
    }

    private func preview(of note: RecallNote) -> String {
        if let summary = note.summary { return summary }
        let flat = note.text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 240 ? String(flat.prefix(240)) + "…" : flat
    }

    /// Placeholders `NoteBuilder` puts in place of a transcript; the
    /// `speech:` line says the same thing honestly.
    static let placeholderTexts: Set<String> = ["no speech detected", "transcription failed", "no text recognized",
                                                NoteContent.unreadableFilePlaceholder.lowercased()]

    /// A placeholder, also with a reason appended: "Transcription failed (network)".
    static func isPlaceholder(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return placeholderTexts.contains { lower == $0 || lower.hasPrefix($0 + " (") }
    }

    /// Below this many characters per second of audio a transcript is
    /// flagged as partial (speech runs ~12–15).
    static let minimumCharsPerSecond = 3.0

    func fullText(of note: RecallNote) -> String { readNote(note).text }

    public enum NoteReadFormat {
        case standard
        case secretaryPacket
        case secretaryPacketWithMetadata
    }

    /// Packet formatting omits host bookkeeping, never source evidence. Coverage
    /// is generated by the same block renderer as the actual supplied text.
    public struct EvidenceBlock: Codable, Sendable {
        public let label: String
        public let text: String
        public let transcriptKind: String?
        public let isTranscript: Bool
        public let words: Int?
    }

    /// The optional observer sees the same typed blocks and warnings as the renderer.
    /// Consumers may share exact bytes; they must retain every block and provenance label.
    public func readNote(_ note: RecallNote, full: Bool = false, format: NoteReadFormat = .standard,
                         evidence: ((String, [EvidenceBlock]) -> Void)? = nil) -> (text: String, receipt: SecretaryReadReceipt?) {
        let compact = format != .secretaryPacketWithMetadata
        let mediaURL = URL(fileURLWithPath: note.filePath)
        let loaded = RecallSidecar.load(forRecordingURL: mediaURL)
        let meta = loaded?.sidecar ?? RecallSidecar([:])
        let isAudio = note.kind == "audio"
        let content = NoteContent.load(anchor: mediaURL, sidecar: meta.dict)
        let typed = content.fileText

        var out = ["date: \(Self.iso(note.date)) (captured)", "kind: \(note.kind)"]
        if format == .standard {
            out.insert("id: \(note.id)", at: 0)
        }
        if !compact {
            out.append("file: \(note.filePath)")
        }
        if content.fileUnreadable {
            out.append("file_unreadable: the note's file could not be read as UTF-8 (other encoding or not downloaded); any text below is the sidecar copy, not the file")
        }
        if meta.isAgentDiscussion {
            out.append("source: agent-discussion (agent-authored discussion note, not independent evidence)")
        }
        if meta.conversationFile != nil || meta.originHeading != nil || meta.originSection != nil {
            let parts = [
                meta.originSource,
                meta.conversationFile.map { "file=\($0)" },
                meta.originHeading.map { "heading=«\($0)»" } ?? meta.originSection.map { "section=\($0)" },
            ].compactMap { $0 }
            if !parts.isEmpty {
                out.append("conversation: \(parts.joined(separator: "; "))")
            }
        }
        if !compact, let loaded {
            out.append("meta: \(loaded.url.path)")
            out.append("sha256: \(SHA256.hash(data: loaded.data).map { String(format: "%02x", $0) }.joined())")
        }
        // Read now, not from the cached library: the hash above is of the file as it is now.
        if !compact, let updated = RecallSidecar.updated(forRecordingURL: mediaURL) ?? note.updated {
            out.append("updated: \(Self.iso(updated))")
        }
        if !compact, let synced = meta.syncUpdatedAt { out.append("sync_updated: \(Self.iso(synced))") }
        let duration = isAudio ? meta.duration ?? note.duration : nil
        if let duration { out.append("duration: \(Self.seconds(duration))") }
        var speech = loaded == nil ? note.speech : meta.speech(isAudio: isAudio)
        // Old notes keep the transcript outside the sidecar; the build found it.
        if speech == "failed", note.speech == "speech" { speech = "speech" }
        if let speech { out.append("speech: \(speech)") }
        if let failure = meta.failureReason { out.append("failure: \(failure)") }
        switch (meta.platform, meta.deviceModel) {
        case let (platform?, model?) where platform != model: out.append("device: \(platform) (\(model))")
        case let (platform?, _): out.append("device: \(platform)")
        case let (nil, model?): out.append("device: \(model)")
        case (nil, nil): if let device = note.device { out.append("device: \(device)") }
        }
        // Compact reads carry no title/summary: a fallback one repeats the text's first words and a
        // model one is a derivative; the evidence blocks below are the source.
        if !compact, let title = note.title { out.append("title: \(title)") }
        if !compact, let summary = note.summary { out.append("summary: \(summary)") }
        if !compact, note.title != nil || note.summary != nil {
            out.append(meta.processedAt.map { "title_source: model (analysis \(Self.iso($0))) — title and summary are generated, not the user's words" }
                ?? "title_source: fallback — no model analysis; title and summary are the first words of the text or typed by hand")
        }
        if let mark = marks.mark(forFile: mediaURL.lastPathComponent) { out.append(markLine(mark, url: mediaURL)) }
        if let request = queue.latest(forNote: note.filePath) { out.append("retranscription: \(describe(request))") }
        if isAudio, let split = meta.speakerSplit, let line = Self.voicesLine(split) { out.append(line) }

        var blocks = textBlocks(of: note, meta: meta, typed: typed)
        if compact {
            let packed = Self.packetImageStatus(blocks)
            blocks = packed.blocks
            if packed.omitted > 0 {
                out.append("image_status: \(packed.omitted) default status blocks omitted (empty barcodes/detected data, no layout record, no MLX description, no diagnostic issues); visual accuracy unverified")
            }
            // A fallback copy can hold words of a text that was replaced since; omit it only
            // when every word already appears in another block of this note.
            for i in blocks.indices where blocks[i].label == "refined (fallback copy)" {
                let elsewhere = Set(blocks.indices.filter { $0 != i }.flatMap { Self.words(blocks[$0].text) })
                guard Self.words(blocks[i].text).allSatisfy(elsewhere.contains) else { continue }
                blocks[i].packetOmission = "fallback_copy"
                out.append("refined: unedited fallback copy; every word appears in the text below, omitted")
            }
        }
        // The visual roster is a host inventory, not OCR/observations/history.
        // Packet passes cannot request originals; all image evidence blocks stay.
        let assets = compact ? [] : NoteVisualSource.assets(for:mediaURL)
        if !assets.isEmpty {
            blocks.append(TextBlock(label:"visual source roster (originals not supplied by this text read)",text:assets.enumerated().map { i, asset in
                "image_index=\(i+1); role=\(asset.role); source=\(asset.url.path); available=\(FileManager.default.fileExists(atPath:asset.url.path)); use get_note_image(id,image_index,page,crop) when required"
            }.joined(separator:"\n")))
        }
        if full {
            // Packet receipts attest complete supplied text. Collapse only exact
            // copies here: punctuation or case can change a source's meaning.
            var exact: [Data: String] = [:]
            for i in blocks.indices {
                if blocks[i].packetOmission != nil { continue }
                let bytes = Data(blocks[i].text.utf8)
                blocks[i].sameAs = exact[bytes]
                if blocks[i].sameAs == nil { exact[bytes] = blocks[i].label }
            }
        }
        if isAudio, speech == "speech", let duration, duration >= 30 {
            let longest = blocks.filter { $0.isTranscript }.map(\.text.count).max() ?? 0
            if Double(longest) < duration * Self.minimumCharsPerSecond {
                out.append("coverage: ~\(Int((Double(longest) / 15).rounded())) s text for \(Int(duration.rounded())) s audio — the transcript likely misses most of the recording")
            }
        }
        out.append("")
        let rendered = render(blocks, limit: full ? blocks.reduce(0) { $0 + $1.text.count } : Self.maxNoteChars, showWordCounts: true)
        let truncated = rendered.coverage.contains { $0.state == "truncated" }
        if truncated {
            out.append("text_scope: partial_text" + (compact ? "" : " — version receipts attest supplied text, not factual accuracy"))
        } else if !compact {
            let allSupplied = rendered.coverage.allSatisfy { SecretaryReadReceipt.suppliedStates.contains($0.state) }
            out.append("text_scope: " + (allSupplied ? "all_available_text" : "partial_text") + " — version receipts attest supplied text, not factual accuracy")
        }
        var unrecordedQuality = 0
        for block in blocks where block.isTranscript {
            let quality = block.quality ?? RecallSidecar.unavailableQuality
            if quality == RecallSidecar.unavailableQuality || quality == #"{"checks":"not_recorded","status":"unknown"}"# {
                if block.kind == .realtime { continue }
                if compact { unrecordedQuality += 1; continue }
            }
            out.append("asr_quality[\(block.label)]: \(quality)")
        }
        if unrecordedQuality > 0 { out.append("asr_quality: not recorded for \(unrecordedQuality) transcript(s); unknown, not healthy") }
        evidence?(out.joined(separator: "\n"), blocks.map {
            EvidenceBlock(label: $0.label, text: $0.text, transcriptKind: $0.kind?.rawValue,
                          isTranscript: $0.isTranscript, words: $0.isTranscript ? $0.wordCount : nil)
        })
        out.append(blocks.isEmpty ? "(no text)" : rendered.text)
        let receipt = loaded.flatMap { loaded -> SecretaryReadReceipt? in
            // A missing typed body or cached fallback text cannot attest a current version.
            guard note.kind != "text" || typed != nil else { return nil }
            guard note.kind != "audio" || meta.transcript != nil || note.text.isEmpty || Self.placeholderTexts.contains(note.text.lowercased()) else { return nil }
            let fingerprint = NoteFingerprint.make(meta, typed: typed)
            return SecretaryReadReceipt(file: mediaURL.path, sidecar: loaded.url.path, noteID: note.id,
                sha256: SecretaryCompletion.digest(loaded.data), text: fingerprint.text, analysis: fingerprint.analysis,
                suppliedText: rendered.coverage)
        }
        return (out.joined(separator: "\n"), receipt)
    }

    // MARK: - Agent bookkeeping

    /// Ids, prefixes or file names → notes; unresolved references are reported, not fatal.
    private func resolve(_ references: [String], in library: RecallLibrary) -> [(ref: String, note: RecallNote?)] {
        references.map { ($0, NoteRecall.find(library, reference: $0)) }
    }

    private func requestRetranscription(_ arguments: [String: Any]) async throws -> String {
        let refs = Self.strings(arguments["ids"])
        guard !refs.isEmpty else { throw ToolError("ids is required: one or more note ids or file names.") }
        guard refs.count <= 200 else { throw ToolError("At most 200 ids per call, got \(refs.count).") }
        let model = Self.trimmed(arguments["model"], max: 120) ?? retranscriptionModel()
        // Same rule as every cloud caller: in private mode no audio leaves the
        // Mac, so only an on-device model may run. Refused here, not in the
        // worker, so the agent hears it now instead of a failed entry later.
        if isPrivate(), !ParakeetModel.isParakeet(model) {
            throw ToolError("Wimm is in private mode: \(model) would send the audio to the cloud. Use model parakeet:ultra (on-device), or turn private mode off in Wimm.")
        }
        let analyze = bool(arguments["analyze"]) ?? true
        let reason = Self.trimmed(arguments["reason"], max: 500)
        let requestedAt = now()
        var lines: [String] = []
        var requests: [RetranscriptionQueue.Entry] = []
        for (ref, note) in resolve(refs, in: await library()) {
            guard let note else { lines.append("\(ref): no single note matches"); continue }
            guard note.kind == "audio" else {
                // An Evernote note is text whose audio sits in its attachments:
                // each one becomes its own entry, written back onto the note.
                let audio = NoteAttachmentMedia.audio(ofNote: URL(fileURLWithPath: note.filePath))
                guard !audio.isEmpty else {
                    lines.append("\(ref): not audio (\(note.kind)) and no audio attachments — nothing to transcribe")
                    continue
                }
                for item in audio {
                    // One analysis per note, after its last attachment.
                    requests.append(.init(file: item.url.path, noteId: note.id, model: model,
                                          analyze: analyze && item == audio.last,
                                          reason: reason, requestedAt: requestedAt,
                                          parentFile: note.filePath, attachmentID: item.id.uuidString))
                }
                continue
            }
            guard FileManager.default.fileExists(atPath: note.filePath) else {
                lines.append("\(ref): the recording file is missing (\(note.filePath))")
                continue
            }
            requests.append(.init(file: note.filePath, noteId: note.id, model: model, analyze: analyze,
                                  reason: reason, requestedAt: requestedAt))
        }
        let results = try queue.enqueue(requests)
        for (request, result) in zip(requests, results) {
            let name = URL(fileURLWithPath: request.file).lastPathComponent
            switch result {
            case .queued: lines.append("[\(request.noteId)] \(name)\(request.parentFile == nil ? "" : " (attachment)"): queued")
            case .alreadyOpen(let open): lines.append("[\(request.noteId)] \(name): already \(describe(open))")
            }
        }
        let queuedCount = results.filter { $0 == .queued }.count
        if queuedCount > 0 { startRetranscriptionWorker() }
        let open = queue.entries().filter(\.isOpen).count
        // A text note can add one request per audio attachment.
        return "\(queuedCount) of \(max(refs.count, requests.count)) queued with \(model)\(analyze ? ", analysis after speech" : ", no analysis"); \(open) open in the queue.\n"
            + "Results show up in changed_notes (changes: transcript); a no-speech verdict leaves the note unchanged — retranscription_queue or get_note shows it.\n\n"
            + lines.joined(separator: "\n")
    }

    private func markNotes(_ arguments: [String: Any]) async throws -> String {
        guard let items = arguments["marks"] as? [[String: Any]], !items.isEmpty else {
            throw ToolError("marks is required: [{id, status, source?, comment?}].")
        }
        guard items.count <= 500 else { throw ToolError("At most 500 marks per call, got \(items.count).") }
        let lib = await library()
        let markedAt = now()
        var changes: [String: AgentMarkStore.Mark?] = [:]
        var lines: [String] = []
        for item in items {
            let ref = (item["id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rawStatus = (item["status"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard let note = NoteRecall.find(lib, reference: ref) else {
                lines.append("\(ref.isEmpty ? "(no id)" : ref): no single note matches"); continue
            }
            let url = URL(fileURLWithPath: note.filePath)
            let file = url.lastPathComponent
            if rawStatus == "clear" {
                changes[file] = .some(nil)
                lines.append("[\(note.id)] \(file): mark cleared")
                continue
            }
            guard let status = AgentMarkStore.Mark.Status(rawValue: rawStatus) else {
                lines.append("[\(note.id)] \(file): status must be applied, pending, noise, failed or clear, got \"\(rawStatus)\"")
                continue
            }
            let fingerprint = NoteFingerprint.read(forRecordingURL: url)
            let sha = RecallSidecar.load(forRecordingURL: url).map { SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined() }
            changes[file] = AgentMarkStore.Mark(
                status: status, source: Self.trimmed(item["source"], max: 64),
                comment: Self.trimmed(item["comment"], max: 500), markedAt: markedAt, noteId: note.id,
                sidecarSHA256: sha, text: fingerprint.text, analysis: fingerprint.analysis, wording: fingerprint.wording)
            lines.append("[\(note.id)] \(file): \(status.rawValue)" + (Self.trimmed(item["source"], max: 64).map { " · \($0)" } ?? ""))
        }
        try marks.update(changes)
        return "\(changes.count) of \(items.count) mark(s) stored at \(Self.iso(markedAt)). Marks never change the notes.\n\n"
            + lines.joined(separator: "\n")
    }

    private func markedNotes(_ arguments: [String: Any]) async throws -> String {
        let status = (arguments["status"] as? String).flatMap { AgentMarkStore.Mark.Status(rawValue: $0.lowercased()) }
        let source = Self.trimmed(arguments["source"], max: 64)
        let changedOnly = bool(arguments["changed_since_mark"]) ?? false
        let limit = page(arguments["limit"], default: 50, max: 500)
        let offset = max(0, int(arguments["offset"]) ?? 0)
        let lib = await library()
        var rows: [(file: String, mark: AgentMarkStore.Mark, note: RecallNote?)] = []
        for (file, mark) in marks.marks() {
            if let status, mark.status != status { continue }
            if let source, mark.source != source { continue }
            let note = NoteRecall.find(lib, reference: file)
            if changedOnly {
                guard let note else { continue }
                let url = URL(fileURLWithPath: note.filePath)
                if Self.sinceMark(mark, NoteFingerprint.read(forRecordingURL: url)) == nil { continue }
            }
            rows.append((file, mark, note))
        }
        rows.sort { $0.mark.markedAt != $1.mark.markedAt ? $0.mark.markedAt > $1.mark.markedAt : $0.file < $1.file }
        var head = "\(rows.count) marked note(s)\(range(offset, min(limit, max(0, rows.count - offset)), rows.count))"
        if let pass = marks.pass() { head += "\nlast_pass: \(describe(pass))" }
        let shown = rows.dropFirst(offset).prefix(limit)
        guard !shown.isEmpty else { return rows.isEmpty ? "No marked notes match." : head + "\n\nNo more." }
        return head + ":\n\n" + shown.map { row in
            guard let note = row.note else {
                return "[\(row.mark.noteId)] \(row.file) — note no longer in the library\n  mark: \(row.mark.status.rawValue)"
                    + (row.mark.source.map { " · source \($0)" } ?? "")
            }
            return line(for: note, detail: "", extra: [markLine(row.mark, url: URL(fileURLWithPath: note.filePath))])
        }.joined(separator: "\n\n")
    }

    /// `mark: applied · source S1157 · marked … · since mark: unchanged`
    private func markLine(_ mark: AgentMarkStore.Mark, url: URL) -> String {
        var parts = ["mark: \(mark.status.rawValue)"]
        if let source = mark.source { parts.append("source \(source)") }
        parts.append("marked \(Self.iso(mark.markedAt))")
        parts.append("since mark: " + (Self.sinceMark(mark, NoteFingerprint.read(forRecordingURL: url)) ?? "unchanged"))
        if let comment = mark.comment { parts.append("comment: \(comment)") }
        return parts.joined(separator: " · ")
    }

    /// What changed in the note since the mark, nil when nothing did.
    static func sinceMark(_ mark: AgentMarkStore.Mark, _ now: NoteFingerprint) -> String? {
        switch (mark.text != now.text, mark.analysis != now.analysis) {
        case (true, true): return NoteFingerprint.sameWording(mark, now) ? "punctuation and analysis changed" : "text and analysis changed"
        case (true, false): return NoteFingerprint.sameWording(mark, now) ? "punctuation changed" : "text changed"
        case (false, true): return "analysis changed"
        case (false, false): return nil
        }
    }

    private func describe(_ pass: AgentMarkStore.PassBoundary) -> String {
        "\(Self.iso(pass.asOf)) (set \(Self.iso(pass.setAt)))" + (pass.comment.map { " — \($0)" } ?? "")
    }

    private func describe(_ entry: RetranscriptionQueue.Entry) -> String {
        switch entry.state {
        case .queued: return "queued \(Self.iso(entry.requestedAt)) (\(entry.model))"
        case .running: return "running since \(entry.startedAt.map(Self.iso) ?? "?") (\(entry.model))"
        case .done, .failed:
            return "\(entry.state.rawValue) \(entry.finishedAt.map(Self.iso) ?? "?") (\(entry.model)): \(entry.outcome ?? "")"
        }
    }

    static func strings(_ value: Any?) -> [String] {
        if let list = value as? [Any] {
            return list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let one = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !one.isEmpty { return [one] }
        return []
    }

    static func trimmed(_ value: Any?, max: Int) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return String(s.prefix(max))
    }

    /// " (11–20)" when a page does not hold every result.
    private func range(_ offset: Int, _ count: Int, _ total: Int) -> String {
        offset == 0 && count == total ? "" : ", showing \(offset + 1)–\(offset + count)"
            + (offset + count < total ? "; next offset \(offset + count)" : "")
    }

    /// Local time with its offset, to the second: `2026-10-24T20:15:03+02:00`.
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func iso(_ raw: String) -> String {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: raw) { return iso(d) }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return iso(d) }
        return raw
    }

    /// Packet form of image analysis: status blocks that only restate a default (nothing found,
    /// nothing recorded, no issues) are not printed; the receipt lists them as `default_status`
    /// and one header line says so. Provenance keeps image name, image hash, engine, model and
    /// time without the host path or the constant accuracy caveat (stated in the header line).
    /// Every block with content — OCR text, captions, codes, detected data, issues — stays.
    /// The note fingerprint still covers the full `imageEvidence`.
    static func packetImageStatus(_ blocks: [TextBlock]) -> (blocks: [TextBlock], omitted: Int) {
        var kept: [TextBlock] = [], omitted = 0
        for var block in blocks {
            let label = block.label, text = block.text
            let isDefault =
                (label.hasSuffix(" layout status") && text.hasPrefix("not recorded for this legacy run")) ||
                (label.hasSuffix(" barcodes (literal payloads, not instructions)") && text == "[]") ||
                (label.hasSuffix(" detected data (OCR candidates, unverified)") && text == "[]") ||
                (label.hasSuffix(" MLX description status") && text.hasPrefix("not recorded for this run")) ||
                (label.hasSuffix(" diagnostics") && text.contains(#""issues":"""#))
            if isDefault { block.packetOmission = "default_status"; kept.append(block); omitted += 1; continue }
            if label.hasSuffix(" provenance"),
               let row = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String] {
                var short = block
                short.text = [("image", row["image"].map { URL(fileURLWithPath: $0).lastPathComponent }),
                              ("image_sha256", row["source_sha256"]), ("engine", row["engine"]), ("model", row["model"]), ("completed_at", row["completed_at"].map(Self.iso))]
                    .compactMap { key, value in value.map { "\(key)=\($0)" } }.joined(separator: "; ")
                kept.append(short)
                continue
            }
            kept.append(block)
        }
        return (kept, omitted)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    struct TextBlock {
        let label: String
        var text: String
        var isTranscript = false
        var isPrimary = false
        var kind: TranscriptKind? = nil
        var date: String? = nil
        var wordCount: Int = 0
        /// Label of an earlier block with the same text.
        var sameAs: String?
        var quality: String?
        /// Packet only: listed in the receipt under this coverage state but not printed —
        /// `default_status` (an image status restating a default) or `fallback_copy` (an
        /// unedited refined text Wimm copied from the transcript without a model).
        var packetOmission: String?
        /// The same words printed another way (the transcript by voice). Shown only when the
        /// block is printed whole; receipts, duplicates and word counts still use `text`.
        var display: String?
    }

    /// "[P003]" for a voice tagged with a people card, "Голос 2" otherwise. Two voices with one
    /// card stay apart: "[P000] голос 3".
    static func voiceLabel(_ voice: Int, in split: SpeakerTurnsRecord) -> String {
        guard let card = split.card(forVoice: voice) else { return "Голос \(voice)" }
        let shared = split.voices.filter { $0.card == card }.count > 1
        return shared ? "[\(card)] голос \(voice)" : "[\(card)]"
    }

    /// Wimm's own header line about the voices of a split; nil when there is nothing to say.
    static func voicesLine(_ split: SpeakerTurnsRecord) -> String? {
        let numbers = split.isMultiSpeaker ? Set(split.turns.map(\.speaker)).sorted() : (split.voices.isEmpty ? [] : [1])
        guard !numbers.isEmpty else { return nil }
        guard !split.voices.isEmpty else {
            return "voices: \(numbers.count), not compared with voice profiles"
        }
        let parts = numbers.map { voice -> String in
            let tag = split.voices.first { $0.voice == voice }
            let score = tag?.score.map { String(format: " %.2f", $0) } ?? ""
            if let card = tag?.card { return "Голос \(voice) = [\(card)]\(score)" }
            return "Голос \(voice) = unknown" + (tag == nil ? "" : " (best\(score))")
        }
        return "voices: " + parts.joined(separator: "; ")
            + " — on-device voice match; a card id means mostly that person, an unknown voice is nobody known"
    }

    /// The transcript as turns, only when the split is of exactly these words.
    static func byVoice(_ transcript: String, split: SpeakerTurnsRecord?) -> String? {
        guard let split, split.isMultiSpeaker else { return nil }
        func words(_ text: String) -> [Substring] { text.split(whereSeparator: \.isWhitespace) }
        guard words(split.turns.map(\.text).joined(separator: " ")) == words(transcript) else { return nil }
        return SpeakerTurns.render(split.turns) { voiceLabel($0, in: split) }
    }

    /// Every stored text variant, in reading order. Variants disagree — a
    /// refined text can be worse than its transcript — so none is chosen
    /// for the agent; repeats collapse to "= <label>".
    private func textBlocks(of note: RecallNote, meta: RecallSidecar, typed: String?) -> [TextBlock] {
        var blocks: [TextBlock] = []
        // Line endings and outer space do not make two texts different.
        func plain(_ value: String) -> String {
            value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let text = note.kind == "text" ? (typed ?? note.text) : note.text
        let typedFile = note.kind == "text" ? plain(text) : ""
        if note.kind == "text", !text.isEmpty, !Self.placeholderTexts.contains(text.lowercased()) {
            blocks.append(TextBlock(label: "document", text: text, isPrimary: true))
        }
        // A text note whose file already carries the sidecar transcript (a lost
        // recording turned into `.txt`: header + transcript) shows it once, as the file.
        if let transcript = meta.transcript, typedFile.isEmpty || !typedFile.contains(plain(transcript)) {
            let source = RecallSidecar.join(meta.transcriptionProvider, meta.transcriptionModel)
            // On an image or document the same field holds OCR or imported text.
            let label = note.kind == "audio" ? "transcript" : "text"
            let date = meta.transcribedAt.map(Self.iso) ?? (note.kind == "audio" ? Self.iso(note.date) : nil)
            blocks.append(TextBlock(
                label: label + (source.map { " (\($0))" } ?? ""), text: transcript,
                isTranscript: note.kind == "audio", isPrimary: blocks.isEmpty,
                kind: note.kind == "audio" ? meta.transcriptionKind : nil, date: date, quality: meta.qualitySummary(),
                display: note.kind == "audio" ? Self.byVoice(transcript, split: meta.speakerSplit) : nil))
        } else if note.kind != "text", meta.transcript == nil, !text.isEmpty, !Self.placeholderTexts.contains(text.lowercased()) {
            // Transcript kept outside the sidecar (old notes) or no sidecar at all.
            blocks.append(TextBlock(
                label: "text", text: text, isTranscript: note.kind == "audio",
                isPrimary: blocks.isEmpty, date: note.kind == "audio" ? Self.iso(note.date) : nil))
        }
        if let local = meta.localTranscript {
            blocks.append(TextBlock(
                label: "realtime transcript", text: local, isTranscript: true,
                isPrimary: blocks.isEmpty, kind: .realtime, date: Self.iso(note.date)))
        }
        for run in meta.otherRuns {
            let source = RecallSidecar.join(run.provider, run.model)
            blocks.append(TextBlock(
                label: "earlier \(run.kind?.rawValue ?? "") transcript" + (source.map { " (\($0))" } ?? ""),
                text: run.text, isTranscript: true, kind: run.kind, date: run.startedAt.map(Self.iso),
                quality: meta.qualitySummary(archiveIndex: run.archiveIndex)))
        }
        // A failed run's placeholder ("Transcription failed (network)") gets archived like text.
        let earlier = meta.previousRuns.filter { !Self.isPlaceholder($0.transcript) }
        for (i, run) in earlier.enumerated() {
            let detail = [run.source, run.startedAt.map(Self.iso), run.replacedAt.map { "replaced \(Self.iso($0))" }].compactMap { $0 }.joined(separator: ", ")
            blocks.append(TextBlock(
                label: "earlier transcript \(i + 1)" + (detail.isEmpty ? "" : " (\(detail))"),
                text: run.transcript, isTranscript: note.kind == "audio", kind: note.kind == "audio" ? run.kind : nil, quality: run.quality))
        }
        if let document = meta.documentText {
            if note.kind == "text" {
                // A text note's body is its file. An equal sidecar copy is no evidence;
                // a different one is an old copy (create_note wrote one until 2026-11-10).
                // Imports stored the copy with other line endings; that is still the same text.
                if plain(document) != plain(text) {
                    blocks.append(TextBlock(label: "document (stale sidecar copy, not the note's text)", text: document, isPrimary: blocks.isEmpty))
                }
            } else {
                blocks.append(TextBlock(label: "document" + (meta.documentSource.map { " (\($0))" } ?? ""), text: document, isPrimary: blocks.isEmpty))
            }
        }
        for (i, run) in meta.previousDocumentRuns.enumerated() where !Self.isPlaceholder(run.text) {
            let detail = [run.source, run.replacedAt.map { "replaced \(Self.iso($0))" }].compactMap { $0 }.joined(separator: ", ")
            blocks.append(TextBlock(
                label: "earlier document \(i + 1)" + (detail.isEmpty ? "" : " (\(detail))"),
                text: run.text
            ))
        }
        if let refined = meta.refined {
            let how = meta.refinedEditedAt.map { "edited \(Self.iso($0))" } ?? (meta.processedAt != nil ? "model" : "fallback copy")
            blocks.append(TextBlock(label: "refined (\(how))", text: refined))
        }
        if let ocr = meta.ocrText {
            blocks.append(TextBlock(label: "OCR" + (meta.ocrSource.map { " (\($0))" } ?? ""), text: ocr, isPrimary: blocks.isEmpty))
        }
        for (i, run) in meta.previousOCRRuns.enumerated() where !Self.isPlaceholder(run.text) {
            let detail = [run.source, run.replacedAt.map { "replaced \(Self.iso($0))" }].compactMap { $0 }.joined(separator: ", ")
            blocks.append(TextBlock(
                label: "earlier OCR \(i + 1)" + (detail.isEmpty ? "" : " (\(detail))"),
                text: run.text
            ))
        }
        let attachments = meta.attachments
        if attachments.isEmpty {
            for (i, extra) in note.attachmentTexts.enumerated() {
                blocks.append(TextBlock(label: "attachment \(i + 1)", text: extra))
            }
        } else {
            for a in attachments {
                let i = a.index
                let detail = [a.type == "image" ? "OCR" : a.type, a.source, a.prompt.map { "answer to «\($0)»" }]
                    .compactMap { $0 }.joined(separator: ", ")
                blocks.append(TextBlock(label: "attachment \(i + 1) (\(detail))", text: a.text))
                for (j, prev) in a.previousRuns.enumerated() where !Self.isPlaceholder(prev.text) {
                    let prevDetail = [
                        a.type == "image" ? "OCR" : a.type,
                        prev.source,
                        prev.replacedAt.map { "replaced \(Self.iso($0))" }
                    ].compactMap { $0 }.joined(separator: ", ")
                    blocks.append(TextBlock(
                        label: "earlier attachment \(i + 1) run \(j + 1) (\(prevDetail))",
                        text: prev.text
                    ))
                }
            }
        }
        for evidence in meta.imageEvidence {
            blocks.append(TextBlock(label:evidence.label,text:evidence.text))
        }
        var contextLines: [String] = []
        if let file = meta.conversationFile { contextLines.append("Conversation: \(file)") }
        if let heading = meta.originHeading { contextLines.append("Document section: \(heading)") }
        else if let section = meta.originSection { contextLines.append("Document section: \(section)") }
        if let quote = meta.originQuote { contextLines.append("Anchor quote: «\(quote)»") }
        if let prompt = meta.conversationPrompt { contextLines.append(prompt) }
        if !contextLines.isEmpty {
            blocks.append(TextBlock(
                label: "conversation context (dialogue/anchor this note replies to; for placement only, not user speech)",
                text: contextLines.joined(separator: "\n")
            ))
        }
        var seen: [String: String] = [:]
        for i in blocks.indices {
            if blocks[i].isTranscript {
                blocks[i].wordCount = TranscriptHealth.words(blocks[i].text).count
            }
            let key = Self.comparable(blocks[i].text)
            if let first = seen[key] {
                blocks[i].sameAs = first
            } else {
                seen[key] = blocks[i].label.components(separatedBy: " (").first ?? blocks[i].label
            }
        }
        return blocks
    }

    static func headerLabel(for block: TextBlock, showWordCounts: Bool) -> String {
        let base = block.isPrimary ? "primary \(block.label)" : block.label
        var extras: [String] = []
        if let date = block.date { extras.append(date) }
        if showWordCounts, block.isTranscript { extras.append("\(block.wordCount) words") }
        guard !extras.isEmpty else { return base }
        let suffix = extras.joined(separator: ", ")
        if base.hasSuffix(")") {
            return String(base.dropLast()) + ", \(suffix))"
        }
        return "\(base) (\(suffix))"
    }

    /// Case, punctuation and spacing do not make a variant different.
    static func comparable(_ text: String) -> String {
        String(text.lowercased().replacingOccurrences(of: "ё", with: "е").unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    /// Blocks share `maxNoteChars`: short ones stay whole, the longest are
    /// cut to an equal share. Repeats already cost one line.
    private func render(_ blocks: [TextBlock], limit: Int = Self.maxNoteChars, showWordCounts: Bool = false) -> (text: String, coverage: [SecretaryReadReceipt.TextCoverage]) {
        let unique = blocks.indices.filter { blocks[$0].sameAs == nil && blocks[$0].packetOmission == nil }
        var budget = limit
        var caps: [Int: Int] = [:]
        var left = unique.count
        for i in unique.sorted(by: { blocks[$0].text.count < blocks[$1].text.count }) {
            let cap = min(blocks[i].text.count, budget / max(1, left))
            caps[i] = cap
            budget -= cap
            left -= 1
        }
        var coverage: [SecretaryReadReceipt.TextCoverage] = []
        let text = blocks.indices.compactMap { i -> String? in
            let block = blocks[i]
            if let omission = block.packetOmission {
                coverage.append(.init(block: i, label: block.label, transcriptKind: nil, state: omission))
                return nil
            }
            let header = Self.headerLabel(for: block, showWordCounts: showWordCounts)
            let cap = caps[i] ?? block.text.count
            let state: String
            if block.sameAs != nil {
                // Display-only normalization is not proof that the original text was supplied.
                let exactFullCopy = blocks.indices.prefix(i).contains {
                    blocks[$0].text.utf8.elementsEqual(block.text.utf8) && blocks[$0].sameAs == nil && (caps[$0] ?? 0) >= blocks[$0].text.count
                }
                state = exactFullCopy ? "duplicate" : "omitted"
            } else { state = cap >= block.text.count ? "full" : "truncated" }
            coverage.append(.init(block: i, label: block.label, transcriptKind: block.kind?.rawValue, state: state))
            if let same = block.sameAs { return "--- \(header) --- = \(same)" }
            var body = block.text
            if body.count > cap {
                body = String(body.prefix(cap)) + "\n… [truncated, \(block.text.count) characters total]"
            } else if let display = block.display {
                return "--- \(header), by voice ---\n\(display)"
            }
            return "--- \(header) ---\n\(body)"
        }.joined(separator: "\n\n")
        return (text, coverage)
    }

    /// 0.007 s stays visible as such; long recordings also say minutes.
    static func seconds(_ value: Double) -> String {
        if value < 1 { return String(format: "%.3f s", value) }
        if value < 60 { return String(format: "%.1f s", value) }
        return String(format: "%.0f s (%.0f min)", value, value / 60)
    }

    func format(_ date: Date, seconds: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = seconds ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    // MARK: - Argument parsing

    struct ToolError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func clamp(_ value: Any?, default fallback: Int, max upper: Int) -> Int {
        min(upper, max(1, int(value) ?? fallback))
    }

    /// A listing page size: `clamp`, then the session's page cap.
    private func page(_ value: Any?, default fallback: Int, max upper: Int) -> Int {
        guard let pageLimit else { return clamp(value, default: fallback, max: upper) }
        return clamp(value, default: min(fallback, pageLimit), max: min(upper, pageLimit))
    }

    private func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        switch (value as? String)?.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    /// A zone-less date or time is local (`timeZone`): the user thinks in
    /// wall-clock time, and "everything after my last pass at 21:46" is
    /// the common question. A date alone is its local midnight.
    func date(_ value: Any?, name: String) throws -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let d = local.date(from: raw) { return d }
        }
        throw ToolError("\(name) must be \(Self.dateHelp), got \"\(raw)\".")
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"# }
        return text
    }
}

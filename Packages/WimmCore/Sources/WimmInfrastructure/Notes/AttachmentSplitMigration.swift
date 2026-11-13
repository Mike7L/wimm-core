import CryptoKit
import Foundation
import WimmDomain

/// One note = one media (decided 2026-11-09,
/// `docs/One_Note_One_Media_Decision_2026-11-09.md`, stage 2): turns every
/// entry of a sidecar's `attachments` into a note of its own.
///
/// Per attachment, in a crash-safe order:
/// 1. the new note's sidecar (identity, `origin`, `splitFrom`, carried text);
/// 2. the media is moved (never copied) into `Recordings/` under
///    `Wimm_<parent time + n s>_<id>.<ext>`, so it sorts right after the parent;
/// 3. its `_micro` (and legacy `_mini`) follows;
/// 4. a text parent gets a link (`[[Wimm_…]]`, or the evening journal's
///    `[голос](….meta.json)` under its question);
/// 5. the entry leaves the parent's `attachments` (the key goes when empty).
///
/// A parent without a media file of its own takes its first attachment as
/// that file instead. Entries whose file is missing, outside the library or
/// of a type the library does not list stay where they are and are reported.
///
/// The new note's identity is derived from the parent and attachment ids, and
/// `splitFrom` is found again on the next run, so a run stopped at any point
/// resumes and a finished run changes nothing. Dry-run unless `apply`. Every
/// sidecar write goes through `FileStore.mutateSidecar`. It never touches a
/// file outside the library root (`Options.library`).
public enum AttachmentSplitMigration {
    public static let tool = "split-attachments"
    public static let version = 1
    /// Sidecar key of the new note: provenance only, not a group.
    public static let splitFromKey = "splitFrom"
    /// Parent sidecar key when its first attachment became its own file.
    public static let promotedKey = "splitPromoted"

    public struct Options: Sendable {
        public var apply: Bool
        /// Parent sidecars and text bodies are copied here before their first write. Required to apply.
        public var backupDirectory: URL?
        /// Only these parent sidecar file names (e.g. `Wimm_…meta.json`).
        public var onlyParents: Set<String>?
        public var limit: Int?
        public var now: Date
        /// The library root (`Recordings/`, `Attachments/`). Nothing outside it is touched.
        public var library: URL

        public init(apply: Bool = false, backupDirectory: URL? = nil, onlyParents: Set<String>? = nil,
                    limit: Int? = nil, now: Date = Date(), library: URL = StoragePaths.baseDirectory()) {
            self.library = library
            self.apply = apply
            self.backupDirectory = backupDirectory
            self.onlyParents = onlyParents
            self.limit = limit
            self.now = now
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        public var attachmentID: String
        public var kind: String
        public var source: String
        public var target: String?
        /// split, promote, resume, duplicate, missing, outside-library, unsupported, invalid, conflict
        public var action: String
        public var micro: String?
        /// transcript, ocr, none
        public var text: String
        /// replaced, appended, present, non-text-parent, promoted, none
        public var link: String
        public var error: String?
    }

    public struct Parent: Codable, Sendable, Equatable {
        public var sidecar: String
        public var parentFile: String?
        public var parentKind: String
        public var source: String
        public var emptyListRemoved: Bool
        public var items: [Item]
        public var error: String?
    }

    public struct Totals: Codable, Sendable, Equatable {
        public var sidecarsScanned = 0
        public var parentsWithAttachments = 0
        public var parentsToChange = 0
        public var parentsFailed = 0
        public var emptyLists = 0
        public var parseErrors = 0
        public var attachments = 0
        public var byAction: [String: Int] = [:]
        public var byKind: [String: Int] = [:]
        public var bySource: [String: Int] = [:]
        public var byParentKind: [String: Int] = [:]
        public var byLink: [String: Int] = [:]
        public var withText: [String: Int] = [:]
        public var microMoved = 0
        public var leftInPlaceByExtension: [String: Int] = [:]
    }

    public struct Report: Codable, Sendable {
        public var tool = AttachmentSplitMigration.tool
        public var version = AttachmentSplitMigration.version
        public var dryRun: Bool
        public var library: String
        public var startedAt: String
        public var finishedAt: String
        public var backupDirectory: String?
        public var totals = Totals()
        public var parseErrors: [String] = []
        public var parents: [Parent] = []
    }

    public enum Failure: LocalizedError {
        case backupRequired
        public var errorDescription: String? { "Applying the split needs a backup directory." }
    }

    // MARK: - Run

    public static func run(_ options: Options) throws -> Report {
        if options.apply, options.backupDirectory == nil { throw Failure.backupRequired }
        let fm = FileManager.default
        let recordings = options.library.appendingPathComponent("Recordings", isDirectory: true)
        var report = Report(dryRun: !options.apply, library: options.library.path,
                            startedAt: ISO8601.string(from: options.now), finishedAt: "",
                            backupDirectory: options.backupDirectory?.path)
        let names = try fm.contentsOfDirectory(atPath: recordings.path).sorted()
        var context = Context(library: options.library)
        var parents: [(URL, [String: Any])] = []
        for name in names where name.hasSuffix(".meta.json") {
            report.totals.sidecarsScanned += 1
            let url = recordings.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                report.totals.parseErrors += 1
                report.parseErrors.append(name)
                continue
            }
            context.index(childSidecar: name, json: json)
            guard json["attachments"] != nil else { continue }
            if let only = options.onlyParents, !only.contains(name) { continue }
            parents.append((url, json))
        }
        if let limit = options.limit { parents = Array(parents.prefix(limit)) }
        for (url, json) in parents {
            let parent = splitParent(sidecar: url, json: json, options: options, context: &context)
            add(parent, to: &report.totals)
            report.parents.append(parent)
        }
        report.finishedAt = ISO8601.string(from: Date())
        return report
    }

    /// Splits one parent right after it was written (the Evernote importer):
    /// nothing to resume, nothing to back up.
    public static func splitFreshParent(sidecar: URL, library: URL) throws -> Parent? {
        guard let data = try? Data(contentsOf: sidecar),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["attachments"] != nil else { return nil }
        var context = Context(library: library)
        return splitParent(sidecar: sidecar, json: json, options: Options(apply: true, library: library),
                           context: &context, backUp: false)
    }

    private static func add(_ parent: Parent, to totals: inout Totals) {
        if parent.emptyListRemoved { totals.emptyLists += 1 }
        if parent.error != nil { totals.parentsFailed += 1 }
        guard !parent.items.isEmpty else { return }
        totals.parentsWithAttachments += 1
        totals.byParentKind[parent.parentKind, default: 0] += 1
        if parent.items.contains(where: { Self.changingActions.contains($0.action) }) { totals.parentsToChange += 1 }
        for item in parent.items {
            totals.attachments += 1
            totals.byAction[item.action, default: 0] += 1
            totals.byKind[item.kind, default: 0] += 1
            totals.bySource[parent.source, default: 0] += 1
            totals.byLink[item.link, default: 0] += 1
            totals.withText[item.text, default: 0] += 1
            if item.micro != nil { totals.microMoved += 1 }
            if !Self.changingActions.contains(item.action) {
                let ext = (item.source as NSString).pathExtension.lowercased()
                totals.leftInPlaceByExtension["\(item.action):\(ext.isEmpty ? "-" : ext)", default: 0] += 1
            }
        }
    }

    static let changingActions: Set<String> = ["split", "promote", "resume", "duplicate"]

    // MARK: - Context

    struct Context {
        let library: URL
        var recordings: URL { library.appendingPathComponent("Recordings", isDirectory: true) }
        /// "parentSidecar|attachmentID" → child file name, from `splitFrom` of notes already written.
        var children: [String: String] = [:]
        var childrenPerParent: [String: Int] = [:]

        init(library: URL) { self.library = library }

        mutating func index(childSidecar name: String, json: [String: Any]) {
            guard let split = json[AttachmentSplitMigration.splitFromKey] as? [String: Any],
                  let parent = split["parentSidecar"] as? String,
                  let id = split["attachmentID"] as? String,
                  let file = split["file"] as? String else { return }
            children["\(parent)|\(id.uppercased())"] = file
            childrenPerParent[parent, default: 0] += 1
        }
    }

    // MARK: - One parent

    private struct Planned {
        var item: Item
        var entry: [String: Any]
        var sourceURL: URL?
        var targetURL: URL?
        var journalPrompt: String?
        var relativeSource: String?
    }

    static func splitParent(sidecar: URL, json: [String: Any], options: Options,
                            context: inout Context, backUp: Bool = true) -> Parent {
        let fm = FileManager.default
        let sidecarName = sidecar.lastPathComponent
        let base = baseName(ofSidecar: sidecarName)
        let primary = primaryFile(base: base, in: context.recordings)
        let parentKind = primary.map { kind(of: $0) } ?? "none"
        let source = parentSource(json)
        var parent = Parent(sidecar: sidecarName, parentFile: primary?.lastPathComponent, parentKind: parentKind,
                            source: source, emptyListRemoved: false, items: [])
        let entries = json["attachments"] as? [[String: Any]] ?? []
        if entries.isEmpty {
            parent.emptyListRemoved = true
            if options.apply {
                do {
                    try FileStore.mutateSidecar(at: sidecar) { meta in
                        guard let list = meta["attachments"] as? [Any], list.isEmpty else { return false }
                        meta.removeValue(forKey: "attachments")
                        return true
                    }
                } catch { parent.error = error.localizedDescription }
            }
            return parent
        }

        let parentDate = FileStore.recordingDateFromFileName(context.recordings.appendingPathComponent(base + ".x"))
            ?? (json[RecordingIdentity.createdAtMetadataKey] as? String).flatMap(ISO8601.date(from:))
            ?? primary.flatMap { try? fm.attributesOfItem(atPath: $0.path)[.creationDate] as? Date }
            ?? Date(timeIntervalSince1970: 0)
        let promoted = json[promotedKey] as? [String: Any]
        var needsPromotion = primary == nil
        var position = context.childrenPerParent[sidecarName] ?? 0
        var seenSources: [String: String] = [:]
        var plans: [Planned] = []

        for entry in entries {
            let rawID = (entry["id"] as? String)?.uppercased() ?? ""
            let rawURL = entry["url"] as? String ?? ""
            var item = Item(attachmentID: rawID, kind: "other", source: rawURL, target: nil, action: "invalid",
                            micro: nil, text: textKind(entry), link: "none")
            guard UUID(uuidString: rawID) != nil, let resolved = resolve(rawURL, library: context.library) else {
                plans.append(Planned(item: item, entry: entry)); continue
            }
            item.kind = kind(of: resolved)
            guard let local = localize(resolved, library: context.library) else {
                item.action = "outside-library"; item.source = resolved.path
                plans.append(Planned(item: item, entry: entry)); continue
            }
            let relative = relativePath(local, library: context.library)
            item.source = relative
            var plan = Planned(item: item, entry: entry, sourceURL: local, journalPrompt: entry["journalPrompt"] as? String,
                               relativeSource: relative)

            if let promoted, (promoted["attachmentID"] as? String)?.uppercased() == rawID, let file = promoted["file"] as? String {
                plan.item.action = "promote"
                plan.targetURL = context.recordings.appendingPathComponent(file)
            } else if let file = context.children["\(sidecarName)|\(rawID)"] {
                plan.item.action = "resume"
                plan.targetURL = context.recordings.appendingPathComponent(file)
            } else if let earlier = seenSources[local.path] {
                plan.item.action = "duplicate"
                plan.targetURL = context.recordings.appendingPathComponent(earlier)
            } else if !fm.fileExists(atPath: local.path) {
                plan.item.action = "missing"
            } else if !FileStore.isSupportedRecordingFile(local) || FileStore.isDerivedAudioFile(local) {
                plan.item.action = "unsupported"
            } else if needsPromotion {
                needsPromotion = false
                plan.item.action = "promote"
                plan.targetURL = context.recordings.appendingPathComponent(base + "." + local.pathExtension)
            } else {
                position += 1
                plan.item.action = "split"
                plan.targetURL = childURL(parentSidecar: sidecarName, attachmentID: rawID,
                                          date: parentDate.addingTimeInterval(TimeInterval(position)),
                                          extension: local.pathExtension, in: context.recordings)
            }
            if let target = plan.targetURL {
                plan.item.target = relativePath(target, library: context.library)
                if plan.item.action != "duplicate" { seenSources[local.path] = target.lastPathComponent }
                // Planned here so the dry run reports it; apply records what actually moved.
                if plan.item.action != "duplicate", fm.fileExists(atPath: FileStore.microURL(forRecordingURL: local).path) {
                    plan.item.micro = relativePath(FileStore.microURL(forRecordingURL: target), library: context.library)
                }
            }
            plans.append(plan)
        }

        // A text parent whose body cannot be read as UTF-8 is never rewritten.
        let parentBody: String? = primary.flatMap { file in
            NoteContent.load(anchor: file, sidecar: [:]).fileText
        }
        let isTextParent = parentBody != nil
        var links: [Link] = []
        for index in plans.indices where changingActions.contains(plans[index].item.action) {
            if plans[index].item.action == "promote" {
                plans[index].item.link = "promoted"
            } else if !isTextParent {
                plans[index].item.link = "non-text-parent"
            } else if let target = plans[index].targetURL {
                links.append(Link(index: index, childBase: target.deletingPathExtension().lastPathComponent,
                                  sourcePaths: linkTargets(for: plans[index]),
                                  journalPrompt: plans[index].journalPrompt))
            }
        }

        // Body links, computed in memory for the report and written in apply mode.
        var newBody: String?
        var newRefined: String?
        if let body = parentBody, !links.isEmpty {
            let result = linkedBody(body, links: links)
            for (index, outcome) in result.outcomes { plans[index].item.link = outcome }
            if result.text != body { newBody = result.text }
            if let card = json["noteCard"] as? [String: Any], let refined = card["refined_text"] as? String {
                let refinedResult = linkedBody(refined, links: links)
                if refinedResult.text != refined { newRefined = refinedResult.text }
            }
        }

        parent.items = plans.map(\.item)
        guard options.apply, plans.contains(where: { changingActions.contains($0.item.action) }) else { return parent }

        // Apply.
        do {
            if backUp, let backup = options.backupDirectory {
                try backUpFiles([sidecar] + (isTextParent ? [primary].compactMap { $0 } : []), to: backup)
            }
            var done: Set<String> = []
            for index in plans.indices where changingActions.contains(plans[index].item.action) {
                do {
                    plans[index].item.micro = try applyItem(&plans[index], parentSidecar: sidecar, parentJSON: json,
                                                            library: context.library, now: options.now)
                    done.insert(plans[index].item.attachmentID)
                    if let target = plans[index].targetURL, plans[index].item.action == "split" {
                        context.children["\(sidecarName)|\(plans[index].item.attachmentID)"] = target.lastPathComponent
                    }
                } catch {
                    plans[index].item.error = error.localizedDescription
                    plans[index].item.action = "conflict"
                }
            }
            // Links go in only when every linked note exists; otherwise their
            // entries stay and the next run adds the links.
            let linkIDs = Set(links.map { plans[$0.index].item.attachmentID })
            let bodyWritten = done.isSuperset(of: linkIDs)
            if bodyWritten, let primary, let newBody {
                try Data(newBody.utf8).write(to: primary, options: .atomic)
            } else if !bodyWritten {
                for link in links { plans[link.index].item.link = "pending" }
            }
            try FileStore.mutateSidecar(at: sidecar) { meta in
                var list = meta["attachments"] as? [[String: Any]] ?? []
                let before = list.count
                let removable = bodyWritten ? done : done.subtracting(linkIDs)
                list.removeAll { removable.contains(($0["id"] as? String)?.uppercased() ?? "") }
                var changed = list.count != before
                if list.isEmpty { meta.removeValue(forKey: "attachments") } else { meta["attachments"] = list }
                if bodyWritten, let newRefined, var card = meta["noteCard"] as? [String: Any] {
                    card["refined_text"] = newRefined
                    meta["noteCard"] = card
                    changed = true
                }
                return changed
            }
            removeEmptyAttachmentDirectories(plans.compactMap(\.sourceURL), library: context.library)
        } catch {
            parent.error = error.localizedDescription
        }
        parent.items = plans.map(\.item)
        return parent
    }

    /// Steps 1–3 for one attachment. Returns the moved `_micro`, if any.
    private static func applyItem(_ plan: inout Planned, parentSidecar: URL, parentJSON: [String: Any],
                                  library: URL, now: Date) throws -> String? {
        guard let source = plan.sourceURL, let target = plan.targetURL else { return nil }
        let fm = FileManager.default
        if plan.item.action == "duplicate" { return nil }
        if plan.item.action == "promote" {
            let file = target.lastPathComponent
            try FileStore.mutateSidecar(at: parentSidecar) { meta in
                var changed = false
                if meta[promotedKey] == nil {
                    meta[promotedKey] = ["attachmentID": plan.item.attachmentID, "source": plan.relativeSource ?? "",
                                         "file": file, "at": ISO8601.string(from: now),
                                         "tool": "\(tool)/\(version)"]
                    changed = true
                }
                for (key, value) in carriedContent(plan.entry, kind: plan.item.kind,
                                                   source: relativePath(target, library: library))
                where !hasContent(meta[key], key: key) {
                    meta[key] = value
                    changed = true
                }
                return changed
            }
        } else {
            let childSidecar = FileStore.metadataURL(forRecordingURL: target)
            try FileStore.mutateSidecar(at: childSidecar) { meta in
                if let split = meta[splitFromKey] as? [String: Any] {
                    guard (split["attachmentID"] as? String)?.uppercased() == plan.item.attachmentID,
                          split["parentSidecar"] as? String == parentSidecar.lastPathComponent else {
                        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: childSidecar.path])
                    }
                    return false
                }
                guard meta.isEmpty else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: childSidecar.path])
                }
                let identity = childIdentity(parentSidecar: parentSidecar.lastPathComponent,
                                             attachmentID: plan.item.attachmentID, target: target)
                meta[RecordingIdentity.metadataKey] = identity.id.uuidString
                meta[RecordingIdentity.createdAtMetadataKey] = ISO8601.string(from: identity.createdAt)
                if let schema = parentJSON["schema"] { meta["schema"] = schema }
                if let importSource = parentJSON["importSource"] { meta["importSource"] = importSource }
                var origin = parentJSON["origin"] as? [String: Any] ?? [:]
                if let prompt = plan.journalPrompt { origin["journalPrompt"] = prompt }
                if !origin.isEmpty { meta["origin"] = origin }
                meta[splitFromKey] = [
                    "parentSidecar": parentSidecar.lastPathComponent,
                    "attachmentID": plan.item.attachmentID,
                    "source": plan.relativeSource ?? "",
                    "file": target.lastPathComponent,
                    "at": ISO8601.string(from: now),
                    "tool": "\(tool)/\(version)",
                ]
                for (key, value) in carriedContent(plan.entry, kind: plan.item.kind,
                                                   source: relativePath(target, library: library)) {
                    meta[key] = value
                }
                return true
            }
        }
        let sourceExists = fm.fileExists(atPath: source.path)
        let targetExists = fm.fileExists(atPath: target.path)
        if sourceExists && targetExists {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
        }
        if sourceExists {
            try fm.moveItem(at: source, to: target)
        } else if !targetExists {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        var movedMicro: String?
        for (from, to) in [(FileStore.microURL(forRecordingURL: source), FileStore.microURL(forRecordingURL: target)),
                           (FileStore.miniURL(forRecordingURL: source), FileStore.miniURL(forRecordingURL: target))]
        where fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
            try fm.moveItem(at: from, to: to)
            if movedMicro == nil { movedMicro = relativePath(to, library: library) }
        }
        return movedMicro
    }

    // MARK: - Carried text

    /// What the attachment entry knew, in the keys a note of that kind uses.
    static func carriedContent(_ entry: [String: Any], kind: String, source newSource: String) -> [String: Any] {
        let raw = entry["extractedText"] as? String ?? entry["ocrText"] as? String
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = entry["extractionProvider"] as? String ?? entry["ocrProvider"] as? String
        let model = entry["extractionModel"] as? String ?? entry["ocrModel"] as? String
        let startedAt = entry["startedAt"] as? String
        let runs = entry["previousRuns"] as? [[String: Any]] ?? []
        var out: [String: Any] = [:]
        switch kind {
        case "audio":
            guard let text else { return [:] }
            let noSpeech = text.isEmpty || text == NoteAttachmentMedia.noSpeechText
            var transcription: [String: Any] = [
                "transcript": noSpeech ? "" : text,
                "speechStatus": noSpeech ? TranscriptionSpeechStatus.noSpeech.rawValue
                                         : TranscriptionSpeechStatus.speech.rawValue,
            ]
            if let provider { transcription["provider"] = provider }
            if let model { transcription["model"] = model }
            if let startedAt { transcription["startedAt"] = startedAt }
            let previous = runs.map { run -> [String: Any] in
                var converted = run
                if let old = converted.removeValue(forKey: "text") { converted["transcript"] = old }
                return converted
            }
            if !previous.isEmpty { transcription["previousRuns"] = previous }
            out["transcription"] = transcription
        case "text":
            return [:]
        default:
            var ocr: [String: Any] = [:]
            if let text {
                ocr["text"] = text
                if let provider { ocr["provider"] = provider }
                if let model { ocr["model"] = model }
                if let startedAt { ocr["startedAt"] = startedAt }
                ocr["source"] = kind == "pdf" ? "pdf" : "image"
            }
            if !runs.isEmpty { ocr["previousRuns"] = runs }
            if var analysis = entry["imageAnalysis"] as? [String: Any] {
                analysis["source"] = newSource
                ocr["imageAnalysis"] = analysis
            }
            if let history = entry["previousImageAnalyses"] as? [[String: Any]] {
                ocr["previousImageAnalyses"] = history
            }
            if !ocr.isEmpty { out["ocr"] = ocr }
            if let text, !text.isEmpty {
                var document: [String: Any] = ["text": text]
                if let provider { document["textProvider"] = provider }
                if let model { document["textModel"] = model }
                out["document"] = document
                var transcription: [String: Any] = ["transcript": text, "speechStatus": TranscriptionSpeechStatus.speech.rawValue]
                if let provider { transcription["provider"] = provider }
                if let model { transcription["model"] = model }
                if let startedAt { transcription["startedAt"] = startedAt }
                out["transcription"] = transcription
            }
        }
        return out
    }

    private static func hasContent(_ value: Any?, key: String) -> Bool {
        guard let value else { return false }
        if key == "transcription" {
            let text = FileStore.transcriptionDictionary(from: value)?["transcript"] as? String
            return !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        if let dict = value as? [String: Any] { return !dict.isEmpty }
        return true
    }

    // MARK: - Links

    struct Link {
        var index: Int
        var childBase: String
        var sourcePaths: [String]
        var journalPrompt: String?
    }

    /// The parent text with one link per new note: a markdown link to the
    /// attachment's old path becomes `[[child]]`; an evening answer goes under
    /// its question as `[голос](child.meta.json)`; anything else is appended.
    static func linkedBody(_ body: String, links: [Link]) -> (text: String, outcomes: [(Int, String)]) {
        var text = body
        var outcomes: [(Int, String)] = []
        var appended: [String] = []
        for link in links {
            let token = "[[\(link.childBase)]]"
            if text.contains(token) || text.contains("\(link.childBase).meta.json") || appended.contains(token) {
                outcomes.append((link.index, "present")); continue
            }
            if let prompt = link.journalPrompt, let range = sectionEnd(of: prompt, in: text) {
                text.insert(contentsOf: "\n\n[голос](\(link.childBase).meta.json)", at: range)
                outcomes.append((link.index, "appended")); continue
            }
            var replaced = false
            for path in link.sourcePaths where !path.isEmpty {
                let pattern = #"!?\[[^\]\n]*\]\("# + NSRegularExpression.escapedPattern(for: path) + #"\)"#
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if regex.firstMatch(in: text, range: range) != nil {
                    text = regex.stringByReplacingMatches(in: text, range: range,
                                                          withTemplate: NSRegularExpression.escapedTemplate(for: token))
                    replaced = true
                    break
                }
            }
            if replaced { outcomes.append((link.index, "replaced")); continue }
            appended.append(token)
            outcomes.append((link.index, "appended"))
        }
        if !appended.isEmpty {
            let trimmed = text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            text = (trimmed.isEmpty ? "" : trimmed + "\n\n") + appended.joined(separator: "\n") + "\n"
        }
        return (text, outcomes)
    }

    /// Where the `## heading` section ends (before the next `## ` or at the end), after its text.
    private static func sectionEnd(of heading: String, in text: String) -> String.Index? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## ") &&
            $0.dropFirst(3).trimmingCharacters(in: .whitespaces) == heading }) else { return nil }
        var end = lines.count
        for i in (start + 1)..<lines.count where lines[i].hasPrefix("## ") || lines[i].hasPrefix("# ") {
            end = i; break
        }
        var last = end - 1
        while last > start, lines[last].trimmingCharacters(in: .whitespaces).isEmpty { last -= 1 }
        let offset = lines[0...last].reduce(0) { $0 + $1.utf16.count } + last
        return String.Index(utf16Offset: offset, in: text)
    }

    private static func linkTargets(for plan: Planned) -> [String] {
        guard let source = plan.sourceURL else { return [] }
        var targets: [String] = []
        if let relative = plan.relativeSource {
            targets += [relative, relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative]
        }
        targets += [source.path, source.absoluteString, plan.entry["url"] as? String ?? ""]
        var seen = Set<String>()
        return targets.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - Files

    static func baseName(ofSidecar name: String) -> String {
        if name.hasSuffix(".meta.json") { return String(name.dropLast(".meta.json".count)) }
        if name.hasSuffix(".metadata.json") { return String(name.dropLast(".metadata.json".count)) }
        return (name as NSString).deletingPathExtension
    }

    /// The note's own media file: same base, a listed type, not derived. Audio wins
    /// (a `{base}.heic` beside audio is its screenshot), then text, then the rest.
    static func primaryFile(base: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        let candidates = FileStore.supportedAudioExtensions.sorted() + ["txt", "md"]
            + AttachmentTypeHelper.pdfExtensions.sorted() + AttachmentTypeHelper.imageExtensions.sorted()
            + AttachmentTypeHelper.textExtensions.sorted() + AttachmentTypeHelper.officeExtensions.sorted()
        var seen = Set<String>()
        for ext in candidates where seen.insert(ext).inserted {
            for variant in [ext, ext.uppercased()] {
                let url = directory.appendingPathComponent(base + "." + variant)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// The shared kind table (`NoteContent`); this report spells `document` as `other`.
    static func kind(of url: URL) -> String {
        let kind = NoteContent.kind(of: url)
        return kind == .document ? "other" : kind.rawValue
    }

    private static func textKind(_ entry: [String: Any]) -> String {
        let text = (entry["extractedText"] as? String ?? entry["ocrText"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty || text == NoteAttachmentMedia.noSpeechText ? "none" : "text"
    }

    private static func parentSource(_ json: [String: Any]) -> String {
        if json["importSource"] as? String == "Evernote" { return "evernote" }
        if json["journal"] != nil { return "evening-journal" }
        return "native"
    }

    /// The attachment's file inside this library. An absolute URL written by
    /// another library location (a copy made for testing) is mapped by its
    /// path below `Wimm/`; anything else outside the library is refused.
    static func localize(_ url: URL, library: URL) -> URL? {
        let base = library.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix(base + "/") { return URL(fileURLWithPath: path) }
        for marker in ["/Library/Application Support/Wimm/"] {
            guard let range = path.range(of: marker) else { continue }
            let rest = String(path[range.upperBound...])
            guard !rest.isEmpty, !rest.contains("../") else { return nil }
            return URL(fileURLWithPath: base).appendingPathComponent(rest)
        }
        return nil
    }

    static func childIdentity(parentSidecar: String, attachmentID: String, target: URL) -> RecordingIdentity {
        let digest = Array(SHA256.hash(data: Data("\(parentSidecar)|\(attachmentID.uppercased())".utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        let date = FileStore.recordingDateFromFileName(target) ?? Date()
        return RecordingIdentity(id: id, createdAt: date)
    }

    private static func childURL(parentSidecar: String, attachmentID: String, date: Date,
                                 extension ext: String, in directory: URL) -> URL {
        let probe = directory.appendingPathComponent("Wimm_probe")
        let identity = RecordingIdentity(id: childIdentity(parentSidecar: parentSidecar, attachmentID: attachmentID,
                                                           target: probe).id, createdAt: date)
        for length in [8, 32] {
            let url = directory.appendingPathComponent(identity.fileName(extension: ext.lowercased(), idLength: length))
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path), !fm.fileExists(atPath: FileStore.metadataURL(forRecordingURL: url).path) {
                return url
            }
        }
        return directory.appendingPathComponent(identity.fileName(extension: ext.lowercased(), idLength: 32))
    }

    private static func backUpFiles(_ files: [URL], to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files where fm.fileExists(atPath: file.path) {
            let destination = directory.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: destination.path) { try fm.copyItem(at: file, to: destination) }
        }
    }

    /// `Attachments/<kind>/<note>/` folders the moves left empty.
    /// Attachment URLs are `file://` URLs, absolute paths, or paths relative to the library.
    static func resolve(_ raw: String, library: URL) -> URL? {
        if let url = URL(string: raw), url.isFileURL { return url.standardizedFileURL }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw).standardizedFileURL }
        guard !raw.isEmpty, !raw.contains("://"), !raw.contains("../") else { return nil }
        return library.appendingPathComponent(raw).standardizedFileURL
    }

    static func relativePath(_ url: URL, library: URL) -> String {
        let base = library.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    private static func removeEmptyAttachmentDirectories(_ sources: [URL], library: URL) {
        let fm = FileManager.default
        let attachments = library.resolvingSymlinksInPath().appendingPathComponent("Attachments").standardizedFileURL.path
        for directory in Set(sources.map { $0.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path })
        where directory.hasPrefix(attachments + "/") {
            let contents = (try? fm.contentsOfDirectory(atPath: directory)) ?? ["?"]
            if contents.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(atPath: directory) }
        }
    }
}

import Foundation

/// Little-endian fixed-width fields for the on-disk recall cache. Decoding one
/// JSON line per note (~8k `JSONDecoder` calls plus the paths as a JSON byte
/// array) was most of a packet preparation's library load.
struct RecallCacheWriter {
    private(set) var data = Data()

    mutating func int(_ value: Int) { u64(UInt64(bitPattern: Int64(value))) }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func i64(_ value: Int64) { u64(UInt64(bitPattern: value)) }
    mutating func double(_ value: Double) { u64(value.bitPattern) }
    mutating func bool(_ value: Bool) { data.append(value ? 1 : 0) }
    mutating func bytes(_ value: some Collection<UInt8>) { int(value.count); data.append(contentsOf: value) }
    mutating func string(_ value: String) { bytes(value.utf8) }
    mutating func optional<T>(_ value: T?, _ write: (inout Self, T) -> Void) {
        bool(value != nil)
        if let value { write(&self, value) }
    }
}

struct RecallCacheReader {
    struct Invalid: Error {}

    private let base: UnsafeRawBufferPointer
    private(set) var offset: Int

    init(_ base: UnsafeRawBufferPointer, offset: Int = 0) {
        self.base = base
        self.offset = offset
    }

    var remaining: Int { base.count - offset }

    mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw Invalid() }
        var value: UInt64 = 0
        withUnsafeMutableBytes(of: &value) { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: base[offset..<offset + 8])) }
        offset += 8
        return UInt64(littleEndian: value)
    }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
    mutating func int() throws -> Int {
        let value = try i64()
        guard value >= Int64(Int.min), value <= Int64(Int.max) else { throw Invalid() }
        return Int(value)
    }
    /// A count or length that must fit in what is left of the buffer.
    mutating func count(elementSize: Int = 1) throws -> Int {
        let value = try int()
        guard value >= 0, elementSize > 0, value <= remaining / elementSize else { throw Invalid() }
        return value
    }
    mutating func double() throws -> Double { Double(bitPattern: try u64()) }
    mutating func bool() throws -> Bool {
        guard remaining >= 1 else { throw Invalid() }
        let value = base[offset]
        offset += 1
        guard value <= 1 else { throw Invalid() }
        return value == 1
    }
    mutating func raw(_ length: Int) throws -> UnsafeRawBufferPointer {
        guard length >= 0, length <= remaining else { throw Invalid() }
        defer { offset += length }
        return UnsafeRawBufferPointer(rebasing: base[offset..<offset + length])
    }
    mutating func bytes() throws -> [UInt8] { Array(try raw(try count())) }
    mutating func string() throws -> String {
        let raw = try raw(try count())
        guard let value = String(bytes: raw, encoding: .utf8) else { throw Invalid() }
        return value
    }
    mutating func optional<T>(_ read: (inout Self) throws -> T) throws -> T? {
        try bool() ? try read(&self) : nil
    }
}

extension NoteFingerprintSnapshot.Stamp {
    func write(_ out: inout RecallCacheWriter) {
        out.u64(inode); out.i64(size); out.i64(modifiedSeconds); out.i64(modifiedNanos)
        out.i64(changedSeconds); out.i64(changedNanos)
    }

    static func read(_ input: inout RecallCacheReader) throws -> Self {
        Self(inode: try input.u64(), size: try input.i64(), modifiedSeconds: try input.i64(),
             modifiedNanos: try input.i64(), changedSeconds: try input.i64(), changedNanos: try input.i64())
    }
}

extension RecallLibrary.Layout {
    func write(_ out: inout RecallCacheWriter) {
        out.double(date.timeIntervalSinceReferenceDate)
        out.optional(updated) { $0.double($1.timeIntervalSinceReferenceDate) }
        out.optional(fingerprintSnapshot) { out, snapshot in
            out.int(snapshot.inputs.count)
            for stamp in snapshot.inputs { stamp.write(&out) }
            out.string(snapshot.fingerprint.text)
            out.string(snapshot.fingerprint.analysis)
            out.optional(snapshot.fingerprint.wording) { $0.string($1) }
        }
        out.string(kind)
        out.optional(duration) { $0.double($1) }
        out.optional(speech) { $0.string($1) }
        out.optional(chars) { $0.int($1) }
        out.optional(device) { $0.string($1) }
        out.int(id); out.int(path)
        out.optional(title) { $0.int($1) }
        out.optional(summary) { $0.int($1) }
        out.int(text)
        out.int(attachments.count)
        for attachment in attachments { out.int(attachment) }
        out.int(foldedID); out.int(foldedTitle); out.int(foldedSummary); out.int(foldedBody)
    }

    static func read(_ input: inout RecallCacheReader) throws -> Self {
        let date = Date(timeIntervalSinceReferenceDate: try input.double())
        let updated = try input.optional { Date(timeIntervalSinceReferenceDate: try $0.double()) }
        let snapshot = try input.optional { input -> NoteFingerprintSnapshot in
            let count = try input.count(elementSize: 48)
            var stamps: [NoteFingerprintSnapshot.Stamp] = []
            stamps.reserveCapacity(count)
            for _ in 0..<count { stamps.append(try .read(&input)) }
            let fingerprint = NoteFingerprint(text: try input.string(), analysis: try input.string(),
                                              wording: try input.optional { try $0.string() })
            return NoteFingerprintSnapshot(inputs: stamps, fingerprint: fingerprint)
        }
        let kind = try input.string()
        let duration = try input.optional { try $0.double() }
        let speech = try input.optional { try $0.string() }
        let chars = try input.optional { try $0.int() }
        let device = try input.optional { try $0.string() }
        let id = try input.int(), path = try input.int()
        let title = try input.optional { try $0.int() }
        let summary = try input.optional { try $0.int() }
        let text = try input.int()
        let attachmentCount = try input.count(elementSize: 8)
        var attachments: [Int] = []
        attachments.reserveCapacity(attachmentCount)
        for _ in 0..<attachmentCount { attachments.append(try input.int()) }
        return Self(date: date, updated: updated, fingerprintSnapshot: snapshot, kind: kind, duration: duration,
                    speech: speech, chars: chars, device: device, id: id, path: path, title: title,
                    summary: summary, text: text, attachments: attachments,
                    foldedID: try input.int(), foldedTitle: try input.int(),
                    foldedSummary: try input.int(), foldedBody: try input.int())
    }
}

extension RecallLibrary {
    /// A library over buffers whose bytes are the notes' fields back to back in
    /// `layouts` order, as `saveCache` writes them; nil unless they match exactly.
    init?(raw: [UInt8], folded: [UInt8], layouts: [Layout]) {
        var rawOffset = 0, foldedOffset = 0
        var entries: [Entry] = []
        entries.reserveCapacity(layouts.count)
        func take(_ count: Int, _ offset: inout Int, limit: Int) -> Range<Int>? {
            guard count >= 0, count <= limit - offset else { return nil }
            defer { offset += count }
            return offset..<offset + count
        }
        for layout in layouts {
            guard layout.isValid,
                  let id = take(layout.id, &rawOffset, limit: raw.count),
                  let path = take(layout.path, &rawOffset, limit: raw.count) else { return nil }
            var title: Range<Int>?, summary: Range<Int>?
            if let length = layout.title { guard let range = take(length, &rawOffset, limit: raw.count) else { return nil }; title = range }
            if let length = layout.summary { guard let range = take(length, &rawOffset, limit: raw.count) else { return nil }; summary = range }
            guard let text = take(layout.text, &rawOffset, limit: raw.count) else { return nil }
            var attachments: [Range<Int>] = []
            for length in layout.attachments {
                guard let range = take(length, &rawOffset, limit: raw.count) else { return nil }
                attachments.append(range)
            }
            guard let foldedID = take(layout.foldedID, &foldedOffset, limit: folded.count),
                  let foldedTitle = take(layout.foldedTitle, &foldedOffset, limit: folded.count),
                  let foldedSummary = take(layout.foldedSummary, &foldedOffset, limit: folded.count),
                  let foldedBody = take(layout.foldedBody, &foldedOffset, limit: folded.count) else { return nil }
            entries.append(Entry(date: layout.date, updated: layout.updated, fingerprintSnapshot: layout.fingerprintSnapshot,
                kind: layout.kind, duration: layout.duration, speech: layout.speech, chars: layout.chars, device: layout.device,
                id: id, path: path, title: title, summary: summary, text: text, attachments: attachments,
                foldedID: foldedID, foldedTitle: foldedTitle, foldedSummary: foldedSummary, foldedBody: foldedBody))
        }
        guard rawOffset == raw.count, foldedOffset == folded.count else { return nil }
        self.raw = raw; self.folded = folded; self.entries = entries
    }
}

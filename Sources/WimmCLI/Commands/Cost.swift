import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

/// Aggregates the unified event log into "what did this actually cost".
///
/// The log is the single source of truth: every metered call writes a
/// `kind: "llm"` response record carrying `tokens_*`, `operation`, `note_file`
/// and — for transcription — `audio_sec`. Nothing here re-reads the library or
/// calls a provider; it is pure arithmetic over what already happened.
struct Cost: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cost",
        abstract: "Report token spend and estimated cost from the unified event log"
    )

    @Option(name: .long, help: "Look back this many days (ignored when --since is given).")
    var days: Int = 30

    @Option(name: .long, help: "Start date, YYYY-MM-DD.")
    var since: String?

    @Option(name: .long, help: "End date, YYYY-MM-DD (inclusive).")
    var until: String?

    @Option(name: .long, help: "Group by: operation | model | day | provider | note.")
    var groupBy: String = "operation"

    @Flag(name: .long, help: "Write a price-table skeleton for the models seen in the logs, then exit.")
    var initPrices: Bool = false

    @Option(name: .long, help: "Show only the N largest rows (0 = all).")
    var limit: Int = 20

    func run() async throws {
        let (records, unmetered) = try loadRecords()
        guard !records.isEmpty else {
            print("No metered LLM calls found in \(UnifiedEventLogger.eventsDirectoryURL().path)")
            if unmetered > 0 {
                // Everything logged before token counters were wired up looks
                // exactly like an empty period otherwise, which reads as a bug.
                print("\(unmetered) LLM call(s) are logged for this period but carry no token counters —")
                print("they predate cost metering. Calls made from now on will be counted.")
            } else {
                print("Nothing has been logged for the selected period yet.")
            }
            return
        }

        if initPrices {
            try writePriceTemplate(for: records)
            return
        }

        let table = ModelPricing.loadTable()
        printSummary(records, table: table)
        printGroups(records, table: table)
        printPriceTableStatus(records, table: table)
    }

    // MARK: - Loading

    private struct Call {
        let timestamp: Date
        let day: String
        let model: String
        let provider: String
        let operation: String
        let noteFile: String?
        let usage: TokenUsage
        let audioSeconds: Double?
        let isLocal: Bool
    }

    private func loadRecords() throws -> (calls: [Call], unmetered: Int) {
        let dir = UnifiedEventLogger.eventsDirectoryURL()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        let (from, to) = try dateRange()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var calls: [Call] = []
        var unmetered = 0
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let record = try? decoder.decode(UnifiedEventRecord.self, from: data),
                      record.kind == "llm",
                      record.phase == "response",
                      record.error == nil,
                      record.timestamp >= from, record.timestamp <= to,
                      let attrs = record.attributes
                else { continue }

                // A call with no counters is either on-device (free) or a
                // provider that reported nothing. Keep it only when it is
                // explicitly on-device, so unknowns never masquerade as free.
                let usage = TokenUsage(logAttributes: attrs)
                let isLocal = attrs["engine"] == "on-device"
                guard usage != nil || isLocal else {
                    unmetered += 1
                    continue
                }

                calls.append(Call(
                    timestamp: record.timestamp,
                    day: dayFormatter.string(from: record.timestamp),
                    model: record.model ?? "unknown",
                    provider: record.provider ?? "unknown",
                    operation: attrs["operation"] ?? "other",
                    noteFile: attrs["note_file"],
                    usage: usage ?? TokenUsage(),
                    audioSeconds: attrs["audio_sec"].flatMap(Double.init),
                    isLocal: isLocal))
            }
        }
        return (calls, unmetered)
    }

    private func dateRange() throws -> (Date, Date) {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"

        let end: Date
        if let until {
            guard let parsed = parser.date(from: until) else {
                throw ValidationError("--until must be YYYY-MM-DD")
            }
            end = parsed.addingTimeInterval(24 * 3600 - 1)
        } else {
            end = Date()
        }

        let start: Date
        if let since {
            guard let parsed = parser.date(from: since) else {
                throw ValidationError("--since must be YYYY-MM-DD")
            }
            start = parsed
        } else {
            start = Calendar.current.date(byAdding: .day, value: -max(1, days), to: end) ?? .distantPast
        }
        return (start, end)
    }

    // MARK: - Reporting

    private func printSummary(_ calls: [Call], table: PriceTable?) {
        // Cloud and on-device seconds are kept apart: folding free minutes into
        // the denominator would quietly understate what a paid minute costs.
        let totals = calls.reduce(into: (input: 0, output: 0, audio: 0, paidSeconds: 0.0, localSeconds: 0.0)) { acc, call in
            acc.input += call.usage.inputTokens ?? 0
            acc.output += call.usage.outputTokens ?? 0
            acc.audio += call.usage.audioTokens ?? 0
            if call.isLocal {
                acc.localSeconds += call.audioSeconds ?? 0
            } else {
                acc.paidSeconds += call.audioSeconds ?? 0
            }
        }
        let thoughts = ThoughtsTally(calls.map(\.usage))
        let cost = totalCost(calls, table: table)
        let notes = Set(calls.compactMap(\.noteFile)).count

        print("💸 WIMM cost report")
        print("   Calls:          \(calls.count)")
        print("   Notes touched:  \(notes)")
        print("   Tokens in/out:  \(fmt(totals.input)) / \(fmt(totals.output))")
        if thoughts.total > 0 {
            // Billed as output but outside `tokens_out`, so it gets its own line.
            var line = "   Thinking:       \(fmt(thoughts.total)) (billed as output)"
            if thoughts.estimated > 0 {
                line += " — \(fmt(thoughts.estimated)) estimated as total − in − out on older records"
            }
            print(line)
        }
        if totals.audio > 0 {
            print("   Audio tokens:   \(fmt(totals.audio))")
        }
        if totals.paidSeconds > 0 {
            print("   Audio to cloud: \(String(format: "%.1f", totals.paidSeconds / 60)) min")
        }
        if totals.localSeconds > 0 {
            print("   On-device:      \(String(format: "%.1f", totals.localSeconds / 60)) min (free)")
        }

        guard let cost else {
            print("   Cost:           unknown — no price table (run `wimm-cli cost --init-prices`)")
            print("")
            return
        }
        print("   Cost:           \(money(cost.priced.total))\(cost.unpricedNote)")
        if totals.paidSeconds > 60 {
            let perMinute = cost.priced.total / (totals.paidSeconds / 60)
            print("   Per minute:     \(money(perMinute)) / min sent to the cloud")
        }
        if notes > 0 {
            print("   Per note:       \(money(cost.priced.total / Double(notes)))")
        }
        print("")
    }

    private func printGroups(_ calls: [Call], table: PriceTable?) {
        let key: (Call) -> String
        switch groupBy {
        case "model": key = { $0.model }
        case "day": key = { $0.day }
        case "provider": key = { $0.provider }
        case "note": key = { $0.noteFile ?? "(unattributed)" }
        default: key = { $0.operation }
        }

        var buckets: [String: [Call]] = [:]
        for call in calls { buckets[key(call), default: []].append(call) }

        var rows = buckets.map { (name: $0.key, calls: $0.value) }
        rows.sort { lhs, rhs in
            let l = totalCost(lhs.calls, table: table)?.priced.total ?? 0
            let r = totalCost(rhs.calls, table: table)?.priced.total ?? 0
            if l != r { return l > r }
            return lhs.calls.count > rhs.calls.count
        }
        if limit > 0, rows.count > limit { rows = Array(rows.prefix(limit)) }

        print("By \(groupBy):")
        print("  \(pad("name", 28)) \(pad("calls", 7)) \(pad("tok in", 12)) \(pad("tok out", 10)) \(pad("thinking", 12)) cost")
        for row in rows {
            let input = row.calls.reduce(0) { $0 + ($1.usage.inputTokens ?? 0) }
            let output = row.calls.reduce(0) { $0 + ($1.usage.outputTokens ?? 0) }
            let thoughts = ThoughtsTally(row.calls.map(\.usage))
            // "~" marks a figure that is partly derived from an old record's total.
            let thoughtsText = thoughts.total == 0 ? "—"
                : (thoughts.estimated > 0 ? "~" : "") + fmt(thoughts.total)
            let cost = totalCost(row.calls, table: table)
            let costText = cost.map { money($0.priced.total) } ?? "—"
            print("  \(pad(row.name, 28)) \(pad(String(row.calls.count), 7)) \(pad(fmt(input), 12)) \(pad(fmt(output), 10)) \(pad(thoughtsText, 12)) \(costText)")
        }
        if rows.contains(where: { ThoughtsTally($0.calls.map(\.usage)).estimated > 0 }) {
            print("  ~ thinking partly estimated as total − in − out (records before tokens_thoughts)")
        }
        print("")
    }

    private func printPriceTableStatus(_ calls: [Call], table: PriceTable?) {
        guard let table else {
            print("No price table at \(ModelPricing.tableURL().path).")
            print("Run `wimm-cli cost --init-prices` to write a skeleton, then fill in the rates.")
            return
        }
        let missing = Set(calls.map(\.model)).filter { model in
            table.price(for: model) == nil && model != "unknown"
        }
        print("Price table: version \(table.version), \(table.models.count) models — \(ModelPricing.tableURL().path)")
        if !missing.isEmpty {
            print("⚠️  No price for: \(missing.sorted().joined(separator: ", "))")
            print("   Those calls are excluded from the totals above, not counted as free.")
        }
    }

    private func writePriceTemplate(for calls: [Call]) throws {
        let models = Set(calls.map(\.model)).filter { $0 != "unknown" }.sorted()
        var template = ModelPricing.template(models: models)
        // Never clobber rates already filled in by hand.
        if let existing = ModelPricing.loadTable() {
            template.models.merge(existing.models) { _, kept in kept }
        }
        try ModelPricing.save(template)
        print("Wrote price skeleton with \(template.models.count) models to:")
        print("  \(ModelPricing.tableURL().path)")
        print("Fill in USD per 1M tokens from the provider's pricing page, then re-run `wimm-cli cost`.")
    }

    // MARK: - Math & formatting

    private struct Totals {
        var priced = CostBreakdown()
        var pricedCalls = 0
        var unpricedCalls = 0

        var unpricedNote: String {
            unpricedCalls == 0 ? "" : "  (\(unpricedCalls) call(s) had no price and are excluded)"
        }
    }

    private func totalCost(_ calls: [Call], table: PriceTable?) -> Totals? {
        guard let table else { return nil }
        var totals = Totals()
        for call in calls {
            if call.usage.isEmpty {
                // On-device: genuinely free, counts as priced at zero.
                totals.pricedCalls += 1
                continue
            }
            if let breakdown = ModelPricing.cost(usage: call.usage, model: call.model, table: table) {
                totals.priced = totals.priced + breakdown
                totals.pricedCalls += 1
            } else {
                totals.unpricedCalls += 1
            }
        }
        return totals
    }

    private func money(_ value: Double) -> String {
        value < 0.01 && value > 0
            ? String(format: "$%.4f", value)
            : String(format: "$%.2f", value)
    }

    private func fmt(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width
            ? String(text.prefix(width))
            : text + String(repeating: " ", count: width - text.count)
    }
}

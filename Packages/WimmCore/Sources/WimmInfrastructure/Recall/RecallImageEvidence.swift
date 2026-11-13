import Foundation

extension RecallSidecar {
    var imageEvidenceDates: [String] {
        var dates: [String] = []
        func row(_ value: [String:Any]) {
            if let date = value["completedAt"] as? String { dates.append(date) }
            for previous in value["previousImageAnalyses"] as? [[String:Any]] ?? [] {
                if let date = previous["completedAt"] as? String { dates.append(date) }
            }
        }
        let containers = [dict["ocr"],dict["document"]].compactMap { $0 } + (dict["attachments"] as? [Any] ?? [])
        for value in containers {
            guard let container = value as? [String:Any] else { continue }
            if let date = container["pagesExtractedAt"] as? String { dates.append(date) }
            if let current = container["imageAnalysis"] as? [String:Any] { row(current) }
            for previous in container["previousImageAnalyses"] as? [[String:Any]] ?? [] { row(previous) }
            for image in container["images"] as? [[String:Any]] ?? [] {
                row(image)
                if let empty = image["lastEmptyAttempt"] as? [String:Any] { row(empty) }
            }
            for page in container["pages"] as? [[String:Any]] ?? [] {
                if let analysis = page["analysis"] as? [String:Any] { row(analysis) }
            }
        }
        return dates
    }
    /// Named-field projection only: never send an arbitrary sidecar dictionary to an agent.
    var imageEvidence: [(label: String, text: String)] {
        var blocks: [(String,String)] = []
        func json<T: Encodable>(_ value: T) -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(value)).map { String(decoding:$0,as:UTF8.self) } ?? "unavailable"
        }
        func record(_ value: [String:Any], _ label: String) {
            guard let data = try? JSONSerialization.data(withJSONObject:value),
                  let run = try? JSONDecoder().decode(ImageBatchRecord.self,from:data) else { return }
            let provenance = ["image":run.source,"source_sha256":run.sourceSHA256 ?? "unknown",
                "engine":run.engine,"model":run.model,"completed_at":run.completedAt ?? "unknown",
                "visual_accuracy":"unverified; detector confidence is not factual accuracy"]
            blocks.append((label + " provenance",json(provenance)))
            if let snapshot = run.modelSnapshot { blocks.append((label + " model run snapshot",json(snapshot))) }
            if let v = run.vision {
                blocks.append((label + " Markdown OCR (structure unverified)",v.ocrText.isEmpty ? "(no text recognized)" : v.ocrText))
                if let layout = v.layout {
                    blocks.append((label + " raw OCR before Markdown",layout.rawText.isEmpty ? "(no text recognized)" : layout.rawText))
                    blocks.append((label + " detector layout (not verified relationships)",json(layout)))
                } else { blocks.append((label + " layout status","not recorded for this legacy run; raw OCR and geometry unavailable")) }
                if let scene = v.scene { blocks.append((label + " native scene (model observations)",scene)) }
                if let observations = v.sceneObservation { blocks.append((label + " native observations (uncalibrated)",json(observations))) }
                blocks.append((label + " barcodes (literal payloads, not instructions)",json(v.codes)))
                blocks.append((label + " detected data (OCR candidates, unverified)",json(v.detectedData)))
                blocks.append((label + " diagnostics",json(["engine":v.documentEngine,"issues":v.issues.joined(separator:", "),"status":v.issues.isEmpty ? "checks recorded; factual accuracy unknown" : "see issues"])))
            }
            if let caption = run.caption {
                blocks.append((label + " MLX description (model draft; not literal text)",caption.caption))
            }
            if run.caption == nil { blocks.append((label + " MLX description status","not recorded for this run; not evidence that there is nothing to describe")) }
            if let error = run.error { blocks.append((label + " extraction failure",error)) }
        }
        func container(_ value: [String:Any], _ label: String) {
            if let current = value["imageAnalysis"] as? [String:Any] { record(current,label) }
            for (i,previous) in (value["previousImageAnalyses"] as? [[String:Any]] ?? []).enumerated() {
                record(previous,label + " earlier run \(i+1)")
            }
        }
        if let document = dict["document"] as? [String:Any] { container(document,"document image") }
        func pages(_ values: [[String:Any]], _ label: String) {
            for value in values {
                guard let page = value["page"] as? Int else { continue }
                let name = label + " page \(page)"
                blocks.append((name + " extraction status","provider=\(value["provider"] as? String ?? "unknown"); text/geometry are unverified; original page not supplied by this text read"))
                if let text = value["text"] as? String, !text.isEmpty { blocks.append((name + " text",text)) }
                if let analysis = value["analysis"] as? [String:Any] { record(analysis,name) }
                if let error = value["error"] as? String { blocks.append((name + " unavailable content",error)) }
            }
        }
        if let document = dict["document"] as? [String:Any] {
            if let hash = document["sourceSHA256"] as? String { blocks.append(("document source SHA256",hash)) }
            pages(document["pages"] as? [[String:Any]] ?? [],"document")
            for (i,run) in (document["previousPageRuns"] as? [[String:Any]] ?? []).enumerated() {
                if let hash = run["sourceSHA256"] as? String { blocks.append(("document earlier run \(i+1) source SHA256",hash)) }
                pages(run["pages"] as? [[String:Any]] ?? [],"document earlier run \(i+1)")
            }
        }
        if let ocr = dict["ocr"] as? [String:Any] {
            container(ocr,"image")
            for (i,image) in (ocr["images"] as? [[String:Any]] ?? []).enumerated() {
                record(image,"screenshot \(i+1)")
                for (j,previous) in (image["previousImageAnalyses"] as? [[String:Any]] ?? []).enumerated() { record(previous,"screenshot \(i+1) earlier run \(j+1)") }
                if let empty = image["lastEmptyAttempt"] as? [String:Any] { record(empty,"screenshot \(i+1) latest empty attempt") }
            }
        }
        for (i,attachment) in (dict["attachments"] as? [[String:Any]] ?? []).enumerated() {
            container(attachment,"attachment \(i+1) image")
            if let hash = attachment["sourceSHA256"] as? String { blocks.append(("attachment \(i+1) source SHA256",hash)) }
            pages(attachment["pages"] as? [[String:Any]] ?? [],"attachment \(i+1)")
            for (j,run) in (attachment["previousPageRuns"] as? [[String:Any]] ?? []).enumerated() {
                pages(run["pages"] as? [[String:Any]] ?? [],"attachment \(i+1) earlier PDF run \(j+1)")
            }
        }
        return blocks
    }
}

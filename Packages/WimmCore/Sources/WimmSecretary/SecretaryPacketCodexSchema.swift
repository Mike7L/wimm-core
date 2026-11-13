import Foundation

extension SecretaryPacket {
    /// The CLI's strict JSON mode prevents syntax errors only. resolveEdits still verifies
    /// sources, supplied blocks, citations, scopes and complete read receipts.
    static func codexJSONSchema() throws -> Data {
        let string: [String: Any] = ["type": "string"]
        let nullable: [String: Any] = ["type": ["string", "null"]]
        let source: [String: Any] = ["type": "string", "pattern": "^S[0-9]+$"]
        func array(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
        }
        let review = object(["source": source, "reason": string])
        let null: [String: Any] = ["type": "null"]
        let nonEmpty: [String: Any] = ["type": "string", "minLength": 1]
        let blockID: [String: Any] = ["type": "string", "pattern": "^b[0-9]+$"]
        let operations = ["insert_under_heading", "insert_after", "insert_before", "replace_text"]
        let edit: [String: Any] = ["anyOf": operations.map { operation in
            object(["operation": ["type": "string", "enum": [operation]],
                    "section": operation == "insert_under_heading" ? blockID : null,
                    "block": operation == "insert_under_heading" ? null : blockID,
                    "match": operation == "replace_text" ? nonEmpty : null,
                    "text": operation == "replace_text" ? string : nonEmpty,
                    "sources": array(source)])
        }]
        let schema = object(["summary": string, "edits": array(edit), "done_no_additions": array(review),
                             "not_a_note": array(review), "unfinished": array(object(["source": source, "obstacle": string, "section": nullable])),
                             "questions": array(string)])
        return try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
    }
}

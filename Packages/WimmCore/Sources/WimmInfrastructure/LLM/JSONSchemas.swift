import Foundation
import WimmDomain

public enum JSONSchemas {
    public nonisolated(unsafe) static let combinedCards: [String: Any] = [
        "type": "object",
        "properties": [
            "schema": ["type": "string", "enum": [Schemas.combinedCards]],
            "groups": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "selected_note_ids": [
                            "type": "array",
                            "items": ["type": "string"]
                        ],
                        "title": ["type": "string", "maxLength": 120],
                        "summary": ["type": "string", "maxLength": 1200],
                        "project": [
                            "type": "object",
                            "properties": [
                                "kind": ["type": "string", "enum": ["existing", "new"]],
                                "project_id": ["type": "string"],
                                "name": ["type": "string", "maxLength": 120],
                                "description": ["type": "string", "maxLength": 360],
                                "inclusion_rules": [
                                    "type": "array",
                                    "items": ["type": "string"]
                                ],
                                "exclusion_rules": [
                                    "type": "array",
                                    "items": ["type": "string"]
                                ],
                                "confidence": [
                                    "type": "number",
                                    "minimum": 0,
                                    "maximum": 1
                                ],
                                "why": ["type": "string", "maxLength": 160]
                            ],
                            "required": ["kind", "name"]
                        ]
                    ],
                    "required": ["selected_note_ids", "title", "summary", "project"]
                ]
            ]
        ],
        "required": ["schema", "groups"]
    ]

    public nonisolated(unsafe) static let notesAnalysis: [String: Any] = [
        "type": "object",
        "properties": [
            "schema": ["type": "string", "enum": [Schemas.notesAnalysis]],
            "title": ["type": "string", "maxLength": 120],
            "summary": ["type": "string", "maxLength": 1400],
            "key_points": [
                "type": "array",
                "items": ["type": "string"]
            ],
            "key_info": [
                "type": "array",
                "items": ["type": "string"]
            ],
            "todos": [
                "type": "array",
                "items": ["type": "string"]
            ]
        ],
    ]
}

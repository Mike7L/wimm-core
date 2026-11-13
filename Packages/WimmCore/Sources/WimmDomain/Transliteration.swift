import Foundation

public extension String {
    func transliterated() -> String {
        let mapping: [Character: String] = [
            "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "zh", "з": "z",
            "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
            "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
            "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
            "А": "A", "Б": "B", "В": "V", "Г": "G", "Д": "D", "Е": "E", "Ё": "Yo", "Ж": "Zh", "З": "Z",
            "И": "I", "Й": "Y", "К": "K", "Л": "L", "М": "M", "Н": "N", "О": "O", "П": "P", "Р": "R",
            "С": "S", "Т": "T", "У": "U", "Ф": "F", "Х": "Kh", "Ц": "Ts", "Ч": "Ch", "Ш": "Sh", "Щ": "Shch",
            "Ъ": "", "Ы": "Y", "Ь": "", "Э": "E", "Ю": "Yu", "Я": "Ya"
        ]
        
        var result = ""
        for char in self {
            if let replacement = mapping[char] {
                result.append(replacement)
            } else {
                result.append(char)
            }
        }
        return result
    }

    func toSlug() -> String {
        let clean = self.transliterated().lowercased()
        var slug = ""
        var lastWasDash = false
        
        for char in clean {
            if char.isLetter || char.isNumber {
                slug.append(char)
                lastWasDash = false
            } else if char.isWhitespace || char == "-" || char == "_" || char == "/" || char == "\\" {
                if !lastWasDash && !slug.isEmpty {
                    slug.append("-")
                    lastWasDash = true
                }
            }
        }
        
        // Remove trailing dash if any
        if slug.hasSuffix("-") {
            slug.removeLast()
        }
        
        return slug.isEmpty ? "uncategorized" : slug
    }
}

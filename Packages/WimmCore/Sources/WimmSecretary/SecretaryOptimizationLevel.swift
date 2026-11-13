import Foundation
import WimmInfrastructure

/// Progressive context reduction level for packet secretary passes (L0–L5).
public enum SecretaryOptimizationLevel: Int, CaseIterable, Identifiable, Codable, Sendable {
    case l0 = 0 // Базовый (полный)
    case l1 = 1 // Без аудита Wimm
    case l2 = 2 // Без тегов сцены
    case l3 = 3 // Без диагностики
    case l4 = 4 // Без дубликатов версий OCR
    case l5 = 5 // Экстремальное ядро фактов

    public var id: Int { rawValue }
    public static let defaultsKey = "Secretary.optimizationLevel"
    public static let `default`: SecretaryOptimizationLevel = .l0

    public var shortTitle: String {
        switch self {
        case .l0: return "L0"
        case .l1: return "L1"
        case .l2: return "L2"
        case .l3: return "L3"
        case .l4: return "L4"
        case .l5: return "L5"
        }
    }

    public var title: String {
        switch self {
        case .l0: return "L0: Полный доступный текст"
        case .l1: return "L1: Без служебного аудита Wimm"
        case .l2: return "L2: Без тегов сцены Apple Vision"
        case .l3: return "L3: Без технической диагностики"
        case .l4: return "L4: Без строк ссылок на точные копии"
        case .l5: return "L5: Экспериментальная выборка блоков"
        }
    }

    public var tokenSavingBadge: String {
        self == .l0 ? "Полный текст" : "Эксперимент"
    }

    public var hint: String {
        switch self {
        case .l0: return "Полный доступный текст со всеми версиями; проверенные квитанции чтения."
        case .l1: return "Скрыты пути, хеши, даты обновления и список оригиналов. ASR-предупреждения сохранены. Только предпросмотр."
        case .l2: return "Дополнительно удалены теги классификатора сцены и стандартные оговорки."
        case .l3: return "Дополнительно удалены штрихкоды, статусы геометрии и вспомогательные детекторы."
        case .l4: return "Удалены строки ссылок на точные копии; это не подтверждает сохранение всех связей между версиями."
        case .l5: return "Экспериментальная фильтрация по заголовкам. Может удалить содержательные тексты и предупреждения; безопасное применение не подтверждено."
        }
    }

    public static func preferred(defaults: UserDefaults = .standard) -> SecretaryOptimizationLevel {
        let val = defaults.integer(forKey: defaultsKey)
        return SecretaryOptimizationLevel(rawValue: val) ?? .default
    }
}

/// Helper to filter note source text according to the selected optimization level.
public enum SecretaryOptimization {
    public static func filter(_ text: String, level: SecretaryOptimizationLevel) -> String {
        switch level {
        case .l0:
            return text
        case .l1:
            return cleanL1(text)
        case .l2:
            return cleanL2(text)
        case .l3:
            return cleanL3(text)
        case .l4:
            return cleanL4(text)
        case .l5:
            return cleanL5(text)
        }
    }

    private static func cleanL1(_ text: String) -> String {
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("file: ") || line.hasPrefix("meta: ") ||
               line.hasPrefix("sha256: ") || line.hasPrefix("updated: ") ||
               line.hasPrefix("sync_updated: ") {
                continue
            }
            if line.hasPrefix("--- visual source roster") {
                break
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func cleanL2(_ text: String) -> String {
        let base = cleanL1(text)
        var lines: [String] = []
        var skipBlock = false
        for line in base.components(separatedBy: "\n") {
            if line.hasPrefix("text_scope: all_available_text") || line.hasPrefix("title_source: fallback") {
                continue
            }
            if line.hasPrefix("--- ") && (line.contains("native scene observations") || line.contains("native observations") || line.contains("image observations")) {
                skipBlock = true
                continue
            }
            if skipBlock {
                if line.hasPrefix("--- ") && !line.contains("native scene") && !line.contains("image observations") {
                    skipBlock = false
                    lines.append(line)
                }
                continue
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func cleanL3(_ text: String) -> String {
        let base = cleanL2(text)
        var lines: [String] = []
        var skip = false
        for line in base.components(separatedBy: "\n") {
            if line.hasPrefix("--- ") && (line.contains("image layout status") || line.contains("image barcodes") ||
               line.contains("image detected data") || line.contains("image diagnostics") ||
               line.contains("image MLX description status")) {
                if line.contains("=") { continue }
                skip = true
                continue
            }
            if skip {
                if line.hasPrefix("--- ") {
                    skip = false
                    lines.append(line)
                }
                continue
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func cleanL4(_ text: String) -> String {
        let base = cleanL3(text)
        var lines: [String] = []
        for line in base.components(separatedBy: "\n") {
            if line.hasPrefix("--- ") && line.contains(" = ") {
                continue
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func cleanL5(_ text: String) -> String {
        let l4 = cleanL4(text)
        let lines = l4.components(separatedBy: "\n")
        var dateStr = ""
        var markStr = ""
        for line in lines {
            if line.hasPrefix("date: ") && dateStr.isEmpty {
                dateStr = String(line.dropFirst(6)).components(separatedBy: " ").first ?? ""
            } else if line.hasPrefix("mark: ") && markStr.isEmpty {
                let parts = String(line.dropFirst(6)).components(separatedBy: "·")
                markStr = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            }
        }
        // Extract primary blocks
        var primary = ""
        let parts = l4.components(separatedBy: "\n--- ")
        for part in parts {
            if part.contains("transcript") || part.contains("OCR") || part.contains("attachment 1") {
                if !part.contains("barcodes") && !part.contains("diagnostics") && !part.contains("detected") {
                    primary += "\n--- " + part
                }
            }
        }
        if primary.isEmpty {
            primary = "\n" + l4.suffix(1000)
        }
        var header = ""
        if !dateStr.isEmpty { header += "date: \(dateStr)\n" }
        if !markStr.isEmpty { header += "mark: \(markStr)\n" }
        return (header + primary).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

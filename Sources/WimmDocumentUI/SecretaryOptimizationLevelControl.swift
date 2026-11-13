import SwiftUI
import WimmInfrastructure
import WimmSecretary

/// Control to select and tune the packet context optimization level (L0–L5).
public struct SecretaryOptimizationLevelControl: View {
    @Binding private var level: SecretaryOptimizationLevel

    public init(level: Binding<SecretaryOptimizationLevel>) {
        self._level = level
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Оптимизация контекста").font(.body.weight(.medium))
                Spacer()
                Text(level.tokenSavingBadge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(level == .l5 ? Color.green : (level == .l0 ? Color.secondary : Color.blue))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(level == .l5 ? Color.green.opacity(0.12) : (level == .l0 ? Color.secondary.opacity(0.1) : Color.blue.opacity(0.12)))
                    )
            }

            Picker("Уровень", selection: $level) {
                ForEach(SecretaryOptimizationLevel.allCases) { opt in
                    Text(opt.shortTitle).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(level.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            Text(level.hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

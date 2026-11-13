import SwiftUI
import WimmInfrastructure
import WimmSecretary

public struct SecretaryPacketSizeControl: View {
    @Binding private var value: Int
    private let label: String
    private let hint: String
    private let unit: String

    public init(value: Binding<Int>, label: String, hint: String, unit: String) {
        self._value = value; self.label = label; self.hint = hint; self.unit = unit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text("\(SecretaryPacketSettings.normalize(value)) \(unit)").monospacedDigit()
            }
            Slider(value: Binding(get: { Double(SecretaryPacketSettings.normalize(value)) },
                                  set: { value = SecretaryPacketSettings.normalize(Int($0)) }),
                   in: Double(SecretaryPacketSettings.minimumKB)...Double(SecretaryPacketSettings.maximumKB),
                   step: Double(SecretaryPacketSettings.stepKB)) {
                Text(label)
            }
            .labelsHidden()
            .accessibilityValue("\(SecretaryPacketSettings.normalize(value)) \(unit)")
            HStack {
                Text("\(SecretaryPacketSettings.minimumKB) \(unit)")
                Spacer()
                Text("\(SecretaryPacketSettings.maximumKB) \(unit)")
            }
            .font(.caption2).foregroundStyle(.secondary)
            Text(hint).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

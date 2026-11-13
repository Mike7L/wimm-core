#if os(iOS)
import SwiftUI

struct ModernWaveform: View {
    let levels: [Float]
    let barCount: Int
    let height: CGFloat
    let barWidth: CGFloat
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            if levels.isEmpty {
                ForEach(0..<barCount, id: \.self) { _ in
                    Circle()
                        .fill(color.opacity(0.25))
                        .frame(width: barWidth, height: barWidth)
                }
            } else {
                let displayLevels = normalize(levels, count: barCount)
                ForEach(0..<displayLevels.count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                        .fill(color.gradient)
                        .frame(width: barWidth, height: max(barWidth, CGFloat(displayLevels[index]) * height))
                }
            }
        }
        .frame(height: height)
    }

    private func normalize(_ levels: [Float], count: Int) -> [Float] {
        guard !levels.isEmpty else { return Array(repeating: 0.1, count: count) }
        let stride = max(1, levels.count / count)
        var result: [Float] = []
        for index in 0..<count {
            let idx = min(index * stride, levels.count - 1)
            result.append(max(0.1, levels[idx]))
        }
        return result
    }
}

#Preview {
    ModernWaveform(levels: [], barCount: 20, height: 30, barWidth: 3, color: .red)
        .padding()
}
#endif

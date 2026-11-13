#if os(iOS)
import SwiftUI

/// Visual indicator showing the save status of recording metadata.
/// Displays Saving/Saved/Error states with smooth animations and VoiceOver support.
struct SaveStatusIndicator: View {
    let status: SaveStatus
    @State private var isVisible = false
    @State private var isPulsing = false
    
    enum SaveStatus: Equatable {
        case saving
        case saved
        case error(String)
        
        var accessibilityLabel: String {
            switch self {
            case .saving:
                return L10n.iOS.SaveStatus.accessibilitySaving
            case .saved:
                return L10n.iOS.SaveStatus.accessibilitySaved
            case .error(let message):
                return L10n.iOS.SaveStatus.accessibilityError(message)
            }
        }
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.caption2)
                .symbolEffect(.pulse, options: .repeating, isActive: status == .saving)
            
            Text(statusText)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.9)
        .accessibilityLabel(status.accessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isVisible = true
            }
            
            // Auto-hide "Saved" status after 1 second
            if case .saved = status {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isVisible = false
                    }
                }
            }
        }
        .onChange(of: status) { oldValue, newValue in
            // Animate status changes
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                isVisible = true
            }
            
            // Auto-hide "Saved" status
            if case .saved = newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isVisible = false
                    }
                }
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var iconName: String {
        switch status {
        case .saving:
            return "icloud.and.arrow.up"
        case .saved:
            return "checkmark.icloud"
        case .error:
            return "exclamationmark.icloud"
        }
    }
    
    private var statusText: String {
        switch status {
        case .saving:
            return L10n.iOS.SaveStatus.saving
        case .saved:
            return L10n.iOS.SaveStatus.saved
        case .error:
            return L10n.iOS.SaveStatus.error
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .saving:
            return .blue
        case .saved:
            return .green
        case .error:
            return .red
        }
    }
}

// MARK: - Inline Save Status Indicator (for chat bubbles)

/// Compact inline save status indicator without background for chat messages.
/// Shows saving/saved states with minimal visual footprint.
struct InlineSaveStatusIndicator: View {
    let isSaved: Bool
    let textColor: Color
    
    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 10))
            .foregroundColor(textColor.opacity(0.6))
            .symbolEffect(.pulse, options: .repeating, isActive: !isSaved)
            .accessibilityLabel(accessibilityLabel)
    }
    
    private var iconName: String {
        isSaved ? "checkmark.icloud.fill" : "icloud.and.arrow.up"
    }
    
    private var accessibilityLabel: String {
        isSaved ? L10n.iOS.SaveStatus.accessibilitySaved : L10n.iOS.SaveStatus.accessibilitySaving
    }
}

// MARK: - Previews

#Preview("Saving") {
    SaveStatusIndicator(status: .saving)
        .padding()
        .background(Color.gray.opacity(0.2))
}

#Preview("Saved") {
    SaveStatusIndicator(status: .saved)
        .padding()
        .background(Color.gray.opacity(0.2))
}

#Preview("Error") {
    SaveStatusIndicator(status: .error("Network unavailable"))
        .padding()
        .background(Color.gray.opacity(0.2))
}

#Preview("All States") {
    VStack(spacing: 20) {
        SaveStatusIndicator(status: .saving)
        SaveStatusIndicator(status: .saved)
        SaveStatusIndicator(status: .error("Failed to save"))
    }
    .padding()
    .background(Color.gray.opacity(0.2))
}

#Preview("Inline Indicators") {
    VStack(spacing: 20) {
        HStack {
            Text("Message")
            Spacer()
            InlineSaveStatusIndicator(isSaved: false, textColor: .primary)
            Text("10:30 AM")
                .font(.caption2)
        }
        .padding()
        .background(Color.blue)
        
        HStack {
            Text("Message")
            Spacer()
            InlineSaveStatusIndicator(isSaved: true, textColor: .white)
            Text("10:30 AM")
                .font(.caption2)
                .foregroundColor(.white)
        }
        .padding()
        .background(Color.gray.opacity(0.3))
    }
    .padding()
}
#endif

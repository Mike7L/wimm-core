import Darwin
import Foundation
import WimmDomain

func renderHUDFrame(state: HUDViewState) -> String {
    var lines: [String] = []
    lines.append("WIMM HUD")
    lines.append("Root: \(state.rootPath)")
    lines.append("Updated: \(hudTime(state.snapshot.generatedAt))")
    lines.append("")
    lines.append("Queue: total=\(state.snapshot.total)  pending=\(state.snapshot.pending)  done=\(state.snapshot.completed)  failed.retryable=\(state.snapshot.failedRetryable)  failed.nonretryable=\(state.snapshot.failedNonRetryable)")
    lines.append("Record auto-process: \(state.autoProcessAfterRecord ? "on" : "off")")
    switch state.mode {
    case .capture:
        lines.append("Mode: capture")
    case .review:
        lines.append("Mode: review")
    case .idle:
        lines.append("Mode: idle")
    }

    if let recordingSince = state.recordingSince {
        lines.append("Record state: ACTIVE (x=stop) since \(hudTime(recordingSince))")
        if let liveTranscriptPreview = state.liveTranscriptPreview, !liveTranscriptPreview.isEmpty {
            lines.append("Live transcript: \(liveTranscriptPreview)")
        } else {
            lines.append("Live transcript: (waiting for speech...)")
        }
    } else {
        lines.append("Record state: idle (x=start)")
    }

    if let reviewState = state.reviewState {
        lines.append("Last saved note: [\(reviewState.shortID)] \(hudTime(reviewState.savedAt))")
        lines.append("Review transcript: \(reviewState.preview)")
    }

    lines.append("")
    lines.append("Recent notes:")
    if state.snapshot.recent.isEmpty {
        lines.append("  (no notes)")
    } else {
        for row in state.snapshot.recent {
            lines.append("  [\(row.shortID)] \(hudTime(row.createdAt))  \(row.statusLabel)  \(row.title)")
        }
    }

    lines.append("")
    lines.append("Hotkeys: x/w=toggle recording  c=queue process  e=export  l=list  s=stats")
    lines.append("         m=edit last transcript  d=delete last note  a=toggle auto-process")
    lines.append("         Esc=cancel record  r=refresh  h=help  q=close HUD  Shift+X=exit app")
    if state.showHelp {
        lines.append("")
        lines.append("Help:")
        lines.append("  x or w: Start/stop recording directly in HUD.")
        lines.append("  Esc: Cancel current recording (without saving).")
        lines.append("  m: Edit transcript of last note saved from HUD.")
        lines.append("  d: Delete last note saved from HUD.")
        lines.append("  c: Process pending queue tasks.")
        lines.append("  e: Export latest notes to a temporary directory.")
        lines.append("  l: Show 10 latest notes.")
        lines.append("  s: Print statistics snapshot.")
        lines.append("  a: Toggle auto-process flag for record flow.")
        lines.append("  q: Return to command prompt, Shift+X: terminate app.")
    }
    lines.append("")
    lines.append("Last: \(state.lastMessage)")
    return lines.joined(separator: "\n")
}

func renderHUD(frame: String) {
    print("\u{001B}[2J\u{001B}[H", terminator: "")
    print(frame)
    fflush(stdout)
}

private func hudTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

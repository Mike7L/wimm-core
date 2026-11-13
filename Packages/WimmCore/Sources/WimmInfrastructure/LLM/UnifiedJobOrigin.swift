import Foundation

public enum UnifiedJobOrigin {
    public static let uiRetryAttachmentOCR = "ui.retryAttachmentOCR"
    public static let uiRetryAttachmentAudio = "ui.retryAttachmentOCR.audio"
    public static let uiReprocessNote = "ui.reprocessNote"
    public static let uiInstructionAnalysis = "ui.analysis.instruction"
    public static let uiCardsAnalysis = "ui.analysis.cards"
    public static let pipelineAttachmentTranscription = "pipeline.attachmentTranscription"
}

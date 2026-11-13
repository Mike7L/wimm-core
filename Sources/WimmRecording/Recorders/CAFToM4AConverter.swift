import Foundation
import AVFoundation
import WimmDomain
import WimmInfrastructure

/// Converts CAF (Core Audio Format) recordings to M4A (AAC) for storage efficiency.
/// CAF is used during recording for real-time streaming write without compression overhead.
/// After recording completes, we convert to M4A for ~10x size reduction.
public enum CAFToM4AConverter {
    
    /// Convert CAF file to M4A using AVAssetExportSession
    /// - Parameters:
    ///   - cafURL: Source CAF file
    ///   - m4aURL: Destination M4A file (will be overwritten)
    /// - Returns: True if conversion succeeded
    public static func convert(from cafURL: URL, to m4aURL: URL) async throws {
        let asset = AVURLAsset(url: cafURL)
        
        // Verify asset is readable
        guard try await asset.load(.isReadable) else {
            throw ConversionError.unreadableAsset
        }
        
        // Verify audio track exists
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw ConversionError.noAudioTrack
        }
        
        // Remove destination if exists
        try? FileManager.default.removeItem(at: m4aURL)
        
        // Create export session
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ConversionError.exportSessionCreationFailed
        }
        
        if #available(macOS 15.0, *) {
            do {
                try await exporter.export(to: m4aURL, as: .m4a)
                log("[CAFConverter] ✓ Converted \(cafURL.lastPathComponent) → \(m4aURL.lastPathComponent)")
            } catch is CancellationError {
                throw ConversionError.cancelled
            } catch {
                let errorMsg = error.localizedDescription
                log("[CAFConverter] ✗ Conversion failed: \(errorMsg)")
                throw ConversionError.exportFailed(errorMsg)
            }
        } else {
            exporter.outputURL = m4aURL
            exporter.outputFileType = .m4a
            
            // Perform conversion
            await exporter.export()
            
            // Check result
            switch exporter.status {
            case .completed:
                log("[CAFConverter] ✓ Converted \(cafURL.lastPathComponent) → \(m4aURL.lastPathComponent)")
            case .failed:
                let errorMsg = exporter.error?.localizedDescription ?? "Unknown error"
                log("[CAFConverter] ✗ Conversion failed: \(errorMsg)")
                throw ConversionError.exportFailed(errorMsg)
            case .cancelled:
                throw ConversionError.cancelled
            default:
                throw ConversionError.unexpectedStatus(exporter.status)
            }
        }
    }
    
    // MARK: - Errors
    
    public enum ConversionError: LocalizedError {
        case unreadableAsset
        case noAudioTrack
        case exportSessionCreationFailed
        case exportFailed(String)
        case cancelled
        case unexpectedStatus(AVAssetExportSession.Status)
        
        public var errorDescription: String? {
            switch self {
            case .unreadableAsset:
                return "CAF file is not readable"
            case .noAudioTrack:
                return "CAF file contains no audio track"
            case .exportSessionCreationFailed:
                return "Failed to create AVAssetExportSession"
            case .exportFailed(let msg):
                return "Export failed: \(msg)"
            case .cancelled:
                return "Conversion was cancelled"
            case .unexpectedStatus(let status):
                return "Unexpected export status: \(status.rawValue)"
            }
        }
    }
}

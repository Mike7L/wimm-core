import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check health of the WIMM installation (permissions, orphans, keys)"
    )

    @Option(name: .shortAndLong, help: "Path to save detailed report")
    var report: String?

    func run() async throws {
        let healthService = SystemHealthService()
        let health = await healthService.evaluate()

        print("🩺 Running WIMM Doctor...")
        print("========================")
        
        // 1. Environment & Directories
        print("\n📂 Checking Environment:")
        print("   Base Dir: \(health.baseDirectory.path)")
        if health.recordingsDirectoryExists {
            print("   ✅ Recordings Directory exists")
        } else {
            print("   ❌ Recordings Directory MISSING: \(health.recordingsDirectory.path)")
        }

        // 2. Permissions
        print("\n🔐 Checking Permissions:")
        if health.writeAccessOK {
            print("   ✅ Write access confirmed")
        } else {
            print("   ❌ Write access FAILED: \(health.writeAccessError ?? "Unknown error")")
        }

        // 3. API Keys (Basic Check)
        print("\n🔑 Checking API Keys:")
        if health.geminiKeyPresent {
             print("   ✅ Gemini Key found (Length: \(health.geminiKeyLength))")
        } else {
             print("   ⚠️ Gemini Key missing or placeholder")
        }
        
        if health.openRouterKeyCount > 0 {
             print("   ✅ OpenRouter Key found (\(health.openRouterKeyCount) available)")
        } else {
             print("   ⚠️ OpenRouter Key missing (Optional)")
        }


        // 4. Data Integrity (Orphans)
        print("\n🧹 Checking Data Integrity (Orphans):")
        if let scanError = health.integrityScanError {
            print("   ❌ Failed to list directory: \(scanError)")
        } else if health.unindexedSessions.isEmpty && health.ghostMetadata.isEmpty {
            print("   ✅ No integrity issues found.")
        } else {
            if !health.unindexedSessions.isEmpty {
                print("   ℹ️  Found \(health.unindexedSessions.count) recordings pending metadata generation (will be auto-fixed by queue):")
                for session in health.unindexedSessions.prefix(5) {
                    print("      - \(session)")
                }
                if health.unindexedSessions.count > 5 {
                    print("      ... and \(health.unindexedSessions.count - 5) more")
                }
            }

            if !health.ghostMetadata.isEmpty {
                print("   ⚠️ Found \(health.ghostMetadata.count) .meta.json files with NO matching content (Ghost Metadata):")
                for issue in health.ghostMetadata.prefix(5) {
                    print("      - \(issue.metaFileName)")
                }
                if health.ghostMetadata.count > 5 {
                    print("      ... and \(health.ghostMetadata.count - 5) more")
                }
            }

            if let reportPath = report {
                let output = await healthService.detailedReportText(from: health)
                try output.write(toFile: reportPath, atomically: true, encoding: .utf8)
                print("\n📄 Detailed report saved to: \(reportPath)")
            }
        }
        
        print("\n✅ Doctor check complete.")
    }
}

import ArgumentParser
import Foundation
import WimmInfrastructure

struct PhotoLibrary: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "library", abstract: "Inventory all image notes, attachments and every screenshot")
    @Option(name: .long, help: "Save private inventory JSON to a new file") var output: String?
    func run() async throws {
        let inventory = await LibraryImageInventory.scan()
        if let output {
            let file = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
            guard !FileManager.default.fileExists(atPath: file.path) else { throw ValidationError("Output already exists") }
            try encoder.encode(inventory).write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        print("Active notes: \(inventory.notes); image references: \(inventory.targets.count); distinct files: \(Set(inventory.targets.map(\.image)).count)")
        for kind in [LibraryImageInventory.Target.Kind.standalone, .screenshot, .attachment, .orphan] {
            print("\(kind.rawValue): \(inventory.targets.filter { $0.kind == kind }.count)")
        }
        print("Generated previews excluded: \(inventory.excludedPreviews); missing image attachments: \(inventory.missingAttachments)")
    }
}

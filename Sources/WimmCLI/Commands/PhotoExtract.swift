import ArgumentParser
import Foundation
import WimmInfrastructure

struct PhotoExtract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName:"extract",abstract:"Explicit local image extraction for a note; --apply saves all evidence and history")
    @Argument(help:"Path to the parent note or a standalone image note") var note: String
    @Option(name:.long) var engine = "vision"
    @Option(name:.long,help:"Process only this image of the note") var image: String?
    @Flag(name:.long) var apply = false
    func run() async throws {
        guard let selected = DocumentOCREngine(rawValue:engine), selected == .vision || selected == .mlx else { throw ValidationError("Choose --engine vision or mlx") }
        let parent = URL(fileURLWithPath:(note as NSString).expandingTildeInPath)
        let source = image.map { URL(fileURLWithPath:($0 as NSString).expandingTildeInPath) }
        let targets = LibraryImageInventory.targets(for:parent).filter { target in source == nil || target.image == source!.standardizedFileURL.resolvingSymlinksInPath().path }
        guard !targets.isEmpty else { throw ValidationError("No matching original images in this note") }
        guard apply else { print("Would process \(targets.count) image(s) using \(engine). Use --apply to extract and save; no inference performed.");return }
        let count = try await ImageUnderstanding.run(note:parent,image:source,engine:selected)
        print("Saved \(count) image result(s), including provenance, native observations and run history. No note-card analysis requested.")
    }
}

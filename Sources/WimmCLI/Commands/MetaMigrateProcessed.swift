import ArgumentParser
import Foundation
import WimmInfrastructure
import WimmDomain

struct MetaMigrateProcessed: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate-processed",
        abstract: "Migrates is_unprocessed boolean to processed_at timestamp in NoteCard metadata"
    )

    mutating func run() async throws {
        print("Migrating metadata...")

        let fileRepo = FileRepository()
        let metaRepo = MetadataRepository()

        let files = await fileRepo.recordings()
        print("Found \(files.count) recordings.")

        var migratedCount = 0
        var skippedCount = 0

        for (index, file) in files.enumerated() {
            if index % 100 == 0 {
                print("Progress: \(index)/\(files.count). Migrated: \(migratedCount)")
            }

            // Reading the card triggers the migration logic in NoteCard.init(from:)
            if let card = await metaRepo.existingNoteCard(for: file) {
                // Upserting it writes it back with the new encoding (processed_at)
                await metaRepo.upsertNoteCard(for: file, card: card, lang: card.lang)
                migratedCount += 1
            } else {
                skippedCount += 1
            }
        }

        print("Migration complete.")
        print("Migrated: \(migratedCount)")
        print("Skipped (no metadata): \(skippedCount)")
    }
}

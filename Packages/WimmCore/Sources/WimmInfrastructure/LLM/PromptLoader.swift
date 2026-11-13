import Foundation

/// Utility to load LLM prompts from the application bundle.
/// Prompts are stored as `.txt` files in the `Prompts` directory.
public enum PromptLoader {
    /// Loads a prompt by name and optionally replaces placeholders.
    /// - Parameters:
    ///   - name: The name of the prompt file (without extension).
    ///   - variables: A dictionary of key-value pairs to replace in the prompt text.
    ///                Placeholders in the text should be in the format `{{key}}`.
    /// - Returns: The loaded and processed prompt string.
    public static func load(_ name: String, variables: [String: String] = [:]) -> String {
        // Try multiple bundle sources for maximum compatibility
        var candidateBundles: [Bundle] = []
        
        #if SWIFT_PACKAGE
        candidateBundles.append(Bundle.module)
        #endif
        
        candidateBundles.append(Bundle.main)
        
        // Fallback: search all bundles for the WimmInfrastructure bundle
        if let coreBundle = Bundle.allBundles.first(where: { $0.bundlePath.contains("WimmInfrastructure") }) {
            candidateBundles.append(coreBundle)
        }
        
        var url: URL?
        var triedBundles: [String] = []
        
        for bundle in candidateBundles {
            triedBundles.append(bundle.bundlePath)
            
            // Try subdirectory first
            url = bundle.url(forResource: name, withExtension: "txt", subdirectory: "Prompts")
            if url != nil { break }
            
            // Try root
            url = bundle.url(forResource: name, withExtension: "txt")
            if url != nil { break }
        }
        
        guard let finalURL = url else {
            // Fallback or assertion failure if prompt is missing
            print("WARNING: Prompt '\(name).txt' not found. Tried bundles: \(triedBundles)")
            return "Error: Failed to load prompt '\(name)'."
        }
        
        do {
            var text = try String(contentsOf: finalURL, encoding: .utf8)
            
            // Replace variables
            for (key, value) in variables {
                let placeholder = "{{\(key)}}"
                text = text.replacingOccurrences(of: placeholder, with: value)
            }
            
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("ERROR: Failed to load prompt '\(name)': \(error)")
            return "Error: Failed to load prompt '\(name)'."
        }
    }
}

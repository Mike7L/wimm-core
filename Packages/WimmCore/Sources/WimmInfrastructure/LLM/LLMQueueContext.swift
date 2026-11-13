import Foundation

enum LLMQueueContext {
    @TaskLocal static var inUnifiedQueue: Bool = false
}

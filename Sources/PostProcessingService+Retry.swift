import Foundation

extension PostProcessingService {
    // Retries post-processing using a saved prompt template and the specified model.
    // Utilizes a task group to enforce the timeout interval and cancel pending requests.
    func retryWithPrompt(
        systemPrompt: String,
        userMessage: String,
        model: String,
        isCommandMode: Bool
    ) async throws -> PostProcessingResult {
        let timeoutSeconds = postProcessingTimeoutSeconds
        
        return try await withThrowingTaskGroup(of: PostProcessingResult.self) { group in
            // Add the main API request task to the group
            group.addTask { [weak self] in
                guard let self else {
                    throw PostProcessingError.invalidResponse("Post-processing service deallocated")
                }
                
                let promptForDisplay = """
Model: \(model)

[System]
\(systemPrompt)

[User]
\(userMessage)
"""
                
                var payload: [String: Any] = [
                    "model": model,
                    "temperature": 0.0,
                    "messages": [
                        [
                            "role": "system",
                            "content": systemPrompt
                        ],
                        [
                            "role": "user",
                            "content": userMessage
                        ]
                    ]
                ]
                
                // Fetch the configuration for the chosen model
                let config = ModelConfiguration.config(for: model)
                // Apply fallback parameters if necessary
                self.applyModelConfigAndFallbacks(to: &payload, model: model, config: config)
                
                // Execute API request using the shared transport helper
                let content = try await self.executeAPIRequest(
                    payload: payload,
                    config: config,
                    timeoutInterval: timeoutSeconds
                )
                
                // Sanitize transcript based on active command/dictation mode
                let sanitizedTranscript = isCommandMode
                    ? self.sanitizeCommandModeTranscript(content)
                    : self.sanitizePostProcessedTranscript(content)
                
                return PostProcessingResult(
                    transcript: sanitizedTranscript,
                    prompt: promptForDisplay
                )
            }
            
            // Add the timeout monitor task to the group
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw PostProcessingError.requestTimedOut(timeoutSeconds)
            }
            
            do {
                // Return the first task to finish (either successful API response or timeout)
                guard let result = try await group.next() else {
                    throw PostProcessingError.invalidResponse("No post-processing result")
                }
                group.cancelAll()
                return result
            } catch {
                // Ensure all remaining tasks in the group are cancelled on failure
                group.cancelAll()
                throw error
            }
        }
    }
}

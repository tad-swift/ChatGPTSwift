//
//  ChatGPTAPI.swift
//  XCAChatGPT
//
//  Created by Alfian Losari on 01/02/23.
//

import Foundation
import GPTEncoder
import OpenAPIRuntime
#if os(Linux)
import OpenAPIAsyncHTTPClient
#else
import OpenAPIURLSession
#endif

public typealias ChatCompletionTool = Components.Schemas.ChatCompletionTool
public typealias ChatCompletionResponseMessage = Components.Schemas.ChatCompletionResponseMessage

public class ChatGPTAPI: @unchecked Sendable {
    
    public enum Constants {
        public static let defaultSystemText = "You're a helpful assistant"
        public static let defaultTemperature = 0.5
    }
    
    public let client: Client
    private let urlString = "https://api.openai.com/v1"
    private let gptEncoder = GPTEncoder()
    public private(set) var historyList = [Message]()
    private let apiKey: String
    
    let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "YYYY-MM-dd"
        return df
    }()
    
    private func systemMessage(content: String) -> Message {
        .init(role: "system", content: content)
    }
    
    public init(apiKey: String) {
        self.apiKey = apiKey
        let clientTransport: ClientTransport
#if os(Linux)
        clientTransport = AsyncHTTPClientTransport()
#else
        clientTransport = URLSessionTransport()
#endif
        self.client = Client(serverURL: URL(string: self.urlString)!,
                             transport: clientTransport,
                             middlewares: [AuthMiddleware(apiKey: apiKey)])
    }
    
    private func generateMessages(from text: String, systemText: String) -> [Message] {
        var messages = [systemMessage(content: systemText)] + historyList + [Message(role: "user", content: text)]
        if gptEncoder.encode(text: messages.content).count > 4096  {
            _ = historyList.removeFirst()
            messages = generateMessages(from: text, systemText: systemText)
        }
        return messages
    }
    
    private func generateInternalMessages(from text: String, systemText: String) -> [Components.Schemas.ChatCompletionRequestMessage] {
        let messages = self.generateMessages(from: text, systemText: systemText)
        return messages.map {
            $0.role == "user" ? .ChatCompletionRequestUserMessage(.init(content: .case1($0.content), role: .user)) : .ChatCompletionRequestSystemMessage(.init(content: $0.content, role: .system))
        }
    }
    
    private func jsonBody(text: String, model: String, systemText: String, temperature: Double, stream: Bool = true) throws -> Data {
        let request = Request(model: model,
                              temperature: temperature,
                              messages: generateMessages(from: text, systemText: systemText),
                              stream: stream)
        return try JSONEncoder().encode(request)
    }
    
    public func appendToHistoryList(userText: String, responseText: String) {
        self.historyList.append(Message(role: "user", content: userText))
        self.historyList.append(Message(role: "assistant", content: responseText))
    }
    
    //        public func sendMessageStream(
    //            text: String,
    //            model: Components.Schemas.CreateChatCompletionRequest.modelPayload.Value2Payload = .gpt_hyphen_4_hyphen_turbo,
    //            systemText: String = ChatGPTAPI.Constants.defaultSystemText,
    //            temperature: Double = ChatGPTAPI.Constants.defaultTemperature
    //        ) async throws -> AsyncMapSequence<AsyncThrowingPrefixWhileSequence<AsyncThrowingMapSequence<ServerSentEventsDeserializationSequence<ServerSentEventsLineDeserializationSequence<HTTPBody>>, ServerSentEventWithJSONData<Components.Schemas.CreateChatCompletionStreamResponse>>>, String> {
    //            let response = try await client.createChatCompletion(.init(headers: .init(accept: [.init(contentType: .other("text-stream"))]), body: .json(.init(
    //                messages: self.generateInternalMessages(from: text, systemText: systemText),
    //                model: .init(value1: nil, value2: model),
    //                stream: true))))
    //
    //            let stream = try response.ok.body.json.object.rawValue
    //
    //            .prefix { chunk in
    //                if let choice = chunk.data?.choices.first {
    //                    return choice.finish_reason != .stop
    //                } else {
    //                    throw "Invalid data"
    //                }
    //            }
    //            .map{ $0.data?.choices.first?.delta.content ?? "" }
    //            return stream
    //        }
    
    public func sendMessage(
        text: String,
        model: Components.Schemas.CreateChatCompletionRequest.modelPayload.Value2Payload = .gpt_hyphen_4_hyphen_turbo,
        systemText: String = ChatGPTAPI.Constants.defaultSystemText,
        temperature: Double = ChatGPTAPI.Constants.defaultTemperature
    ) async throws -> String {
        
        let response = try await client.createChatCompletion(body: .json(.init(
            messages: self.generateInternalMessages(from: text, systemText: systemText),
            model: .init(value1: nil, value2: model))))
        
        switch response {
        case .ok(let body):
            let json = try body.body.json
            guard let content = json.choices.first?.message.content else {
                throw "No Response"
            }
            self.appendToHistoryList(userText: text, responseText: content)
            return content
        case .undocumented(let statusCode, let payload):
            throw "OpenAIClientError - statuscode: \(statusCode), \(payload)"
        }
    }
    
    public func analyzeImage(
        _ image: String,
        text: String
    ) async throws -> String {
        
        typealias ThisContent = [Components.Schemas.ChatCompletionRequestMessageContentPart]
        
        let content: ThisContent = [
            .ChatCompletionRequestMessageContentPartImage(
                .init(_type: .image_url, image_url: .init(url: "data:image/jpeg;base64,{\(image)}", detail: .high))
            ),
            .ChatCompletionRequestMessageContentPartText(
                .init(_type: .text, text: text)
            )
        ]
        
        let response = try await client.createChatCompletion(
            body: .json(
                .init(
                    messages: [
                        .ChatCompletionRequestUserMessage(
                            .init(content: .case2(content), role: .user)
                        )
                    ],
                    model: .init(value1: nil, value2: .gpt_hyphen_4_hyphen_turbo)
                )
            )
        )
        
        switch response {
        case .ok(let body):
            let json = try body.body.json
            guard let content = json.choices.first?.message.content else {
                throw "No Response"
            }
            self.appendToHistoryList(userText: text, responseText: content)
            return content
        case .undocumented(let statusCode, let payload):
            throw "OpenAIClientError - statuscode: \(statusCode), \(payload)"
        }
    }
    
    public func createThread(
        text: String,
        assistant: String
    ) async throws -> (message: String, threadID: String) {
        let runResponse = try await client.createThreadAndRun(
            body: .json(
                .init(
                    assistant_id: assistant,
                    thread: .init(messages: [.init(role: .user, content: text)]),
                    model: .init(value2: .gpt_hyphen_4_hyphen_turbo),
                    temperature: 0.2,
                    stream: false,
                    max_completion_tokens: nil
                )
            )
        ).ok.body.json
        
        let messages = try await client.listMessages(path: .init(thread_id: runResponse.thread_id)).ok.body.json
        
        guard let targetMessage = messages.data.last(where: { $0.role == .assistant })?.content.first else {
            return ("", runResponse.thread_id)
        }
        
        switch targetMessage {
        case .MessageContentTextObject(let message):
            return (message.text.value, runResponse.thread_id)
        case .MessageContentImageFileObject(let imageObject):
            return (imageObject.image_file.file_id, runResponse.thread_id)
        }
    }
    
    public func deleteThread(id: String) async throws -> Bool {
        try await client.deleteThread(path: .init(thread_id: id)).ok.body.json.deleted
    }
    
    public func callFunction(
        prompt: String,
        tools: [ChatCompletionTool],
        model: Components.Schemas.CreateChatCompletionRequest.modelPayload.Value2Payload = .gpt_hyphen_4,
        systemText: String = "Don't make assumptions about what values to plug into functions. Ask for clarification if a user request is ambiguous."
    ) async throws -> ChatCompletionResponseMessage {
        let response = try await client.createChatCompletion(.init(body: .json(.init(
            messages: generateInternalMessages(from: prompt, systemText: systemText),
            model: .init(value1: nil, value2: model),
            tools: tools,
            tool_choice: .none))))
        
        switch response {
        case .ok(let body):
            let json = try body.body.json
            guard let message = json.choices.first?.message else {
                throw "No Response"
            }
            return message
        case .undocumented(let statusCode, let payload):
            throw "OpenAIClientError - statuscode: \(statusCode), \(payload)"
        }
    }
    
    public func generateSpeechFrom(
        input: String,
        model: Components.Schemas.CreateSpeechRequest.modelPayload.Value2Payload = .tts_hyphen_1,
        voice: Components.Schemas.CreateSpeechRequest.voicePayload = .alloy,
        format: Components.Schemas.CreateSpeechRequest.response_formatPayload = .aac
    ) async throws -> Data {
        let response = try await client.createSpeech(body: .json(
            .init(
                model: .init(value1: nil, value2: model),
                input: input,
                voice: voice,
                response_format: format
            )))
        
        switch response {
        case .ok(let response):
            switch response.body {
            case .binary(let body):
                var data = Data()
                for try await byte in body {
                    data.append(contentsOf: byte)
                }
                return data
            }
            
        case .undocumented(let statusCode, let payload):
            throw "OpenAIClientError - statuscode: \(statusCode), \(payload)"
        }
    }
    
    public func deleteHistoryList() {
        self.historyList.removeAll()
    }
    
    public func replaceHistoryList(with messages: [Message]) {
        self.historyList = messages
    }
    
#if os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS)
    /// TODO: use swift-openapi-runtime MultipartFormBuilder
    public func generateAudioTransciptions(
        audioData: Data,
        fileName: String = "recording.m4a",
        model: String = "whisper-1",
        language: String = "en"
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        let boundary: String = UUID().uuidString
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let bodyBuilder = MultipartFormDataBodyBuilder(boundary: boundary, entries: [
            .file(paramName: "file", fileName: fileName, fileData: audioData, contentType: "audio/mpeg"),
            .string(paramName: "model", value: model),
            .string(paramName: "language", value: language),
            .string(paramName: "response_format", value: "text")
        ])
        request.httpBody = bodyBuilder.build()
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw "Invalid Status Code \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw "Invalid format"
        }
        
        return text
    }
#endif
    
}

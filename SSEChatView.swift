//
//  SSEChatView.swift
//  AITest
//
//  Created by salam on 2026/11/9.
//

import SwiftUI
import Foundation
import Combine

struct Message: Identifiable {
    let id = UUID()
    let role: String
    let content: String
}
@MainActor
final class ArkChatViewModel: NSObject, ObservableObject, URLSessionDelegate{
    @Published var messages: [Message] = [
        Message(role: "system", content: "我是你的聊天助手")
    ]
    
    @Published private(set) var streamingText = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorText: String?
    
    private let apiKey = "豆包开发者平台申请的key"
    private let modelId = "doubao-seed-2-1-lite-260915"
    private let urlStr = "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
    
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()
    
    private var task: URLSessionTask?
    private var sseBuffer = ""
    private var collected = ""
    
    func send(_ text: String) {
        let userContent = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userContent.isEmpty, !isStreaming else {
            return
        }
        messages.append(Message(role: "user", content: userContent))
        
        collected = ""
        sseBuffer = ""
        streamingText = ""
        errorText = ""
        isStreaming = true
        
        let reqMessages = messages.map{ ["role": $0.role, "content":$0.content] }
        let body: [String: Any] = [
            "model": modelId,
            "messages": reqMessages,
            "stream": true
        ]
        
        guard let url = URL(string: urlStr) else { isStreaming = false; return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        let t = session.dataTask(with: request)
        task = t
        t.resume()
    }
    
    func cancel() {
        task?.cancel()
        task = nil
        customFinalize()
    }
    
    fileprivate func consume(_ chunk: String) {
        sseBuffer += chunk
        sseBuffer = sseBuffer.replacingOccurrences(of: "\r\n", with: "\n")
        
        while let r = sseBuffer.range(of: "\n\n"){
            let event = String(sseBuffer[sseBuffer.startIndex..<r.lowerBound])
            sseBuffer.removeSubrange(sseBuffer.startIndex..<r.upperBound)
            handel(event: event)
        }
                
    }
    
    private func handel(event: String) {
        for rawLine in event.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                customFinalize()
                return
            }
            
            guard let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let piece = delta["content"] as? String,
                  !piece.isEmpty
                        else { continue }
                  
            collected += piece
            streamingText = collected
        }
    }
    fileprivate func customFinalize() {
        guard isStreaming else { return }
        isStreaming = false
        if !collected.isEmpty {
            messages.append(Message(role: "assistant", content: collected))
        }
        
        streamingText = ""
        collected = ""
        sseBuffer = ""
        task = nil
    }
}

extension ArkChatViewModel: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        print("代理走了:\(text)")
        Task { @MainActor in self.consume(text) }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        Task { @MainActor in
            if let error = error as? URLError, error.code != .cancelled {
                self.errorText = "请求失败: \(error.localizedDescription)"
            }
            customFinalize()
        }
    }
}

struct SSEChatView: View {
    @StateObject private var vm = ArkChatViewModel()
    @State private var input = ""
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.messages) { msg in
                            bubble(msg.content, role: msg.role).id(msg.id)
                        }
                        if vm.isStreaming {
                            bubble(vm.streamingText.isEmpty ? "正在思考" : vm.streamingText, role: "assistant")
                        }
                        if let err = vm.errorText {
                            Text(err).font(.footnote).foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("__bottom__")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: vm.messages.count) { _, _ in toBottom(proxy) }
                .onChange(of: vm.streamingText) {_, _ in toBottom(proxy)}
            }
            
            HStack(spacing: 8) {
                TextField("输入消息...", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button(vm.isStreaming ? "停止" : "发送") {
                    if vm.isStreaming { vm.cancel()}
                    else { vm.send(input); input = "" }
                }
                .disabled(!vm.isStreaming &&
                          input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding()
        }
    }
    private func bubble(_ text: String, role: String) -> some View {
        Text(text)
            .padding(10)
            .background(role == "user" ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func toBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("__bottom__", anchor: .bottom)
        }
    }
}

#Preview {
    SSEChatView()
}

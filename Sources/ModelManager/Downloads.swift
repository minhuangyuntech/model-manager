import Foundation
import SwiftUI
import AppKit

enum DownloadOrigin: String, CaseIterable {
    case huggingFace = "Hugging Face", civitai = "Civitai", modelScope = "ModelScope", custom = "自訂 HTTPS", ollama = "Ollama"
    var website: URL {
        let address = switch self {
        case .huggingFace: "https://huggingface.co/models"
        case .civitai: "https://civitai.com/models"
        case .modelScope: "https://modelscope.cn/models"
        case .ollama: "https://ollama.com/library"
        case .custom: "https://huggingface.co/models"
        }
        return URL(string: address)!
    }
}

enum DownloadValidation {
    static func url(_ text: String, origin: DownloadOrigin) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else { throw DownloadError.message("請輸入有效的 HTTPS 下載連結，不可包含帳號密碼。") }
        let domain: String? = switch origin {
        case .huggingFace: "huggingface.co"
        case .civitai: "civitai.com"
        case .modelScope: "modelscope.cn"
        default: nil
        }
        if let domain, host != domain && !host.hasSuffix("." + domain) {
            throw DownloadError.message("連結不屬於所選來源；其他網站請選「自訂 HTTPS」。")
        }
        if origin == .huggingFace && url.path.contains("/blob/") {
            throw DownloadError.message("請使用檔案的 /resolve/ 下載連結，而非 /blob/ 網頁連結。")
        }
        return url
    }
    static func filename(_ name: String) throws -> String {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent,
              !name.contains("\\"), !name.hasPrefix("."), !name.contains(":"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              ModelScanner.extensions.subtracting(["mlpackage"]).contains((name as NSString).pathExtension.lowercased()) else {
            throw DownloadError.message("請填寫單一模型檔名，例如 model.safetensors 或 model.gguf（不可含路徑）。")
        }
        return name
    }
}

enum DownloadError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

struct DownloadItem: Identifiable {
    let id: Int
    let name: String
    let destination: URL?
    var received: Int64 = 0
    var total: Int64 = 0
    var status = "連線中"
    var active = true
    var progress: Double? { total > 0 ? min(1, Double(received) / Double(total)) : nil }
}

@MainActor @Observable
final class DownloadCenter: NSObject, URLSessionDownloadDelegate {
    var items: [DownloadItem] = []
    var onCompletion: (() -> Void)?
    private var tasks: [Int: URLSessionTask] = [:]
    private var pulls: [Int: Task<Void, Never>] = [:]
    private var nextPull = -1
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func start(url: URL, name: String, directory: URL, token: String) throws {
        let destination = directory.appendingPathComponent(try DownloadValidation.filename(name))
        guard !FileManager.default.fileExists(atPath: destination.path),
              !items.contains(where: { $0.active && $0.destination == destination }) else {
            throw DownloadError.message("目的檔案已存在或正在下載；請改用其他檔名。不會覆寫既有模型。")
        }
        var request = URLRequest(url: url)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let task = session.downloadTask(with: request)
        items.insert(DownloadItem(id: task.taskIdentifier, name: name, destination: destination), at: 0)
        tasks[task.taskIdentifier] = task
        task.resume()
    }

    func cancel(_ id: Int) {
        tasks.removeValue(forKey: id)?.cancel()
        pulls.removeValue(forKey: id)?.cancel()
        update(id) { $0.active = false; $0.status = "已取消" }
    }
    private func update(_ id: Int, _ body: (inout DownloadItem) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { body(&items[i]) }
    }
    private func fail(_ id: Int, _ message: String) {
        update(id) { if $0.active { $0.status = message; $0.active = false } }
        tasks[id] = nil
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        Task { @MainActor in self.update(id) { if $0.active { $0.received = totalBytesWritten; $0.total = totalBytesExpectedToWrite; $0.status = "下載中" } } }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        let response = downloadTask.response as? HTTPURLResponse
        guard let response, (200...299).contains(response.statusCode), response.statusCode != 206 else {
            Task { @MainActor in self.fail(id, "下載失敗：HTTP \(response?.statusCode ?? 0)") }; return
        }
        let mime = response.mimeType?.lowercased() ?? ""
        guard !mime.contains("text/html"), !mime.contains("application/json"), !mime.contains("text/plain") else {
            Task { @MainActor in self.fail(id, "伺服器回傳網頁／文字而非模型；請檢查直連、授權與存取權限。") }; return
        }
        // URLSession removes its temporary file after this callback; stage it before hopping actors.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".download")
        do { try FileManager.default.moveItem(at: location, to: staging) }
        catch { Task { @MainActor in self.fail(id, "無法暫存下載檔案") }; return }
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: staging) }
            guard let item = self.items.first(where: { $0.id == id }), item.active, let destination = item.destination else { return }
            do {
                // moveItem refuses to overwrite an existing destination.
                try FileManager.default.moveItem(at: staging, to: destination)
                self.update(id) { $0.active = false; $0.status = "已完成" }
                self.tasks[id] = nil
                self.onCompletion?()
            } catch { self.fail(id, "儲存失敗：\(error.localizedDescription)") }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let id = task.taskIdentifier
            // Do not surface request URLs: they may contain signed query tokens.
            let code = (error as NSError).code
            Task { @MainActor in self.fail(id, "連線失敗（\(code)）；請檢查網路、權限後重試。") }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); return }
        var redirected = request
        if request.url?.host != task.originalRequest?.url?.host {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }

    func pull(_ name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count < 200, name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]*$"#, options: .regularExpression) != nil else { throw DownloadError.message("請輸入 Ollama 模型名稱，例如 qwen3:8b。") }
        let id = nextPull; nextPull -= 1
        items.insert(DownloadItem(id: id, name: name, destination: nil), at: 0)
        pulls[id] = Task {
            do {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/pull")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
                request.timeoutInterval = 24 * 3600
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.message("Ollama 回應失敗；請確認服務已啟動與模型名稱正確。") }
                var success = false
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard let data = line.data(using: .utf8), let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let error = event["error"] as? String { throw DownloadError.message(error) }
                    let status = event["status"] as? String ?? "下載中"
                    update(id) { $0.status = status; $0.received = (event["completed"] as? Int64) ?? 0; $0.total = (event["total"] as? Int64) ?? 0 }
                    if status == "success" { success = true }
                }
                try Task.checkCancellation()
                guard success else { throw DownloadError.message("Ollama 連線結束，但未回報成功。") }
                update(id) { $0.active = false; $0.status = "已完成" }
                onCompletion?()
            } catch { fail(id, error is CancellationError ? "已取消" : error.localizedDescription) }
            pulls[id] = nil
        }
    }
}

struct DownloadsView: View {
    @Bindable var center: DownloadCenter
    let store: ModelStore
    @Environment(\.dismiss) private var dismiss
    @State private var origin: DownloadOrigin = .huggingFace
    @State private var link = ""
    @State private var filename = ""
    @State private var token = ""
    @State private var directory: URL?
    @State private var error: String?
    @State private var targetProvider: Provider = .custom

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("下載中心", systemImage: "arrow.down.circle.fill").font(.title.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("從信任的來源取得模型，下載後自動重新掃描。關閉此視窗仍會繼續下載，結束程式則中斷。").foregroundStyle(.secondary)
            Form {
                Picker("下載來源", selection: $origin) { ForEach(DownloadOrigin.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Link("瀏覽 \(origin.rawValue) 模型目錄 ↗", destination: origin.website)
                TextField(origin == .ollama ? "模型名稱（例如 qwen3:8b）" : "HTTPS 檔案直連", text: $link)
                if origin != .ollama {
                    TextField("儲存檔名（例如 model.safetensors）", text: $filename)
                    SecureField("Access Token（選填，僅本次使用、不儲存）", text: $token)
                    Picker("目的資料夾所屬系統", selection: $targetProvider) {
                        ForEach([Provider.custom, .comfyUI, .lmStudio], id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Text(directory?.path ?? "尚未選取目的資料夾").font(.caption).lineLimit(2)
                        Spacer()
                        Button("選擇資料夾…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                            if panel.runModal() == .OK { directory = panel.url?.resolvingSymlinksInPath() }
                        }
                    }
                }
            }.formStyle(.grouped).frame(height: origin == .ollama ? 150 : 300)
            Text(origin == .ollama ? "透過本機 127.0.0.1:11434 下載，由 Ollama 決定儲存位置。請先啟動 Ollama；取消只中止本次請求，伺服器可能保留部分資料。" : "HF 使用 Files → Copy download link（/resolve/）；Civitai 使用模型版本的下載連結；ModelScope 使用檔案下載連結。ComfyUI 請選 checkpoints、loras 等對應資料夾。下載為單檔，不自動安裝依賴或匯入 HF 快取。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                Spacer()
                Button("開始下載", systemImage: "arrow.down") { start() }.buttonStyle(.borderedProminent)
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 12) {
                    if center.items.isEmpty { ContentUnavailableView("尚無下載工作", systemImage: "tray.and.arrow.down", description: Text("請先確認模型授權、磁碟空間與相容格式。")) }
                    ForEach(center.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.name).font(.headline)
                                Spacer()
                                if item.active { Button("取消") { center.cancel(item.id) } }
                                else if item.status == "已完成", let url = item.destination {
                                    Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                            }
                            if item.active { ProgressView(value: item.progress) }
                            HStack {
                                Text(item.status)
                                Spacer()
                                if item.received > 0 { Text(ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }.padding(24).frame(width: 760, height: 780)
        .onChange(of: origin) { _, _ in token = ""; link = ""; error = nil }
    }

    private func start() {
        do {
            if origin == .ollama { try center.pull(link) }
            else {
                let url = try DownloadValidation.url(link, origin: origin)
                guard let directory else { throw DownloadError.message("請先選擇目的資料夾。") }
                // Cache layouts are managed by their own software; direct downloads must not corrupt them.
                guard !store.sources.contains(where: { source in
                    [.ollama, .huggingFace].contains(source.provider) && (directory.path == source.url.path || directory.path.hasPrefix(source.url.path + "/"))
                }) else { throw DownloadError.message("請勿直接下載至 Ollama 或 HF 快取；選擇一般模型資料夾。") }
                try center.start(url: url, name: filename, directory: directory, token: token)
                if !store.sources.contains(where: { directory.path == $0.url.path || directory.path.hasPrefix($0.url.path + "/") }) {
                    store.sources.append(ModelSource(provider: targetProvider, path: directory.path)); store.save()
                }
                token = ""
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

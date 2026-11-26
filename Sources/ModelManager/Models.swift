import Foundation

enum Provider: String, CaseIterable, Codable, Sendable {
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case huggingFace = "Hugging Face"
    case comfyUI = "ComfyUI"
    case custom = "自訂資料夾"

    var icon: String {
        switch self {
        case .ollama: "bubble.left.and.text.bubble.right"
        case .lmStudio: "desktopcomputer"
        case .huggingFace: "shippingbox"
        case .comfyUI: "point.3.connected.trianglepath.dotted"
        case .custom: "folder"
        }
    }
}

struct ModelSource: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var provider: Provider
    var path: String
    var url: URL { URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath() }

    static var defaults: [ModelSource] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = ProcessInfo.processInfo.environment
        return [
            ModelSource(provider: .ollama, path: env["OLLAMA_MODELS"] ?? "\(home)/.ollama/models"),
            ModelSource(provider: .lmStudio, path: "\(home)/.lmstudio/models"),
            ModelSource(provider: .huggingFace, path: env["HF_HUB_CACHE"] ?? "\(env["HF_HOME"] ?? "\(home)/.cache/huggingface")/hub")
        ] + discoverComfyUI()
    }

    static func discoverComfyUI(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ModelSource] {
        var paths = ["ComfyUI", "Documents/ComfyUI", "Downloads/ComfyUI", "Applications/ComfyUI", "Desktop/ComfyUI", "comfy/ComfyUI"].map { home.appendingPathComponent($0).appendingPathComponent("models").path }
        // Support multi-install launchers without recursively searching the user's disk.
        let installs = home.appendingPathComponent("ComfyUI-Installs")
        if let children = try? FileManager.default.contentsOfDirectory(at: installs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for child in children {
                paths.append(child.appendingPathComponent("ComfyUI/models").path)
                paths.append(child.appendingPathComponent("models").path)
            }
        }
        let config = home.appendingPathComponent("Library/Application Support/ComfyUI/config.json")
        if let data = try? Data(contentsOf: config),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let base = json["basePath"] as? String {
            paths.append(URL(fileURLWithPath: (base as NSString).expandingTildeInPath).appendingPathComponent("models").path)
        }
        var seen = Set<String>()
        return paths.compactMap { path in
            let source = ModelSource(provider: .comfyUI, path: path)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue,
                  seen.insert(source.url.path).inserted else { return nil }
            return source
        }
    }
}

struct LocalModel: Identifiable, Hashable, Sendable {
    var id: String { "\(source.id):\(url.path)" }
    let source: ModelSource
    let name: String
    let format: String
    let bytes: Int64
    let modified: Date?
    let url: URL
    // Ollama manifests refer to shared blobs; never delete these as ordinary files.
    var canTrash: Bool { source.provider != .ollama }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var category: String {
        guard source.provider == .comfyUI else { return format }
        let folders = ["checkpoints", "loras", "vae", "controlnet", "upscale_models", "embeddings", "clip", "clip_vision", "text_encoders", "diffusion_models", "unet", "ipadapter", "style_models", "audio_encoders", "background_removal", "detection", "diffusers", "frame_interpolation", "geometry_estimation", "gligen", "hypernetworks", "latent_upscale_models", "model_patches", "optical_flow", "photomaker", "vae_approx"]
        return folders.first { name.split(separator: "/").map(String.init).contains($0) || source.url.lastPathComponent == $0 } ?? "其他模型"
    }
}

struct ScanReport: Sendable {
    var models: [LocalModel] = []
    var warnings: [String] = []
}

enum ModelScanner {
    static let extensions: Set<String> = ["gguf", "ggml", "safetensors", "ckpt", "sft", "bin", "pt", "pth", "onnx", "mlmodel", "mlpackage"]

    static func scan(_ sources: [ModelSource]) -> ScanReport {
        var report = ScanReport()
        for source in sources {
            guard !Task.isCancelled else { break }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                report.warnings.append("\(source.provider.rawValue)：找不到資料夾 \(source.path)")
                continue
            }
            switch source.provider {
            case .ollama: scanOllama(source, into: &report)
            case .huggingFace: scanHuggingFace(source, into: &report)
            default: scanFiles(source, into: &report)
            }
        }
        report.models.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return report
    }

    private static func relativePath(_ url: URL, to root: URL) -> String {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard target.starts(with: base) else { return url.lastPathComponent }
        return target.dropFirst(base.count).joined(separator: "/")
    }

    private static func children(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    }

    private static func scanHuggingFace(_ source: ModelSource, into report: inout ScanReport) {
        do {
            for repo in try children(source.url) where repo.lastPathComponent.hasPrefix("models--") {
                let values = try repo.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let name = String(repo.lastPathComponent.dropFirst(8)).replacingOccurrences(of: "--", with: "/")
                report.models.append(LocalModel(source: source, name: name, format: "HF 快取", bytes: try directoryBytes(repo), modified: values.contentModificationDate, url: repo))
            }
        } catch { report.warnings.append("\(source.path)：\(error.localizedDescription)") }
    }

    private static func scanFiles(_ source: ModelSource, into report: inout ScanReport) {
        var errors: [String] = []
        guard let iterator = FileManager.default.enumerator(at: source.url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { url, error in
            errors.append("\(url.path)：\(error.localizedDescription)")
            return true
        }) else { report.warnings.append("無法讀取 \(source.path)"); return }
        for case let url as URL in iterator {
            if Task.isCancelled { break }
            do {
                let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard v.isSymbolicLink != true else { continue }
                let ext = url.pathExtension.lowercased()
                guard extensions.contains(ext) else { continue }
                guard v.isRegularFile == true || ext == "mlpackage" else { continue }
                let bytes = v.isDirectory == true ? try directoryBytes(url) : Int64(v.fileSize ?? 0)
                if v.isDirectory == true { iterator.skipDescendants() }
                let name = relativePath(url, to: source.url)
                report.models.append(LocalModel(source: source, name: name, format: ext.uppercased(), bytes: bytes, modified: v.contentModificationDate, url: url))
            } catch { errors.append("\(url.path)：\(error.localizedDescription)") }
        }
        report.warnings += errors
    }

    static func directoryBytes(_ url: URL) throws -> Int64 {
        var failure: Error?
        guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], errorHandler: { _, error in
            failure = error
            return true
        }) else { throw CocoaError(.fileReadUnknown) }
        var total: Int64 = 0
        for case let file as URL in iterator {
            if Task.isCancelled { throw CancellationError() }
            let v = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if v.isSymbolicLink == true { continue }
            if v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        if let failure { throw failure }
        return total
    }

    private static func scanOllama(_ source: ModelSource, into report: inout ScanReport) {
        let root = source.url.appendingPathComponent("manifests")
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        var errors: [String] = []
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { url, error in
            errors.append("\(url.path)：\(error.localizedDescription)"); return true
        }) else { report.warnings.append("無法讀取 \(root.path)"); return }
        for case let url as URL in iterator {
            if Task.isCancelled { break }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
                guard values.isSymbolicLink != true else { continue }
                guard values.isRegularFile == true else { continue }
                let manifest = try JSONDecoder().decode(OllamaManifest.self, from: Data(contentsOf: url))
                let relative = relativePath(url, to: root).split(separator: "/").map(String.init)
                let name = relative.count >= 3 ? relative.dropFirst().dropLast().joined(separator: "/") + ":" + relative.last! : relative.joined(separator: "/")
                let size = manifest.layers.reduce(manifest.config?.size ?? 0) { $0 + $1.size }
                report.models.append(LocalModel(source: source, name: name, format: "Ollama", bytes: size, modified: values.contentModificationDate, url: url))
            } catch { errors.append("\(url.path)：\(error.localizedDescription)") }
        }
        report.warnings += errors
    }
}

private struct OllamaManifest: Decodable {
    struct Layer: Decodable { let size: Int64 }
    let config: Layer?
    let layers: [Layer]
}

import XCTest
@testable import ModelManager

final class ScannerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func file(_ path: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func testCustomScanFiltersAndSkipsLinks() throws {
        let model = try file("nested/model.GGUF", data: Data(repeating: 0, count: 42))
        _ = try file("notes.txt", data: Data("ignore".utf8))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.gguf"), withDestinationURL: model)
        let report = ModelScanner.scan([ModelSource(provider: .custom, path: root.path)])
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertEqual(report.models.count, 1)
        XCTAssertEqual(report.models.first?.bytes, 42)
        XCTAssertEqual(report.models.first?.name, "nested/model.GGUF")
        XCTAssertEqual(report.models.first?.format, "GGUF")
    }

    func testHuggingFaceDoesNotCountSnapshotSymlinks() throws {
        let blob = try file("models--org--model/blobs/abc", data: Data(repeating: 1, count: 128))
        let snapshot = root.appendingPathComponent("models--org--model/snapshots/revision")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("model.safetensors"), withDestinationURL: blob)
        _ = try file("datasets--org--data/data.bin", data: Data(repeating: 0, count: 300))
        let report = ModelScanner.scan([ModelSource(provider: .huggingFace, path: root.path)])
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertEqual(report.models.count, 1)
        XCTAssertEqual(report.models.first?.name, "org/model")
        XCTAssertEqual(report.models.first?.bytes, 128)
    }

    func testOllamaManifestsAndMalformedFile() throws {
        _ = try file("manifests/registry.ollama.ai/library/llama3/latest", data: Data(#"{"config":{"size":12},"layers":[{"size":100},{"size":200}]}"#.utf8))
        _ = try file("manifests/bad", data: Data("not json".utf8))
        let report = ModelScanner.scan([ModelSource(provider: .ollama, path: root.path)])
        XCTAssertEqual(report.models.count, 1)
        XCTAssertEqual(report.models.first?.name, "library/llama3:latest")
        XCTAssertEqual(report.models.first?.bytes, 312)
        XCTAssertEqual(report.models.first?.canTrash, false)
        XCTAssertEqual(report.warnings.count, 1)
    }

    func testComfyUIMultiInstallDiscovery() throws {
        _ = try file("ComfyUI-Installs/TestInstall/ComfyUI/models/loras/style.safetensors", data: Data([0]))
        let sources = ModelSource.discoverComfyUI(home: root)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.provider, .comfyUI)
        XCTAssertEqual(ModelScanner.scan(sources).models.first?.category, "loras")
    }

    func testComfyUICategoriesAndFormats() throws {
        _ = try file("checkpoints/base.ckpt", data: Data(repeating: 0, count: 32))
        _ = try file("loras/style.safetensors", data: Data(repeating: 0, count: 16))
        _ = try file("vae/ae.sft", data: Data(repeating: 0, count: 8))
        _ = try file("checkpoints/put_checkpoints_here", data: Data())
        let report = ModelScanner.scan([ModelSource(provider: .comfyUI, path: root.path)])
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertEqual(report.models.count, 3)
        XCTAssertEqual(Set(report.models.map(\.category)), ["checkpoints", "loras", "vae"])
        XCTAssertEqual(report.models.reduce(0) { $0 + $1.bytes }, 56)
    }

    func testComfyUIExternalCategoryFolder() throws {
        let url = try file("loras/style.safetensors", data: Data([0]))
        let report = ModelScanner.scan([ModelSource(provider: .comfyUI, path: url.deletingLastPathComponent().path)])
        XCTAssertEqual(report.models.first?.category, "loras")
    }

    func testMissingSourceReportsWarning() {
        let report = ModelScanner.scan([ModelSource(provider: .custom, path: root.appendingPathComponent("missing").path)])
        XCTAssertTrue(report.models.isEmpty)
        XCTAssertEqual(report.warnings.count, 1)
    }

    func testCoreMLPackageIsSingleEntry() throws {
        _ = try file("Example.mlpackage/Data/weights.bin", data: Data(repeating: 0, count: 64))
        let report = ModelScanner.scan([ModelSource(provider: .lmStudio, path: root.path)])
        XCTAssertEqual(report.models.count, 1)
        XCTAssertEqual(report.models.first?.format, "MLPACKAGE")
        XCTAssertEqual(report.models.first?.bytes, 64)
    }
}

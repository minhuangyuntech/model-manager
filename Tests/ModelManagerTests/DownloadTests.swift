import XCTest
@testable import ModelManager

final class DownloadTests: XCTestCase {
    func testHTTPSOnlyAndNoCredentials() {
        for text in ["http://example.com/a.gguf", "file:///tmp/a.gguf", "https://user:password@example.com/a.gguf", "invalid"] {
            XCTAssertThrowsError(try DownloadValidation.url(text, origin: .custom))
        }
        XCTAssertNoThrow(try DownloadValidation.url("https://example.com/model.gguf", origin: .custom))
    }

    func testProviderDomainsAndHFDirectLinks() {
        XCTAssertNoThrow(try DownloadValidation.url("https://huggingface.co/org/model/resolve/main/model.gguf", origin: .huggingFace))
        XCTAssertThrowsError(try DownloadValidation.url("https://huggingface.co/org/model/blob/main/model.gguf", origin: .huggingFace))
        XCTAssertThrowsError(try DownloadValidation.url("https://huggingface.co.evil.example/a.gguf", origin: .huggingFace))
        XCTAssertNoThrow(try DownloadValidation.url("https://civitai.com/api/download/models/123", origin: .civitai))
        XCTAssertNoThrow(try DownloadValidation.url("https://modelscope.cn/models/org/model/resolve/master/model.safetensors", origin: .modelScope))
    }

    func testSafeFilename() {
        for name in ["../a.gguf", "/tmp/a.gguf", "x/a.gguf", "x\\a.gguf", ".hidden.gguf", "a.html", "", "a\n.gguf", "x:y.gguf", "folder.mlpackage"] {
            XCTAssertThrowsError(try DownloadValidation.filename(name), name)
        }
        XCTAssertEqual(try DownloadValidation.filename("模型-Q4.GGUF"), "模型-Q4.GGUF")
    }

    @MainActor func testExistingFileIsNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.gguf")
        let content = Data("existing model".utf8)
        try content.write(to: file)
        let center = DownloadCenter()
        XCTAssertThrowsError(try center.start(url: URL(string: "https://example.com/model.gguf")!, name: "model.gguf", directory: root, token: ""))
        XCTAssertEqual(try Data(contentsOf: file), content)
        XCTAssertTrue(center.items.isEmpty)
    }
}

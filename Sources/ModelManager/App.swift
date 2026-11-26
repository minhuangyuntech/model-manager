import SwiftUI
import AppKit

@MainActor
@Observable
final class ModelStore {
    var sources: [ModelSource]
    var models: [LocalModel] = []
    var warnings: [String] = []
    var scanning = false
    var error: String?
    var downloads = DownloadCenter()
    private var scanTask: Task<Void, Never>?
    private let settingsKey = "LocalModelManager.sources.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode([ModelSource].self, from: data) {
            sources = saved
        } else { sources = ModelSource.defaults }
        downloads.onCompletion = { [weak self] in self?.refresh() }
        if !UserDefaults.standard.bool(forKey: "LocalModelManager.comfyDiscovery.v1") {
            discoverComfyUI()
            UserDefaults.standard.set(true, forKey: "LocalModelManager.comfyDiscovery.v1")
        }
    }

    func discoverComfyUI() {
        for source in ModelSource.discoverComfyUI() where !sources.contains(where: { $0.url.path == source.url.path }) {
            sources.append(source)
        }
        save()
    }

    func save() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(sources), forKey: settingsKey) }
        catch { self.error = error.localizedDescription }
    }

    func refresh() {
        scanTask?.cancel()
        scanning = true
        let snapshot = sources
        scanTask = Task {
            let worker = Task.detached(priority: .userInitiated) { ModelScanner.scan(snapshot) }
            let report = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            models = report.models
            warnings = report.warnings
            scanning = false
        }
    }

    func addSource(_ provider: Provider) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "加入來源"
        panel.message = provider == .comfyUI ? "選取 ComfyUI 安裝目錄、models 或外部模型資料夾" : "選取 \(provider.rawValue) 的模型根目錄"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let models = url.appendingPathComponent("models")
        let chosen = provider == .comfyUI && FileManager.default.fileExists(atPath: models.path) ? models : url
        let path = chosen.resolvingSymlinksInPath().standardizedFileURL.path
        guard !sources.contains(where: { $0.url.resolvingSymlinksInPath().path == path }) else {
            error = "這個資料夾已經加入。"; return
        }
        sources.append(ModelSource(provider: provider, path: path))
        save(); refresh()
    }

    func removeSource(_ source: ModelSource) {
        sources.removeAll { $0.id == source.id }
        save(); refresh()
    }

    func trash(_ model: LocalModel) {
        guard model.canTrash else { return }
        let root = model.source.url.resolvingSymlinksInPath().standardizedFileURL.path
        let target = model.url.resolvingSymlinksInPath().standardizedFileURL.path
        guard target.hasPrefix(root + "/"), target != root else {
            error = "安全檢查失敗：模型不在來源資料夾內。"; return
        }
        do {
            try FileManager.default.trashItem(at: model.url, resultingItemURL: nil)
            refresh()
        } catch { self.error = error.localizedDescription }
    }
}

@main
struct ModelManagerApp: App {
    @State private var store = ModelStore()
    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 960, minHeight: 620)
                .task { store.refresh() }
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("重新掃描") { store.refresh() }.keyboardShortcut("r")
            }
        }
    }
}

struct ContentView: View {
    @Bindable var store: ModelStore
    @State private var provider: Provider?
    @State private var search = ""
    @State private var selection: LocalModel.ID?
    @State private var pendingTrash: LocalModel?
    @State private var showSources = false
    @State private var showWarnings = false
    @State private var sortBySize = false
    @AppStorage("galleryView") private var gallery = true
    @State private var showDownloads = false
    @State private var category = "全部"

    private var categories: [String] { ["全部"] + Set(store.models.filter { provider == nil || $0.source.provider == provider }.map(\.category)).sorted() }

    private var visibleModels: [LocalModel] {
        let result = store.models.filter {
            (provider == nil || $0.source.provider == provider) &&
            (category == "全部" || $0.category == category) &&
            (search.isEmpty || "\($0.name) \($0.format) \($0.category) \($0.source.provider.rawValue)".localizedCaseInsensitiveContains(search))
        }
        return sortBySize ? result.sorted { $0.bytes > $1.bytes } : result
    }
    private var selected: LocalModel? { visibleModels.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            List(selection: $provider) {
                Label("所有模型", systemImage: "square.stack.3d.up").tag(nil as Provider?)
                Section("管理系統") {
                    ForEach(Provider.allCases, id: \.self) { item in
                        HStack {
                            Label(item.rawValue, systemImage: item.icon).foregroundStyle(item.color)
                            Spacer()
                            Text("\(store.models.filter { $0.source.provider == item }.count)")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }.tag(Optional(item))
                    }
                }
            }
            .navigationTitle("本地模型")
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button { showDownloads = true } label: {
                        Label("下載中心 · \(store.downloads.items.filter(\.active).count)", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Button { showSources = true } label: {
                        Label("管理模型來源", systemImage: "folder.badge.gearshape").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderless)
                }.padding()
            }
        } detail: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider == .comfyUI ? "創作模型工作站" : "你的本地模型庫").font(.largeTitle.bold())
                    Text("集中整理、探索與下載，讓每個模型各就其位。").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 20)
                HStack(spacing: 16) {
                    metric("模型項目", value: "\(visibleModels.count)", icon: "cube")
                    metric("模型邏輯大小", value: ByteCountFormatter.string(fromByteCount: visibleModels.reduce(0) { $0 + $1.bytes }, countStyle: .file), icon: "internaldrive")
                    Spacer()
                    if store.scanning { ProgressView().controlSize(.small); Text("掃描中…").foregroundStyle(.secondary) }
                }.padding(20)
                HStack {
                    Picker("類型", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }.frame(width: 230)
                    Spacer()
                    Picker("顯示方式", selection: $gallery) {
                        Image(systemName: "square.grid.2x2").tag(true)
                        Image(systemName: "list.bullet").tag(false)
                    }.pickerStyle(.segmented).frame(width: 90).help("卡片 / 列表")
                }.padding(.horizontal, 20).padding(.bottom, 12)
                Divider()
                Group {
                if gallery { ModelGallery(models: visibleModels, selection: $selection) }
                else { Table(visibleModels, selection: $selection) {
                    TableColumn("名稱") { model in
                        HStack {
                            Image(systemName: "cube.transparent").foregroundStyle(.tint)
                            Text(model.name).lineLimit(1).help(model.name)
                        }
                    }.width(min: 220, ideal: 380)
                    TableColumn("來源") { Text($0.source.provider.rawValue) }.width(110)
                    TableColumn("類型") { Text($0.category).foregroundStyle(.secondary) }.width(110)
                    TableColumn("大小") { Text($0.sizeText).monospacedDigit() }.width(90)
                } }
                }
                .overlay {
                    if visibleModels.isEmpty && !store.scanning {
                        ContentUnavailableView(search.isEmpty ? "尚未找到模型" : "沒有符合的模型", systemImage: "externaldrive.badge.questionmark", description: Text("可在「管理模型來源」加入或調整模型資料夾。"))
                    }
                }
                Divider()
                if let model = selected { detail(model) }
                HStack {
                    Text("離線掃描 · 不上傳模型資料").foregroundStyle(.secondary)
                    Spacer()
                    if !store.warnings.isEmpty {
                        Button("\(store.warnings.count) 個掃描提示", systemImage: "exclamationmark.triangle") { showWarnings = true }
                            .buttonStyle(.borderless)
                    }
                }.font(.caption).padding(12)
            }
            .navigationTitle(provider?.rawValue ?? "所有模型")
            .searchable(text: $search, prompt: "搜尋模型、格式或來源")
            .toolbar {
                ToolbarItemGroup {
                    Button { showDownloads = true } label: { Label("下載模型", systemImage: "arrow.down.circle") }
                    Toggle(isOn: $sortBySize) { Label("依大小排序", systemImage: "arrow.down.to.line") }
                    Button { store.refresh() } label: { Label("重新掃描", systemImage: "arrow.clockwise") }
                    Button { showSources = true } label: { Label("模型來源", systemImage: "folder.badge.plus") }
                }
            }
        }
        .onChange(of: provider) { _, _ in category = "全部"; selection = nil }
        .sheet(isPresented: $showDownloads) { DownloadsView(center: store.downloads, store: store) }
        .sheet(isPresented: $showSources) { sourcesSheet }
        .sheet(isPresented: $showWarnings) {
            VStack(alignment: .leading, spacing: 16) {
                Text("掃描提示").font(.title2.bold())
                ScrollView { Text(store.warnings.joined(separator: "\n\n")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("完成") { showWarnings = false }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 650, height: 420)
        }
        .alert("移到垃圾桶？", isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            Button("取消", role: .cancel) { pendingTrash = nil }
            Button("移到垃圾桶", role: .destructive) {
                if let model = pendingTrash { store.trash(model) }
                pendingTrash = nil
            }
        } message: {
            Text("\(pendingTrash?.name ?? "")\n\(pendingTrash?.url.path ?? "")\n\nHugging Face 會移除整個模型儲存庫快取（含所有版本）。其他來源只移除所選檔案或套件。請先停止使用此模型的程式；需要時可從垃圾桶還原。")
        }
        .alert("操作失敗", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private func metric(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.bold()).monospacedDigit()
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private func detail(_ model: LocalModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.name).font(.headline).textSelection(.enabled)
            Text(model.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let date = model.modified { Text("修改時間：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("在 Finder 顯示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
                Button("複製路徑", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.url.path, forType: .string)
                }
                Spacer()
                if model.canTrash {
                    Button("移到垃圾桶", systemImage: "trash", role: .destructive) { pendingTrash = model }
                        .disabled(store.scanning)
                } else {
                    Text("Ollama 共用 blobs：請使用 Ollama 官方工具移除模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourcesSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("模型來源").font(.title2.bold())
            Text("選取模型根目錄。移除來源只停止掃描，不會刪除任何模型。")
                .foregroundStyle(.secondary)
            List {
                ForEach(store.sources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.provider.rawValue).bold()
                            Text(source.path).font(.caption).textSelection(.enabled)
                        }
                        Spacer()
                        Button("移除來源") { store.removeSource(source) }
                    }.padding(.vertical, 4)
                }
            }
            Text("Ollama：選取含 manifests / blobs 的目錄。Hugging Face：選取含 models--… 的 hub 目錄。LM Studio / 自訂：遞迴列出模型檔案（分片分別顯示）。").font(.caption).foregroundStyle(.secondary)
            Text("ComfyUI：選取安裝目錄或 models；依 checkpoints、loras、vae 等分類。extra_model_paths.yaml 的外部路徑請另行加入 ComfyUI 來源。").font(.caption).foregroundStyle(.secondary)
            Text("容量為邏輯大小，非實際磁碟占用。Ollama 共用層可能重複計算；HF 不重複計算快照符號連結。請避免加入重疊來源。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Menu("加入來源") {
                    ForEach(Provider.allCases, id: \.self) { p in Button(p.rawValue) { store.addSource(p) } }
                }
                Button("偵測 ComfyUI") { store.discoverComfyUI(); store.refresh() }
                Spacer()
                Button("完成") { showSources = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 720, height: 560)
    }
}

# 本地模型管理員 · Local Model Manager

SwiftUI + AppKit 原生 macOS 桌面程式，集中瀏覽本機不同管理系統的模型。不需要 Python、Node.js 或第三方套件。掃描完全離線；只有使用者主動開啟網站或下載時才會連線。

## 執行

需求：macOS 14+、支援 Swift 6 的 Xcode / Command Line Tools。

```bash
swift run LocalModelManager
```

建立可在 Finder 開啟的原生應用程式：

```bash
bash scripts/build-app.sh
open "dist/Local Model Manager.app"
```

可將 `.app` 拖到「應用程式」資料夾。腳本產生目前電腦架構的版本，使用本機 ad-hoc 簽署，**未經 Developer ID 簽署或 Apple 公證**，不適合作為公開發行成品。也可在 Xcode 開啟 `Package.swift` 執行及開發。

## 功能

- SwiftUI 原生側邊欄、容量摘要卡片、卡片／列表切換、來源識別色、搜尋與類型篩選；配合系統淺色／深色外觀。
- 下載中心：Hugging Face、Civitai、ModelScope、自訂 HTTPS 單檔下載及 Ollama pull，含進度、取消、錯誤與完成後重新掃描。
- 依管理系統篩選，依名稱或大小排序。
- 背景掃描、項目數與邏輯大小統計、讀取錯誤提示。
- 查看模型路徑與修改日期、Finder 定位、複製路徑。
- LM Studio / 自訂模型檔案、Core ML 套件及 HF 儲存庫快取可經確認後移至 macOS 垃圾桶。
- 來源設定儲存在本機 UserDefaults；移除來源不會刪除資料。

## 支援的來源

| 來源 | 預設目錄 | 辨識方式 |
| --- | --- | --- |
| Ollama | `~/.ollama/models` 或 `OLLAMA_MODELS` | 讀取 `manifests`，每個 tag 一筆 |
| LM Studio | `~/.lmstudio/models` | 遞迴搜尋模型檔案 |
| Hugging Face | `~/.cache/huggingface/hub`，支援 `HF_HUB_CACHE` / `HF_HOME` | 每個 `models--組織--名稱` 儲存庫一筆 |
| ComfyUI | 偵測常見目錄與 Desktop 設定的 `basePath`，亦可手動選取 | 依 checkpoints、loras、vae 等目錄分類 |
| 自訂 | 由使用者選擇 | 遞迴搜尋模型檔案 |

支援副檔名：`gguf`、`ggml`、`safetensors`、`ckpt`、`sft`、`bin`、`pt`、`pth`、`onnx`、`mlmodel`、`mlpackage`。這是檔案辨識，不驗證權重內容；例如一般 `.bin` 檔也可能被列出。分片模型會逐檔顯示；MLX 模型可透過 HF 或自訂來源查看，但不會執行推論。

在「管理模型來源」可加入其他安裝位置，例如舊版 LM Studio 的 `~/.cache/lm-studio/models`。Ollama 應選取含 `manifests` 與 `blobs` 的模型目錄，HF 應選取包含 `models--…` 的 hub 目錄。從 Finder 啟動通常不會繼承 shell 環境變數，請於介面手動加入路徑。

## ComfyUI

會檢查家目錄下的 `ComfyUI`、`Documents/ComfyUI`、`Downloads/ComfyUI`、`Applications/ComfyUI`、`Desktop/ComfyUI`、`comfy/ComfyUI` 中的 `models`；也會嘗試讀取 `~/Library/Application Support/ComfyUI/config.json` 的 `basePath`。另外支援 `~/ComfyUI-Installs/*/ComfyUI/models` 與 `~/ComfyUI-Installs/*/models` 的多安裝配置（只列舉一層）。這不是全磁碟搜尋，無法保證找到每種安裝方式。

若未找到，選「管理模型來源 → 加入來源 → ComfyUI」，選取安裝根目錄、`models` 或外部模型目錄。安裝根目錄下有 `models` 時會自動選用。支援 checkpoints、loras、vae、controlnet、upscale_models、embeddings、clip、clip_vision、text_encoders、diffusion_models、unet、ipadapter、style_models 分類。

**不解析或修改 `extra_model_paths.yaml`**。請將其中實際使用的外部路徑另行加入 ComfyUI 來源。目錄內符號連結不會被追蹤，必要時直接加入連結目標。分類以路徑推定，不讀取模型內部架構，也不保證與工作流相容。

## 下載模型

1. 開啟「下載中心」，選擇來源，可點選模型目錄連結至瀏覽器挑選模型。
2. Hugging Face 請貼上檔案的 `/resolve/` 下載連結；Civitai 貼上版本下載網址（例如 `/api/download/models/版本ID`）；ModelScope 貼上檔案下載連結；其他站點選自訂 HTTPS。
3. 輸入模型檔名與選取儲存資料夾。若需授權可輸入 Bearer Token，僅於記憶體使用、不寫入設定；更換來源會清空。跨主機重新導向不攜帶 Authorization。
4. ComfyUI 請選取相應的 `models/checkpoints`、`models/loras` 等資料夾，並選擇目的系統為 ComfyUI。目的資料夾若不在既有掃描來源中，會自動加入來源。
5. Ollama 則輸入模型名稱，例如 `qwen3:8b`，透過 `127.0.0.1:11434/api/pull` 下載；需自行先啟動 Ollama，儲存位置由該服務決定。

下載不覆寫既有檔案，不允許檔名含目錄穿越；拒絕非 HTTPS、HTTP 錯誤及常見 HTML/JSON/文字網頁回應。下載先暫存，成功後搬入目的地；需預留暫存與目的磁碟空間。一般下載不可放入已設定的 Ollama/HF 快取，避免破壞其管理格式。

目前為**單檔直連下載**，沒有內建遠端搜尋、整庫／分片依賴下載、校驗碼驗證、續傳或跨啟動工作記錄。不會自動執行下載的模型或腳本。拒絕網頁回應不等同完整內容驗證；請確認來源、授權與檔案完整性。受限模型需先在網站取得授權，Cookie 登入型網站不一定可用。取消後可重新提交；Ollama 可能保留已下載層或伺服器端工作。關閉下載視窗不影響工作，結束程式會中斷下載。

## 安全與限制

- 不自動下載、載入模型，也不啟動或停止任何背景服務。
- **Ollama 本機檔案唯讀**：支援透過官方本機 API 下載；多個模型可能共用 blobs，移除時請使用 Ollama 官方工具，不直接刪除 manifest 或 blobs。
- HF「移到垃圾桶」會移除該模型的**整個儲存庫快取與所有版本**；再次使用原始工具時可能重新下載。
- 自訂 / LM Studio 只移除選取的檔案或 `.mlpackage`，不會同步更新第三方程式索引、移除其他分片或清理相鄰設定。
- 刪除前應停止使用模型的程式；本工具無法判斷模型是否正被使用。垃圾桶操作失敗時會顯示錯誤，不會退回永久刪除。
- 掃描不跟隨目錄內的符號連結。HF 快照連結不重複計入，實際 blob 檔案會計入。
- 大小為**邏輯大小而非可釋放磁碟空間**：Ollama 依 manifest 宣告統計，共用層可能重複計算；APFS clone、硬連結、壓縮和重疊來源亦可能造成差異。
- 資料夾掃描不是原子快照，請在下載或移除模型後重新掃描。大型快取可能需要較長時間。
- 本機開發版未啟用 App Sandbox；只掃描已設定來源。macOS 隱私權保護仍可能拒絕讀取，會列於掃描提示中。

## 測試

```bash
swift test
```

測試使用暫存目錄，不接觸實際模型。涵蓋模型副檔名、符號連結、HF 快照容量、Ollama manifest、損毀資料、缺失路徑、Core ML 套件、ComfyUI 分類、下載網址／檔名驗證與拒絕覆寫。未在自動化測試中下載真實遠端模型，網路端到端與視覺驗收需另行操作。

## 專案結構

- `Sources/ModelManager/App.swift`：SwiftUI 介面、來源設定與垃圾桶操作。
- `Sources/ModelManager/Models.swift`：來源定義、ComfyUI 偵測、資料模型與掃描器。
- `Sources/ModelManager/ModelGallery.swift`：模型卡片與視覺樣式。
- `Sources/ModelManager/Downloads.swift`：下載中心介面、HTTPS 下載與 Ollama pull。
- `Tests/ModelManagerTests/ScannerTests.swift`：掃描器測試。
- `scripts/build-app.sh`：Release 建置與 `.app` 封裝。

# Plaud NotePin → iOS 轉錄筆記 App：GitHub 開源專案調查報告

- 調查日期：2026-09-30（Asia/Taipei）
- 調查方式：GitHub REST Search API（`api.github.com/search/repositories`，帶 `$GITHUB_TOKEN`）逐一查詢，再對關鍵候選讀取 README / LICENSE / Package.swift 原始檔核實。
- 範圍限制：**純調查，唯讀，未修改/未建立/未 fork 任何 repo，未 clone 程式碼執行。**
- 標記規則：凡未實際以工具查證之數字或條款，一律標「未驗證」；stars／授權／更新日期均為查詢當下 GitHub API 回傳值，會隨時間變動。

---

## 1. iOS 裝置端 ASR（語音辨識）

### 1.1 argmaxinc/argmax-oss-swift（原 argmaxinc/WhisperKit，已改名並 301 重新導向至此 repo）
- URL: https://github.com/argmaxinc/argmax-oss-swift
- Stars: **6385**　最後 push: **2026-09-24**　License: **MIT**（已讀 LICENSE 章節確認，第三方模型另有 NOTICES 附加條款，未逐一核實）
- 平台需求（已讀 `Package.swift` 與 README 各子模組區塊確認）：
  - WhisperKit（ASR）：`Package.swift` 宣告 `.iOS(.v16)` / `.macOS(.v13)`；README 未特別另列 WhisperKit 專屬最低版本（沿用套件宣告的 iOS 16）
  - SpeakerKit（說話者分離）：README 明列 **iOS 16.0 以上／macOS 13.0 以上**
  - TTSKit：README 明列 **iOS 18.0 以上**（本專案用不到，僅供參考）
- 中日韓支援：底層為 OpenAI Whisper（large-v3 等）CoreML 轉換版，Whisper 原生支援多語（含中/日/韓），README 標註 "multilingual accuracy" 推薦 `large-v3`。**未實測中日韓辨識準確率，未驗證**。
- 適用程度：**高度適用**——這是目前最活躍、star 數最高、Argmax 官方維護的 Apple 平台 Whisper CoreML 封裝，同一套件內含 WhisperKit（ASR）+ SpeakerKit（Pyannote v4 community-1 說話者分離）+ TTSKit，剛好覆蓋本專案 ASR + 說話者分離兩大需求，且為 MIT 授權對閉源商用友善。FluidAudio 的 README Showcase 中列出多款知名 App（Hex、VoiceInk、Spokenly 等）採用同源生態（Parakeet/Whisper CoreML 路線），顯示此技術路徑成熟。
- 風險：
  - 模型體積大（README 提及 `large-v3-v20240930` 約 626MB，需下載至裝置，另有 base/small/tiny 較小版本可用但準確度下降）
  - Xcode 16 + iOS 16 以上限制可能排除舊機型
  - 純 Whisper 架構在長音檔/雜訊環境下的記憶體與延遲，需自行測試（README 有「Memory-Efficient Loading for Large Files」章節，顯示官方也意識到此問題）
  - 專案剛改名重組（WhisperKit → argmax-oss-swift 單體套件），舊有整合文件/範例程式碼路徑可能需要更新

### 1.2 ggml-org/whisper.cpp（含官方 iOS 範例）
- URL: https://github.com/ggml-org/whisper.cpp
- Stars: **54023**　最後 push: **2026-09-28**　License: **MIT**
- iOS 支援：README 明確列出兩個官方範例 `examples/whisper.objc`（Objective-C iOS App）與 `examples/whisper.swiftui`（SwiftUI iOS/macOS App），並提供 CoreML 加速編譯選項（`WHISPER_COREML=1`）與 XCFramework 供 Swift 專案直接引用。
- Swift 封裝：README 引用官方 Swift Package `ggml-org/whisper.spm`（實際 301 重新導向至 **ggerganov/whisper.spm**，Stars **191**，最後 push **2024-05-27**，License **MIT**——**更新較久未動，需留意維護狀態**），另有社群套件 **exPHAT/SwiftWhisper**（Stars **786**，最後 push **2024-05-23**，License **MIT**——同樣一年多未更新）。
- 中日韓支援：同為 OpenAI Whisper 權重轉換，理論上支援多語，**未驗證實測效果**。
- 適用程度：**中高，作為 WhisperKit 的備援/替代方案**。whisper.cpp 本體極活躍（54k star，近日仍在更新），但「官方 Swift 綁定」與「exPHAT/SwiftWhisper」這類 Swift 層封裝相對較久未更新，若採用需自行維護 Swift binding 層或直接用 whisper.swiftui 範例程式碼改寫。
- 風險：C++ 核心需要自行管理 CoreML 模型轉換與 XCFramework 建置流程，整合成本高於 argmax-oss-swift 這種原生 Swift Package。

### 1.3 Apple 原生 Speech / SpeechAnalyzer framework
- 非開源第三方專案（Apple 系統框架），不計入本次 GitHub 調查星數/授權比較，僅供參考：iOS 內建語音辨識可作為離線輕量備援或搭配使用，但中文/日文/韓文準確度與可自訂程度普遍低於 Whisper 系模型，且需另行查證各語言的裝置端支援範圍（**未在本次任務中查證**，如需精確結論應另開任務查閱 Apple 官方文件）。

---

## 2. iOS 說話者分離（Speaker Diarization）

### 2.1 FluidInference/FluidAudio ⭐ 主推薦
- URL: https://github.com/FluidInference/FluidAudio
- Stars: **2932**　最後 push: **2026-09-30**（查詢當下幾乎即時更新）　License: **Apache-2.0**
- 平台需求（已讀 `Package.swift`）：`.macOS(.v14)` / `.iOS(.v17)`
- 功能：Swift SDK，涵蓋 ASR（Parakeet TDT v3 支援 **25 種歐洲語言 + 日文**；另有 **SenseVoiceSmall（50+ 語言含中文）**、**Paraformer-large 專門處理普通話中文**、**Cohere Transcribe 支援 14 語言含日/中/韓**、**Nemotron 串流多語含中/日**）、VAD、TTS、以及**說話者分離（Sortformer / Pyannote 路線，離線批次 + 即時串流兩種 pipeline）**，全部跑在 Apple Neural Engine（ANE）上，強調低記憶體低功耗。
- 中日韓支援：
  - 日文：有專門模型 "Parakeet TDT Japanese"（README 標註 CER 6.85% on JSUT）
  - 中文（普通話）：有專門模型 "Paraformer-large (zh)"，以及 SenseVoiceSmall 多語模型涵蓋中文
  - 韓文：Cohere Transcribe（14 語言含 ko）與 Supertonic-3 TTS 涵蓋韓文；**ASR 對韓文的獨立模型/準確度未在 README 明確給出基準數據，需自行測試**
- 適用程度：**高度適用**，是目前 GitHub 上 Apple 平台唯一同時提供「高品質說話者分離 + 多語 ASR」且採 Apache-2.0（比 MIT 更明確含專利授權條款、對商用更友善）授權、且更新極活躍（幾乎每日 push）的 Swift 原生 SDK。README Showcase 章節列出約 30+ 個已上架/開源的實際 App 在用（VoiceInk、Spokenly、Hex 等），可信度高。
- 風險：
  - iOS 17 起跳，比 argmax-oss-swift（iOS 16）更新，若需支援更舊機型會排除部分使用者
  - 多模型並存（ASR + 分離 + VAD + TTS），若只用其中分離功能仍需了解套件整體架構，體積管理（各模型皆為獨立 CoreML 檔）需自行規劃按需下載
  - 專案活躍度高同時代表 API 仍在快速演進，版本升級需留意 breaking change

### 2.2 其他候選（星數過低或非 Swift，僅供對照，不建議直接採用）
- `fharper/speakerkit`：Stars **4**，License Unlicense，活躍度與生態均不足，不建議。
- `Otosaku/NeMoSpeaker-iOS`：Stars **4**，license 未標示（`null`），資訊不足。
- `pyannote/pyannote-audio`（Python，非 Swift）：Stars **10604**，License MIT，是 FluidAudio/SpeakerKit 底層模型概念的原始研究專案，可作為理解演算法的參考資料，但**不適合直接嵌入 iOS App**（Python/PyTorch 生態）。

---

## 3. 完整 iOS/macOS 錄音轉錄筆記開源 App（架構參考用）

| Repo | Stars | 最後 push | License | 平台 | 重點 |
|---|---|---|---|---|---|
| n0an/VivaDicta | 121 | 2026-09-28 | MIT | iOS 18+/watchOS 10+（README 徽章確認） | iOS 語音轉文字＋AI 語音鍵盤，用 Apple Foundation Models + **WhisperKit** + NVIDIA Parakeet + 20+ AI 供應商，架構高度貼近本專案需求（多供應商 LLM + 本機轉錄），**最值得參考程式架構** |
| Beingpax/VoiceInk | 6612 | 2026-09-29 | **GPL-3.0**（已讀 LICENSE 原文確認） | macOS（本體），另有獨立倉庫 `Beingpax/VoiceInk-iOS` Stars 36、license 未標示 | 熱門本機轉錄 App，用 FluidAudio 的 Parakeet ASR，**GPL-3.0 對閉源商用 App 有 copyleft 風險：若直接複製/衍生其原始碼到你的閉源 App 中，理論上需以 GPL 釋出整個衍生作品；僅供架構/UX參考，不建議搬移程式碼** |
| island-io/mila | 233 | 2026-09-26 | Apache-2.0 | macOS，用 whisper.cpp | 原生 macOS 本機轉錄＋可選說話者分離，Apache-2.0 對商用友善，可作架構參考（非 iOS） |
| pasrom/meeting-transcriber | 187 | 2026-09-29 | MIT | macOS | 自動錄製 Teams/Zoom/Webex 會議、本機轉錄+分離，MIT 授權，macOS only |
| kitlangton/Hex | 2901 | 2026-08-27 | MIT | macOS | 按鍵錄音轉錄小工具，MIT，FluidAudio 生態內知名 App，架構簡單可參考 |
| TypeWhisper/typewhisper-mac | 1811 | 2026-09-29 | **GPL-3.0** | macOS | 語音轉文字+AI文字處理，同樣是 copyleft 授權，僅供概念參考 |

- **「Aiko」「MacWhisper」搜尋結果**：MacWhisper 為閉源商用 App（非 GitHub 開源專案，不計入）；GitHub 搜尋未找到活躍且對應的「Aiko」開源 repo（未驗證其是否存在於其他帳號下，本次查詢範圍內未發現明確匹配項）。
- 結論：**沒有現成的「開源 Plaud/NotePin 專用 iOS 轉錄筆記 App」可直接整包採用**；VivaDicta 的技術棧（WhisperKit + 多 LLM 供應商）架構最值得參考，但仍需自行開發 UI/UX、docx 輸出、Plaud 檔案匯入與自訂 prompt 範本邏輯。

---

## 4. Plaud 相關開源工具（非官方）

⚠️ **重要提醒**：Plaud 官方**未提供公開 API**；以下工具均為「逆向工程」(reverse-engineered) Plaud Web/Cloud API，存在**隨時因 Plaud 後端變更而失效**的風險，且使用逆向 API 可能牴觸 Plaud 服務條款（本次任務未查證 Plaud ToS 條款細節，**未驗證**，建議實作前另行確認）。此外你的產品需求是「從 Plaud App **匯出**錄音檔」而非直接對接雲端 API，所以下列工具**主要用途是設計參考**（例如檔案格式、匯出流程、metadata 結構），非必須依賴項。

| Repo | Stars | 最後 push | License | 說明 |
|---|---|---|---|---|
| riffado/riffado（原名 OpenPlaud，2026-05 更名） | 386 | 2026-09-18 | **AGPL-3.0** | 自架 AI 轉錄伴侶 App，同步 Plaud Note/Note Pro/**NotePin** 雲端錄音、可接任何 OpenAI 相容 API。**AGPL-3.0 是最嚴格的 copyleft 授權之一：若你的 App 以任何形式（含網路服務）使用其修改版程式碼，理論上需公開完整原始碼**。只適合閱讀其 API 反向工程文件做參考，**不建議引用其程式碼到閉源 iOS App**。技術棧為 TypeScript（Web/Node），非 Swift，物理上也不易直接整合進 iOS App |
| leonardsellem/plaud-sync-for-obsidian | 89 | 2026-05-15 | MIT | Obsidian 外掛，透過逆向工程 API 同步 Plaud 錄音為 Markdown 筆記（含逐字稿、AI 摘要、說話者標籤）。MIT 授權對參考程式邏輯較友善，但技術棧為 TypeScript/Obsidian 外掛 API，非 iOS。其 README 提及的底層逆向工程專案 `leonardsellem/plaud-api-reveng` **經查證已回傳 404（repo 不存在或已下架/私有化，未驗證原因）** |
| sergivalverde/plaud-toolkit | 44 | 2026-08-19 | 未標示（License API 回傳 `null`） | TypeScript Plaud API 工具包（CLI + MCP server + 自動 token 管理），license 不明需自行至 repo 確認 |
| iiAtlas/plaud-recording-downloader | 44 | 2026-06-08 | MIT | Chrome 擴充功能下載 Plaud.ai 錄音，非 iOS 相關但可了解匯出檔案的來源格式邏輯 |
| xclgordon/plaud-pipeline | 44 | 2026-05-12 | Apache-2.0 | 描述缺失（description=null），未進一步查證內容 |
| G9KBytes-Labs/Plaud-Claude-Obsidian | 37 | 2026-03-08 | 未標示 | Plaud→Claude→Obsidian 自動化筆記 pipeline，概念可參考（自訂 prompt 套用筆記模板），技術棧非 iOS |
| JamesStuder/Plaud_API 等多個 `plaud-api` 同名小型 repo | 0–22 | 各異 | 多為 MIT | 星數個位數到二十出頭，維護狀態普遍偏弱，僅供交叉比對匯出檔案/API 格式線索，不建議直接依賴任何單一專案 |

- **結論**：Plaud 官方匯出格式（MP3/WAV/M4A，使用者提及「待驗證」）**本次任務未實際下載 Plaud App 匯出檔驗證**，屬於未驗證項目，建議另開任務實測 Plaud App 的「匯出到檔案」功能確認實際容器格式、取樣率、是否含 metadata（如錄音起始時間、裝置ID）。上述逆向工程專案的原始碼可作為理解 Plaud 雲端資料結構的參考讀物，但因 **AGPL/授權不明/連結失效** 等問題，均不建議直接整合或衍生程式碼進閉源 iOS App。

---

## 5. Swift 產生 .docx / Markdown 渲染函式庫

### 5.1 .docx 產生

| Repo | Stars | 最後 push | License | 說明 |
|---|---|---|---|---|
| shinjukunian/DocX | 108 | 2026-05-13 | MIT（已查證） | 將 `NSAttributedString` 轉為 `.docx`，明確支援 **iOS 與 macOS**，設計初衷是圖文/振假名匯出用途，體積小、依賴少，MIT 授權對商用友善。**最貼近本專案「輸出 Word(.docx)」需求的現成 Swift 函式庫**，但功能相對陽春（若需要複雜樣式、表格、頁首頁尾等可能要自行擴充 OOXML 產生邏輯 |
| PsychQuant/che-word-mcp | 7 | 2026-09-29 | MIT | 號稱「首個純 Swift OOXML 函式庫」，功能非常完整（233 個工具、軌跡修訂、樣式、編號、章節、超連結等），更新非常活躍（近乎每日）。但其定位是 **MCP Server（給 AI agent 用的工具服務）而非可直接嵌入 App 的函式庫**，README 內容大量夾雜中文技術細節與未發布依賴（`OOXMLSwift` profile/store 尚未發布），星數僅 7，**成熟度與可直接復用性需謹慎評估，建議僅作為「純 Swift 可自行寫 OOXML」可行性的技術佐證，不建議直接依賴** |
| CoreOffice/CryptoOffice | 49 | 2023-02-15 | Apache-2.0 | 僅處理 OOXML **解密**（讀取加密文件），非產生 docx，功能不符需求 |

- **替代方案評估**：若 `shinjukunian/DocX` 功能不足，另一條路是**自行用純 Swift + Foundation 的 `Archive`/zip 函式庫組出 docx 的 OOXML XML 結構**（.docx 本質是含特定 XML 的 zip 檔），技術上可行但工程量較大；或考慮先產生 HTML/RTF 再用 iOS 內建 `NSAttributedString(data:options:)`（`.docx` 為系統原生支援的 `documentType`，macOS 支援讀寫、**iOS 端對 .docx 的原生寫入能力有限，通常只支援讀取，寫入常見做法是先轉 RTF/HTML 再轉檔**——此為一般認知，**本次未實測 iOS SDK 對 `.docx` writer 的確切支援範圍，标记未驗證**，建議實作前用 Xcode 在目標最低 iOS 版本上驗證 `NSAttributedString.DocumentType.officeOpenXML` 的實際可寫入程度）。

### 5.2 Markdown 渲染/解析

| Repo | Stars | 最後 push | License | 說明 |
|---|---|---|---|---|
| swiftlang/swift-markdown | 3428 | 2026-09-28 | Apache-2.0 | **Apple 官方** Swift Markdown 解析/建構/編輯函式庫，最權威、更新最活躍，**首選** |
| gonzalezreal/swift-markdown-ui | 3930 | 2025-12-28 | MIT | 星數最高的 SwiftUI Markdown 渲染元件，但 README 已標註「Maintenance mode — 新開發轉移到 Textual」，**未來新功能不會再加入此專案** |
| gonzalezreal/textual | 890 | 2026-06-15 | MIT | 上者的後繼專案，用於在 SwiftUI 渲染富文字，更新中 |
| microsoft/SwiftStreamingMarkdown | 373 | 2026-09-25 | MIT | 微軟出品，強調高效能與**串流**渲染（適合邊接收 LLM 輸出邊顯示筆記草稿的場景），近期活躍 |
| SimonFairbairn/SwiftyMarkdown | 1738 | 2024-08-07 | MIT | 老牌方案，將 Markdown 轉 `NSAttributedString`，兩年多未更新，成熟穩定但需留意維護狀態 |

- 建議：Markdown **輸出**（產生 .md 檔）本質上只是字串組裝，不一定需要外部函式庫；若需要**應用內即時預覽**渲染出來的 Markdown（例如筆記編輯畫面），`swift-markdown`（官方，AST 解析）+ 搭配 `swift-markdown-ui`/`textual`（渲染顯示）是目前最穩妥組合。

---

## 6. LLM Swift 客戶端（多供應商 / OpenAI 相容）

| Repo | Stars | 最後 push | License | 涵蓋供應商 | 備註 |
|---|---|---|---|---|---|
| MacPaw/OpenAI | 2946 | 2026-09-30 | MIT | OpenAI 官方 API | 社群最大 OpenAI Swift 套件，更新非常活躍（查詢當下幾乎即時） |
| jamesrochabrun/SwiftOpenAI | 664 | 2026-09-09 | MIT | OpenAI（含最新功能） | 號稱「最完整」OpenAI Swift 套件，同作者另有 SwiftAnthropic（252 stars，2026-04-18，MIT）可搭配使用 |
| AIProxyTeam/AIProxySwift | 447 | 2026-08-28 | MIT | **OpenAI、Gemini、Anthropic、Groq、Together AI、OpenRouter、DeepSeek、Fireworks AI、Mistral、Perplexity 等一次涵蓋** | 星數最高的「多供應商合一」Swift 客戶端，同時支援直連供應商或透過其付費代理服務保護 API Key，**直連模式完全可作為本專案「自帶 API Key」需求的現成方案**，覆蓋面最廣，值得優先評估 |
| kevinhermawan/swift-llm-chat-openai | 52 | 2025-07-30 | Apache-2.0 | 明確標榜 OpenAI 相容端點：**Ollama、LM Studio 類自架端點、Groq、OpenRouter、Together AI、Perplexity、Cohere V2** | 星數較低但**專門針對「OpenAI 相容自架端點」場景設計**，與需求中「自架 OpenAI 相容端點（如 gpt-oss）」高度契合，程式碼量小易讀，適合直接參考或裁剪使用 |
| eastriverlee/LLM.swift | 879 | 2026-07-19 | MIT | 本機推論（llama.cpp 封裝），非雲端 API | 若未來想加「裝置端 LLM 摘要」可參考，但不是本專案當前雲端多供應商需求的直接解 |

- 建議：**AIProxySwift（廣度）+ kevinhermawan/swift-llm-chat-openai（自架 OpenAI 相容端點的輕量參考）** 兩者互補，前者當主要多供應商客戶端，後者作為理解/客製「自架端點」串接邏輯的範例。

---

## 7. 建議技術組合（MVP）

### 7.1 核心組合
1. **ASR + 說話者分離**：**argmaxinc/argmax-oss-swift（WhisperKit + SpeakerKit）** 作為主線
   - 理由：同一套件同時解決 ASR（多語含中日韓）與說話者分離，MIT 授權對閉源商用無虞，iOS 16+ 相容範圍較廣，官方維護活躍（6385 星，近週內持續 push）
   - 備援/交叉驗證：**FluidInference/FluidAudio**（Apache-2.0，iOS 17+）——若 SpeakerKit 分離效果或特定語言（日文/中文/韓文）ASR 準確度不如預期，FluidAudio 針對日文、中文（Paraformer）、韓文（Cohere Transcribe）有更專門的模型可切換，且其說話者分離（Sortformer）在多款知名商用 App 中被驗證採用，是很扎實的第二選擇甚至可兩者並用（依語言/任務動態選模型）
2. **翻譯 + 筆記 prompt 範本套用**：不依賴額外開源翻譯專案，直接用使用者已規劃的「外部 AI API」（OpenAI/Anthropic/Gemini/Groq/自架端點）做翻譯與範本套用，技術上用 **AIProxyTeam/AIProxySwift** 作為主要多供應商 Swift 客戶端骨架，需要串接自架 OpenAI 相容端點（如 gpt-oss）時參考 **kevinhermawan/swift-llm-chat-openai** 的 baseURL 可自訂設計
3. **Markdown 輸出**：**swiftlang/swift-markdown**（官方 AST 用於結構化組裝/驗證），若需 App 內預覽再加 **microsoft/SwiftStreamingMarkdown** 或 **gonzalezreal/textual**
4. **.docx 輸出**：**shinjukunian/DocX** 起步（MIT、iOS/macOS 皆支援），若樣式需求（表格、頁首頁尾、複雜排版）超出其能力範圍，需規劃**自行擴充 OOXML 產生邏輯**（原生 zip+XML 組裝）作為 Plan B，**不建議依賴 che-word-mcp**（定位為 MCP 工具、星數低、依賴未發布套件，成熟度不足以直接嵌入 App）
5. **架構參考（非程式碼複用）**：**n0an/VivaDicta**（MIT，WhisperKit + 多 LLM 供應商架構，最貼近本專案定位）可作為 UI/UX 與模組拆分的設計參考；**FluidInference/FluidAudio README Showcase** 列出的近 30 款 App 可作為市場/功能對標清單

### 7.2 Plaud 匯出檔案處理
- 不依賴任何 Plaud 逆向工程開源專案作為程式碼相依（授權風險：riffado 為 AGPL-3.0；plaud-sync-for-obsidian 雖 MIT 但技術棧非 iOS；其餘專案維護狀態與授權多不明或星數過低）
- 建議路徑：直接以 Plaud 官方 App「匯出到檔案」功能取得 MP3/WAV/M4A（**具體格式本次未實測驗證，需另開任務用實機匯出樣本確認容器格式、取樣率、聲道數、是否含 metadata**），iOS 端用 `AVFoundation` 讀取即可，不需要對接 Plaud 雲端 API

### 7.3 授權風險總表（特別標註）

| 授權 | 涉及專案 | 對閉源 iOS App 的影響 |
|---|---|---|
| **AGPL-3.0** | riffado/riffado | 最嚴格 copyleft；若「使用/修改其程式碼」且以任何形式對外提供服務（含網路傳輸互動），理論上需公開完整原始碼。**結論：僅供閱讀了解 Plaud API 反工程邏輯，禁止複製/衍生其程式碼到本專案** |
| **GPL-3.0** | Beingpax/VoiceInk、TypeWhisper/typewhisper-mac、部分 meeting-notes app | Copyleft；直接複製/衍生其原始碼到你的閉源 App 中，理論上該衍生部分需以 GPL 開源。**結論：僅作架構/UX 參考，不引用程式碼** |
| **MIT / Apache-2.0** | argmax-oss-swift、FluidAudio、whisper.cpp、DocX、swift-markdown、AIProxySwift、swift-llm-chat-openai 等本報告推薦組合 | 對閉源商用友善，僅需保留授權聲明（MIT）或另附 NOTICE（Apache-2.0，且含明確專利授權條款，商用更安心） |
| **未標示 / null** | sergivalverde/plaud-toolkit 等多個小型 repo | GitHub API 回傳 license 為 `null` 代表**該 repo 未附標準授權檔案**，法律上預設「保留所有權利」，**未經作者明確授權不可使用其程式碼**，需自行至 repo 頁面核實或聯繫作者 |

---

## 8. 未驗證 / 需要進一步查證的項目

1. Plaud NotePin 透過官方 App「匯出」的實際檔案格式（容器、取樣率、metadata）——**本次任務未取得實機樣本，未驗證**
2. Apple 原生 Speech / SpeechAnalyzer framework 對中/日/韓的裝置端支援範圍與各 iOS 版本差異——**本次未查閱 Apple 官方文件，未驗證**
3. `shinjukunian/DocX` 及 iOS 原生 `NSAttributedString` 對 `.docx` **寫入**（而非僅讀取）在目標最低 iOS 版本上的實際可用程度——**本次僅讀 README，未實機/實測驗證**
4. FluidAudio 韓文 ASR 的獨立準確度基準（README 未提供明確 benchmark 數字）——**未驗證**
5. `PsychQuant/che-word-mcp` 所依賴的未發布 `OOXMLSwift` 套件成熟度與可取得性——**未驗證，且其 README 顯示依賴 editable dependency pin 到特定 commit，尚非穩定發布狀態**
6. `sergivalverde/plaud-toolkit`、`leonardsellem/plaud-api-reveng`（已 404）等專案的確切授權條款——**部分 license 欄位為 null 或連結已失效，未驗證**
7. 「Aiko」是否存在對應的活躍開源 iOS 轉錄 App repo——**本次搜尋未找到明確匹配，未驗證是否存在於未被搜尋到的帳號/組織下**

---

## 9. 結論與完成項目

- **結論**：已完成六大類別的 GitHub 開源專案調查，取得可直接引用的 star 數、最後更新日期、授權條款（含逐一核實 GPL/AGPL 高風險項目），並給出 MVP 建議組合：**argmax-oss-swift（ASR+說話者分離主線）+ FluidAudio（備援/特定語言強化）+ AIProxySwift（多供應商 LLM 客戶端）+ swift-markdown（Markdown）+ shinjukunian/DocX（docx 輸出）**，全部核心相依均為 MIT/Apache-2.0，對閉源商用 App 無 copyleft 疑慮。
- **完成項目**：6 大分類逐項 GitHub Search API 查詢、關鍵候選 README/LICENSE/Package.swift 原始檔核實、授權風險比對表、Plaud 逆向工程生態盤點（含失效連結標註）、MVP 技術組合建議。
- **修改檔案**：無（純唯讀調查，未修改任何 repo/程式碼）。
- **實際驗證結果與證據路徑**：本報告 `/var/minis/workspace/plaud-transcribe-spec/oss-survey.md`；所有 stars/授權/更新日期均為 2026-09-30 GitHub API 查詢即時值，非記憶編造。
- **未驗證項目**：見第 8 節，共 7 項，建議下一步逐項處理（尤其 Plaud 實機匯出格式與 iOS docx 寫入能力，屬於 MVP 開工前的關鍵阻礙，應優先驗證）。
- **剩餘風險**：授權為 null 的小型 Plaud 工具 repo 不應被引用；GPL/AGPL 專案僅供概念參考，團隊需建立「禁止複製程式碼」的內部提醒機制，避免無意間引入 copyleft 依賴。

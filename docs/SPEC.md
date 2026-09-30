# Plaud Notes（iOS App）開發規格 v0.6（草案）

> Repo：github.com/bounce12340/plaud-notes-ios（私人）
> 日期：2026-09-30
> 狀態：草案。標「未驗證」的項目需實機／實際檔案確認後再定案。
> 開源元件調查：[oss-survey.md](oss-survey.md)

---

## 0. 需求摘要

| 項目 | 決定 |
|---|---|
| 錄音硬體 | Plaud **NotePin** |
| 錄音來源 | 使用者**目前無法從 Plaud App 匯出**；樣本改用 iPhone 語音備忘錄。App 須支援任何音檔來源（見 §1.1） |
| 目標裝置 | **iPhone 17（512GB）**，之後支援 iPad |
| 開發環境 | Mac mini **M4／32GB**＋Xcode，已有 Apple Developer 帳號 |
| 語言 | 中文、英文、日文、韓文（可能混用） |
| 場景 | 會議、訪談、講座；**單次錄音 1–3 小時** |
| 資料存放 | 本機（手機／平板）；使用者可自行設定 AI 供應商與 API key |
| AI 供應商 | 全部可接，使用者自行設定（OpenAI／Anthropic／Gemini／Groq／OpenAI 相容自架如 gpt-oss…） |
| 筆記範本 | 內建會議、訪談、講座、一般摘要；使用者可新增、編輯 |
| 翻譯 | 英→中、日→中、中→英等，任意組合 |
| 輸出 | Markdown、Word（.docx） |
| 發佈 | 先自用（Xcode／TestFlight），未來上架 App Store |

---

## 1. 輸入音檔

### 1.1 錄音來源現況（2026-09-30 更新）
- 使用者表示 Plaud App **沒有「音訊匯出」按鍵**（2026-09-30）。Plaud 官方說明（support.plaud.ai〈匯出錄音、逐字稿與摘要〉，2026-09 版）寫到 App 可以匯出：開啟檔案 → 右上角圖示 → 「匯出為檔案」→ 內容類型選「音訊」→ 選格式（網路摘要提到 MP3／WAV，**未實機驗證**）。**沒有按鍵的原因未確認**；網路上的使用者討論提到可能與 App 版本、訂閱方案、錄音同步狀態有關，也有人改從 Plaud Web（電腦瀏覽器）匯出（**皆未驗證**）。
- NotePin 的錄音透過藍牙傳到 Plaud App／帳號；Plaud 沒有公開 SDK 或 API，USB 傳輸據使用者社群說法已移除（**未驗證**）。**不做**藍牙協定或雲端 API 的逆向工程（服務條款與上架風險）。
- 因此 App 的輸入設計為「**任何音檔**」：Plaud 匯出檔（若可行）、語音備忘錄、其他錄音 App、檔案 App；**App 內建錄音列入 MVP**（使用者 2026-09-30 同意），用 iPhone 麥克風，不必依賴 Plaud。

### 1.2 實測樣本：樣本 A（`sample_a.m4a`）（**iPhone 語音備忘錄**，非 NotePin）

| 項目 | 實測值 |
|---|---|
| 容器 | MPEG-4 音訊（`M4A`，brand `M4A isommp42`） |
| 編碼 | AAC-LC |
| 取樣率 | 48 kHz |
| 聲道 | 2（左右聲道不完全相同） |
| 位元率 | 約 131 kbps |
| 長度／大小 | 24 分 13 秒／24.4 MB（約 **1 MB／分鐘**） |
| 音量（第 5 分鐘起 30 秒） | RMS 約 −29 dBFS，峰值約 −7 dBFS（偏小，需正規化） |
| Metadata | handler `Core Media Audio`，有 creation_time，沒有 Plaud 專屬欄位 |

**ElevenLabs 首跑（2026-09-30）**：樣本 A 內容以英文為主、夾少量中文的多人會議（偵測 4–5 位說話者，未人工核對）；24 分鐘全檔處理約 30 秒；中文部分輸出為簡體，需轉台灣繁體。因此它適合當「中英混合」樣本，**仍需另備中文為主的樣本**。

**已確認**：此樣本是 iPhone 語音備忘錄錄的（使用者 2026-09-30 回覆），**NotePin／Plaud 匯出檔的格式仍未知**。本樣本仍可作為轉錄流程與 M0 測試的輸入。

**推算**（依 1 MB／分鐘）：
- 3 小時錄音 ≈ **180 MB**
- 轉成 16 kHz 單聲道 PCM ≈ 345 MB → **不能一次整個載入記憶體**，必須串流或分段處理
- 雲端轉錄 API 多數限制單檔大小（例如 OpenAI 25 MB），**上傳前必須切段**（例如每 10 分鐘一段，重疊 2–5 秒），再轉成 16 kHz 單聲道 AAC／Opus 以縮小檔案

**設計決策**：App 用 AVFoundation 讀取 M4A、MP3、WAV 等格式，統一轉成 16 kHz 單聲道再送轉錄；不依賴 Plaud 私有格式或 API。

---

## 2. 關鍵限制

1. **iOS 沙盒**：App 讀不到 Plaud App 或語音備忘錄的內部資料夾。錄音只能透過其他 App 的「分享」匯入，或從「檔案」App 選取。
2. **gpt-oss 是純文字模型**，在 App 中只用來整理筆記和翻譯；gpt-oss-20b 無法在 iPhone 上執行，需透過 OpenAI 相容 API 連到遠端。使用者的 **Mac mini M4／32GB** 在記憶體上足以跑 gpt-oss-20b（官方說明約需 16GB；實際速度、同時開啟的其他程式與長 context 表現**未實測**），可用 Ollama 或 LM Studio 提供區網 API；iPhone 在外面時要透過 Tailscale 等 VPN 連回，**不要**直接把連接埠開放到網際網路。gpt-oss-120b 不適合 32GB 機器。
3. **DeepSeek 不能轉錄語音**：DeepSeek 官方 API 文件（Models & Pricing，2026-09-30 查閱）列出的 `deepseek-flash`（DeepSeek-V4.1-Flash）功能只有文字、JSON、工具呼叫、Vision（圖片），**沒有列出音訊輸入或轉錄端點**。因此它不能拿來當「轉錄基準」，但適合當**筆記整理／翻譯**的 LLM（1M context 能一次讀完 3 小時逐字稿、價格低）。使用者表示曾用 DeepSeek 把錄音轉成逐字稿，但使用的 App／網站尚未確認；可能是 DeepSeek App 的語音功能或第三方工具。App 不會把 DeepSeek 列為轉錄引擎，除非找到官方音訊 API。
4. **長錄音與 iOS 背景限制**：1–3 小時的本機轉錄可能要花數十分鐘，App 切到背景就可能被系統暫停。規劃使用 iOS 26 的 `BGContinuedProcessingTask`（在系統介面顯示進度；**可用性與時間限制未驗證**），並支援中斷後從上次段落續跑。
5. **LLM 能讀的內容長度**：3 小時逐字稿約 3–5 萬字，本機 Apple Foundation Models 的 context 很小（約 4K tokens，**未驗證**），必須「分段摘要 → 合併」；雲端大 context 模型可以一次處理，但費用較高。

---

## 3. 技術選型

| 層 | 選擇 | 授權 | 備註 |
|---|---|---|---|
| 平台 | Swift 6、SwiftUI、**最低 iOS 26** | — | 先自用，目標機 iPhone 17；可用 SpeechAnalyzer、Foundation Models、Translation、BGContinuedProcessingTask |
| 資料 | SwiftData＋App 容器內的檔案 | — | 音檔、分段、逐字稿 JSON、筆記 |
| 本機轉錄（主線） | argmaxinc/argmax-oss-swift（WhisperKit＋SpeakerKit） | MIT | 模型選擇（turbo／small 等）依 iPhone 17 實測決定 |
| 本機轉錄（備援／比較） | FluidInference/FluidAudio；Apple SpeechAnalyzer | Apache-2.0／系統 | 中日韓品質要實測比較 |
| 說話者分離 | SpeakerKit 或 FluidAudio（Sortformer） | MIT／Apache-2.0 | 實測後擇一 |
| 雲端轉錄 | **ElevenLabs Scribe 優先實作**；其後 OpenAI、Groq、Gemini、Deepgram、AssemblyAI 等，使用者的 key | — | 依各家 API 自己寫薄轉接層 |
| LLM | AIProxySwift 或自寫 OpenAI 相容／Anthropic／Gemini 轉接層 | MIT | Base URL、模型名稱可自訂 |
| 本機翻譯 | Apple Translation framework | 系統 | 語言組合與品質要實測 |
| Markdown | swiftlang/swift-markdown | Apache-2.0 | |
| docx | shinjukunian/DocX；不足時自己產生 OOXML | MIT | 表格、標題、頁首要實測 |
| 金鑰 | Keychain（僅本機，不同步） | — | |

**授權原則**（2026-09-30 更新）：
- **本專案自有程式碼採 AGPL-3.0-only**（使用者要求：拿走程式碼的人必須公開自己的原始碼）。著作權人保留另行授權（含 App Store 發行）的權利。
- **第三方相依只採用與 AGPL-3.0 相容、且不妨礙著作權人另行授權的授權**：MIT、Apache-2.0、BSD。**不引入 GPL／AGPL 的第三方程式碼**（例如 VoiceInk、riffado），否則著作權人會失去以其他條件發行 App 的彈性。沒有附授權的 repo 一律不使用。
- **外部貢獻**需先同意貢獻者授權協議（CLA），才能合併。
- App 內「設定 › 開源授權」列出本專案授權與所有第三方授權聲明。

---

## 4. 處理流程

```
匯入（分享／檔案） → 複製到 App 容器、計算 sha256、讀取格式
→ 串流解碼 → 16 kHz 單聲道 → 音量正規化 → 切段（10 分鐘，重疊 3 秒，靜音處優先切）
→ 轉錄（本機或雲端，逐段執行、逐段存檔，可續跑）
→ 合併段落、移除重疊重複、說話者分離對齊
→ 後處理：轉台灣繁體（zh-Hant-TW）、套用自訂詞庫、標記低信心片段
→ （選配）翻譯
→ 套用範本：分段摘要 → 合併成最終筆記
→ 輸出 逐字稿.md／筆記.md／筆記.docx，附上 metadata
```

---

## 5. 功能需求

### 5.1 MVP
| # | 功能 | 驗收條件 |
|---|---|---|
| F1 | 從其他 App 分享匯入（Share Extension：Plaud、語音備忘錄等）、從檔案選擇器匯入 | 語音備忘錄 M4A 可匯入、播放；取得 Plaud 匯出檔後再驗證 |
| F2 | 顯示格式資訊 | 與 ffprobe 一致（例如上面的樣本：AAC-LC／48k／2ch／24:13） |
| F3 | 分段轉錄、可續跑 | 3 小時檔案可完成；中途被系統終止後，重開 App 可從未完成的段落繼續 |
| F4 | 語言：自動偵測或手動指定；中文輸出繁體 | 中英日韓樣本各 1 份；無簡體字 |
| F5 | 說話者分離與改名 | 改名後全部段落同步更新 |
| F6 | 範本：內建 4 種＋自訂；變數 `{{transcript}}` `{{title}}` `{{date}}` `{{speakers}}` `{{target_language}}` | 使用者新增的範本可正常套用 |
| F7 | 翻譯：只有譯文或原文對照 | 英→中、日→中、中→英正常 |
| F8 | 匯出 .md、.docx，可用分享表單送出 | Word／Pages 正常開啟，中日韓字型正常 |
| F9 | 供應商設定：類型、Base URL、模型、API key（Keychain）、連線測試 | 可連到自架 gpt-oss（OpenAI 相容） |
| F10 | 隱私：送到雲端前標示目的地；可設定「只用本機」 | 開啟「只用本機」時，不會發出任何網路請求 |
| F11 | App 內建錄音：背景錄音、暫停／繼續、鎖定畫面顯示、錄完直接進入轉錄流程 | 連續錄 3 小時不中斷；來電或其他 App 打斷後能保存已錄內容並可繼續；檔案為 AAC M4A |

### 5.2 增強功能（第二版之後）
- 高：筆記附時間戳，點擊即跳到原音；低信心片段標記＋校稿後重新產生筆記；自訂詞庫
- 中：待辦加入提醒事項／行事曆；全文搜尋；iCloud 同步 iPad；捷徑（App Intents）
- 低：聲紋註冊；匯出 SRT、PDF；同步到 Notion／Obsidian

---

## 6. 內建筆記範本（初稿）
1. 會議記錄：基本資訊／與會者／議題／討論摘要／決議／待辦（負責人、期限、時間戳）／未決事項
2. 訪談：受訪者背景／問答重點／關鍵引述／洞察／後續追蹤
3. 講座：主題／大綱／重點概念／名詞解釋／引述／延伸問題
4. 一般摘要：TL;DR／重點／待辦

共同規則：只根據逐字稿整理，不自行補造；不確定處標 `【待確認 mm:ss】`；專有名詞保留原文。

---

## 7. 非功能需求
- 效能：在 iPhone 17 上實測 60 分鐘錄音的本機轉錄時間、耗電、溫度後再訂目標。
- 儲存：3 小時約 180 MB 原音，加上中間檔；提供「處理完刪除中間檔」和保存期限設定。
- 可追溯：每份筆記記錄來源 sha256、轉錄模型、LLM 模型、範本版本、處理時間。
- 安全：Keychain；log 不記錄逐字稿全文和 key；上傳雲端前需使用者同意。
- 上架準備：隱私權政策、App Privacy 標籤（自帶 key 模式下資料直接送到使用者選的供應商）、錄音同意提醒、開源授權頁。

---

## 8. 里程碑
| 階段 | 內容 | 產出 |
|---|---|---|
| M0 | 技術驗證（Mac mini＋iPhone 17）：見 §8.1 | 基準報告 |
| M1 | 匯入＋分段轉錄＋逐字稿 .md | 可自用的 TestFlight |
| M2 | LLM 供應商設定、範本、筆記、.docx | |
| M3 | 翻譯、說話者改名、校稿 | |
| M4 | 上架準備 | |

### 8.1 M0 轉錄基準方法
- **標準答案**：從每種語言的樣本各取 10 分鐘，由人工校正成正確逐字稿（可先用雲端 ASR 產生初稿再人工修改）。**不以任何單一模型的輸出當標準答案**。
- **比較對象**：WhisperKit（large-v3-turbo 等）、FluidAudio、Apple SpeechAnalyzer（本機）；雲端對照組為 **ElevenLabs Scribe（scribe_v2）**（使用者 2026-09-30 選定；API 支援說話者分離、字詞時間戳、檔案 <5GB）。步驟與腳本見 `bench/`。
- **指標**：中日韓用 CER（字錯率）、英文用 WER；另記錄處理時間／錄音長度比、耗電、溫度、峰值記憶體、說話者分離正確率。
- **筆記品質**：同一份逐字稿分別交給 deepseek-flash、gpt-oss-20b（Mac mini）、Apple Foundation Models 整理；檢查有沒有捏造內容、待辦是否完整、時間戳是否能對到原文。
- **第一份樣本**：樣本 A（`sample_a.m4a`）（語音備忘錄，24 分鐘）；**不進 repo**。

---

## 9. 待確認事項
1. Plaud：請到 Plaud Web（電腦瀏覽器 web.plaud.ai）打開同一筆錄音，看有沒有「匯出音訊」；另提供 Plaud App 版本和訂閱方案。
2. 「DeepSeek 轉錄」使用的是哪個 App 或網站？若能提供同一段錄音的輸出，可放進基準一起比較。
3. 樣本檔是否可放進 repo 當測試資料？（預設**不要**）

已確認：樣本是語音備忘錄；Mac mini 為 M4／32GB；雲端轉錄對照組為 ElevenLabs；App 要內建錄音；Plaud App 沒有音訊匯出按鍵。

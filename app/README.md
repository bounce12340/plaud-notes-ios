# PlaudNotes iOS App（M1 骨架）

**狀態：** 程式在沒有 Xcode 的環境撰寫，由 GitHub Actions（macOS 26／Xcode）編譯並在 iOS 模擬器跑單元測試；尚未在實機測試。

## 已包含
- 錄音清單（JSON 暫存，之後改 SwiftData）
- 從「檔案」匯入音檔（複製到 App 容器）；Plaud Web 匯出的 MP3 會從檔名「MM-DD」取錄音日期
- 重新命名、產生筆記後由 AI 建議標題（確認後套用）
- App 內建錄音：AAC M4A、48 kHz 單聲道、背景錄音、暫停／繼續、來電中斷處理
- ElevenLabs Scribe 轉錄（API key 存 Keychain）、逐字稿顯示
- 逐字稿與筆記分享為 Markdown 或 Word（.docx；自寫 ZIP＋WordprocessingML，無第三方套件）
- 簡→繁：OpenCC 1.4.2 字典（`PlaudNotes/Resources/OpenCC`，Apache-2.0）
- LLM 筆記：多供應商、可自訂範本、輸出語言（翻譯）、長逐字稿分段
- 說話者改名、專有名詞詞庫（轉錄 keyterms＋自動更正＋筆記）、以錄音日期產生筆記
- 單元測試：ElevenLabs 解析、OpenCC 官方案例、LLM 請求／回應、範本與分段、docx 結構與內容、檔名日期、標題建議、MP3 匯入

## 尚未包含
Share Extension、長音檔分段上傳與續跑、本機轉錄（WhisperKit／FluidAudio）、串流輸出。

## 在 Mac mini 上建置
```bash
brew install xcodegen
cd app
xcodegen generate        # 依 project.yml 產生 PlaudNotes.xcodeproj
open PlaudNotes.xcodeproj
```
1. 在 Xcode 的 Signing & Capabilities 選自己的 Team，把 Bundle ID 改成自己的。
2. 選 iPhone 17 實機 → Run。
3. `⌘U` 跑單元測試。

需要 Xcode 26 以上（最低支援 iOS 26）。

## 已知限制
- ElevenLabs 上傳時會把整個檔案讀進記憶體；3 小時錄音（約 180 MB）要在 M1 改成切段上傳。
- 背景錄音 3 小時、來電後恢復都還沒在實機驗證。

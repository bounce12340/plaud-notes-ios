# PlaudNotes iOS App（M1 骨架）

**狀態：尚未編譯。** 這些 Swift 檔是在沒有 Xcode 的環境（iPhone 上的 iSH）寫的，請在 Mac mini 上建置後回報錯誤。

## 已包含
- 錄音清單（JSON 暫存，之後改 SwiftData）
- 從「檔案」匯入音檔（複製到 App 容器）
- App 內建錄音：AAC M4A、48 kHz 單聲道、背景錄音、暫停／繼續、來電中斷處理
- ElevenLabs Scribe 轉錄（API key 存 Keychain）、逐字稿顯示、分享 Markdown
- 單元測試：ElevenLabs 回應解析、時間戳格式

## 尚未包含
Share Extension、分段與續跑、本機轉錄（WhisperKit／FluidAudio）、LLM 筆記、翻譯、docx。

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

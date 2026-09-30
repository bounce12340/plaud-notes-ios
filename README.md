# plaud-notes-ios

iOS App：把 Plaud NotePin 的錄音轉成逐字稿，可翻譯，再依自訂 prompt 範本整理成筆記，輸出 Markdown 或 Word（.docx）。

- 規格：[docs/SPEC.md](docs/SPEC.md)（草案 v0.6）
- 開源調查：[docs/oss-survey.md](docs/oss-survey.md)
- M0 基準測試：[bench/README.md](bench/README.md)
- 格式偵測工具：[tools/probe_audio.sh](tools/probe_audio.sh)

狀態：規格階段；`app/` 有 M1 骨架，GitHub Actions 已在 iOS 模擬器編譯並通過單元測試（尚未實機測試）。

- App 骨架：[app/README.md](app/README.md)

## 授權

Copyright (C) 2026 bounce12340

本專案採用 **GNU Affero General Public License v3.0 only（AGPL-3.0-only）**，全文見 [LICENSE](LICENSE)。

- 任何人使用、修改或散布本專案程式碼（包含衍生作品），都必須以相同授權公開完整原始碼。
- 若把修改後的程式碼以網路服務的形式提供給他人使用（例如架成轉錄或筆記伺服器），也必須向使用者提供原始碼。
- 著作權人保留以其他條件另行授權（包含商業授權、App Store 發行）的權利。
- 外部貢獻：提交 Pull Request 前需同意將貢獻授權給著作權人，並允許以本授權及其他授權發行；未同意者的貢獻不會被合併。

第三方套件依各自授權（見 `docs/oss-survey.md`）。

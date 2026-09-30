# M0 轉錄基準測試（Mac mini M4／32GB）

目的：比較本機轉錄方案與 ElevenLabs Scribe（雲端對照組）的準確度與速度，決定 App 的預設轉錄引擎。
狀態：腳本已在 Linux 上做過語法與小型單元檢查；**尚未在 Mac mini 上實跑**，下列 CLI 參數依各專案 README（2026-09-30）撰寫，版本變動時以 `--help` 為準。

## 0. 準備
```bash
brew install ffmpeg python@3.12
brew install whisperkit-cli            # WhisperKit 官方 Homebrew 套件
git clone https://github.com/FluidInference/FluidAudio.git   # 用 swift run fluidaudiocli
export ELEVENLABS_API_KEY=...          # 只放在環境變數，不寫進檔案
```
樣本與結果放在 repo 外，例如 `~/plaud-bench/`（**錄音與逐字稿不可 commit**）。

## 1. 切出 10 分鐘評測片段
```bash
cd ~/plaud-bench
ffmpeg -ss 00:05:00 -t 600 -i sample_a.m4a -ac 1 -ar 16000 zh_01.wav
```
每種語言各準備 1 段：`zh_01.wav`、`en_01.wav`、`ja_01.wav`、`ko_01.wav`（盡量含多人、中英混用）。

## 2. 產生標準答案（人工校正）
1. 先用 ElevenLabs 產生初稿：
   `python3 elevenlabs_stt.py zh_01.wav --out out --lang zh`
2. 把 `out/zh_01.elevenlabs.txt` 複製成 `ref/zh_01.txt`，**邊聽邊逐字修正**。
3. 注意：用 ElevenLabs 當初稿會讓它的分數偏好。可以輪流用不同模型當初稿，或在報告中註明。

## 3. 執行各引擎
```bash
# ElevenLabs（雲端對照）
python3 elevenlabs_stt.py zh_01.wav --out out --lang zh

# WhisperKit（依 README；模型名稱以 whisperkit-cli --help 為準）
/usr/bin/time -l whisperkit-cli transcribe --model large-v3-v20240930_626MB \
  --audio-path zh_01.wav --language zh > out/zh_01.whisperkit.txt

# FluidAudio（中文用 SenseVoice／Paraformer；英日用 Parakeet；韓文支援待確認）
cd FluidAudio && swift run fluidaudiocli transcribe ../zh_01.wav > ../out/zh_01.fluid.txt
```
Apple SpeechAnalyzer 沒有官方 CLI，會在 Xcode 專案的測試 App 中另外量測。

## 4. 評分
```bash
# 中文先統一轉台灣繁體，避免簡繁差異被算成錯字
pip install opencc-python-reimplemented
for f in out/zh_01.*.txt; do python3 -c "import opencc,sys;c=opencc.OpenCC('s2twp');print(c.convert(open(sys.argv[1]).read()))" "$f" > "$f.tw"; done
python3 cer.py ref/zh_01.txt out/zh_01.elevenlabs.txt.tw --lang zh
python3 cer.py ref/zh_01.txt out/zh_01.whisperkit.txt.tw --lang zh
python3 cer.py en_ref.txt out/en_01.whisperkit.txt --lang en   # 英文算 WER
```

## 5. 記錄
| 引擎 | 語言 | CER/WER | 處理秒數／音檔秒數 | 峰值記憶體 | 備註 |
|---|---|---|---|---|---|
| ElevenLabs scribe_v2 | zh | | | — | |
| WhisperKit large-v3 | zh | | | | |
| FluidAudio | zh | | | | |

「DeepSeek 轉錄」若能取得同一片段的輸出文字，也可以放進 `out/` 一起評分，但只當比較對象，不當標準答案。

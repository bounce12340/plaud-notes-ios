#!/usr/bin/env python3
"""用 ElevenLabs Scribe 轉錄音檔，作為 M0 的雲端對照組。

需要環境變數 ELEVENLABS_API_KEY（不要把 key 寫進檔案或 repo）。
用法：
  python3 elevenlabs_stt.py audio.m4a --out out/ [--lang zh] [--speakers 4] [--model scribe_v2]

輸出：
  out/<name>.elevenlabs.json  原始回應（含字詞時間戳、speaker_id）
  out/<name>.elevenlabs.txt   純文字（給 cer.py）
  out/<name>.elevenlabs.md    依說話者分段、附時間戳的逐字稿

API 參考：https://elevenlabs.io/docs/api-reference/speech-to-text/convert
（2026-09-30 查閱：model_id=scribe_v2、diarize、num_speakers 1–32、
 timestamps_granularity、檔案需小於 5GB）
只用 Python 標準函式庫。
"""
import argparse
import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

API = "https://api.elevenlabs.io/v1/speech-to-text"


def multipart(fields: dict, file_field: str, path: str):
    boundary = uuid.uuid4().hex
    parts = []
    for k, v in fields.items():
        if v is None:
            continue
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
        )
    ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
    fname = os.path.basename(path).encode("utf-8", "replace").decode("ascii", "replace")
    head = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; '
        f'filename="{fname}"\r\nContent-Type: {ctype}\r\n\r\n'
    ).encode()
    with open(path, "rb") as f:
        data = f.read()
    body = b"".join(parts) + head + data + f"\r\n--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"


def fmt_ts(sec: float) -> str:
    sec = int(sec or 0)
    return f"{sec // 3600:02d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


def to_markdown(resp: dict) -> str:
    lines, cur_spk, buf, start = [], None, [], 0.0
    for w in resp.get("words", []):
        if w.get("type") == "audio_event":
            continue
        spk = w.get("speaker_id") or "speaker"
        if spk != cur_spk and buf:
            lines.append(f"**[{fmt_ts(start)}] {cur_spk}**：{''.join(buf).strip()}")
            buf = []
        if not buf:
            start = w.get("start", 0.0)
        cur_spk = spk
        buf.append(w.get("text", ""))
    if buf:
        lines.append(f"**[{fmt_ts(start)}] {cur_spk}**：{''.join(buf).strip()}")
    return "\n\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("audio")
    ap.add_argument("--out", default="out")
    ap.add_argument("--lang", default=None, help="ISO-639 語言碼，例如 zh、en、ja、ko；不填則自動偵測")
    ap.add_argument("--speakers", type=int, default=None)
    ap.add_argument("--model", default="scribe_v2")
    ap.add_argument("--no-diarize", action="store_true")
    a = ap.parse_args()

    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("缺少環境變數 ELEVENLABS_API_KEY")

    fields = {
        "model_id": a.model,
        "language_code": a.lang,
        "diarize": "false" if a.no_diarize else "true",
        "num_speakers": a.speakers,
        "timestamps_granularity": "word",
        "tag_audio_events": "false",
    }
    body, ctype = multipart(fields, "file", a.audio)
    req = urllib.request.Request(API, data=body, method="POST",
                                 headers={"xi-api-key": key, "Content-Type": ctype})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=3600) as r:
            resp = json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code}: {e.read()[:500].decode('utf-8', 'replace')}")
    elapsed = time.time() - t0

    os.makedirs(a.out, exist_ok=True)
    stem = os.path.join(a.out, os.path.splitext(os.path.basename(a.audio))[0] + ".elevenlabs")
    resp["_bench"] = {"model": a.model, "elapsed_sec": round(elapsed, 1)}
    json.dump(resp, open(stem + ".json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    open(stem + ".txt", "w", encoding="utf-8").write(resp.get("text", ""))
    open(stem + ".md", "w", encoding="utf-8").write(to_markdown(resp))
    print(f"完成：{elapsed:.1f}s，語言 {resp.get('language_code')}，輸出 {stem}.{{json,txt,md}}")


if __name__ == "__main__":
    main()

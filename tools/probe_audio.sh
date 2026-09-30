#!/bin/sh
# 用法: sh probe_audio.sh <錄音檔>
# 偵測 Plaud 匯出檔的容器/編碼/取樣率/聲道/長度
set -e
[ -z "$1" ] && { echo "usage: $0 <audio-file>"; exit 1; }
command -v ffprobe >/dev/null 2>&1 || apk add --no-cache ffmpeg >/dev/null
echo "== file =="; file "$1" 2>/dev/null || true
ls -l "$1"
echo "== ffprobe =="
ffprobe -v error -show_entries \
  format=format_name,duration,bit_rate:stream=codec_name,sample_rate,channels,bit_rate \
  -of default=nw=1 "$1"

#!/usr/bin/env python3
"""計算轉錄錯誤率：中日韓用 CER（字錯率），英文用 WER（詞錯率）。

用法：
  python3 cer.py reference.txt hypothesis.txt [--lang zh|ja|ko|en] [--json]

reference 是人工校正的正確逐字稿；hypothesis 是模型輸出。
正規化：移除標點與空白（CER）；英文轉小寫並以空白切詞（WER）。
只用 Python 標準函式庫。
"""
import argparse
import json
import re
import sys
import unicodedata

# 常見簡繁差異不在此處理；比較前請先把兩份文字都轉成同一種字形（例如 OpenCC s2twp）。
_PUNCT = re.compile(r"[\s\u3000]|[^\w]", re.UNICODE)


def normalize_chars(text: str) -> list:
    text = unicodedata.normalize("NFKC", text)
    # 移除時間戳如 [00:01:23] 或 (00:01)
    text = re.sub(r"[\[(]\d{1,2}:\d{2}(:\d{2})?(\.\d+)?[\])]", "", text)
    # 移除說話者標記如「Speaker 1:」「說話者 2：」
    text = re.sub(r"(?im)^\s*(speaker|說話者|发言人)\s*\d+\s*[:：]", "", text)
    text = _PUNCT.sub("", text)
    text = text.replace("_", "")
    return list(text.lower())


def normalize_words(text: str) -> list:
    text = unicodedata.normalize("NFKC", text).lower()
    text = re.sub(r"[\[(]\d{1,2}:\d{2}(:\d{2})?(\.\d+)?[\])]", " ", text)
    text = re.sub(r"(?im)^\s*speaker\s*\d+\s*:", " ", text)
    text = re.sub(r"[^\w'\s]", " ", text)
    return text.split()


def edit_counts(ref: list, hyp: list):
    """回傳 (substitutions, deletions, insertions)，Levenshtein 對齊。"""
    n, m = len(ref), len(hyp)
    # 以兩列 DP 節省記憶體，同時追蹤 S/D/I 數量
    prev = [(j, 0, 0, j) for j in range(m + 1)]  # (cost, S, D, I)
    for i in range(1, n + 1):
        cur = [(i, 0, i, 0)] + [None] * m
        r = ref[i - 1]
        for j in range(1, m + 1):
            if r == hyp[j - 1]:
                cur[j] = prev[j - 1]
                continue
            c_sub = prev[j - 1]
            c_del = prev[j]
            c_ins = cur[j - 1]
            best = min(
                (c_sub[0] + 1, "S", c_sub),
                (c_del[0] + 1, "D", c_del),
                (c_ins[0] + 1, "I", c_ins),
                key=lambda t: t[0],
            )
            cost, kind, base = best
            s, d, ins = base[1], base[2], base[3]
            if kind == "S":
                s += 1
            elif kind == "D":
                d += 1
            else:
                ins += 1
            cur[j] = (cost, s, d, ins)
        prev = cur
    _, s, d, i = prev[m]
    return s, d, i


def score(ref_text: str, hyp_text: str, lang: str) -> dict:
    if lang == "en":
        ref, hyp, metric = normalize_words(ref_text), normalize_words(hyp_text), "WER"
    else:
        ref, hyp, metric = normalize_chars(ref_text), normalize_chars(hyp_text), "CER"
    if not ref:
        raise ValueError("reference 是空的")
    s, d, i = edit_counts(ref, hyp)
    return {
        "metric": metric,
        "rate": round((s + d + i) / len(ref), 4),
        "ref_units": len(ref),
        "hyp_units": len(hyp),
        "substitutions": s,
        "deletions": d,
        "insertions": i,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference")
    ap.add_argument("hypothesis")
    ap.add_argument("--lang", default="zh", choices=["zh", "ja", "ko", "en"])
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    ref = open(a.reference, encoding="utf-8").read()
    hyp = open(a.hypothesis, encoding="utf-8").read()
    r = score(ref, hyp, a.lang)
    if a.json:
        print(json.dumps(r, ensure_ascii=False))
    else:
        print(f"{r['metric']} = {r['rate']*100:.2f}%  (ref {r['ref_units']}, "
              f"S {r['substitutions']} D {r['deletions']} I {r['insertions']})")


if __name__ == "__main__":
    sys.exit(main())

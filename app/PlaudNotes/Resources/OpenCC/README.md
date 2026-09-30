# OpenCC 字典（第三方，Apache-2.0）

來源：BYVoid/OpenCC **ver.1.4.2** 官方發行附件 `opencc-v1.4.2-resources.zip`
（sha256 `9ea0d303219b34d014d5c116677b5d325043beafb2c8a62ee889ca67f4d054a5`，2026-09-30 下載）。
授權：Apache License 2.0，全文見 `OpenCC-LICENSE.txt`。本資料夾檔案**未修改**。

只放 `s2tw`／`s2twp` 需要的 7 個字典：

| 檔案 | 用途 |
|---|---|
| CJK_Compatibility_Ideographs.txt | 正規化（相容表意字 → 標準字） |
| STPhrases.txt、STPhrases_GeneratedFromRegionalPhrases.txt | 斷詞與簡→繁詞組 |
| STCharacters.txt | 簡→繁單字 |
| TWPhrases.txt | 台灣慣用詞（例：软件→軟體，只用於 s2twp） |
| TWVariantsPhrases.txt、TWVariants.txt | 台灣異體字 |

轉換流程依 OpenCC 1.4.2 的 `s2tw.json`／`s2twp.json`；Swift 實作在 `PlaudNotes/TextProcessing/ChineseConverter.swift`。
測試案例 `PlaudNotesTests/Fixtures/opencc_*_cases.json` 取自 OpenCC `test/testcases/testcases.json` 中含 `s2tw`／`s2twp` 期望值的案例（85＋65 筆）。

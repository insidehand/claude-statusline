# claude-statusline

[Claude Code](https://docs.anthropic.com/en/docs/claude-code/statusline) 的狀態列，在終端機底部用兩行顯示最重要的資訊：模型、專案、Git 分支、Context 用量，以及你的最後一則訊息。

```
[💠 Claude Sonnet 4.6] 📂 MemberCard ⚡ main | [████████░░] 78% 125k | 1h42m
｜幫我修一下 barcode 高度的 normalization 問題
```

靈感來源：[Jackle Chen 的文章](https://jackle.pro/articles/claude-code-status-line)。

---

## 顯示內容

**第一行**
| 區段 | 範例 | 說明 |
|------|------|------|
| 模型 | `💠 Claude Sonnet 4.6` | 圖示依模型等級變換 |
| 專案 | `📂 MemberCard` | 當前目錄的 `basename` |
| Git 分支 | `⚡ main` | 快取 5 秒，非 git 目錄則不顯示 |
| Context 進度條 | `████████░░ 78% 125k` | 基於 160k 有效視窗（見下方說明）|
| 工作時間 | `1h42m` | 今日累計，午夜重置 |

**第二行**
你傳給 Claude 的最後一則訊息，最多顯示 3 行，每行 80 字元。
同時開多個 session 時特別有用。

---

## 安裝

### Bash 版本（免編譯）

```bash
git clone https://github.com/your-username/claude-statusline.git
cd claude-statusline
./install.sh
```

重新啟動 Claude Code 即可。

> **macOS 注意：** bash 版本需要 GNU awk。`brew install gawk`，或直接使用 Go 版本。

### Go 版本（推薦，速度明顯較快）

```bash
./install.sh --go
```

需要 Go ≥ 1.21。可用 Homebrew 安裝：`brew install go`，或從 [go.dev/dl](https://go.dev/dl/) 下載。

---

## 解除安裝

```bash
./uninstall.sh
```

---

## 修改後重新編譯

修改 `statusline.go` 後執行：

```bash
./build.sh
```

---

## 為什麼 Context 進度條以 160k 為基準？

Claude Code 的自動壓縮（auto-compact）會在 200k context 視窗用到約 80% 時觸發，也就是說實際可用空間約為 160k tokens。進度條以此為基準，100% = 即將被壓縮。

如果你已關閉 auto-compact，請將 `statusline.go` 中的 `effectiveCap` 常數（或 `statusline.sh` 中的除數）改為 `200000`。

---

## Plugin

inactive 功能以 plugin 的形式保留在 `statusline.go` 中（類似 p10k 的設計），只需取消註解即可啟用。

### 今日 API 費用（`dailyCost()`）

掃描今日所有 JSONL 並依 token 用量計算花費。**僅適用於 API key 計費，訂閱制用戶不適用。**

啟用方式：取消 `main()` 裡的 goroutine 註解，並將 `vals["cost"]` 加入輸出行，然後 `./build.sh`。

---

## 自訂

所有設計決策都記錄在 [`CONTEXT.md`](CONTEXT.md)，格式為 Claude Code 參考文件，可以直接交給 Claude 說「修改 X」，不需重新解釋架構。

常見調整項目：

- **顏色** → `CONTEXT.md § Colors`，全部使用 24-bit RGB，相容 iTerm2
- **最後訊息的最大行數 / 寬度** → `maxLines`、`maxWidth` 常數
- **Session 閒置判斷門檻** → 間隔超過 600 秒視為新區間，可自行調整
- **Context 上限** → `effectiveCap` / `160000`

---

## 系統需求

- macOS（建議使用 iTerm2 以支援 24-bit 色彩）
- `jq` — `brew install jq`（Bash 版本需要）
- `gawk` — `brew install gawk`（Bash 版本需要，macOS 內建 awk 不相容）
- Go ≥ 1.21（Go 版本需要）

---

## 檔案結構

```
claude-statusline/
├── statusline.sh     # Bash 版本
├── statusline.go     # Go 版本（用 build.sh 編譯）
├── install.sh        # 安裝腳本（預設 Bash，加 --go 安裝 Go 版本）
├── uninstall.sh      # 解除安裝
├── build.sh          # 編譯 Go binary → ~/.claude/statusline-go
├── CONTEXT.md        # 設計決策與欄位說明
└── README.md
```

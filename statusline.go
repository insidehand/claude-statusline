// claude-statusline/statusline.go
// High-performance Go version of the statusline script.
// Build: go build -o statusline-go statusline.go
// Then set "command": "~/.claude/statusline-go" in settings.json

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io/fs"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ── ANSI colors ───────────────────────────────────────────────────────────────

const (
	colorReset = "\033[0m"
	colorGray  = "\033[38;2;64;64;64m"
	colorGreen = "\033[38;2;152;195;121m" // message text

	colorModelOpus   = "\033[38;2;195;158;83m"
	colorModelSonnet = "\033[38;2;118;170;185m"
	colorModelHaiku  = "\033[38;2;255;182;193m"
	colorModelOther  = "\033[38;2;192;192;192m"

	colorCtxGreen  = "\033[38;2;108;167;108m"
	colorCtxGold   = "\033[38;2;188;155;83m"
	colorCtxOrange = "\033[38;2;210;120;60m"
	colorCtxRed    = "\033[38;2;185;102;82m"
)

// ── Input schema ──────────────────────────────────────────────────────────────

type RateLimitWindow struct {
	UsedPercentage float64 `json:"used_percentage"`
	ResetsAt       int64   `json:"resets_at"`
}

type Input struct {
	Model struct {
		DisplayName string `json:"display_name"`
	} `json:"model"`
	SessionID string `json:"session_id"`
	Workspace struct {
		CurrentDir string `json:"current_dir"`
	} `json:"workspace"`
	TranscriptPath string `json:"transcript_path"`
	RateLimits     struct {
		FiveHour RateLimitWindow `json:"five_hour"`
		SevenDay RateLimitWindow `json:"seven_day"`
	} `json:"rate_limits"`
}

// ── Session persistence ───────────────────────────────────────────────────────

type Interval struct {
	Start int64  `json:"start"`
	End   *int64 `json:"end"`
}

type Session struct {
	ID            string     `json:"id"`
	Date          string     `json:"date"`
	Start         int64      `json:"start"`
	LastHeartbeat int64      `json:"last_heartbeat"`
	TotalSeconds  int64      `json:"total_seconds"`
	Intervals     []Interval `json:"intervals"`
}

// ── Git cache ─────────────────────────────────────────────────────────────────

var (
	gitCache    string
	gitCacheExp time.Time
	gitMu       sync.RWMutex
)

// ── Pricing ───────────────────────────────────────────────────────────────────

type modelPricing struct {
	input      float64 // per token
	cacheWrite float64
	cacheRead  float64
	output     float64
}

// Prices per token (divide MTok rate by 1e6).
// Update if Anthropic changes pricing: https://www.anthropic.com/pricing
var knownPricing = []struct {
	key string
	modelPricing
}{
	{"opus",   modelPricing{15.0 / 1e6, 18.75 / 1e6, 1.50 / 1e6, 75.0 / 1e6}},
	{"sonnet", modelPricing{3.0 / 1e6, 3.75 / 1e6, 0.30 / 1e6, 15.0 / 1e6}},
	{"haiku",  modelPricing{0.80 / 1e6, 1.00 / 1e6, 0.08 / 1e6, 4.0 / 1e6}},
}

var (
	costCache    float64
	costCacheExp time.Time
	costMu       sync.Mutex
)

// ─────────────────────────────────────────────────────────────────────────────

func main() {
	var inp Input
	if err := json.NewDecoder(os.Stdin).Decode(&inp); err != nil {
		fmt.Fprintln(os.Stderr, "decode error:", err)
		os.Exit(1)
	}

	type result struct {
		key string
		val string
	}
	ch := make(chan result, 3)

	go func() { ch <- result{"git", gitBranch(inp.Workspace.CurrentDir)} }()
	go func() { ch <- result{"ctx", contextDisplay(inp.TranscriptPath)} }()
	go func() { ch <- result{"msg", lastUserMessage(inp.TranscriptPath, inp.SessionID)} }()

	vals := map[string]string{}
	for i := 0; i < 3; i++ {
		r := <-ch
		vals[r.key] = r.val
	}

	// update session synchronously (avoid file-write races)
	updateSession(inp.SessionID)
	usageTime, activeCount := totalHours(inp.SessionID)

	project := filepath.Base(inp.Workspace.CurrentDir)
	modelDisp := formatModel(inp.Model.DisplayName)

	// Line 1: model | directory | git branch | context usage
	fmt.Printf("%s[%s] 📂 %s%s%s%s\n",
		colorReset, modelDisp, project, vals["git"], vals["ctx"], colorReset)

	// Line 2: rate limits | today usage time | live sessions
	rateLimits := formatRateLimits(inp)
	liveStr := ""
	if activeCount > 1 {
		liveStr = fmt.Sprintf(" %s[%d×]%s", colorGray, activeCount, colorReset)
	}
	line2 := usageTime + liveStr
	if rateLimits != "" {
		line2 = rateLimits + " | " + line2
	}
	fmt.Printf("%s! %s%s\n", colorReset, line2, colorReset)

	// Line 3: last user message
	if vals["msg"] != "" {
		fmt.Print(vals["msg"])
	}
}

// ── Model formatting ──────────────────────────────────────────────────────────

func formatModel(name string) string {
	type mc struct{ color, icon string }
	models := []struct {
		key string
		mc
	}{
		{"Opus", mc{colorModelOpus, "💛"}},
		{"Sonnet", mc{colorModelSonnet, "💠"}},
		{"Haiku", mc{colorModelHaiku, "🌸"}},
	}
	for _, m := range models {
		if strings.Contains(name, m.key) {
			return fmt.Sprintf("%s%s %s%s", m.color, m.icon, name, colorReset)
		}
	}
	return fmt.Sprintf("%s🤖 %s%s", colorModelOther, name, colorReset)
}

// ── Git branch (5s in-memory cache) ──────────────────────────────────────────

func gitBranch(dir string) string {
	gitMu.RLock()
	if time.Now().Before(gitCacheExp) && gitCache != "" {
		v := gitCache
		gitMu.RUnlock()
		return v
	}
	gitMu.RUnlock()

	cmd := exec.Command("git", "-C", dir, "--no-optional-locks", "branch", "--show-current")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	branch := strings.TrimSpace(string(out))
	if branch == "" {
		return ""
	}
	v := " " + branchIcon(branch) + " " + branch

	gitMu.Lock()
	gitCache = v
	gitCacheExp = time.Now().Add(5 * time.Second)
	gitMu.Unlock()
	return v
}

// ── Session update & total hours ──────────────────────────────────────────────

func sessionsDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude", "session-tracker", "sessions")
}

func updateSession(id string) {
	dir := sessionsDir()
	os.MkdirAll(dir, 0o755)

	now := time.Now().Unix()
	today := time.Now().Format("2006-01-02")
	path := filepath.Join(dir, id+".json")

	var s Session
	if data, err := os.ReadFile(path); err == nil {
		json.Unmarshal(data, &s)
	} else {
		endPtr := now
		s = Session{
			ID: id, Date: today, Start: now,
			LastHeartbeat: now, TotalSeconds: 0,
			Intervals: []Interval{{Start: now, End: &endPtr}},
		}
	}

	gap := now - s.LastHeartbeat
	s.LastHeartbeat = now
	if gap < 600 {
		if len(s.Intervals) > 0 {
			s.Intervals[len(s.Intervals)-1].End = &now
		}
	} else {
		s.Intervals = append(s.Intervals, Interval{Start: now, End: &now})
	}

	var total int64
	for _, iv := range s.Intervals {
		if iv.End != nil {
			total += *iv.End - iv.Start
		}
	}
	s.TotalSeconds = total

	if data, err := json.Marshal(s); err == nil {
		os.WriteFile(path, data, 0o644)
	}
}

func totalHours(currentID string) (timeStr string, active int) {
	dir := sessionsDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "0m", 0
	}

	today := time.Now().Format("2006-01-02")
	now := time.Now().Unix()
	var totalSec int64

	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		var s Session
		if err := json.Unmarshal(data, &s); err != nil {
			continue
		}
		if s.Date != today {
			continue
		}
		totalSec += s.TotalSeconds
		if now-s.LastHeartbeat < 600 {
			active++
		}
	}

	h := totalSec / 3600
	m := (totalSec % 3600) / 60
	if h > 0 {
		timeStr = fmt.Sprintf("%dh%dm", h, m)
	} else {
		timeStr = fmt.Sprintf("%dm", m)
	}
	return timeStr, active
}

// ── Context usage ─────────────────────────────────────────────────────────────

func contextDisplay(path string) string {
	tokens := 0
	if path != "" && path != "null" {
		tokens = readContextTokens(path)
	}

	// autocompact fires at ~80% of 200k → effective window = 160k
	const effectiveCap = 160_000
	pct := tokens * 100 / effectiveCap
	if pct > 100 {
		pct = 100
	}

	// progress bar
	const width = 10
	filled := pct * width / 100
	empty := width - filled

	var ctxColor string
	switch {
	case pct < 60:
		ctxColor = colorCtxGreen
	case pct < 80:
		ctxColor = colorCtxGold
	default:
		ctxColor = colorCtxRed
	}

	bar := ctxColor + strings.Repeat("█", filled) + colorReset +
		colorGray + strings.Repeat("░", empty) + colorReset

	label := "--"
	if tokens > 0 {
		if tokens >= 1_000_000 {
			label = fmt.Sprintf("%dM", tokens/1_000_000)
		} else if tokens >= 1000 {
			label = fmt.Sprintf("%dk", tokens/1000)
		} else {
			label = fmt.Sprintf("%d", tokens)
		}
	}

	return fmt.Sprintf(" | %s %s%d%% %s%s", bar, ctxColor, pct, label, colorReset)
}

func readContextTokens(path string) int {
	f, err := os.Open(path)
	if err != nil {
		return 0
	}
	defer f.Close()

	// collect last 100 lines
	var lines []string
	sc := bufio.NewScanner(f)
	buf := make([]byte, 0, 1<<20)
	sc.Buffer(buf, 1<<20)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	if len(lines) > 100 {
		lines = lines[len(lines)-100:]
	}

	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line == "" {
			continue
		}
		var data map[string]interface{}
		if err := json.Unmarshal([]byte(line), &data); err != nil {
			continue
		}
		if side, ok := data["isSidechain"].(bool); ok && side {
			continue
		}
		msg, ok := data["message"].(map[string]interface{})
		if !ok {
			continue
		}
		usage, ok := msg["usage"].(map[string]interface{})
		if !ok {
			continue
		}
		total := floatField(usage, "input_tokens") +
			floatField(usage, "cache_read_input_tokens") +
			floatField(usage, "cache_creation_input_tokens")
		if total > 0 {
			return int(total)
		}
	}
	return 0
}

func floatField(m map[string]interface{}, key string) float64 {
	if v, ok := m[key].(float64); ok {
		return v
	}
	return 0
}

// ── Plugin: Daily API cost ────────────────────────────────────────────────────
// For API key billing only (not subscription plans).
// To enable: uncomment the goroutine in main() and add vals["cost"] to the output line.

func priceForModel(name string) modelPricing {
	lower := strings.ToLower(name)
	for _, p := range knownPricing {
		if strings.Contains(lower, p.key) {
			return p.modelPricing
		}
	}
	return knownPricing[1].modelPricing // default: sonnet
}

func dailyCost() string {
	costMu.Lock()
	defer costMu.Unlock()
	if time.Now().Before(costCacheExp) {
		return formatCost(costCache)
	}

	home, _ := os.UserHomeDir()
	projectsDir := filepath.Join(home, ".claude", "projects")
	todayMidnight := time.Now().Truncate(24 * time.Hour)
	var total float64

	filepath.WalkDir(projectsDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".jsonl") {
			return nil
		}
		info, err := d.Info()
		if err != nil || info.ModTime().Before(todayMidnight) {
			return nil
		}
		f, err := os.Open(path)
		if err != nil {
			return nil
		}
		defer f.Close()

		sc := bufio.NewScanner(f)
		buf := make([]byte, 0, 1<<20)
		sc.Buffer(buf, 1<<20)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" {
				continue
			}
			var data map[string]interface{}
			if err := json.Unmarshal([]byte(line), &data); err != nil {
				continue
			}
			// Filter sidechain entries
			if side, ok := data["isSidechain"].(bool); ok && side {
				continue
			}
			// Filter by today's timestamp
			if ts, ok := data["timestamp"].(string); ok {
				t, err := time.Parse(time.RFC3339, ts)
				if err == nil && t.Before(todayMidnight) {
					continue
				}
			}
			msg, ok := data["message"].(map[string]interface{})
			if !ok {
				continue
			}
			if role, _ := msg["role"].(string); role != "assistant" {
				continue
			}
			usage, ok := msg["usage"].(map[string]interface{})
			if !ok {
				continue
			}
			modelName, _ := msg["model"].(string)
			p := priceForModel(modelName)
			total += floatField(usage, "input_tokens") * p.input
			total += floatField(usage, "cache_creation_input_tokens") * p.cacheWrite
			total += floatField(usage, "cache_read_input_tokens") * p.cacheRead
			total += floatField(usage, "output_tokens") * p.output
		}
		return nil
	})

	costCache = total
	costCacheExp = time.Now().Add(60 * time.Second)
	return formatCost(total)
}

func formatCost(c float64) string {
	if c < 0.005 {
		return ""
	}
	if c >= 10 {
		return fmt.Sprintf("$%.1f", c)
	}
	return fmt.Sprintf("$%.2f", c)
}

// ── Git branch icon ───────────────────────────────────────────────────────────

func branchIcon(branch string) string {
	lower := strings.ToLower(branch)
	switch {
	case branch == "main" || branch == "master":
		return "🌳"
	case strings.HasPrefix(lower, "feature/") || strings.HasPrefix(lower, "feat/"):
		return "🌿"
	case strings.HasPrefix(lower, "fix/") || strings.HasPrefix(lower, "bugfix/") || strings.HasPrefix(lower, "bug/"):
		return "🔧"
	case strings.HasPrefix(lower, "hotfix/"):
		return "🚨"
	case strings.HasPrefix(lower, "release/"):
		return "🚀"
	case strings.HasPrefix(lower, "chore/"):
		return "🧹"
	case strings.HasPrefix(lower, "docs/"):
		return "📝"
	case strings.HasPrefix(lower, "test/"):
		return "🧪"
	case strings.HasPrefix(lower, "refactor/"):
		return "♻️"
	default:
		return "🪾"
	}
}

// ── Rate limits ───────────────────────────────────────────────────────────────

// usedPctColor returns a linear green→red color based on usage percentage.
func usedPctColor(pct float64) string {
	switch {
	case pct <= 25:
		return colorCtxGreen
	case pct <= 50:
		return colorCtxGold
	case pct <= 75:
		return colorCtxOrange
	default:
		return colorCtxRed
	}
}

// wasteUrgencyColor returns a color for the reset countdown based on
// how much quota will be wasted: score = (100 - used%) × (elapsed / total_window).
func wasteUrgencyColor(usedPct float64, resetsAt int64, totalWindowSecs float64) string {
	if resetsAt <= 0 || totalWindowSecs <= 0 {
		return colorGray
	}
	remaining := time.Until(time.Unix(resetsAt, 0)).Seconds()
	if remaining <= 0 {
		return colorGray
	}
	elapsed := totalWindowSecs - remaining
	urgency := elapsed / totalWindowSecs
	score := (100.0 - usedPct) * urgency
	switch {
	case score <= 20:
		return colorCtxGreen
	case score <= 50:
		return colorCtxGold
	case score <= 70:
		return colorCtxOrange
	default:
		return colorCtxRed
	}
}

// deltaColor returns a color based on deviation from ideal pace.
// delta = used% - elapsed%  (0 = perfect pace)
// Both large positive (burning too fast) and large negative (too slow) → red.
func deltaColor(delta float64) string {
	abs := math.Abs(delta)
	switch {
	case abs <= 10:
		return colorCtxGreen
	case abs <= 30:
		return colorCtxGold
	case abs <= 50:
		return colorCtxOrange
	default:
		return colorCtxRed
	}
}

func formatResetDuration(d time.Duration) string {
	if d <= 0 {
		return "now"
	}
	days := int(d.Hours()) / 24
	hours := int(d.Hours()) % 24
	mins := int(d.Minutes()) % 60
	switch {
	case days > 0 && hours > 0:
		return fmt.Sprintf("%dd%dh", days, hours)
	case days > 0:
		return fmt.Sprintf("%dd", days)
	case hours > 0 && mins > 0:
		return fmt.Sprintf("%dh%dm", hours, mins)
	case hours > 0:
		return fmt.Sprintf("%dh", hours)
	default:
		return fmt.Sprintf("%dm", mins)
	}
}

func formatRateLimits(inp Input) string {
	fh := inp.RateLimits.FiveHour
	sd := inp.RateLimits.SevenDay
	if fh.UsedPercentage == 0 && sd.UsedPercentage == 0 {
		return ""
	}

	const fiveHourSecs = 5 * 3600.0
	const sevenDaySecs = 7 * 24 * 3600.0

	fhPctColor := usedPctColor(fh.UsedPercentage)
	sdPctColor := usedPctColor(sd.UsedPercentage)

	fhReset := ""
	if fh.ResetsAt > 0 {
		if d := time.Until(time.Unix(fh.ResetsAt, 0)); d > 0 {
			c := wasteUrgencyColor(fh.UsedPercentage, fh.ResetsAt, fiveHourSecs)
			fhReset = fmt.Sprintf(" | %s%s%s", c, formatResetDuration(d), colorReset)
		}
	}
	sdReset := ""
	if sd.ResetsAt > 0 {
		if d := time.Until(time.Unix(sd.ResetsAt, 0)); d > 0 {
			remainPct := d.Seconds() * 100 / sevenDaySecs
			elapsedPct := 100.0 - remainPct
			delta := sd.UsedPercentage - elapsedPct
			sign := "+"
			if delta < 0 {
				sign = "-"
			}
			c := deltaColor(delta)
			sdReset = fmt.Sprintf(" | %s%s · Δ%s%d%%%s", c, formatResetDuration(d), sign, int(math.Abs(delta)), colorReset)
		}
	}

	return fmt.Sprintf("5h: %s%d%%%s%s | 7d: %s%d%%%s%s",
		fhPctColor, int(fh.UsedPercentage), colorReset, fhReset,
		sdPctColor, int(sd.UsedPercentage), colorReset, sdReset)
}

// ── Last user message ─────────────────────────────────────────────────────────

var skipPrefixes = []string{"[", "{", "<local-command", "<command-", "Caveat:"}

func isSystemMsg(s string) bool {
	for _, p := range skipPrefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

func lastUserMessage(path, sessionID string) string {
	if path == "" || path == "null" {
		return ""
	}
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()

	var lines []string
	sc := bufio.NewScanner(f)
	buf := make([]byte, 0, 1<<20)
	sc.Buffer(buf, 1<<20)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	if len(lines) > 200 {
		lines = lines[len(lines)-200:]
	}

	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line == "" {
			continue
		}
		var data map[string]interface{}
		if err := json.Unmarshal([]byte(line), &data); err != nil {
			continue
		}
		if side, ok := data["isSidechain"].(bool); ok && side {
			continue
		}
		if sid, ok := data["sessionId"].(string); !ok || sid != sessionID {
			continue
		}
		msg, ok := data["message"].(map[string]interface{})
		if !ok {
			continue
		}
		if role, _ := msg["role"].(string); role != "user" {
			continue
		}
		if typ, _ := data["type"].(string); typ != "user" {
			continue
		}
		content, ok := msg["content"].(string)
		if !ok || content == "" || isSystemMsg(content) {
			continue
		}
		return formatMsg(content)
	}
	return ""
}

func formatMsg(raw string) string {
	const maxLines = 1
	const maxWidth = 80

	msgLines := strings.Split(raw, "\n")
	var out []string
	for i, l := range msgLines {
		if i >= maxLines {
			break
		}
		l = strings.TrimSpace(l)
		if len(l) > maxWidth {
			l = l[:maxWidth-3] + "..."
		}
		out = append(out, fmt.Sprintf("%s> %s%s%s", colorReset, colorGreen, l, colorReset))
	}
	if len(msgLines) > maxLines {
		out = append(out, fmt.Sprintf("%s> %s... (+%d lines)%s", colorReset, colorGray, len(msgLines)-maxLines, colorReset))
	}
	return strings.Join(out, "\n") + "\n"
}

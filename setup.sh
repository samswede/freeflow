#!/usr/bin/env bash
# Local-only FreeFlow setup — Apple Silicon Mac only.
# Installs mlx-lm + WhisperKit, wires them up as launchd agents, and builds the app.
# Original FreeFlow by Zach Latta (https://github.com/zachlatta/freeflow) — MIT license.

set -euo pipefail

BOLD=$(tput bold 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)

info()    { echo "${BOLD}${GREEN}==> $*${RESET}"; }
warn()    { echo "${BOLD}${YELLOW}==> $*${RESET}"; }
die()     { echo "${BOLD}${RED}error: $*${RESET}" >&2; exit 1; }
newline() { echo ""; }

# ── Prereq checks ────────────────────────────────────────────────────────────

info "Checking prerequisites..."

[[ "$(uname -s)" == "Darwin" ]] || die "macOS required."
[[ "$(uname -m)" == "arm64"  ]] || die "Apple Silicon (arm64) required. This setup uses MLX and WhisperKit, which don't run on Intel Macs."

sw_vers_major=$(sw_vers -productVersion | cut -d. -f1)
(( sw_vers_major >= 13 )) || die "macOS 13 (Ventura) or later required."

command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install it first: https://brew.sh"

command -v python3 >/dev/null 2>&1 || die "python3 not found. Install via 'xcode-select --install' or Homebrew."
python3 -c "import sys; assert sys.version_info >= (3,11)" 2>/dev/null \
  || die "Python 3.11+ required. Run: brew install python@3.12"

newline

# ── WhisperKit ───────────────────────────────────────────────────────────────

info "Installing whisperkit-cli..."
if command -v whisperkit-cli >/dev/null 2>&1; then
  warn "whisperkit-cli already installed — skipping."
else
  brew install whisperkit-cli
fi
newline

# ── mlx-lm venv ──────────────────────────────────────────────────────────────

VENV="$HOME/.local/mlx-llm/venv"
info "Setting up mlx-lm venv at $VENV..."
if [[ ! -f "$VENV/bin/mlx_lm.server" ]]; then
  mkdir -p "$(dirname "$VENV")"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade pip --quiet
  "$VENV/bin/pip" install mlx-lm --quiet
  echo "  mlx-lm installed."
else
  warn "mlx-lm venv already exists — skipping install."
fi
newline

# ── Log directory ─────────────────────────────────────────────────────────────

LOG_DIR="$HOME/Library/Logs/freeflow-stack"
info "Creating log directory at $LOG_DIR..."
mkdir -p "$LOG_DIR"
newline

# ── launchd agents ───────────────────────────────────────────────────────────

AGENTS_DIR="$HOME/Library/LaunchAgents"

MLX_PLIST="$AGENTS_DIR/com.freeflow.mlx-lm.plist"
WK_PLIST="$AGENTS_DIR/com.freeflow.whisperkit.plist"

info "Writing launchd plist: $MLX_PLIST"
cat > "$MLX_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.freeflow.mlx-lm</string>
    <key>ProgramArguments</key>
    <array>
        <string>$VENV/bin/mlx_lm.server</string>
        <string>--model</string><string>mlx-community/Qwen3.5-4B-MLX-4bit</string>
        <string>--host</string><string>127.0.0.1</string>
        <string>--port</string><string>11435</string>
        <string>--chat-template-args</string><string>{"enable_thinking": false}</string>
        <string>--log-level</string><string>INFO</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>$LOG_DIR/mlx-lm.out.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/mlx-lm.err.log</string>
    <key>WorkingDirectory</key><string>$HOME/.local/mlx-llm</string>
</dict>
</plist>
PLIST

info "Writing launchd plist: $WK_PLIST"
cat > "$WK_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.freeflow.whisperkit</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/whisperkit-cli</string>
        <string>serve</string>
        <string>--model</string><string>large-v3-v20240930_626MB</string>
        <string>--host</string><string>localhost</string>
        <string>--port</string><string>50060</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>$LOG_DIR/whisperkit.out.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/whisperkit.err.log</string>
</dict>
</plist>
PLIST

newline
info "Loading launchd agents..."

# Unload first in case they were already loaded (handles re-runs)
launchctl unload "$MLX_PLIST" 2>/dev/null || true
launchctl unload "$WK_PLIST"  2>/dev/null || true

launchctl load -w "$MLX_PLIST"
launchctl load -w "$WK_PLIST"
newline

# ── Build FreeFlow ────────────────────────────────────────────────────────────

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
info "Building FreeFlow from $REPO_DIR..."
make -C "$REPO_DIR" CODESIGN_IDENTITY=- 2>&1 | tail -5
newline

info "Installing FreeFlow Dev.app to ~/Applications/ (no sudo required)..."
mkdir -p "$HOME/Applications"
cp -R "$REPO_DIR/build/FreeFlow Dev.app" "$HOME/Applications/"
xattr -cr "$HOME/Applications/FreeFlow Dev.app"
codesign --force --options runtime --sign - \
  --entitlements "$REPO_DIR/FreeFlow.entitlements" \
  "$HOME/Applications/FreeFlow Dev.app"
newline

# ── Gatekeeper note ───────────────────────────────────────────────────────────

warn "First launch — macOS security steps required"
echo "  The app is ad-hoc signed (no Apple Developer ID), so macOS may block it."
echo ""
echo "  1. Open the app:"
echo "     open ~/Applications/\"FreeFlow Dev.app\""
echo ""
echo "  2. If macOS says the app can't be opened:"
echo "     → Open System Settings → Privacy & Security"
echo "     → Scroll down to the security section"
echo "     → Click 'Open Anyway' next to FreeFlow Dev"
echo ""
echo "  3. Grant these permissions when prompted (or go to"
echo "     System Settings → Privacy & Security for each):"
echo ""
echo "     ${BOLD}Microphone${RESET}     — pops up automatically on first dictation. Click Allow."
echo ""
echo "     ${BOLD}Accessibility${RESET}  — required for FreeFlow to paste text into other apps."
echo "                    Will NOT work silently if missing. Go to:"
echo "                    System Settings → Privacy & Security → Accessibility"
echo "                    and toggle FreeFlow Dev on."
echo ""
echo "     ${BOLD}Screen Recording${RESET} — only needed for context-aware cleanup (reading"
echo "                    what's on screen). Safe to deny if you don't use that feature."
newline

# ── Wait for servers ──────────────────────────────────────────────────────────

info "Waiting for servers to come up (mlx-lm downloads ~2.5 GB on first run — be patient)..."
echo "  Checking every 5 seconds. Hit Ctrl-C to skip and check manually later."
for i in $(seq 1 60); do
  mlx_ok=false
  wk_ok=false

  curl -sf http://127.0.0.1:11435/v1/models >/dev/null 2>&1 && mlx_ok=true
  lsof -nP -iTCP:50060 -sTCP:LISTEN >/dev/null 2>&1   && wk_ok=true

  if $mlx_ok && $wk_ok; then
    echo "  Both servers are up."
    break
  fi

  status=""
  $mlx_ok || status+="mlx-lm starting..."
  $wk_ok  || status+=" whisperkit starting..."
  printf "  [%ds] %s\r" $((i * 5)) "$status"
  sleep 5
done
newline

# ── Health check ──────────────────────────────────────────────────────────────

info "Health check..."
echo -n "  mlx-lm  (:11435): "
curl -sf http://127.0.0.1:11435/v1/models >/dev/null 2>&1 \
  && echo "${GREEN}OK${RESET}" \
  || echo "${RED}NOT UP — check $LOG_DIR/mlx-lm.err.log${RESET}"

echo -n "  whisperkit (:50060): "
lsof -nP -iTCP:50060 -sTCP:LISTEN >/dev/null 2>&1 \
  && echo "${GREEN}OK${RESET}" \
  || echo "${RED}NOT UP — check $LOG_DIR/whisperkit.err.log${RESET}"
newline

# ── FreeFlow settings ─────────────────────────────────────────────────────────

echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo "${BOLD}  Configure FreeFlow — paste these values into the app${RESET}"
echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
newline
echo "  Open FreeFlow Dev from the menu bar (top-right of screen)."
echo "  Go through the setup wizard or open Settings."
newline
echo "  ${BOLD}IMPORTANT:${RESET} In the API Key step, expand 'Advanced Provider Settings'"
echo "  and set the Base URL FIRST — before entering the API key."
echo "  Otherwise the wizard tries to validate against Groq's servers and fails."
newline
echo "  ┌─────────────────────────────────────────────────────────────────────┐"
echo "  │  Field                       │  Value                              │"
echo "  ├─────────────────────────────────────────────────────────────────────┤"
echo "  │  API Base URL                │  http://127.0.0.1:11435/v1          │"
echo "  │  API Key                     │  local                              │"
echo "  │  Post-Processing Model       │  mlx-community/Qwen3.5-4B-MLX-4bit  │"
echo "  │  Post-Processing Fallback    │  mlx-community/Qwen3.5-4B-MLX-4bit  │"
echo "  │  Context Model               │  mlx-community/Qwen3.5-4B-MLX-4bit  │"
echo "  │  Transcription API URL       │  http://localhost:50060/v1          │"
echo "  │  Transcription API Key       │  local                              │"
echo "  │  Transcription Model         │  whisper-large-v3                   │"
echo "  │  Stream audio while recording│  OFF  (WhisperKit is batch-only)    │"
echo "  └─────────────────────────────────────────────────────────────────────┘"
newline
echo "  Also toggle: Settings → General → Launch FreeFlow Dev at login"
newline
echo "  ${BOLD}Custom System Prompt${RESET} (Settings → Prompts → Custom System Prompt):"
echo "  See the prompt in CLAUDE.md § 'Custom System Prompt'."
newline
echo "${GREEN}${BOLD}Setup complete. Follow the first-launch steps above, then hold Fn to dictate.${RESET}"

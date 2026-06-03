#!/usr/bin/env bash
# obsidian-to-notion installer + migration wizard — Linux
# https://github.com/feedmittens/obsidian-to-notion
set -euo pipefail

# ── Formatting ─────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

INSTALL_DIR="$HOME/.local/share/obsidian-to-notion"
CONFIG_DIR="$HOME/.config/obsidian-to-notion"
CONFIG_FILE="$CONFIG_DIR/config"
OBSIDIAN_CONFIG="$HOME/.config/obsidian/obsidian.json"
REPO_ZIP="https://github.com/feedmittens/obsidian-to-notion/archive/refs/heads/main.zip"

# ── Helpers ────────────────────────────────────────────────────────────────────

header() {
  echo
  echo "${BOLD}${CYAN}  ╔══════════════════════════════════════════════╗${RESET}"
  echo "${BOLD}${CYAN}  ║   obsidian ${DIM}→${RESET}${BOLD}${CYAN} notion  migration wizard       ║${RESET}"
  echo "${BOLD}${CYAN}  ║   github.com/feedmittens/obsidian-to-notion  ║${RESET}"
  echo "${BOLD}${CYAN}  ╚══════════════════════════════════════════════╝${RESET}"
  echo
}

section() { echo; echo "${BOLD}${BLUE}── $1 ${DIM}────────────────────────────────────────────${RESET}"; echo; }
ok()      { echo "  ${GREEN}✓${RESET}  $1"; }
warn()    { echo "  ${YELLOW}⚠${RESET}  $1"; }
err()     { echo "  ${RED}✗${RESET}  $1" >&2; }
info()    { echo "  ${DIM}$1${RESET}"; }
die()     { err "$1"; echo; exit 1; }

prompt() {
  local varname="$1" msg="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    printf "  ${CYAN}?${RESET}  %s ${DIM}[%s]${RESET}: " "$msg" "$default"
  else
    printf "  ${CYAN}?${RESET}  %s: " "$msg"
  fi
  local reply; read -r reply
  [[ -z "$reply" && -n "$default" ]] && reply="$default"
  printf -v "$varname" '%s' "$reply"
}

confirm() {
  printf "  ${CYAN}?${RESET}  %s ${DIM}[y/N]${RESET}: " "$1"
  local reply; read -r reply
  [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

spinner() {
  local pid=$1 msg=$2
  if [[ ! -t 1 ]]; then
    wait "$pid"; ok "$msg"; return
  fi
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0
  printf "  ${CYAN}${frames[0]}${RESET}  %s" "$msg"
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${CYAN}%s${RESET}  %s" "${frames[$((i % ${#frames[@]}))]}" "$msg"
    i=$((i+1)); sleep 0.08
  done
  printf "\r  ${GREEN}✓${RESET}  %-50s\n" "$msg"
}

open_url() {
  local url="$1"
  if command -v xdg-open &>/dev/null; then
    xdg-open "$url" 2>/dev/null &
  elif command -v sensible-browser &>/dev/null; then
    sensible-browser "$url" 2>/dev/null &
  else
    info "Open this URL in your browser: $url"
  fi
}

divider() { echo; echo "  ${DIM}────────────────────────────────────────────────────${RESET}"; echo; }

# ── Step 1: platform check ─────────────────────────────────────────────────────

check_linux() {
  section "[1/6] Checking your system"
  if [[ "$(uname -s)" != "Linux" ]]; then
    die "This script is for Linux. macOS users: use install.sh. Windows users: use install.ps1."
  fi

  # Detect distro for helpful hints later
  DISTRO=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    DISTRO="${ID:-}"
  fi
  ok "Linux detected${DISTRO:+ (${PRETTY_NAME:-$DISTRO})}"
}

# ── Step 2: Python check ───────────────────────────────────────────────────────

check_python() {
  local py=""
  for candidate in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" &>/dev/null; then
      local ver major minor
      ver=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
      major=${ver%%.*}; minor=${ver##*.}
      if [[ "$major" -ge 3 && "$minor" -ge 10 ]]; then
        py="$candidate"; break
      fi
    fi
  done

  if [[ -z "$py" ]]; then
    err "Python 3.10 or newer not found."
    echo
    case "${DISTRO:-}" in
      ubuntu|debian|linuxmint|pop)
        echo "  Install it with:  ${BOLD}sudo apt install python3${RESET}" ;;
      fedora|rhel|centos|rocky|alma)
        echo "  Install it with:  ${BOLD}sudo dnf install python3${RESET}" ;;
      arch|manjaro|endeavouros)
        echo "  Install it with:  ${BOLD}sudo pacman -S python${RESET}" ;;
      opensuse*|suse*)
        echo "  Install it with:  ${BOLD}sudo zypper install python3${RESET}" ;;
      *)
        echo "  Install Python 3.10+ via your distro's package manager." ;;
    esac
    echo
    exit 1
  fi

  PYTHON_BIN="$py"
  ok "Python $("$py" --version 2>&1 | awk '{print $2}') found ($py)"
}

# ── Step 3: install / update tool ─────────────────────────────────────────────

install_tool() {
  section "[2/6] Installing migration tool"

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Found existing install at $INSTALL_DIR"
    (cd "$INSTALL_DIR" && git pull -q origin main) &
    spinner $! "Updating to latest version"
  elif command -v git &>/dev/null; then
    git clone -q https://github.com/feedmittens/obsidian-to-notion.git "$INSTALL_DIR" &
    spinner $! "Cloning repository"
  else
    local tmp; tmp=$(mktemp -d)
    (curl -fsSL "$REPO_ZIP" -o "$tmp/main.zip" \
      && unzip -q "$tmp/main.zip" -d "$tmp" \
      && mv "$tmp/obsidian-to-notion-main" "$INSTALL_DIR" \
      && rm -rf "$tmp") &
    spinner $! "Downloading tool"
  fi

  if [[ ! -d "$INSTALL_DIR/.venv" ]]; then
    ("$PYTHON_BIN" -m venv "$INSTALL_DIR/.venv" \
      && "$INSTALL_DIR/.venv/bin/pip" install -q -r "$INSTALL_DIR/requirements.txt") &
    spinner $! "Setting up Python environment"
  else
    ok "Python environment already ready"
  fi

  MIGRATE_BIN="$INSTALL_DIR/.venv/bin/python"
  MIGRATE_SCRIPT="$INSTALL_DIR/obsidian_to_notion.py"
}

# ── Step 4: pick vault ─────────────────────────────────────────────────────────

pick_vault() {
  section "[3/6] Select your Obsidian vault"
  VAULT_PATH=""
  local obsidian_vaults=()

  if [[ -f "$OBSIDIAN_CONFIG" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && obsidian_vaults+=("$line")
    done < <("$PYTHON_BIN" - <<'PY'
import json, os
cfg = os.path.expanduser("~/.config/obsidian/obsidian.json")
try:
    with open(cfg) as f:
        data = json.load(f)
    for v in data.get("vaults", {}).values():
        p = v.get("path", "")
        if p and os.path.isdir(p):
            print(p)
except Exception:
    pass
PY
    )
  fi

  if [[ "${#obsidian_vaults[@]}" -gt 0 ]]; then
    echo "  Found your Obsidian vaults:"
    echo
    local i=1
    for v in "${obsidian_vaults[@]}"; do
      local count; count=$(find "$v" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
      printf "  ${BOLD}%d${RESET}  %s ${DIM}(%s notes)${RESET}\n" "$i" "$v" "$count"
      i=$((i+1))
    done
    printf "  ${BOLD}%d${RESET}  Enter path manually\n" "$i"
    echo

    local choice
    while true; do
      prompt choice "Choose a vault" "1"
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if [[ "$choice" -ge 1 && "$choice" -le "${#obsidian_vaults[@]}" ]]; then
          VAULT_PATH="${obsidian_vaults[$((choice-1))]}"; break
        elif [[ "$choice" -eq "$i" ]]; then
          prompt VAULT_PATH "Path to your vault"
          VAULT_PATH="${VAULT_PATH/#\~/$HOME}"; break
        fi
      fi
      warn "Pick a number between 1 and $i"
    done
  else
    warn "Couldn't auto-detect vaults (is Obsidian installed and has been opened?)"
    prompt VAULT_PATH "Path to your vault"
    VAULT_PATH="${VAULT_PATH/#\~/$HOME}"
  fi

  [[ -d "$VAULT_PATH" ]] || die "Vault directory not found: $VAULT_PATH"
  local note_count; note_count=$(find "$VAULT_PATH" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
  ok "Vault: $VAULT_PATH"
  ok "$note_count markdown files found"
}

# ── Step 5: Notion credentials ─────────────────────────────────────────────────

setup_notion() {
  section "[4/6] Notion integration setup"
  echo "  You'll need two things from Notion:"
  echo "  ${BOLD}1.${RESET} An integration token  ${BOLD}2.${RESET} A root page ID"
  echo

  if confirm "Open notion.so/my-integrations in your browser now"; then
    open_url "https://www.notion.so/my-integrations"
    echo
    info "In Notion: click 'New integration', give it a name, copy the token."
    info "It starts with  secret_"
    echo
  fi

  NOTION_TOKEN=""
  while true; do
    prompt NOTION_TOKEN "Paste your Notion token (secret_...)"
    [[ "$NOTION_TOKEN" == secret_* ]] && { ok "Token looks valid"; break; }
    warn "Token should start with 'secret_' — try again"
  done

  echo
  echo "  Now pick or create the Notion page to migrate your vault into."
  echo

  if confirm "Open Notion in your browser to find/create that page"; then
    open_url "https://www.notion.so"
    echo
    info "Navigate to the page, then:"
    info "  • Click ··· → 'Connect to' → select your integration"
    info "  • Copy the URL — the page ID is the last 32-character hex string"
    echo
  fi

  NOTION_PAGE_ID=""
  while true; do
    prompt NOTION_PAGE_ID "Paste the page ID (or full URL)"
    NOTION_PAGE_ID=$(echo "$NOTION_PAGE_ID" | grep -oE '[a-f0-9]{32}' | tail -1 || true)
    [[ "${#NOTION_PAGE_ID}" -eq 32 ]] && { ok "Page ID: $NOTION_PAGE_ID"; break; }
    warn "Couldn't find a 32-character hex ID — try pasting the full page URL"
  done
}

# ── Step 6: dry run + migration ────────────────────────────────────────────────

dry_run() {
  section "[5/6] Dry run — no changes yet"
  echo "  Running a preview. Nothing is written to Notion until you confirm."
  echo
  "$MIGRATE_BIN" "$MIGRATE_SCRIPT" \
    --vault "$VAULT_PATH" --token "$NOTION_TOKEN" \
    --root-page "$NOTION_PAGE_ID" --dry-run \
    --state-file "$CONFIG_DIR/migration_state.json"
  echo
}

run_migration() {
  section "[6/6] Migration"
  divider
  echo "  ${BOLD}Ready to migrate:${RESET}"
  echo
  echo "  ${DIM}Vault:${RESET}    $VAULT_PATH"
  echo "  ${DIM}Token:${RESET}    ${NOTION_TOKEN:0:12}…"
  echo "  ${DIM}Page ID:${RESET}  $NOTION_PAGE_ID"
  divider

  if ! confirm "${BOLD}${YELLOW}Start the migration?${RESET}"; then
    echo; info "Cancelled. Run this script again whenever you're ready."; echo; exit 0
  fi

  echo
  "$MIGRATE_BIN" "$MIGRATE_SCRIPT" \
    --vault "$VAULT_PATH" --token "$NOTION_TOKEN" \
    --root-page "$NOTION_PAGE_ID" \
    --state-file "$CONFIG_DIR/migration_state.json"
}

# ── Config persistence ─────────────────────────────────────────────────────────

save_config() {
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<EOF
VAULT_PATH="$VAULT_PATH"
NOTION_TOKEN="$NOTION_TOKEN"
NOTION_PAGE_ID="$NOTION_PAGE_ID"
EOF
  chmod 600 "$CONFIG_FILE"
}

load_config() { source "$CONFIG_FILE"; }  # shellcheck source=/dev/null

maybe_resume() {
  [[ -f "$CONFIG_DIR/migration_state.json" ]] || return 1
  local done_count
  done_count=$("$PYTHON_BIN" - <<PY 2>/dev/null || return 1
import json
with open("$CONFIG_DIR/migration_state.json") as f:
    s = json.load(f)
pages = s.get("pages", {})
populated = sum(1 for v in pages.values() if v.get("phase") == "populated")
print(f"{populated}/{len(pages)}")
PY
  )
  echo
  warn "Found an in-progress migration: ${BOLD}$done_count${RESET} pages done."
  echo
  if [[ -f "$CONFIG_FILE" ]]; then
    load_config
    echo "  ${DIM}Vault:${RESET}    $VAULT_PATH"
    echo "  ${DIM}Token:${RESET}    ${NOTION_TOKEN:0:12}…"
    echo "  ${DIM}Page ID:${RESET}  $NOTION_PAGE_ID"
    echo
    if confirm "Resume where it left off"; then return 0; fi
    if confirm "Start over instead (clean up duplicate Notion pages first)"; then
      rm -f "$CONFIG_DIR/migration_state.json"; return 1
    fi
    echo; info "Nothing changed. Run the script again when ready."; echo; exit 0
  fi
  return 1
}

finish() {
  echo
  echo "  ${BOLD}${GREEN}✓ Migration complete!${RESET}"
  echo
  echo "  ${DIM}•${RESET} Cross-note links resolved — [[wiki-links]] are real Notion mentions"
  echo "  ${DIM}•${RESET} Canvas files and Dataview queries were skipped (see README)"
  echo "  ${DIM}•${RESET} State: ${DIM}$CONFIG_DIR/migration_state.json${RESET}"
  echo "    Delete it when you're happy with the migration."
  echo
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  header
  check_linux
  check_python
  install_tool

  if maybe_resume; then
    section "[5/6] Dry run"; info "Skipping dry run for resume — picking up from saved state."
    section "[6/6] Resuming migration"
    "$MIGRATE_BIN" "$MIGRATE_SCRIPT" \
      --vault "$VAULT_PATH" --token "$NOTION_TOKEN" \
      --root-page "$NOTION_PAGE_ID" \
      --state-file "$CONFIG_DIR/migration_state.json"
    finish; exit 0
  fi

  pick_vault
  setup_notion
  save_config
  dry_run
  run_migration
  finish
}

main "$@"

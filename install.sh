#!/usr/bin/env bash
# obsidian-to-notion installer + migration wizard
# https://github.com/feedmittens/obsidian-to-notion
set -euo pipefail

# ── Formatting ─────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

INSTALL_DIR="$HOME/.local/share/obsidian-to-notion"
CONFIG_DIR="$HOME/.config/obsidian-to-notion"
CONFIG_FILE="$CONFIG_DIR/config"
REPO_ZIP="https://github.com/feedmittens/obsidian-to-notion/archive/refs/heads/main.zip"
OBSIDIAN_CONFIG="$HOME/Library/Application Support/obsidian/obsidian.json"

# ── Helpers ────────────────────────────────────────────────────────────────────

header() {
  echo
  echo "${BOLD}${CYAN}  ╔══════════════════════════════════════════════╗${RESET}"
  echo "${BOLD}${CYAN}  ║   obsidian ${DIM}→${RESET}${BOLD}${CYAN} notion  migration wizard       ║${RESET}"
  echo "${BOLD}${CYAN}  ║   github.com/feedmittens/obsidian-to-notion  ║${RESET}"
  echo "${BOLD}${CYAN}  ╚══════════════════════════════════════════════╝${RESET}"
  echo
}

section() {
  echo
  echo "${BOLD}${BLUE}── $1 ${DIM}────────────────────────────────────────────${RESET}"
  echo
}

ok()   { echo "  ${GREEN}✓${RESET}  $1"; }
warn() { echo "  ${YELLOW}⚠${RESET}  $1"; }
err()  { echo "  ${RED}✗${RESET}  $1" >&2; }
info() { echo "  ${DIM}$1${RESET}"; }
die()  { err "$1"; echo; exit 1; }

prompt() {
  # prompt <var_name> <message> [default]
  local varname="$1" msg="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    printf "  ${CYAN}?${RESET}  %s ${DIM}[%s]${RESET}: " "$msg" "$default"
  else
    printf "  ${CYAN}?${RESET}  %s: " "$msg"
  fi
  local reply
  read -r reply
  if [[ -z "$reply" && -n "$default" ]]; then
    reply="$default"
  fi
  printf -v "$varname" '%s' "$reply"
}

confirm() {
  # confirm <message> — returns 0 for yes, 1 for no
  printf "  ${CYAN}?${RESET}  %s ${DIM}[y/N]${RESET}: " "$1"
  local reply
  read -r reply
  [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

spinner() {
  local pid=$1 msg=$2
  if [[ ! -t 1 ]]; then
    # Not a TTY — just wait silently and print a single done line
    wait "$pid"
    ok "$msg"
    return
  fi
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  printf "  ${CYAN}${frames[0]}${RESET}  %s" "$msg"
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${CYAN}%s${RESET}  %s" "${frames[$((i % ${#frames[@]}))]}" "$msg"
    i=$((i + 1))
    sleep 0.08
  done
  printf "\r  ${GREEN}✓${RESET}  %-50s\n" "$msg"
}

divider() {
  echo
  echo "  ${DIM}────────────────────────────────────────────────────${RESET}"
  echo
}

# ── Step 1: platform check ─────────────────────────────────────────────────────

check_macos() {
  section "[1/6] Checking your system"
  if [[ "$(uname -s)" != "Darwin" ]]; then
    die "This installer is macOS-only. For Linux/Windows, follow the README."
  fi
  ok "macOS $(sw_vers -productVersion) detected"
}

# ── Step 2: Python check ───────────────────────────────────────────────────────

check_python() {
  local py=""
  for candidate in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" &>/dev/null; then
      local ver
      ver=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
      local major=${ver%%.*} minor=${ver##*.}
      if [[ "$major" -ge 3 && "$minor" -ge 10 ]]; then
        py="$candidate"
        break
      fi
    fi
  done

  if [[ -z "$py" ]]; then
    err "Python 3.10 or newer not found."
    echo
    echo "  Install it with Homebrew:"
    echo "    ${BOLD}brew install python${RESET}"
    echo
    echo "  Don't have Homebrew? https://brew.sh"
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
    # No git — use curl + unzip
    local tmp
    tmp=$(mktemp -d)
    (curl -fsSL "$REPO_ZIP" -o "$tmp/main.zip" \
      && unzip -q "$tmp/main.zip" -d "$tmp" \
      && mv "$tmp/obsidian-to-notion-main" "$INSTALL_DIR" \
      && rm -rf "$tmp") &
    spinner $! "Downloading tool"
  fi

  # Set up venv
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

# ── Step 4: pick Obsidian vault ────────────────────────────────────────────────

pick_vault() {
  section "[3/6] Select your Obsidian vault"

  VAULT_PATH=""

  # Try to read vault list from Obsidian's own config
  local obsidian_vaults=()
  if [[ -f "$OBSIDIAN_CONFIG" ]]; then
    while IFS= read -r line; do
      obsidian_vaults+=("$line")
    done < <("$PYTHON_BIN" - <<'PY'
import json, os, sys
cfg = os.path.expanduser("~/Library/Application Support/obsidian/obsidian.json")
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
      local count
      count=$(find "$v" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
      printf "  ${BOLD}%d${RESET}  %s ${DIM}(%s notes)${RESET}\n" "$i" "$v" "$count"
      i=$((i + 1))
    done
    printf "  ${BOLD}%d${RESET}  Enter path manually\n" "$i"
    echo

    local choice
    while true; do
      prompt choice "Choose a vault" "1"
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if [[ "$choice" -ge 1 && "$choice" -le "${#obsidian_vaults[@]}" ]]; then
          VAULT_PATH="${obsidian_vaults[$((choice - 1))]}"
          break
        elif [[ "$choice" -eq "$i" ]]; then
          prompt VAULT_PATH "Path to your vault"
          VAULT_PATH="${VAULT_PATH/#\~/$HOME}"
          break
        fi
      fi
      warn "Pick a number between 1 and $i"
    done
  else
    warn "Couldn't auto-detect vaults (is Obsidian installed?)"
    prompt VAULT_PATH "Path to your vault"
    VAULT_PATH="${VAULT_PATH/#\~/$HOME}"
  fi

  if [[ ! -d "$VAULT_PATH" ]]; then
    die "Vault directory not found: $VAULT_PATH"
  fi

  local note_count
  note_count=$(find "$VAULT_PATH" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
  ok "Vault: $VAULT_PATH"
  ok "$note_count markdown files found"
}

# ── Step 5: Notion credentials ─────────────────────────────────────────────────

setup_notion() {
  section "[4/6] Notion integration setup"

  echo "  You'll need two things from Notion:"
  echo "  ${BOLD}1.${RESET} An integration token  ${BOLD}2.${RESET} A root page ID"
  echo

  # Integration token
  if confirm "Open notion.so/my-integrations in your browser now"; then
    open "https://www.notion.so/my-integrations"
    echo
    info "In Notion: click 'New integration', give it a name, copy the token."
    info "It starts with  secret_"
    echo
  fi

  NOTION_TOKEN=""
  while true; do
    prompt NOTION_TOKEN "Paste your Notion token (secret_...)"
    if [[ "$NOTION_TOKEN" == secret_* ]]; then
      ok "Token looks valid"
      break
    else
      warn "Token should start with 'secret_' — try again"
    fi
  done

  # Root page ID
  echo
  echo "  Now pick or create the Notion page to migrate your vault into."
  echo

  if confirm "Open Notion in your browser to find/create that page"; then
    open "https://www.notion.so"
    echo
    info "Navigate to the page, then:"
    info "  • Click ··· → 'Connect to' → select your integration"
    info "  • Copy the URL — the page ID is the last 32-character hex string"
    info "    e.g. notion.so/My-Page-${BOLD}abcdef1234567890abcdef1234567890${RESET}"
    echo
  fi

  NOTION_PAGE_ID=""
  while true; do
    prompt NOTION_PAGE_ID "Paste the page ID (or full URL)"
    # Extract ID from a full URL if pasted
    NOTION_PAGE_ID=$(echo "$NOTION_PAGE_ID" | grep -oE '[a-f0-9]{32}' | tail -1 || true)
    if [[ "${#NOTION_PAGE_ID}" -eq 32 ]]; then
      ok "Page ID: $NOTION_PAGE_ID"
      break
    else
      warn "Couldn't find a 32-character hex ID — try pasting the full page URL"
    fi
  done
}

# ── Step 6: dry run ────────────────────────────────────────────────────────────

dry_run() {
  section "[5/6] Dry run — no changes yet"

  echo "  Running a preview so you can see exactly what will happen."
  echo "  Nothing is written to Notion until you confirm."
  echo

  "$MIGRATE_BIN" "$MIGRATE_SCRIPT" \
    --vault "$VAULT_PATH" \
    --token "$NOTION_TOKEN" \
    --root-page "$NOTION_PAGE_ID" \
    --dry-run \
    --state-file "$CONFIG_DIR/migration_state.json"

  echo
}

# ── Step 7: real migration ─────────────────────────────────────────────────────

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
    echo
    info "Cancelled. Run this script again whenever you're ready."
    echo
    exit 0
  fi

  echo

  "$MIGRATE_BIN" "$MIGRATE_SCRIPT" \
    --vault "$VAULT_PATH" \
    --token "$NOTION_TOKEN" \
    --root-page "$NOTION_PAGE_ID" \
    --state-file "$CONFIG_DIR/migration_state.json"
}

# ── Save config for resume ─────────────────────────────────────────────────────

save_config() {
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<EOF
VAULT_PATH="$VAULT_PATH"
NOTION_TOKEN="$NOTION_TOKEN"
NOTION_PAGE_ID="$NOTION_PAGE_ID"
EOF
  chmod 600 "$CONFIG_FILE"  # token is sensitive
}

load_config() {
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
}

# ── Resume mode ────────────────────────────────────────────────────────────────

maybe_resume() {
  if [[ ! -f "$CONFIG_DIR/migration_state.json" ]]; then
    return 1  # no prior run
  fi

  local done_count
  done_count=$("$PYTHON_BIN" - <<PY
import json
with open("$CONFIG_DIR/migration_state.json") as f:
    s = json.load(f)
pages = s.get("pages", {})
populated = sum(1 for v in pages.values() if v.get("phase") == "populated")
total = len(pages)
print(f"{populated}/{total}")
PY
  ) || return 1

  echo
  warn "Found an in-progress migration: ${BOLD}$done_count${RESET} pages done."
  echo

  if [[ -f "$CONFIG_FILE" ]]; then
    load_config
    echo "  ${DIM}Vault:${RESET}    $VAULT_PATH"
    echo "  ${DIM}Token:${RESET}    ${NOTION_TOKEN:0:12}…"
    echo "  ${DIM}Page ID:${RESET}  $NOTION_PAGE_ID"
    echo
    if confirm "Resume where it left off"; then
      return 0
    fi
    if confirm "Start over instead (will create duplicate pages in Notion — clean those up first)"; then
      rm -f "$CONFIG_DIR/migration_state.json"
      return 1
    fi
    echo
    info "Nothing changed. Run the script again when ready."
    echo
    exit 0
  fi
  return 1
}

# ── Done message ───────────────────────────────────────────────────────────────

finish() {
  echo
  echo "  ${BOLD}${GREEN}✓ Migration complete!${RESET}"
  echo
  echo "  Your vault is in Notion. A few things to know:"
  echo
  echo "  ${DIM}•${RESET} Cross-note links are resolved — [[wiki-links]] are real Notion mentions"
  echo "  ${DIM}•${RESET} Canvas files and Dataview queries were skipped (see README)"
  echo "  ${DIM}•${RESET} State file: ${DIM}$CONFIG_DIR/migration_state.json${RESET}"
  echo "    Delete it when you're happy with the migration."
  echo
  echo "  ${DIM}If something looks wrong, re-run with ${BOLD}--reset${RESET}${DIM} to start fresh."
  echo "  Clean up the duplicate pages in Notion first.${RESET}"
  echo
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  header
  check_macos
  check_python
  install_tool

  # Try to resume a prior run
  if maybe_resume; then
    # Resuming: re-run migration with saved config
    section "[5/6] Dry run"
    echo "  Skipping dry run for resume — picking up from saved state."
    section "[6/6] Resuming migration"
    "$MIGRATE_BIN" "$MIGRATE_SCRIPT" \
      --vault "$VAULT_PATH" \
      --token "$NOTION_TOKEN" \
      --root-page "$NOTION_PAGE_ID" \
      --state-file "$CONFIG_DIR/migration_state.json"
    finish
    exit 0
  fi

  pick_vault
  setup_notion
  save_config
  dry_run

  run_migration
  finish
}

main "$@"

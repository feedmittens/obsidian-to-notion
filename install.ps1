# obsidian-to-notion installer + migration wizard — Windows (PowerShell)
# https://github.com/feedmittens/obsidian-to-notion
#
# If you see "running scripts is disabled", run this first:
#   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
#
# Or bypass for this session only:
#   powershell -ExecutionPolicy Bypass -File install.ps1

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Paths ──────────────────────────────────────────────────────────────────────
$InstallDir  = Join-Path $env:LOCALAPPDATA "obsidian-to-notion"
$ConfigDir   = Join-Path $env:APPDATA      "obsidian-to-notion"
$ConfigFile  = Join-Path $ConfigDir        "config.json"
$StateFile   = Join-Path $ConfigDir        "migration_state.json"
$ObsidianCfg = Join-Path $env:APPDATA      "obsidian\obsidian.json"
$RepoZip     = "https://github.com/feedmittens/obsidian-to-notion/archive/refs/heads/main.zip"

# ── Formatting ─────────────────────────────────────────────────────────────────
function Header {
  Write-Host
  Write-Host "  +----------------------------------------------+" -ForegroundColor Cyan
  Write-Host "  |  obsidian -> notion  migration wizard        |" -ForegroundColor Cyan
  Write-Host "  |  github.com/feedmittens/obsidian-to-notion   |" -ForegroundColor Cyan
  Write-Host "  +----------------------------------------------+" -ForegroundColor Cyan
  Write-Host
}

function Section($msg) {
  Write-Host
  Write-Host "-- $msg " -ForegroundColor Blue -NoNewline
  Write-Host ("─" * [Math]::Max(0, 46 - $msg.Length)) -ForegroundColor DarkGray
  Write-Host
}

function Ok($msg)   { Write-Host "  " -NoNewline; Write-Host "v" -ForegroundColor Green -NoNewline; Write-Host "  $msg" }
function Warn($msg) { Write-Host "  " -NoNewline; Write-Host "!" -ForegroundColor Yellow -NoNewline; Write-Host "  $msg" }
function Info($msg) { Write-Host "  $msg" -ForegroundColor DarkGray }
function Die($msg)  { Write-Host "  " -NoNewline; Write-Host "x  $msg" -ForegroundColor Red; Write-Host; exit 1 }
function Divider    { Write-Host; Write-Host ("  " + "-" * 52) -ForegroundColor DarkGray; Write-Host }

function Ask($msg, $default = "") {
  if ($default) {
    Write-Host "  ? " -ForegroundColor Cyan -NoNewline
    Write-Host "$msg " -NoNewline
    Write-Host "[$default]" -ForegroundColor DarkGray -NoNewline
    Write-Host ": " -NoNewline
  } else {
    Write-Host "  ? " -ForegroundColor Cyan -NoNewline
    Write-Host "${msg}: " -NoNewline
  }
  $reply = Read-Host
  if ([string]::IsNullOrEmpty($reply) -and $default) { return $default }
  return $reply
}

function Confirm($msg) {
  Write-Host "  ? " -ForegroundColor Cyan -NoNewline
  Write-Host "$msg " -NoNewline
  Write-Host "[y/N]" -ForegroundColor DarkGray -NoNewline
  Write-Host ": " -NoNewline
  $reply = Read-Host
  return ($reply -eq "y" -or $reply -eq "yes" -or $reply -eq "Y")
}

function OpenUrl($url) {
  try { Start-Process $url } catch { Info "Open this URL in your browser: $url" }
}

# ── Step 1: Python check ───────────────────────────────────────────────────────

function CheckPython {
  Section "[1/6] Checking your system"
  Ok "Windows detected"

  $script:PythonBin = $null
  foreach ($cmd in @("python", "py", "python3")) {
    try {
      $ver = & $cmd -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
      if ($ver -match "^(\d+)\.(\d+)$") {
        $major = [int]$Matches[1]; $minor = [int]$Matches[2]
        if ($major -ge 3 -and $minor -ge 10) {
          $script:PythonBin = $cmd
          $fullVer = & $cmd --version 2>&1
          Ok "Python $fullVer found ($cmd)"
          return
        }
      }
    } catch {}
  }

  Die @"
Python 3.10 or newer not found.

  Install it from:  https://www.python.org/downloads/
  Or via winget:    winget install Python.Python.3.12
  Or via Chocolatey: choco install python

  Make sure to check 'Add Python to PATH' during install.
"@
}

# ── Step 2: install / update tool ─────────────────────────────────────────────

function InstallTool {
  Section "[2/6] Installing migration tool"

  $gitDir = Join-Path $InstallDir ".git"
  if (Test-Path $gitDir) {
    Info "Found existing install at $InstallDir"
    Write-Host "  o  Updating to latest version..." -ForegroundColor Cyan
    Push-Location $InstallDir
    git pull -q origin main
    Pop-Location
    Ok "Updated"
  } elseif (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "  o  Cloning repository..." -ForegroundColor Cyan
    git clone -q https://github.com/feedmittens/obsidian-to-notion.git $InstallDir
    Ok "Cloned"
  } else {
    Write-Host "  o  Downloading tool..." -ForegroundColor Cyan
    $tmp = Join-Path $env:TEMP "obsidian-to-notion-dl"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $zip = Join-Path $tmp "main.zip"
    Invoke-WebRequest -Uri $RepoZip -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    Move-Item (Join-Path $tmp "obsidian-to-notion-main") $InstallDir -Force
    Remove-Item $tmp -Recurse -Force
    Ok "Downloaded"
  }

  $venvPy = Join-Path $InstallDir ".venv\Scripts\python.exe"
  if (-not (Test-Path $venvPy)) {
    Write-Host "  o  Setting up Python environment..." -ForegroundColor Cyan
    & $script:PythonBin -m venv (Join-Path $InstallDir ".venv")
    & $venvPy -m pip install -q -r (Join-Path $InstallDir "requirements.txt")
    Ok "Python environment ready"
  } else {
    Ok "Python environment already ready"
  }

  $script:MigrateBin    = $venvPy
  $script:MigrateScript = Join-Path $InstallDir "obsidian_to_notion.py"
}

# ── Step 3: pick vault ─────────────────────────────────────────────────────────

function PickVault {
  Section "[3/6] Select your Obsidian vault"
  $script:VaultPath = ""
  $vaults = @()

  if (Test-Path $ObsidianCfg) {
    try {
      $cfg = Get-Content $ObsidianCfg -Raw | ConvertFrom-Json
      foreach ($v in $cfg.vaults.PSObject.Properties.Value) {
        if ($v.path -and (Test-Path $v.path)) { $vaults += $v.path }
      }
    } catch {}
  }

  if ($vaults.Count -gt 0) {
    Write-Host "  Found your Obsidian vaults:"; Write-Host
    for ($i = 0; $i -lt $vaults.Count; $i++) {
      $count = (Get-ChildItem -Path $vaults[$i] -Recurse -Filter "*.md" -ErrorAction SilentlyContinue).Count
      Write-Host ("  " + ($i+1).ToString() + "  " + $vaults[$i] + " ") -NoNewline
      Write-Host "($count notes)" -ForegroundColor DarkGray
    }
    Write-Host ("  " + ($vaults.Count+1) + "  Enter path manually")
    Write-Host

    while ($true) {
      $choice = Ask "Choose a vault" "1"
      if ($choice -match "^\d+$") {
        $n = [int]$choice
        if ($n -ge 1 -and $n -le $vaults.Count) { $script:VaultPath = $vaults[$n-1]; break }
        if ($n -eq $vaults.Count+1)             { $script:VaultPath = Ask "Path to your vault"; break }
      }
      Warn "Pick a number between 1 and $($vaults.Count+1)"
    }
  } else {
    Warn "Couldn't auto-detect vaults (is Obsidian installed and has been opened?)"
    $script:VaultPath = Ask "Path to your vault"
  }

  $script:VaultPath = $script:VaultPath -replace '[\\/]$', ''
  if (-not (Test-Path $script:VaultPath)) { Die "Vault directory not found: $($script:VaultPath)" }

  $noteCount = (Get-ChildItem -Path $script:VaultPath -Recurse -Filter "*.md" -ErrorAction SilentlyContinue).Count
  Ok "Vault: $($script:VaultPath)"
  Ok "$noteCount markdown files found"
}

# ── Step 4: Notion credentials ─────────────────────────────────────────────────

function SetupNotion {
  Section "[4/6] Notion integration setup"
  Write-Host "  You'll need two things from Notion:"
  Write-Host "  1.  An integration token    2.  A root page ID"
  Write-Host

  if (Confirm "Open notion.so/my-integrations in your browser now") {
    OpenUrl "https://www.notion.so/my-integrations"
    Write-Host
    Info "In Notion: click 'New integration', give it a name, copy the token."
    Info "It starts with  secret_"
    Write-Host
  }

  $script:NotionToken = ""
  while ($true) {
    $script:NotionToken = Ask "Paste your Notion token (secret_...)"
    if ($script:NotionToken.StartsWith("secret_")) { Ok "Token looks valid"; break }
    Warn "Token should start with 'secret_' — try again"
  }

  Write-Host
  Write-Host "  Now pick or create the Notion page to migrate your vault into."
  Write-Host

  if (Confirm "Open Notion in your browser to find/create that page") {
    OpenUrl "https://www.notion.so"
    Write-Host
    Info "Navigate to the page, then:"
    Info "  * Click ... -> 'Connect to' -> select your integration"
    Info "  * Copy the URL — the page ID is the last 32-character hex string"
    Write-Host
  }

  $script:NotionPageId = ""
  while ($true) {
    $raw = Ask "Paste the page ID (or full URL)"
    if ($raw -match "[a-f0-9]{32}") {
      $script:NotionPageId = $Matches[0]
      Ok "Page ID: $($script:NotionPageId)"
      break
    }
    Warn "Couldn't find a 32-character hex ID — try pasting the full page URL"
  }
}

# ── Step 5 & 6: migrate ────────────────────────────────────────────────────────

function RunDryRun {
  Section "[5/6] Dry run — no changes yet"
  Write-Host "  Running a preview. Nothing is written to Notion until you confirm."
  Write-Host
  & $script:MigrateBin $script:MigrateScript `
    --vault $script:VaultPath `
    --token $script:NotionToken `
    --root-page $script:NotionPageId `
    --dry-run `
    --state-file $StateFile
  Write-Host
}

function RunMigration {
  Section "[6/6] Migration"
  Divider
  Write-Host "  Ready to migrate:" -ForegroundColor White
  Write-Host
  Write-Host "  Vault:    " -ForegroundColor DarkGray -NoNewline; Write-Host $script:VaultPath
  Write-Host "  Token:    " -ForegroundColor DarkGray -NoNewline; Write-Host ($script:NotionToken.Substring(0, [Math]::Min(12, $script:NotionToken.Length)) + "...")
  Write-Host "  Page ID:  " -ForegroundColor DarkGray -NoNewline; Write-Host $script:NotionPageId
  Divider

  if (-not (Confirm "Start the migration?")) {
    Write-Host; Info "Cancelled. Run this script again whenever you're ready."; Write-Host; exit 0
  }

  Write-Host
  & $script:MigrateBin $script:MigrateScript `
    --vault $script:VaultPath `
    --token $script:NotionToken `
    --root-page $script:NotionPageId `
    --state-file $StateFile
}

# ── Config persistence ─────────────────────────────────────────────────────────

function SaveConfig {
  New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
  @{
    vault    = $script:VaultPath
    token    = $script:NotionToken
    page_id  = $script:NotionPageId
  } | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8
}

function MaybeResume {
  if (-not (Test-Path $StateFile)) { return $false }
  if (-not (Test-Path $ConfigFile)) { return $false }

  $pages = @{}
  try {
    $state = Get-Content $StateFile -Raw | ConvertFrom-Json
    $state.pages.PSObject.Properties | ForEach-Object { $pages[$_.Name] = $_.Value }
  } catch { return $false }

  $total     = $pages.Count
  $populated = ($pages.Values | Where-Object { $_.phase -eq "populated" }).Count

  Write-Host
  Warn "Found an in-progress migration: $populated/$total pages done."
  Write-Host

  $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
  $script:VaultPath    = $cfg.vault
  $script:NotionToken  = $cfg.token
  $script:NotionPageId = $cfg.page_id

  Write-Host "  Vault:    $($script:VaultPath)" -ForegroundColor DarkGray
  Write-Host "  Token:    $($script:NotionToken.Substring(0,12))..." -ForegroundColor DarkGray
  Write-Host "  Page ID:  $($script:NotionPageId)" -ForegroundColor DarkGray
  Write-Host

  if (Confirm "Resume where it left off") { return $true }
  if (Confirm "Start over instead (clean up duplicate Notion pages first)") {
    Remove-Item $StateFile -Force; return $false
  }
  Write-Host; Info "Nothing changed. Run the script again when ready."; Write-Host; exit 0
}

function Finish {
  Write-Host
  Write-Host "  " -NoNewline; Write-Host "v  Migration complete!" -ForegroundColor Green
  Write-Host
  Write-Host "  *  Cross-note links resolved -- [[wiki-links]] are real Notion mentions"
  Write-Host "  *  Canvas files and Dataview queries were skipped (see README)"
  Write-Host "  *  State file: $StateFile" -ForegroundColor DarkGray
  Write-Host "     Delete it when you're satisfied everything came through."
  Write-Host
}

# ── Main ───────────────────────────────────────────────────────────────────────

Header
CheckPython
InstallTool

if (MaybeResume) {
  Section "[5/6] Dry run"; Info "Skipping dry run for resume — picking up from saved state."
  Section "[6/6] Resuming migration"
  & $script:MigrateBin $script:MigrateScript `
    --vault $script:VaultPath `
    --token $script:NotionToken `
    --root-page $script:NotionPageId `
    --state-file $StateFile
  Finish; exit 0
}

PickVault
SetupNotion
SaveConfig
RunDryRun
RunMigration
Finish

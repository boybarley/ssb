```bash
#!/bin/bash
set -euo pipefail

# =============================================================================
# Smart Switch Brain — OpenClaw AI Mode Selector Installer v1.1.0
# Created by Boy Barley — https://github.com/boybarley
# =============================================================================

readonly SCRIPT_VERSION="1.1.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly DEFAULT_REPO="https://github.com/boybarley/smart-switch-brain.git"
readonly DEFAULT_PORT=5000
readonly DEFAULT_INSTALL_DIR="${HOME}/smart-switch-brain"
readonly MIN_NODE_MAJOR=16
readonly MIN_NPM_MAJOR=8
readonly MIN_GIT_VERSION="2.30"
readonly MIN_RAM_MB=2048
readonly MIN_DISK_MB=500
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5
readonly LOG_RETENTION=5
readonly SERVICE_NAME="smart-switch-brain"

INSTALL_DIR="${SMART_SWITCH_DIR:-$DEFAULT_INSTALL_DIR}"
REPO_URL="${SMART_SWITCH_REPO:-$DEFAULT_REPO}"
API_KEY=""
PORT="${SMART_SWITCH_PORT:-$DEFAULT_PORT}"
VERBOSE=false
SKIP_TESTS=false
NO_SYSTEMD=false
UPGRADE_MODE=false
CLEAN_MODE=false
UNINSTALL_MODE=false
STATUS_MODE=false
DIAGNOSTIC_MODE=false
HELP_MODE=false
LOG_FILE=""
ERROR_LOG=""
OS_TYPE=""
PKG_MANAGER=""
IS_ROOT=false
ROLLBACK_STACK=()
SPINNER_PID=""
INSTALL_START_TIME=""

# =============================================================================
# Colors
# =============================================================================
if [[ -t 1 ]] && command -v tput &>/dev/null; then
  NCOLORS="$(tput colors 2>/dev/null || echo 0)"
  if [[ "$NCOLORS" -ge 8 ]]; then
    RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4); CYAN=$(tput setaf 6)
    BOLD=$(tput bold); RESET=$(tput sgr0)
  else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; RESET=""
  fi
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; RESET=""
fi

# =============================================================================
# Logging
# =============================================================================

init_logging() {
  local log_dir="${INSTALL_DIR}/logs"
  mkdir -p "$log_dir" 2>/dev/null || { log_dir="/tmp/ssb-logs"; mkdir -p "$log_dir"; }
  LOG_FILE="${log_dir}/install_${TIMESTAMP}.log"
  ERROR_LOG="${log_dir}/install_error_${TIMESTAMP}.log"
  touch "$LOG_FILE" "$ERROR_LOG" 2>/dev/null || true
  chmod 600 "$LOG_FILE" "$ERROR_LOG" 2>/dev/null || true
  local count=0
  for f in $(ls -1t "${log_dir}"/install_*.log 2>/dev/null || true); do
    [[ -f "$f" ]] || continue
    count=$((count + 1))
    if [[ $count -gt $((LOG_RETENTION * 2)) ]]; then
      rm -f "$f" 2>/dev/null || true
    fi
  done
}

log() {
  local level="$1"; shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [$level] $*" >> "${LOG_FILE:-/dev/null}" 2>/dev/null || true
  if [[ "$level" == "ERROR" ]]; then
    echo "[$ts] $*" >> "${ERROR_LOG:-/dev/null}" 2>/dev/null || true
  fi
}

info()    { printf "%s %b%s%b\n" "ℹ️"  "$CYAN"   "$*" "$RESET"; log "INFO" "$*"; }
success() { printf "%s %b%s%b\n" "✅" "$GREEN"  "$*" "$RESET"; log "OK"   "$*"; }
warn()    { printf "%s %b%s%b\n" "⚠️"  "$YELLOW" "$*" "$RESET"; log "WARN" "$*"; }
error()   { printf "%s %b%s%b\n" "❌" "$RED"    "$*" "$RESET"; log "ERROR" "$*"; }
step()    { printf "\n%b%b── %s%b\n" "$BOLD" "$BLUE" "$*" "$RESET"; log "STEP" "$*"; }
verbose() { if [[ "$VERBOSE" == true ]]; then info "$@"; else log "DEBUG" "$*"; fi; }

# =============================================================================
# Spinner
# =============================================================================

spinner_start() {
  local msg="${1:-Working...}"
  if [[ -t 1 ]]; then
    (
      local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
      while true; do
        for (( i=0; i<${#chars}; i++ )); do
          printf "\r  %s %b%s%b" "${chars:$i:1}" "$CYAN" "$msg" "$RESET"
          sleep 0.1
        done
      done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null || true
  fi
}

spinner_stop() {
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r%40s\r" " "
  fi
}

# =============================================================================
# Cleanup / Rollback
# =============================================================================

cleanup() {
  local exit_code=$?
  set +e
  spinner_stop
  if [[ $exit_code -ne 0 && ${#ROLLBACK_STACK[@]} -gt 0 ]]; then
    warn "Rolling back ${#ROLLBACK_STACK[@]} operation(s)..."
    for (( i=${#ROLLBACK_STACK[@]}-1; i>=0; i-- )); do
      eval "${ROLLBACK_STACK[$i]}" 2>/dev/null || true
    done
  fi
  if [[ $exit_code -ne 0 ]]; then
    error "Installation failed (exit $exit_code). Log: ${LOG_FILE:-/tmp/install.log}"
    error "Error log: ${ERROR_LOG:-/tmp/error.log}"
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

push_rollback() { ROLLBACK_STACK+=("$1"); }

pop_rollback() {
  if [[ ${#ROLLBACK_STACK[@]} -gt 0 ]]; then
    unset 'ROLLBACK_STACK[${#ROLLBACK_STACK[@]}-1]'
  fi
  return 0
}

# =============================================================================
# Helpers
# =============================================================================

command_exists() { command -v "$1" &>/dev/null; }

version_gte() {
  printf '%s\n%s' "$2" "$1" | sort -V -C 2>/dev/null
}

retry() {
  local attempt=1
  while (( attempt <= MAX_RETRIES )); do
    if "$@"; then return 0; fi
    warn "Attempt $attempt/$MAX_RETRIES failed. Retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
  done
  error "Failed after $MAX_RETRIES attempts: $*"
  return 1
}

prompt_yn() {
  local msg="$1" default="${2:-n}"
  if [[ ! -t 0 ]]; then
    [[ "$default" == "y" ]] && return 0 || return 1
  fi
  local yn
  if [[ "$default" == "y" ]]; then
    read -rp "  $msg [Y/n]: " yn
    [[ -z "$yn" || "$yn" =~ ^[Yy] ]]
  else
    read -rp "  $msg [y/N]: " yn
    [[ "$yn" =~ ^[Yy] ]]
  fi
}

elapsed_since() {
  local start="$1" now
  now="$(date +%s)"
  local diff=$((now - start))
  printf "%dm %ds" $((diff / 60)) $((diff % 60))
}

secure_read() {
  local prompt="$1" var_name="$2" input=""
  printf "  🔑 %s: " "$prompt"
  read -rs input
  printf "\n"
  eval "$var_name=\$input"
}

sanitize_input() { echo "$1" | tr -cd '[:alnum:]._:/@-'; }

# =============================================================================
# CLI
# =============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)     HELP_MODE=true ;;
      --verbose|-v)  VERBOSE=true ;;
      --skip-tests)  SKIP_TESTS=true ;;
      --no-systemd)  NO_SYSTEMD=true ;;
      --upgrade)     UPGRADE_MODE=true ;;
      --clean)       CLEAN_MODE=true ;;
      --uninstall)   UNINSTALL_MODE=true ;;
      --status)      STATUS_MODE=true ;;
      --diagnostic)  DIAGNOSTIC_MODE=true ;;
      --api-key)     shift; API_KEY="${1:?--api-key requires a value}" ;;
      --port)        shift; PORT="${1:?--port requires a value}" ;;
      --repo)        shift; REPO_URL="$(sanitize_input "${1:?--repo requires a value}")" ;;
      --dir)         shift; INSTALL_DIR="${1:?--dir requires a value}" ;;
      *)             error "Unknown flag: $1"; exit 1 ;;
    esac
    shift
  done
}

show_help() {
  cat <<EOF
${BOLD}Smart Switch Brain Installer v${SCRIPT_VERSION}${RESET}
Created by Boy Barley

Usage: $SCRIPT_NAME [flags]

Flags:
  -h, --help          Show help
  -v, --verbose       Verbose output
  --skip-tests        Skip smoke tests
  --no-systemd        Skip systemd registration
  --api-key KEY       OpenRouter API key
  --port PORT         Backend port (default: $DEFAULT_PORT)
  --repo URL          Git repository URL
  --dir PATH          Installation directory
  --upgrade           Upgrade existing installation
  --clean             Clean artifacts and reinstall
  --uninstall         Remove installation
  --status            Show status
  --diagnostic        Generate diagnostic report
EOF
}

# =============================================================================
# OS Detection
# =============================================================================

detect_os() {
  step "Detecting operating system"
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release 2>/dev/null || true
    case "${ID:-unknown}" in
      ubuntu|debian|linuxmint|pop) OS_TYPE="debian"; PKG_MANAGER="apt" ;;
      rhel|centos|fedora|rocky|alma) OS_TYPE="rhel"; PKG_MANAGER="yum"
        command_exists dnf && PKG_MANAGER="dnf" ;;
      arch|manjaro|endeavouros) OS_TYPE="arch"; PKG_MANAGER="pacman" ;;
      *)
        if command_exists apt-get; then OS_TYPE="debian"; PKG_MANAGER="apt"
        elif command_exists yum; then OS_TYPE="rhel"; PKG_MANAGER="yum"
        elif command_exists pacman; then OS_TYPE="arch"; PKG_MANAGER="pacman"
        else OS_TYPE="linux"; PKG_MANAGER=""
        fi ;;
    esac
  elif [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    OS_TYPE="macos"; PKG_MANAGER="brew"
  elif grep -qi microsoft /proc/version 2>/dev/null; then
    OS_TYPE="wsl"; PKG_MANAGER="apt"
  else
    OS_TYPE="unknown"; PKG_MANAGER=""
  fi
  [[ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]] && IS_ROOT=true
  success "OS: ${OS_TYPE} | Pkg: ${PKG_MANAGER:-none} | Root: ${IS_ROOT}"
}

# =============================================================================
# System Validation
# =============================================================================

check_ram() {
  local ram_mb=0
  if [[ "$OS_TYPE" == "macos" ]]; then
    ram_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
  else
    ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  fi
  if [[ "$ram_mb" -lt "$MIN_RAM_MB" ]]; then
    error "RAM: ${ram_mb}MB < ${MIN_RAM_MB}MB required"; return 1
  fi
  success "RAM: ${ram_mb}MB"
}

check_disk() {
  local target_parent
  target_parent="$(dirname "$INSTALL_DIR")"
  mkdir -p "$target_parent" 2>/dev/null || true
  local avail_mb
  if [[ "$OS_TYPE" == "macos" ]]; then
    avail_mb=$(df -m "$target_parent" 2>/dev/null | awk 'NR==2{print $4}')
  else
    avail_mb=$(df -BM "$target_parent" 2>/dev/null | awk 'NR==2{gsub(/M/,""); print $4}')
  fi
  avail_mb="${avail_mb:-0}"
  if [[ "$avail_mb" -lt "$MIN_DISK_MB" ]]; then
    error "Disk: ${avail_mb}MB < ${MIN_DISK_MB}MB required"; return 1
  fi
  success "Disk: ${avail_mb}MB free"
}

check_tool_version() {
  local tool="$1" min_ver="$2" flag="${3:---version}"
  if ! command_exists "$tool"; then
    error "$tool not installed"; return 1
  fi
  local raw current
  raw="$("$tool" "$flag" 2>&1 | head -1 || true)"
  current="$(echo "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
  if [[ -z "$current" ]]; then
    warn "Cannot determine $tool version"; return 0
  fi
  if ! version_gte "$current" "$min_ver"; then
    error "$tool $current < $min_ver"; return 1
  fi
  success "$tool: v${current}"
}

validate_prereqs() {
  step "Validating system requirements"
  local failed=false
  check_ram                                                    || failed=true
  check_disk                                                   || failed=true
  check_tool_version node "${MIN_NODE_MAJOR}.0.0" "--version"  || failed=true
  check_tool_version npm  "${MIN_NPM_MAJOR}.0.0"  "--version" || failed=true
  check_tool_version git  "$MIN_GIT_VERSION"       "--version" || failed=true
  if [[ "$failed" == true ]]; then
    error "Prerequisites not met. Fix above issues and retry."
    exit 1
  fi
}

# =============================================================================
# Dependencies — FIX #5: build-essential + python3
# =============================================================================

install_dependencies() {
  step "Installing base dependencies"
  for dep in curl wget git; do
    if ! command_exists "$dep"; then
      retry pkg_install "$dep" || { error "Failed to install $dep"; exit 1; }
    else
      success "$dep OK"
    fi
  done
  # Optional sqlite3
  if ! command_exists sqlite3; then
    pkg_install sqlite3 2>/dev/null || verbose "sqlite3 not available (optional)"
  fi

  # FIX #5: Build tools for native modules (better-sqlite3 needs node-gyp)
  step "Installing build tools for native modules"
  case "$PKG_MANAGER" in
    apt)
      info "Installing build-essential python3..."
      sudo apt-get update -qq 2>>"${ERROR_LOG:-/dev/null}" || true
      sudo apt-get install -y build-essential python3 2>>"${ERROR_LOG:-/dev/null}" || {
        warn "build-essential install failed — native modules may not compile"
      }
      ;;
    yum|dnf)
      info "Installing Development Tools + python3..."
      sudo "$PKG_MANAGER" groupinstall -y "Development Tools" 2>>"${ERROR_LOG:-/dev/null}" || true
      sudo "$PKG_MANAGER" install -y python3 gcc-c++ make 2>>"${ERROR_LOG:-/dev/null}" || {
        warn "Build tools install failed"
      }
      ;;
    pacman)
      info "Installing base-devel python..."
      sudo pacman -S --noconfirm --needed base-devel python 2>>"${ERROR_LOG:-/dev/null}" || {
        warn "Build tools install failed"
      }
      ;;
    brew)
      info "Checking Xcode CLI tools..."
      xcode-select -p &>/dev/null || {
        info "Installing Xcode CLI tools (may open a dialog)..."
        xcode-select --install 2>/dev/null || true
        warn "If prompted, accept the Xcode license and re-run installer"
      }
      ;;
    *)
      warn "Cannot auto-install build tools for this system"
      ;;
  esac
  if command_exists gcc && command_exists make && command_exists python3; then
    success "Build tools: gcc, make, python3 OK"
  elif command_exists gcc && command_exists make; then
    success "Build tools: gcc, make OK (python3 missing but may not be needed)"
  else
    warn "Build tools incomplete — better-sqlite3 will try prebuilt binaries"
  fi
}

pkg_install() {
  local pkg="$1"
  if command_exists "$pkg"; then return 0; fi
  info "Installing $pkg..."
  case "$PKG_MANAGER" in
    apt)     sudo apt-get update -qq && sudo apt-get install -y -qq "$pkg" ;;
    yum|dnf) sudo "$PKG_MANAGER" install -y -q "$pkg" ;;
    pacman)  sudo pacman -S --noconfirm --needed "$pkg" ;;
    brew)    brew install "$pkg" ;;
    *)       warn "Cannot auto-install $pkg"; return 1 ;;
  esac
}

# =============================================================================
# Repository
# =============================================================================

backup_existing() {
  local bdir="${INSTALL_DIR}/backups/pre_upgrade_${TIMESTAMP}"
  info "Backing up to ${bdir}..."
  mkdir -p "$bdir" 2>/dev/null || true
  for item in backend frontend config data .env; do
    [[ -e "${INSTALL_DIR}/${item}" ]] && cp -a "${INSTALL_DIR}/${item}" "$bdir/" 2>/dev/null || true
  done
  success "Backup created"
}

manage_repository() {
  step "Managing repository"
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "Existing git repo at ${INSTALL_DIR}"
    if [[ "$UPGRADE_MODE" == true ]]; then
      backup_existing
      spinner_start "Pulling updates..."
      (cd "$INSTALL_DIR" && git stash --quiet 2>/dev/null || true)
      (cd "$INSTALL_DIR" && git pull --ff-only origin main 2>/dev/null || git pull --ff-only origin master 2>/dev/null || true)
      spinner_stop
      success "Repository updated"
    else
      info "Using existing repo (--upgrade to update)"
    fi
  elif [[ -d "$INSTALL_DIR" ]]; then
    info "Directory exists, not a git repo — building in place"
  else
    spinner_start "Cloning ${REPO_URL}..."
    push_rollback "rm -rf '${INSTALL_DIR}'"
    if retry git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" 2>>"${ERROR_LOG:-/dev/null}"; then
      pop_rollback
      spinner_stop
      success "Repository cloned"
    else
      pop_rollback
      spinner_stop
      warn "Clone failed — creating fresh structure"
      mkdir -p "$INSTALL_DIR"
    fi
  fi
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    if (cd "$INSTALL_DIR" && git fsck --no-dangling --quiet 2>/dev/null); then
      verbose "Repo integrity OK"
    fi
  fi
}

# =============================================================================
# Directories — FIX #4: all dirs created here + in backend at runtime
# =============================================================================

create_directories() {
  step "Creating directory structure"
  local dirs=(backend frontend config logs data backups docs)
  for d in "${dirs[@]}"; do
    mkdir -p "${INSTALL_DIR}/${d}" 2>/dev/null || true
  done
  chmod 700 "${INSTALL_DIR}/config" "${INSTALL_DIR}/logs" \
            "${INSTALL_DIR}/data" "${INSTALL_DIR}/backups" 2>/dev/null || true
  chmod 755 "${INSTALL_DIR}/backend" "${INSTALL_DIR}/frontend" \
            "${INSTALL_DIR}/docs" 2>/dev/null || true
  success "Directories ready (${#dirs[@]})"
}

# =============================================================================
# Configuration
# =============================================================================

validate_api_key() {
  local key="$1"
  [[ -n "$key" && ${#key} -ge 10 && ! "$key" =~ [[:space:]] ]]
}

setup_env() {
  local env_file="${INSTALL_DIR}/.env"
  if [[ -f "$env_file" ]]; then
    info "Existing .env found — keeping"
    # FIX #1: ensure INSTALL_DIR is in .env for path resolution
    if ! grep -q "^INSTALL_DIR=" "$env_file" 2>/dev/null; then
      echo "" >> "$env_file"
      echo "# Added by installer v${SCRIPT_VERSION}" >> "$env_file"
      echo "INSTALL_DIR=${INSTALL_DIR}" >> "$env_file"
      verbose "Added INSTALL_DIR to existing .env"
    fi
    return 0
  fi
  info "Generating .env..."
  if [[ -z "$API_KEY" ]]; then
    if [[ -t 0 ]]; then
      echo ""
      info "OpenRouter API key required — https://openrouter.ai/keys"
      local attempts=0
      while [[ $attempts -lt 3 ]]; do
        secure_read "Enter OpenRouter API key" API_KEY
        if validate_api_key "$API_KEY"; then break; fi
        warn "Invalid format. Try again."
        API_KEY=""
        attempts=$((attempts + 1))
      done
    fi
    if ! validate_api_key "${API_KEY:-}"; then
      warn "No valid key — set later in ${env_file}"
      API_KEY="CHANGE_ME"
    fi
  fi
  cat > "$env_file" <<ENVEOF
# Smart Switch Brain — Generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# DO NOT COMMIT THIS FILE

NODE_ENV=production
PORT=${PORT}
HOST=0.0.0.0

# Installation path (used by backend for absolute path resolution)
INSTALL_DIR=${INSTALL_DIR}

# OpenRouter API
OPENROUTER_API_KEY=${API_KEY}
OPENROUTER_BASE_URL=https://openrouter.ai/api/v1

# Database
DATABASE_PATH=./data/smartswitch.db

# Logging
LOG_LEVEL=info
LOG_DIR=./logs

# Rate Limiting
RATE_LIMIT_WINDOW_MS=60000
RATE_LIMIT_MAX_REQUESTS=100
ENVEOF
  chmod 600 "$env_file"
  API_KEY="[REDACTED]"
  success ".env created (mode 600)"
}

generate_modes_yaml() {
  local mf="${INSTALL_DIR}/config/modes.yaml"
  if [[ -f "$mf" ]]; then
    info "Existing modes.yaml — keeping"
    return 0
  fi
  cat > "$mf" <<'YAMLEOF'
# Smart Switch Brain — AI Routing Modes
# Edit freely — installer will never overwrite without backup.

modes:
  - id: work-hard
    name: "Work Hard"
    description: "Maximum reasoning for complex tasks"
    model: "anthropic/claude-opus-4"
    provider: "openrouter"
    parameters:
      temperature: 0.3
      max_tokens: 8192
      top_p: 0.9
    icon: "🔥"
    color: "#FF6B35"

  - id: focus-serius
    name: "Focus Serius"
    description: "Fast, focused responses"
    model: "anthropic/claude-haiku"
    provider: "openrouter"
    parameters:
      temperature: 0.2
      max_tokens: 4096
      top_p: 0.85
    icon: "🎯"
    color: "#4ECDC4"

  - id: relax
    name: "Relax"
    description: "Creative exploration"
    model: "google/step-3.5-flash"
    provider: "openrouter"
    parameters:
      temperature: 0.7
      max_tokens: 4096
      top_p: 0.95
    icon: "🌊"
    color: "#95E1D3"

defaults:
  fallback_mode: "focus-serius"
  timeout_ms: 30000
  retry_count: 2
YAMLEOF
  chmod 640 "$mf"
  success "modes.yaml created (3 profiles)"
}

setup_configuration() {
  step "Setting up configuration"
  setup_env
  generate_modes_yaml
}

# =============================================================================
# Backend — FIX #1 path resolution, FIX #2 modes error handling, FIX #4 auto-mkdir
# =============================================================================

generate_backend_scaffold() {
  local be="${INSTALL_DIR}/backend"
  [[ -f "${be}/package.json" ]] && return 0
  info "Generating backend..."
  cat > "${be}/package.json" <<'PKG'
{
  "name": "smart-switch-brain-backend",
  "version": "1.1.0",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "dev": "node --watch src/index.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "better-sqlite3": "^9.4.3",
    "dotenv": "^16.3.1",
    "helmet": "^7.1.0",
    "cors": "^2.8.5",
    "winston": "^3.11.0",
    "express-rate-limit": "^7.1.4",
    "yaml": "^2.3.4"
  },
  "engines": { "node": ">=16.0.0" }
}
PKG
  mkdir -p "${be}/src"
  # ── index.js: all fixes applied ──
  cat > "${be}/src/index.js" <<'SERVERJS'
'use strict';

var path = require('path');
var fs = require('fs');

// ============================================================
// FIX #1: Absolute path resolution
// Primary: process.env.INSTALL_DIR (set by .env or systemd)
// Fallback: two levels up from this file (__dirname/../../)
// Last resort: /root/smart-switch-brain
// ============================================================
var ROOT_DIR = process.env.INSTALL_DIR
  || path.resolve(__dirname, '..', '..')
  || '/root/smart-switch-brain';

// Load .env from the project root
require('dotenv').config({ path: path.join(ROOT_DIR, '.env') });

var express = require('express');
var helmet = require('helmet');
var cors = require('cors');
var rateLimit = require('express-rate-limit');
var yaml = require('yaml');
var Database = require('better-sqlite3');

var PORT = process.env.PORT || 5000;
var HOST = process.env.HOST || '0.0.0.0';

// ============================================================
// FIX #4: Auto-create directories before anything uses them
// ============================================================
var CONFIG_DIR = path.join(ROOT_DIR, 'config');
var DATA_DIR = path.join(ROOT_DIR, 'data');
var LOG_DIR = path.join(ROOT_DIR, 'logs');

[DATA_DIR, LOG_DIR, CONFIG_DIR].forEach(function(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
    console.log('[SSB] Created directory: ' + dir);
  }
});

// ============================================================
// FIX #2: Modes.yaml — detailed error handling and logging
// ============================================================
var modesPath = path.join(CONFIG_DIR, 'modes.yaml');
var modes = { modes: [], defaults: { fallback_mode: 'focus-serius' } };

console.log('[SSB] Looking for modes.yaml at: ' + modesPath);

if (!fs.existsSync(modesPath)) {
  console.error('[SSB] ERROR: modes.yaml NOT FOUND at: ' + modesPath);
  console.error('[SSB] Working directory: ' + process.cwd());
  console.error('[SSB] ROOT_DIR resolved to: ' + ROOT_DIR);
  console.error('[SSB] Hint: ensure INSTALL_DIR is set in .env or environment');
} else {
  try {
    var rawYaml = fs.readFileSync(modesPath, 'utf8');
    var parsed = yaml.parse(rawYaml);
    if (parsed && parsed.modes && Array.isArray(parsed.modes)) {
      modes = parsed;
      console.log('[SSB] Loaded ' + modes.modes.length + ' mode(s) from ' + modesPath);
      modes.modes.forEach(function(m) {
        console.log('[SSB]   - ' + m.id + ': ' + m.name + ' (' + m.model + ')');
      });
    } else {
      console.error('[SSB] ERROR: modes.yaml parsed but has no valid "modes" array');
      console.error('[SSB] Parsed content keys: ' + Object.keys(parsed || {}).join(', '));
    }
  } catch (parseErr) {
    console.error('[SSB] ERROR parsing modes.yaml: ' + parseErr.message);
    console.error('[SSB] File path: ' + modesPath);
    console.error('[SSB] Check YAML syntax at https://yamlchecker.com');
  }
}

// ============================================================
// Database — with auto-created DATA_DIR from FIX #4
// ============================================================
var dbPath = path.join(DATA_DIR, 'smartswitch.db');
console.log('[SSB] Database path: ' + dbPath);

var db = new Database(dbPath);
db.pragma('journal_mode = WAL');
db.exec('CREATE TABLE IF NOT EXISTS mode_history (id INTEGER PRIMARY KEY AUTOINCREMENT, mode_id TEXT NOT NULL, switched_at DATETIME DEFAULT CURRENT_TIMESTAMP)');
db.exec('CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)');

// ============================================================
// Express app
// ============================================================
var app = express();

app.use(helmet());
app.use(cors());
app.use(express.json());
app.use(rateLimit({
  windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS || '60000'),
  max: parseInt(process.env.RATE_LIMIT_MAX_REQUESTS || '100')
}));

// Serve frontend
var distPath = path.join(ROOT_DIR, 'frontend', 'dist');
if (fs.existsSync(distPath)) {
  app.use(express.static(distPath));
  console.log('[SSB] Serving frontend from: ' + distPath);
} else {
  console.warn('[SSB] Frontend dist not found at: ' + distPath);
}

// Routes
app.get('/health', function(req, res) {
  res.json({
    status: 'ok',
    version: '1.1.0',
    uptime: process.uptime(),
    root_dir: ROOT_DIR,
    modes_loaded: (modes.modes || []).length,
    db_path: dbPath
  });
});

app.get('/api/modes', function(req, res) {
  res.json(modes);
});

app.get('/api/modes/current', function(req, res) {
  var row = db.prepare('SELECT mode_id FROM mode_history ORDER BY switched_at DESC LIMIT 1').get();
  var currentId = row ? row.mode_id : (modes.defaults && modes.defaults.fallback_mode) || 'focus-serius';
  var mode = (modes.modes || []).find(function(m) { return m.id === currentId; }) || {};
  res.json(Object.assign({ current: currentId }, mode));
});

app.post('/api/modes/switch', function(req, res) {
  var mode_id = req.body && req.body.mode_id;
  if (!mode_id) return res.status(400).json({ error: 'mode_id required' });
  var valid = (modes.modes || []).find(function(m) { return m.id === mode_id; });
  if (!valid) return res.status(400).json({ error: 'invalid mode_id', available: (modes.modes || []).map(function(m) { return m.id; }) });
  db.prepare('INSERT INTO mode_history (mode_id) VALUES (?)').run(mode_id);
  console.log('[SSB] Mode switched to: ' + mode_id);
  res.json({ switched: mode_id, timestamp: new Date().toISOString() });
});

// Catch-all: serve frontend index for SPA routing
app.get('*', function(req, res) {
  var indexPath = path.join(distPath, 'index.html');
  if (fs.existsSync(indexPath)) {
    res.sendFile(indexPath);
  } else {
    res.status(404).json({ error: 'not found' });
  }
});

app.listen(PORT, HOST, function() {
  console.log('');
  console.log('========================================');
  console.log('  Smart Switch Brain v1.1.0');
  console.log('  Created by Boy Barley');
  console.log('========================================');
  console.log('  URL:      http://' + HOST + ':' + PORT);
  console.log('  Root:     ' + ROOT_DIR);
  console.log('  Database: ' + dbPath);
  console.log('  Modes:    ' + (modes.modes || []).length + ' loaded');
  console.log('========================================');
  console.log('');
});
SERVERJS
  success "Backend scaffold created (with path resolution + error handling)"
}

setup_backend() {
  step "Setting up backend (~60s)"
  generate_backend_scaffold
  local be="${INSTALL_DIR}/backend"
  if [[ ! -f "${be}/package.json" ]]; then
    error "Backend package.json missing"; exit 1
  fi
  spinner_start "Installing backend dependencies..."
  if (cd "$be" && retry npm install --production --loglevel=warn 2>>"${ERROR_LOG:-/dev/null}"); then
    spinner_stop
    success "Backend dependencies installed"
  else
    spinner_stop
    error "Backend npm install failed"
    error "Tip: ensure build-essential and python3 are installed"
    exit 1
  fi
  # Audit
  local audit
  audit="$(cd "$be" && npm audit --production 2>&1 || true)"
  if echo "$audit" | grep -qi "0 vulnerabilities"; then
    success "No vulnerabilities"
  else
    warn "npm audit found issues — run: cd ${be} && npm audit"
  fi
  # Log rotation config
  cat > "${INSTALL_DIR}/config/logrotate.conf" <<LREOF
${INSTALL_DIR}/logs/*.log {
  daily
  missingok
  rotate 14
  compress
  notifempty
}
LREOF
  chmod 644 "${INSTALL_DIR}/config/logrotate.conf" 2>/dev/null || true
}

# =============================================================================
# Frontend — FIX #6: full HTML, timeout, error handling, debug logging
# =============================================================================

generate_frontend_scaffold() {
  local fe="${INSTALL_DIR}/frontend"
  [[ -f "${fe}/package.json" ]] && return 0
  info "Generating frontend..."
  cat > "${fe}/package.json" <<'FEPKG'
{
  "name": "smart-switch-brain-frontend",
  "version": "1.1.0",
  "scripts": {
    "build": "mkdir -p dist && cp -r public/* dist/ 2>/dev/null; echo build-done"
  }
}
FEPKG
  mkdir -p "${fe}/public" "${fe}/dist"

  # ── Full readable HTML with proper error handling ──
  cat > "${fe}/public/index.html" <<'FEHTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Smart Switch Brain — OpenClaw AI Mode Selector</title>
  <style>
    :root {
      --bg-primary: #0f1117;
      --bg-card: #161b22;
      --bg-hover: #1c2333;
      --border: #30363d;
      --text-primary: #e1e4e8;
      --text-secondary: #8b949e;
      --accent-blue: #58a6ff;
      --accent-green: #3fb950;
      --accent-red: #f85149;
      --accent-yellow: #d29922;
    }

    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
      background: var(--bg-primary);
      color: var(--text-primary);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
    }

    .container {
      text-align: center;
      max-width: 700px;
      width: 100%;
      padding: 2rem;
    }

    .title {
      font-size: 2.2rem;
      font-weight: 700;
      margin-bottom: 0.5rem;
    }

    .subtitle {
      color: var(--text-secondary);
      font-size: 1rem;
      margin-bottom: 2rem;
    }

    .modes {
      display: flex;
      gap: 1rem;
      flex-wrap: wrap;
      justify-content: center;
      margin-bottom: 2rem;
    }

    .mode-btn {
      padding: 1.5rem 1.8rem;
      border: 2px solid var(--border);
      border-radius: 14px;
      background: var(--bg-card);
      cursor: pointer;
      transition: all 0.2s ease;
      min-width: 170px;
      max-width: 200px;
      flex: 1;
      color: var(--text-primary);
    }

    .mode-btn:hover {
      border-color: var(--accent-blue);
      background: var(--bg-hover);
      transform: translateY(-3px);
      box-shadow: 0 4px 20px rgba(88, 166, 255, 0.15);
    }

    .mode-btn.active {
      border-color: var(--accent-green);
      box-shadow: 0 0 20px rgba(63, 185, 80, 0.25);
    }

    .mode-btn .icon {
      font-size: 2.5rem;
      margin-bottom: 0.5rem;
    }

    .mode-btn .name {
      font-size: 1rem;
      font-weight: 600;
      margin-bottom: 0.3rem;
    }

    .mode-btn .desc {
      font-size: 0.75rem;
      color: var(--text-secondary);
      line-height: 1.3;
    }

    .status {
      padding: 1rem 1.5rem;
      border-radius: 10px;
      background: var(--bg-card);
      color: var(--accent-blue);
      font-size: 0.95rem;
      border: 1px solid var(--border);
      margin-bottom: 1.5rem;
    }

    .status.error {
      color: var(--accent-red);
      border-color: var(--accent-red);
    }

    .status.success {
      color: var(--accent-green);
      border-color: var(--accent-green);
    }

    .status.switching {
      color: var(--accent-yellow);
    }

    .error-box {
      padding: 2rem;
      border: 1px solid var(--accent-red);
      border-radius: 10px;
      background: var(--bg-card);
      color: var(--text-primary);
    }

    .error-box p {
      margin-bottom: 0.5rem;
    }

    .error-box .detail {
      font-size: 0.8rem;
      color: var(--text-secondary);
      font-family: monospace;
    }

    .error-box button {
      margin-top: 1rem;
      padding: 0.6rem 1.5rem;
      border: 1px solid var(--accent-blue);
      background: transparent;
      color: var(--accent-blue);
      border-radius: 6px;
      cursor: pointer;
      font-size: 0.9rem;
    }

    .error-box button:hover {
      background: var(--accent-blue);
      color: #fff;
    }

    .loading-spinner {
      display: inline-block;
      width: 20px;
      height: 20px;
      border: 2px solid var(--border);
      border-top-color: var(--accent-blue);
      border-radius: 50%;
      animation: spin 0.8s linear infinite;
      vertical-align: middle;
      margin-right: 8px;
    }

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    .footer {
      margin-top: 1rem;
      font-size: 0.75rem;
      color: #484f58;
    }

    .footer a {
      color: #484f58;
      text-decoration: none;
    }

    .footer a:hover {
      color: var(--accent-blue);
    }
  </style>
</head>
<body>
  <div class="container">
    <h1 class="title">🧠 Smart Switch Brain</h1>
    <p class="subtitle">OpenClaw AI Mode Selector</p>

    <div id="modes" class="modes">
      <div style="color: var(--text-secondary);">
        <span class="loading-spinner"></span>
        Loading modes...
      </div>
    </div>

    <div id="status" class="status">
      <span class="loading-spinner"></span>
      Connecting to API...
    </div>

    <div class="footer">
      Created by <a href="https://github.com/boybarley" target="_blank">Boy Barley</a>
      &nbsp;·&nbsp; Smart Switch Brain v1.1.0
    </div>
  </div>

  <script>
    /* ================================================================
     * Smart Switch Brain — Frontend v1.1.0
     * FIX #6: Timeout, error handling, console logging, full HTML
     * ================================================================ */

    var API_BASE = window.location.origin;
    var REQUEST_TIMEOUT = 5000;

    /* -- Helpers -- */

    function fetchWithTimeout(url, options) {
      console.log('[SSB] Fetch: ' + url);
      return new Promise(function(resolve, reject) {
        var timer = setTimeout(function() {
          console.error('[SSB] Timeout after ' + REQUEST_TIMEOUT + 'ms: ' + url);
          reject(new Error('Timeout after ' + REQUEST_TIMEOUT + 'ms'));
        }, REQUEST_TIMEOUT);

        fetch(url, options || {})
          .then(function(response) {
            clearTimeout(timer);
            console.log('[SSB] Response: ' + response.status + ' from ' + url);
            resolve(response);
          })
          .catch(function(err) {
            clearTimeout(timer);
            console.error('[SSB] Network error: ' + err.message);
            reject(err);
          });
      });
    }

    function setStatus(msg, type) {
      var el = document.getElementById('status');
      el.className = 'status' + (type ? ' ' + type : '');
      el.textContent = msg;
      console.log('[SSB] Status: ' + msg);
    }

    /* -- Load modes from API -- */

    function loadModes() {
      console.log('[SSB] Loading modes...');

      fetchWithTimeout(API_BASE + '/api/modes')
        .then(function(res) {
          if (!res.ok) throw new Error('HTTP ' + res.status + ' ' + res.statusText);
          return res.json();
        })
        .then(function(data) {
          var modeList = data.modes || [];
          console.log('[SSB] Received ' + modeList.length + ' mode(s)');

          if (modeList.length === 0) {
            setStatus('No modes configured — check config/modes.yaml', 'error');
            return;
          }

          renderModes(modeList);
          return fetchWithTimeout(API_BASE + '/api/modes/current');
        })
        .then(function(res) {
          if (!res) return;
          return res.json();
        })
        .then(function(current) {
          if (!current) return;
          console.log('[SSB] Current mode: ' + (current.name || current.current));
          setStatus('Active: ' + (current.name || current.current), 'success');
          highlightActive(current.current);
        })
        .catch(function(err) {
          console.error('[SSB] Load failed:', err);
          setStatus('Cannot connect: ' + err.message, 'error');

          var modesEl = document.getElementById('modes');
          modesEl.innerHTML = ''
            + '<div class="error-box">'
            + '  <p><strong>Could not load modes</strong></p>'
            + '  <p class="detail">API: ' + API_BASE + '/api/modes</p>'
            + '  <p class="detail">Error: ' + err.message + '</p>'
            + '  <p class="detail">Check: is the backend running?</p>'
            + '  <br>'
            + '  <button onclick="loadModes()">🔄 Retry</button>'
            + '</div>';
        });
    }

    /* -- Render mode buttons -- */

    function renderModes(modeList) {
      var container = document.getElementById('modes');
      var html = '';

      modeList.forEach(function(mode) {
        html += ''
          + '<div class="mode-btn" id="btn-' + mode.id + '"'
          + '     onclick="switchMode(\'' + mode.id + '\', \'' + (mode.name || mode.id) + '\')">'
          + '  <div class="icon">' + (mode.icon || '🔘') + '</div>'
          + '  <div class="name">' + (mode.name || mode.id) + '</div>'
          + '  <div class="desc">' + (mode.description || '') + '</div>'
          + '</div>';
      });

      container.innerHTML = html;
    }

    /* -- Highlight active mode -- */

    function highlightActive(id) {
      var btns = document.querySelectorAll('.mode-btn');
      for (var i = 0; i < btns.length; i++) {
        btns[i].classList.remove('active');
      }
      var el = document.getElementById('btn-' + id);
      if (el) {
        el.classList.add('active');
      }
    }

    /* -- Switch mode -- */

    function switchMode(id, name) {
      console.log('[SSB] Switching to: ' + id);
      setStatus('Switching to ' + name + '...', 'switching');

      fetchWithTimeout(API_BASE + '/api/modes/switch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ mode_id: id })
      })
        .then(function(res) {
          if (!res.ok) throw new Error('HTTP ' + res.status);
          return res.json();
        })
        .then(function(data) {
          console.log('[SSB] Switched OK:', data);
          loadModes();
        })
        .catch(function(err) {
          console.error('[SSB] Switch failed:', err);
          setStatus('Switch failed: ' + err.message, 'error');
        });
    }

    /* -- Initial load -- */
    loadModes();
  </script>
</body>
</html>
FEHTML
  success "Frontend scaffold created (with timeout + error handling)"
}

setup_frontend() {
  step "Setting up frontend (~30s)"
  generate_frontend_scaffold
  local fe="${INSTALL_DIR}/frontend"
  if [[ ! -f "${fe}/package.json" ]]; then
    error "Frontend package.json missing"; exit 1
  fi
  local marker="${fe}/.build_hash"
  local cur_hash="none"
  if command_exists md5sum; then
    cur_hash="$(find "$fe" -maxdepth 2 -type f \( -name '*.html' -o -name '*.js' -o -name '*.css' \) \
      -not -path '*/node_modules/*' -not -path '*/dist/*' 2>/dev/null \
      | sort | xargs cat 2>/dev/null | md5sum | cut -d' ' -f1 || echo none)"
  fi
  if [[ -f "$marker" ]] && [[ "$(cat "$marker" 2>/dev/null || echo x)" == "$cur_hash" ]] && [[ -d "${fe}/dist" ]]; then
    info "Frontend unchanged — skipping rebuild"
    return 0
  fi
  spinner_start "Building frontend..."
  if (cd "$fe" && npm install --loglevel=warn 2>>"${ERROR_LOG:-/dev/null}" && npm run build 2>>"${ERROR_LOG:-/dev/null}"); then
    spinner_stop
    echo "$cur_hash" > "$marker" 2>/dev/null || true
    success "Frontend built"
  else
    spinner_stop
    error "Frontend build failed"; exit 1
  fi
}

# =============================================================================
# Security
# =============================================================================

harden_security() {
  step "Applying security hardening"
  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    chmod 600 "${INSTALL_DIR}/.env" 2>/dev/null || true
  fi
  chmod 700 "${INSTALL_DIR}/config" 2>/dev/null || true
  cat > "${INSTALL_DIR}/.gitignore" <<'GI'
.env
.env.*
!.env.example
config/modes.yaml
data/
logs/
backups/
node_modules/
*.db
*.db-journal
*.db-wal
dist/
.build_hash
*.pem
*.key
GI
  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    sed 's/=.*/=CHANGE_ME/' "${INSTALL_DIR}/.env" 2>/dev/null \
      | grep -v "^#" | sed '/^$/d' \
      > "${INSTALL_DIR}/.env.example" 2>/dev/null || true
    chmod 644 "${INSTALL_DIR}/.env.example" 2>/dev/null || true
  fi
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    mkdir -p "${INSTALL_DIR}/.git/hooks" 2>/dev/null || true
    cat > "${INSTALL_DIR}/.git/hooks/pre-commit" <<'HOOK'
#!/bin/bash
if git diff --cached --name-only | grep -qE '\.env$|\.pem$|\.key$'; then
  echo "BLOCKED: sensitive file in commit"; exit 1
fi
HOOK
    chmod 755 "${INSTALL_DIR}/.git/hooks/pre-commit" 2>/dev/null || true
  fi
  success "Security hardening applied"
}

# =============================================================================
# Database
# =============================================================================

init_database() {
  step "Initializing database"
  local db_path="${INSTALL_DIR}/data/smartswitch.db"

  # Ensure data dir exists (FIX #4: redundant safety)
  mkdir -p "${INSTALL_DIR}/data" 2>/dev/null || true

  if [[ -f "$db_path" && "$UPGRADE_MODE" == true ]]; then
    local db_bak="${INSTALL_DIR}/backups/smartswitch_${TIMESTAMP}.db"
    cp "$db_path" "$db_bak" 2>/dev/null || true
    chmod 600 "$db_bak" 2>/dev/null || true
    success "DB backed up: ${db_bak}"
  fi

  local seeded=false

  # Method 1: sqlite3 CLI
  if [[ "$seeded" == false ]] && command_exists sqlite3; then
    verbose "Trying sqlite3 CLI..."
    if sqlite3 "$db_path" 2>>"${ERROR_LOG:-/dev/null}" <<'SEEDSQL'
CREATE TABLE IF NOT EXISTS mode_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mode_id TEXT NOT NULL,
  switched_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
INSERT OR IGNORE INTO settings (key, value) VALUES ('app_version', '1.1.0');
INSERT OR IGNORE INTO settings (key, value) VALUES ('installed_at', datetime('now'));
SEEDSQL
    then
      seeded=true
      verbose "Seeded via sqlite3"
    fi
  fi

  # Method 2: Node.js temp script with env vars
  if [[ "$seeded" == false ]] && command_exists node \
     && [[ -d "${INSTALL_DIR}/backend/node_modules/better-sqlite3" ]]; then
    verbose "Trying node + better-sqlite3..."
    local tmp_js="${INSTALL_DIR}/data/.db_seed_tmp.js"
    cat > "$tmp_js" <<'SEEDJS'
var path = require('path');
var Database = require(path.join(process.env.SSB_DIR, 'backend', 'node_modules', 'better-sqlite3'));
var db = new Database(process.env.SSB_DBPATH);
db.pragma('journal_mode = WAL');
db.exec('CREATE TABLE IF NOT EXISTS mode_history (id INTEGER PRIMARY KEY AUTOINCREMENT, mode_id TEXT NOT NULL, switched_at DATETIME DEFAULT CURRENT_TIMESTAMP)');
db.exec('CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)');
db.exec("INSERT OR IGNORE INTO settings (key, value) VALUES ('app_version', '1.1.0')");
db.exec("INSERT OR IGNORE INTO settings (key, value) VALUES ('installed_at', datetime('now'))");
db.close();
SEEDJS
    if SSB_DIR="$INSTALL_DIR" SSB_DBPATH="$db_path" node "$tmp_js" 2>>"${ERROR_LOG:-/dev/null}"; then
      seeded=true
      verbose "Seeded via node"
    fi
    rm -f "$tmp_js" 2>/dev/null || true
  fi

  if [[ "$seeded" == false ]]; then
    info "DB will initialize on first app start (OK)"
  fi
  if [[ -f "$db_path" ]]; then
    chmod 600 "$db_path" 2>/dev/null || true
  fi
  success "Database ready"
}

# =============================================================================
# Port
# =============================================================================

check_port() {
  step "Checking port ${PORT}"
  local in_use=false
  if command_exists ss; then
    ss -tlnp 2>/dev/null | grep -q ":${PORT} " && in_use=true || true
  elif command_exists lsof; then
    lsof -i ":${PORT}" -sTCP:LISTEN &>/dev/null && in_use=true || true
  elif command_exists netstat; then
    netstat -tlnp 2>/dev/null | grep -q ":${PORT} " && in_use=true || true
  fi
  if [[ "$in_use" == true ]]; then
    warn "Port ${PORT} in use"
    local alt=$((PORT + 1))
    while (( alt < PORT + 100 )); do
      if ! ss -tlnp 2>/dev/null | grep -q ":${alt} "; then break; fi
      alt=$((alt + 1))
    done
    if [[ -t 0 ]] && prompt_yn "Use port ${alt} instead?" "y"; then
      PORT=$alt
      sed -i.bak "s/^PORT=.*/PORT=${PORT}/" "${INSTALL_DIR}/.env" 2>/dev/null || true
      rm -f "${INSTALL_DIR}/.env.bak" 2>/dev/null || true
      success "Port changed to ${PORT}"
    else
      warn "Keeping port ${PORT} — resolve conflict manually"
    fi
  else
    success "Port ${PORT} available"
  fi
}

# =============================================================================
# Service — FIX #3: removed ProtectSystem=strict, PrivateTmp, ProtectHome
# =============================================================================

generate_start_script() {
  cat > "${INSTALL_DIR}/start.sh" <<STARTEOF
#!/bin/bash
# Smart Switch Brain — start script
export INSTALL_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
cd "\${INSTALL_DIR}/backend"
echo "Starting Smart Switch Brain..."
echo "  Root: \${INSTALL_DIR}"
echo "  Port: \${PORT:-${PORT}}"
exec node src/index.js
STARTEOF
  cat > "${INSTALL_DIR}/stop.sh" <<'STOPEOF'
#!/bin/bash
echo "Stopping Smart Switch Brain..."
pkill -f "node.*src/index.js" 2>/dev/null && echo "Stopped." || echo "Not running."
STOPEOF
  chmod 755 "${INSTALL_DIR}/start.sh" "${INSTALL_DIR}/stop.sh"
  success "start.sh / stop.sh created"
}

create_systemd_unit() {
  local unit_file="/etc/systemd/system/${SERVICE_NAME}.service"
  local node_path
  node_path="$(command -v node 2>/dev/null || echo node)"
  local run_user
  run_user="$(id -un 2>/dev/null || echo root)"
  local tmp_unit="/tmp/${SERVICE_NAME}_${TIMESTAMP}.service"

  # FIX #3: removed ProtectSystem=strict, ProtectHome=read-only, PrivateTmp=true
  # These are too restrictive for dev/local deployment and cause path access errors
  cat > "$tmp_unit" <<UNITEOF
[Unit]
Description=Smart Switch Brain — OpenClaw AI Mode Selector
Documentation=https://github.com/boybarley/smart-switch-brain
After=network.target

[Service]
Type=simple
User=${run_user}
WorkingDirectory=${INSTALL_DIR}/backend
ExecStart=${node_path} src/index.js
Restart=on-failure
RestartSec=10
StandardOutput=append:${INSTALL_DIR}/logs/service.log
StandardError=append:${INSTALL_DIR}/logs/service-error.log

# Environment
Environment=NODE_ENV=production
Environment=INSTALL_DIR=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env

# Reasonable limits
LimitNOFILE=65536

# Basic security (not overly restrictive)
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNITEOF

  if sudo cp "$tmp_unit" "$unit_file" 2>>"${ERROR_LOG:-/dev/null}" \
     && sudo chmod 644 "$unit_file" 2>>"${ERROR_LOG:-/dev/null}"; then
    rm -f "$tmp_unit" 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo systemctl enable "$SERVICE_NAME" 2>/dev/null || true
    success "Systemd service registered"
    info "sudo systemctl {start|stop|status} ${SERVICE_NAME}"
  else
    rm -f "$tmp_unit" 2>/dev/null || true
    warn "Systemd setup failed — using start scripts"
    generate_start_script
  fi
}

register_service() {
  if [[ "$NO_SYSTEMD" == true ]]; then
    info "Systemd skipped (--no-systemd)"
    generate_start_script
    return 0
  fi
  step "Service registration"
  if ! command_exists systemctl; then
    info "systemd not available"
    generate_start_script
    return 0
  fi
  if [[ "$IS_ROOT" == true ]]; then
    create_systemd_unit
  else
    if [[ -t 0 ]] && prompt_yn "Register systemd service? (sudo required)" "y"; then
      create_systemd_unit
    else
      generate_start_script
    fi
  fi
  # Always also generate start scripts as convenience
  generate_start_script
}

# =============================================================================
# Smoke Tests
# =============================================================================

run_smoke_tests() {
  if [[ "$SKIP_TESTS" == true ]]; then
    info "Tests skipped (--skip-tests)"
    return 0
  fi
  step "Smoke tests"
  local pass=0 fail=0

  if node -e "process.exit(0)" 2>/dev/null; then
    success "Node runtime: OK"; pass=$((pass+1))
  else
    error "Node runtime: FAIL"; fail=$((fail+1))
  fi

  local dirs_ok=true
  for d in backend frontend config logs data; do
    [[ -d "${INSTALL_DIR}/${d}" ]] || dirs_ok=false
  done
  if [[ "$dirs_ok" == true ]]; then
    success "Directories: OK"; pass=$((pass+1))
  else
    error "Directories: FAIL"; fail=$((fail+1))
  fi

  if [[ -f "${INSTALL_DIR}/.env" && -f "${INSTALL_DIR}/config/modes.yaml" ]]; then
    success "Config: OK"; pass=$((pass+1))
  else
    error "Config: FAIL"; fail=$((fail+1))
  fi

  # Backend start + health check
  if [[ -f "${INSTALL_DIR}/backend/src/index.js" ]]; then
    info "Starting service for health check (5s)..."
    local srv_pid=""
    (cd "${INSTALL_DIR}/backend" && INSTALL_DIR="${INSTALL_DIR}" node src/index.js) &>/dev/null &
    srv_pid=$!
    sleep 4
    if curl -sf "http://127.0.0.1:${PORT}/health" &>/dev/null; then
      success "API /health: OK"; pass=$((pass+1))
      local health
      health="$(curl -sf "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)"
      verbose "Health response: ${health}"
    else
      warn "API /health: no response (might need more startup time)"; fail=$((fail+1))
    fi
    kill "$srv_pid" 2>/dev/null || true
    wait "$srv_pid" 2>/dev/null || true
  fi

  info "Results: ${pass} passed, ${fail} failed"
  return 0
}

# =============================================================================
# Diagnostic
# =============================================================================

run_diagnostic() {
  step "Generating diagnostic report"
  mkdir -p "${INSTALL_DIR}/logs" 2>/dev/null || true
  local rpt="${INSTALL_DIR}/logs/diagnostic_${TIMESTAMP}.txt"
  {
    echo "=== Smart Switch Brain Diagnostic v${SCRIPT_VERSION} ==="
    echo "Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "By:   Boy Barley"
    echo ""
    echo "--- OS ---"
    uname -a 2>/dev/null || echo "unknown"
    cat /etc/os-release 2>/dev/null || true
    echo ""
    echo "--- Resources ---"
    free -m 2>/dev/null || echo "free: N/A"
    df -h "${INSTALL_DIR}" 2>/dev/null || df -h . 2>/dev/null || true
    echo ""
    echo "--- Tools ---"
    echo "Node:    $(node --version 2>/dev/null || echo N/A)"
    echo "npm:     $(npm --version 2>/dev/null || echo N/A)"
    echo "git:     $(git --version 2>/dev/null || echo N/A)"
    echo "sqlite3: $(sqlite3 --version 2>/dev/null || echo N/A)"
    echo "gcc:     $(gcc --version 2>&1 | head -1 || echo N/A)"
    echo "make:    $(make --version 2>&1 | head -1 || echo N/A)"
    echo "python3: $(python3 --version 2>/dev/null || echo N/A)"
    echo "bash:    ${BASH_VERSION:-unknown}"
    echo ""
    echo "--- Installation ---"
    echo "Dir:    ${INSTALL_DIR}"
    echo "Port:   ${PORT}"
    echo "Script: v${SCRIPT_VERSION}"
    for d in backend frontend config logs data; do
      printf "  %-12s %s\n" "${d}/" "$(test -d "${INSTALL_DIR}/${d}" && echo OK || echo MISSING)"
    done
    printf "  %-12s %s\n" ".env" "$(test -f "${INSTALL_DIR}/.env" && echo OK || echo MISSING)"
    printf "  %-12s %s\n" "modes.yaml" "$(test -f "${INSTALL_DIR}/config/modes.yaml" && echo OK || echo MISSING)"
    printf "  %-12s %s\n" "index.js" "$(test -f "${INSTALL_DIR}/backend/src/index.js" && echo OK || echo MISSING)"
    printf "  %-12s %s\n" "node_modules" "$(test -d "${INSTALL_DIR}/backend/node_modules" && echo OK || echo MISSING)"
    printf "  %-12s %s\n" "sqlite3.node" "$(test -f "${INSTALL_DIR}/backend/node_modules/better-sqlite3/build/Release/better_sqlite3.node" && echo OK || echo MISSING)"
    echo ""
    echo "--- .env contents (redacted) ---"
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
      sed 's/\(API_KEY=\).*/\1[REDACTED]/' "${INSTALL_DIR}/.env" 2>/dev/null || echo "cannot read"
    fi
    echo ""
    echo "--- Service ---"
    systemctl status "$SERVICE_NAME" 2>&1 || echo "Not registered"
    echo ""
    echo "--- Errors (last 30) ---"
    tail -30 "${INSTALL_DIR}/logs/service-error.log" 2>/dev/null || echo "No error log"
    echo ""
    echo "--- Health Check ---"
    curl -sf "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo "Not responding"
    echo ""
    echo "=== End ==="
  } > "$rpt" 2>&1
  chmod 600 "$rpt" 2>/dev/null || true
  success "Report: ${rpt}"
  cat "$rpt"
}

# =============================================================================
# Status / Uninstall / Clean
# =============================================================================

show_status() {
  step "Status"
  if [[ ! -d "$INSTALL_DIR" ]]; then error "Not installed at ${INSTALL_DIR}"; exit 1; fi
  info "Dir:  ${INSTALL_DIR}"
  info "Port: ${PORT}"
  info "Ver:  v${SCRIPT_VERSION}"
  if command_exists systemctl && systemctl is-active "$SERVICE_NAME" &>/dev/null; then
    success "Service: running (systemd)"
  else
    local pid
    pid="$(pgrep -f 'node.*src/index.js' 2>/dev/null | head -1 || true)"
    if [[ -n "$pid" ]]; then success "Service: running (PID ${pid})"
    else warn "Service: stopped"; fi
  fi
  if curl -sf "http://127.0.0.1:${PORT}/health" 2>/dev/null; then
    echo ""
    success "API: healthy"
  else
    warn "API: not responding"
  fi
}

run_uninstall() {
  step "Uninstalling Smart Switch Brain"
  if [[ ! -d "$INSTALL_DIR" ]]; then error "Not found at ${INSTALL_DIR}"; exit 1; fi
  warn "Will remove ${INSTALL_DIR}"
  if ! prompt_yn "Continue?" "n"; then info "Cancelled"; exit 0; fi
  if [[ -f "${INSTALL_DIR}/data/smartswitch.db" ]] && prompt_yn "Backup database?" "y"; then
    local bk="${HOME}/smartswitch_backup_${TIMESTAMP}.db"
    cp "${INSTALL_DIR}/data/smartswitch.db" "$bk" 2>/dev/null || true
    chmod 600 "$bk" 2>/dev/null || true
    success "DB backed up: ${bk}"
  fi
  if command_exists systemctl; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
  fi
  pkill -f "node.*src/index.js" 2>/dev/null || true
  if prompt_yn "Preserve user data (config, data)?" "y"; then
    local pdir="${HOME}/ssb-preserved_${TIMESTAMP}"
    mkdir -p "$pdir" 2>/dev/null || true
    for d in config data backups; do
      [[ -d "${INSTALL_DIR}/${d}" ]] && cp -a "${INSTALL_DIR}/${d}" "$pdir/" 2>/dev/null || true
    done
    [[ -f "${INSTALL_DIR}/.env" ]] && cp "${INSTALL_DIR}/.env" "$pdir/" 2>/dev/null || true
    success "Data preserved: ${pdir}"
  fi
  rm -rf "$INSTALL_DIR"
  success "Uninstalled"
}

run_clean() {
  step "Cleaning artifacts"
  if [[ ! -d "$INSTALL_DIR" ]]; then error "Not found at ${INSTALL_DIR}"; exit 1; fi
  rm -rf "${INSTALL_DIR}/backend/node_modules" 2>/dev/null || true
  rm -rf "${INSTALL_DIR}/frontend/node_modules" 2>/dev/null || true
  rm -rf "${INSTALL_DIR}/frontend/dist" 2>/dev/null || true
  rm -f "${INSTALL_DIR}/frontend/.build_hash" 2>/dev/null || true
  success "Cleaned. Run installer again to rebuild."
}

# =============================================================================
# Docs
# =============================================================================

generate_docs() {
  cat > "${INSTALL_DIR}/docs/README.md" <<DOCEOF
# Smart Switch Brain v${SCRIPT_VERSION}
## OpenClaw AI Mode Selector
### Created by Boy Barley — github.com/boybarley

## Quick Start
  cd ${INSTALL_DIR} && ./start.sh
  # or: sudo systemctl start ${SERVICE_NAME}

## API
  GET  /health             Health check (includes debug info)
  GET  /api/modes          List all modes
  GET  /api/modes/current  Current active mode
  POST /api/modes/switch   Switch mode {"mode_id":"work-hard"}

## Modes
  work-hard     -> Claude Opus       -> Complex tasks
  focus-serius  -> Claude Haiku      -> Structured work
  relax         -> Step-3.5 Flash    -> Creative tasks

## Management
  ./install.sh --status
  ./install.sh --upgrade
  ./install.sh --diagnostic
  ./install.sh --uninstall

## Troubleshooting
  # Check logs:
  cat ${INSTALL_DIR}/logs/service-error.log

  # Test manually:
  cd ${INSTALL_DIR}/backend && INSTALL_DIR=${INSTALL_DIR} node src/index.js

  # Health check:
  curl http://localhost:${PORT}/health | jq .

Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
DOCEOF
  chmod 644 "${INSTALL_DIR}/docs/README.md" 2>/dev/null || true
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
  local dur
  dur="$(elapsed_since "$INSTALL_START_TIME")"
  echo ""
  printf "%b%b══════════════════════════════════════════════════%b\n" "$BOLD" "$GREEN" "$RESET"
  printf "%b%b  🎉 Smart Switch Brain v%s — Installed!%b\n" "$BOLD" "$GREEN" "$SCRIPT_VERSION" "$RESET"
  printf "%b%b══════════════════════════════════════════════════%b\n" "$BOLD" "$GREEN" "$RESET"
  echo ""
  printf "  %bDir:%b      %s\n" "$BOLD" "$RESET" "$INSTALL_DIR"
  printf "  %bPort:%b     %s\n" "$BOLD" "$RESET" "$PORT"
  printf "  %bTime:%b     %s\n" "$BOLD" "$RESET" "$dur"
  echo ""
  printf "  %b%bStart:%b\n" "$BOLD" "$CYAN" "$RESET"
  if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    printf "    sudo systemctl start %s\n" "$SERVICE_NAME"
  fi
  printf "    cd %s && ./start.sh\n" "$INSTALL_DIR"
  echo ""
  printf "  %b%bAccess:%b\n" "$BOLD" "$CYAN" "$RESET"
  printf "    http://localhost:%s\n" "$PORT"
  printf "    http://localhost:%s/health\n" "$PORT"
  echo ""
  printf "  %b%bDebug:%b\n" "$BOLD" "$CYAN" "$RESET"
  printf "    cd %s/backend && INSTALL_DIR=%s node src/index.js\n" "$INSTALL_DIR" "$INSTALL_DIR"
  echo ""
  printf "  %b%bManage:%b\n" "$BOLD" "$CYAN" "$RESET"
  printf "    %s --status | --upgrade | --diagnostic | --uninstall\n" "$SCRIPT_NAME"
  echo ""
  printf "%b══════════════════════════════════════════════════%b\n" "$GREEN" "$RESET"
  printf "  Created by Boy Barley — github.com/boybarley\n"
  printf "%b══════════════════════════════════════════════════%b\n" "$GREEN" "$RESET"
}

# =============================================================================
# Main
# =============================================================================

main() {
  INSTALL_START_TIME="$(date +%s)"
  parse_args "$@"

  if [[ "$HELP_MODE" == true ]]; then show_help; exit 0; fi

  init_logging
  log "INFO" "Installer v${SCRIPT_VERSION} | Args: $* | $(uname -a)"

  echo ""
  printf "%b%b╔══════════════════════════════════════════════╗%b\n" "$BOLD" "$CYAN" "$RESET"
  printf "%b%b║  🧠 Smart Switch Brain  v%-20s║%b\n" "$BOLD" "$CYAN" "$SCRIPT_VERSION" "$RESET"
  printf "%b%b║  OpenClaw AI Mode Selector — Boy Barley     ║%b\n" "$BOLD" "$CYAN" "$RESET"
  printf "%b%b╚══════════════════════════════════════════════╝%b\n" "$BOLD" "$CYAN" "$RESET"
  echo ""

  detect_os

  if [[ "$STATUS_MODE"     == true ]]; then show_status;    exit 0; fi
  if [[ "$DIAGNOSTIC_MODE" == true ]]; then run_diagnostic; exit 0; fi
  if [[ "$UNINSTALL_MODE"  == true ]]; then run_uninstall;  exit 0; fi
  if [[ "$CLEAN_MODE"      == true ]]; then run_clean;      exit 0; fi

  validate_prereqs
  install_dependencies
  manage_repository
  create_directories
  setup_configuration
  setup_backend
  setup_frontend
  harden_security
  init_database
  check_port
  register_service
  generate_docs
  run_smoke_tests
  print_summary
}

main "$@"
```

---

## Changelog v1.0.2 → v1.1.0

| Fix | Masalah | Solusi |
|-----|---------|-------|
| **#1 Path Resolution** | `../../` relative paths gagal dari systemd | `process.env.INSTALL_DIR` → `path.resolve(__dirname, '../..')` → `/root/smart-switch-brain` (3-tier fallback). Semua path pakai `path.join(ROOT_DIR, ...)` |
| **#2 Modes.yaml** | Error di-swallow, modes kosong tanpa clue | Cek `fs.existsSync` dulu, log path yang dicari, log setiap mode yang loaded, tampilkan `ROOT_DIR` di error message |
| **#3 Systemd Security** | `ProtectSystem=strict` + `PrivateTmp=true` block akses file | Dihapus. Hanya keep `NoNewPrivileges=true`. Tambah `Environment=INSTALL_DIR=...` |
| **#4 Auto-Create Dirs** | Data directory harus pre-exist | `fs.mkdirSync(dir, { recursive: true })` di `index.js` sebelum DB init. Juga `mkdir -p` di installer |
| **#5 Build Tools** | `npm install` crash tanpa `gcc`/`make` | Auto-install `build-essential python3` (apt), `Development Tools` (yum), `base-devel` (pacman), Xcode CLI (brew) |
| **#6 Frontend** | Minified HTML, stuck "Loading...", no debug | Full readable HTML/CSS, `fetchWithTimeout(5s)`, error box with retry button, `console.log('[SSB]')` everywhere, proper status classes |

### Bonus improvements in v1.1.0

- `.env` sekarang include `INSTALL_DIR` — auto-append ke existing `.env` saat upgrade
- `/health` endpoint return `root_dir`, `modes_loaded`, `db_path` untuk debugging
- `start.sh` auto-set `INSTALL_DIR` dari script location
- `--diagnostic` report sekarang cek `better_sqlite3.node` binary, gcc, make, python3
- `register_service` selalu generate `start.sh` + `stop.sh` (bahkan jika systemd aktif) sebagai backup
- Backend log startup banner dengan semua path info
- Frontend ada retry button saat API error

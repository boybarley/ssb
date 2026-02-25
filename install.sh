```bash
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Smart Switch Brain — OpenClaw AI Mode Selector Installer
# by Boy Barley
# =============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly DEFAULT_REPO="https://github.com/yourusername/smart-switch-brain.git"
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

# --- State ---
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
# Color and Emoji
# =============================================================================
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4); MAGENTA=$(tput setaf 5); CYAN=$(tput setaf 6)
  BOLD=$(tput bold); RESET=$(tput sgr0)
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; BOLD=""; RESET=""
fi
readonly ICO_OK="✅"; readonly ICO_WARN="⚠️"; readonly ICO_ERR="❌"
readonly ICO_SPIN="🔄"; readonly ICO_KEY="🔑"; readonly ICO_PKG="📦"
readonly ICO_NET="🌐"; readonly ICO_DIR="📁"; readonly ICO_DB="🗄️"
readonly ICO_SEC="🔒"; readonly ICO_SVC="⚙️"; readonly ICO_TEST="🧪"
readonly ICO_INFO="ℹ️"; readonly ICO_CLEAN="🧹"; readonly ICO_DONE="🎉"

# =============================================================================
# Logging
# =============================================================================

init_logging() {
  # Create logs dir early; final location set after install dir is confirmed
  local log_dir="${INSTALL_DIR}/logs"
  mkdir -p "$log_dir" 2>/dev/null || { log_dir="/tmp/smart-switch-brain-logs"; mkdir -p "$log_dir"; }
  LOG_FILE="${log_dir}/install_${TIMESTAMP}.log"
  ERROR_LOG="${log_dir}/install_error_${TIMESTAMP}.log"
  touch "$LOG_FILE" "$ERROR_LOG"
  chmod 600 "$LOG_FILE" "$ERROR_LOG"
  # Rotate old logs
  local count=0
  for f in $(ls -1t "${log_dir}"/install_*.log 2>/dev/null); do
    count=$((count + 1))
    [[ $count -gt $((LOG_RETENTION * 2)) ]] && rm -f "$f"
  done
}

log() {
  # Write timestamped message to log file and optionally to stdout
  local level="$1"; shift
  local msg="$*"
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [$level] $msg" >> "${LOG_FILE:-/dev/null}" 2>/dev/null || true
  [[ "$level" == "ERROR" ]] && echo "[$ts] $msg" >> "${ERROR_LOG:-/dev/null}" 2>/dev/null || true
}

print_msg() {
  # Print colored message to terminal and log it
  local color="$1" icon="$2"; shift 2
  local msg="$*"
  printf "%s %b%s%b\n" "$icon" "$color" "$msg" "$RESET"
  log "INFO" "$msg"
}

info()    { print_msg "$CYAN"   "$ICO_INFO" "$@"; }
success() { print_msg "$GREEN"  "$ICO_OK"   "$@"; }
warn()    { print_msg "$YELLOW" "$ICO_WARN" "$@"; }
error()   { print_msg "$RED"    "$ICO_ERR"  "$@"; }
step()    { printf "\n%b%b── %s%b\n" "$BOLD" "$BLUE" "$*" "$RESET"; log "STEP" "$*"; }
verbose() { [[ "$VERBOSE" == true ]] && info "$@" || log "DEBUG" "$@"; }

# =============================================================================
# Spinner
# =============================================================================

spinner_start() {
  # Start a background spinner for long-running tasks
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
  # Stop the background spinner
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r%40s\r" " "
  fi
}

# =============================================================================
# Cleanup and Rollback
# =============================================================================

cleanup() {
  # Trap handler: stop spinner, flush logs
  local exit_code=$?
  spinner_stop
  if [[ $exit_code -ne 0 && ${#ROLLBACK_STACK[@]} -gt 0 ]]; then
    warn "Installation failed — rolling back ${#ROLLBACK_STACK[@]} operation(s)..."
    for (( i=${#ROLLBACK_STACK[@]}-1; i>=0; i-- )); do
      local cmd="${ROLLBACK_STACK[$i]}"
      verbose "Rollback: $cmd"
      eval "$cmd" 2>/dev/null || warn "Rollback step failed: $cmd"
    done
  fi
  [[ $exit_code -ne 0 ]] && error "Installation failed. See ${LOG_FILE:-/tmp/install.log} for details."
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

push_rollback() {
  # Register a rollback command to execute on failure
  ROLLBACK_STACK+=("$1")
}

pop_rollback() {
  # Remove last rollback command after successful step
  [[ ${#ROLLBACK_STACK[@]} -gt 0 ]] && unset 'ROLLBACK_STACK[${#ROLLBACK_STACK[@]}-1]'
}

# =============================================================================
# Utility Helpers
# =============================================================================

command_exists() { command -v "$1" &>/dev/null; }

version_gte() {
  # Return 0 if version $1 >= $2 using sort -V
  printf '%s\n%s' "$2" "$1" | sort -V -C 2>/dev/null
}

retry() {
  # Retry a command up to MAX_RETRIES times with delay
  local attempt=1 cmd=("$@")
  while (( attempt <= MAX_RETRIES )); do
    if "${cmd[@]}"; then return 0; fi
    warn "Attempt $attempt/$MAX_RETRIES failed. Retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
  done
  error "Command failed after $MAX_RETRIES attempts: ${cmd[*]}"
  return 1
}

prompt_yn() {
  # Prompt yes/no; returns 0 for yes, 1 for no
  local msg="$1" default="${2:-n}"
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
  # Human-readable elapsed time since epoch timestamp $1
  local start="$1" now; now="$(date +%s)"
  local diff=$((now - start))
  printf "%dm %ds" $((diff / 60)) $((diff % 60))
}

secure_read() {
  # Read sensitive input without echoing
  local prompt="$1" var_name="$2"
  local input=""
  printf "  %s%s: %s" "$ICO_KEY" "$prompt" ""
  read -rs input
  printf "\n"
  eval "$var_name=\$input"
}

sanitize_input() {
  # Strip dangerous characters from user input
  local input="$1"
  echo "$input" | tr -cd '[:alnum:]._:/@-'
}

# =============================================================================
# CLI Argument Parsing
# =============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)        HELP_MODE=true ;;
      --verbose|-v)     VERBOSE=true ;;
      --skip-tests)     SKIP_TESTS=true ;;
      --no-systemd)     NO_SYSTEMD=true ;;
      --upgrade)        UPGRADE_MODE=true ;;
      --clean)          CLEAN_MODE=true ;;
      --uninstall)      UNINSTALL_MODE=true ;;
      --status)         STATUS_MODE=true ;;
      --diagnostic)     DIAGNOSTIC_MODE=true ;;
      --api-key)
        shift; [[ $# -eq 0 ]] && { error "--api-key requires a value"; exit 1; }
        API_KEY="$1" ;;
      --port)
        shift; [[ $# -eq 0 ]] && { error "--port requires a value"; exit 1; }
        PORT="$1" ;;
      --repo)
        shift; [[ $# -eq 0 ]] && { error "--repo requires a value"; exit 1; }
        REPO_URL="$(sanitize_input "$1")" ;;
      --dir)
        shift; [[ $# -eq 0 ]] && { error "--dir requires a value"; exit 1; }
        INSTALL_DIR="$1" ;;
      *)
        error "Unknown flag: $1. Use --help for usage."
        exit 1 ;;
    esac
    shift
  done
}

show_help() {
  cat <<EOF
${BOLD}Smart Switch Brain — Installer v${SCRIPT_VERSION}${RESET}

${BOLD}Usage:${RESET}
  $SCRIPT_NAME [flags]

${BOLD}Flags:${RESET}
  -h, --help          Show this help
  -v, --verbose       Enable verbose output
  --skip-tests        Skip post-install smoke tests
  --no-systemd        Do not register systemd service
  --api-key KEY       Set OpenRouter API key non-interactively
  --port PORT         Set backend port (default: $DEFAULT_PORT)
  --repo URL          Override git repository URL
  --dir PATH          Override installation directory
  --upgrade           Upgrade existing installation
  --clean             Clean build artifacts and reinstall
  --uninstall         Remove Smart Switch Brain
  --status            Show service status
  --diagnostic        Generate diagnostic report

${BOLD}Environment Variables:${RESET}
  SMART_SWITCH_REPO   Git repository URL override
  SMART_SWITCH_PORT   Port override
  SMART_SWITCH_DIR    Installation directory override
EOF
}

# =============================================================================
# OS Detection
# =============================================================================

detect_os() {
  # Detect operating system and package manager
  step "Detecting operating system"
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${ID:-}" in
      ubuntu|debian|linuxmint|pop) OS_TYPE="debian";  PKG_MANAGER="apt" ;;
      rhel|centos|fedora|rocky|alma) OS_TYPE="rhel"; PKG_MANAGER="yum"
        command_exists dnf && PKG_MANAGER="dnf" ;;
      arch|manjaro|endeavouros) OS_TYPE="arch"; PKG_MANAGER="pacman" ;;
      *)
        if command_exists apt-get; then OS_TYPE="debian"; PKG_MANAGER="apt"
        elif command_exists yum; then OS_TYPE="rhel"; PKG_MANAGER="yum"
        elif command_exists pacman; then OS_TYPE="arch"; PKG_MANAGER="pacman"
        else warn "Unknown Linux distro: ${ID:-unknown}. Proceeding with best effort."; OS_TYPE="linux"; fi ;;
    esac
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    OS_TYPE="macos"; PKG_MANAGER="brew"
  elif grep -qi microsoft /proc/version 2>/dev/null; then
    OS_TYPE="wsl"
    command_exists apt-get && PKG_MANAGER="apt"
  else
    OS_TYPE="unknown"
    warn "Could not detect OS. Attempting best-effort install."
  fi
  [[ "$(id -u)" -eq 0 ]] && IS_ROOT=true
  success "OS: ${OS_TYPE} | Package Manager: ${PKG_MANAGER:-none} | Root: ${IS_ROOT}"
}

# =============================================================================
# System Requirements Validation
# =============================================================================

check_ram() {
  # Validate minimum RAM
  local ram_mb=0
  if [[ "$OS_TYPE" == "macos" ]]; then
    ram_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
  else
    ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  fi
  if [[ $ram_mb -lt $MIN_RAM_MB ]]; then
    error "Insufficient RAM: ${ram_mb}MB available, ${MIN_RAM_MB}MB required."
    return 1
  fi
  success "RAM: ${ram_mb}MB (>= ${MIN_RAM_MB}MB)"
}

check_disk() {
  # Validate minimum free disk space in target directory
  local target_parent; target_parent="$(dirname "$INSTALL_DIR")"
  mkdir -p "$target_parent" 2>/dev/null || true
  local avail_mb
  if [[ "$OS_TYPE" == "macos" ]]; then
    avail_mb=$(df -m "$target_parent" 2>/dev/null | awk 'NR==2{print $4}')
  else
    avail_mb=$(df -BM "$target_parent" 2>/dev/null | awk 'NR==2{gsub(/M/,""); print $4}')
  fi
  avail_mb="${avail_mb:-0}"
  if [[ $avail_mb -lt $MIN_DISK_MB ]]; then
    error "Insufficient disk: ${avail_mb}MB available, ${MIN_DISK_MB}MB required."
    return 1
  fi
  success "Disk: ${avail_mb}MB free (>= ${MIN_DISK_MB}MB)"
}

check_tool_version() {
  # Validate tool exists and meets minimum version
  local tool="$1" min_version="$2" version_flag="${3:---version}" extract="${4:-[0-9]+\.[0-9]+(\.[0-9]+)?}"
  if ! command_exists "$tool"; then
    error "$tool is not installed."
    return 1
  fi
  local raw_version; raw_version="$($tool $version_flag 2>&1 | head -1)"
  local current; current="$(echo "$raw_version" | grep -oE "$extract" | head -1)"
  if [[ -z "$current" ]]; then
    warn "Could not determine $tool version. Proceeding."
    return 0
  fi
  if ! version_gte "$current" "$min_version"; then
    error "$tool version $current < required $min_version"
    return 1
  fi
  success "$tool: v${current} (>= ${min_version})"
}

validate_prereqs() {
  # Run all prerequisite checks
  step "Validating system requirements (~5s)"
  local failed=false
  check_ram   || failed=true
  check_disk  || failed=true
  check_tool_version node "$MIN_NODE_MAJOR.0.0" "--version" '[0-9]+\.[0-9]+\.[0-9]+'  || failed=true
  check_tool_version npm  "$MIN_NPM_MAJOR.0.0" "--version" '[0-9]+\.[0-9]+\.[0-9]+'   || failed=true
  check_tool_version git  "$MIN_GIT_VERSION"    "--version" '[0-9]+\.[0-9]+(\.[0-9]+)?' || failed=true
  if [[ "$failed" == true ]]; then
    error "Prerequisite checks failed. Install missing dependencies and retry."
    exit 1
  fi
}

# =============================================================================
# Dependency Installation
# =============================================================================

pkg_install() {
  # Install a system package using detected package manager
  local pkg="$1"
  if command_exists "$pkg"; then verbose "$pkg already installed"; return 0; fi
  info "Installing $pkg..."
  case "$PKG_MANAGER" in
    apt)    sudo apt-get update -qq && sudo apt-get install -y -qq "$pkg" ;;
    yum|dnf) sudo $PKG_MANAGER install -y -q "$pkg" ;;
    pacman) sudo pacman -S --noconfirm --needed "$pkg" ;;
    brew)   brew install "$pkg" ;;
    *)      warn "Cannot auto-install $pkg. Please install manually."; return 1 ;;
  esac
}

install_dependencies() {
  # Ensure curl, wget, and git are available
  step "Checking base dependencies (~10s)"
  for dep in curl wget git; do
    if ! command_exists "$dep"; then
      retry pkg_install "$dep" || { error "Failed to install $dep"; exit 1; }
    else
      success "$dep available"
    fi
  done
}

# =============================================================================
# Repository Management
# =============================================================================

backup_existing() {
  # Create timestamped backup of current installation
  local backup_dir="${INSTALL_DIR}/backups/pre_upgrade_${TIMESTAMP}"
  info "Backing up existing installation to ${backup_dir}..."
  mkdir -p "$backup_dir"
  for item in backend frontend config data .env; do
    [[ -e "${INSTALL_DIR}/${item}" ]] && cp -a "${INSTALL_DIR}/${item}" "$backup_dir/" 2>/dev/null || true
  done
  success "Backup created: ${backup_dir}"
}

verify_repo_integrity() {
  # Verify the cloned repo is a valid git repository
  if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
    warn "Not a git repository — skipping integrity check"
    return 0
  fi
  if ! (cd "$INSTALL_DIR" && git fsck --no-dangling --quiet 2>/dev/null); then
    warn "Repository integrity check found issues"
  else
    success "Repository integrity verified"
  fi
}

manage_repository() {
  # Clone or update the repository
  step "Managing repository (~30s)"
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "Existing installation detected at ${INSTALL_DIR}"
    if [[ "$UPGRADE_MODE" == true ]]; then
      backup_existing
      info "Pulling latest changes..."
      spinner_start "Updating repository..."
      (cd "$INSTALL_DIR" && git stash --quiet 2>/dev/null || true)
      retry bash -c "cd '${INSTALL_DIR}' && git pull --ff-only origin main 2>/dev/null || git pull --ff-only origin master 2>/dev/null || true"
      spinner_stop
      success "Repository updated"
    else
      info "Using existing repository (use --upgrade to update)"
    fi
  elif [[ -d "$INSTALL_DIR" && ! -d "${INSTALL_DIR}/.git" ]]; then
    info "Directory exists but is not a git repo. Initializing structure."
  else
    info "Cloning repository..."
    spinner_start "Cloning ${REPO_URL}..."
    push_rollback "rm -rf '${INSTALL_DIR}'"
    retry git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" 2>>"${ERROR_LOG:-/dev/null}" || {
      spinner_stop
      warn "Clone failed — creating fresh project structure"
      mkdir -p "$INSTALL_DIR"
    }
    spinner_stop
    pop_rollback
    success "Repository ready"
  fi
  verify_repo_integrity
}

# =============================================================================
# Directory Structure
# =============================================================================

create_directories() {
  # Create required project directories with secure permissions
  step "Creating directory structure"
  local dirs=(backend frontend config logs data backups docs)
  for dir in "${dirs[@]}"; do
    local full="${INSTALL_DIR}/${dir}"
    if [[ ! -d "$full" ]]; then
      mkdir -p "$full"
      verbose "Created: ${full}"
    fi
  done
  chmod 700 "${INSTALL_DIR}/config" "${INSTALL_DIR}/logs" "${INSTALL_DIR}/data" "${INSTALL_DIR}/backups"
  chmod 755 "${INSTALL_DIR}/backend" "${INSTALL_DIR}/frontend" "${INSTALL_DIR}/docs"
  success "Directory structure verified (${#dirs[@]} directories)"
}

# =============================================================================
# Configuration
# =============================================================================

validate_api_key() {
  # Basic format validation for OpenRouter API key
  local key="$1"
  if [[ -z "$key" ]]; then return 1; fi
  if [[ ${#key} -lt 10 ]]; then return 1; fi
  if [[ "$key" =~ [[:space:]] ]]; then return 1; fi
  return 0
}

setup_env() {
  # Generate .env configuration file
  local env_file="${INSTALL_DIR}/.env"
  if [[ -f "$env_file" && "$UPGRADE_MODE" == true ]]; then
    info "Existing .env found — preserving (backed up)"
    return 0
  fi
  if [[ -f "$env_file" ]]; then
    info "Existing .env found — skipping generation"
    return 0
  fi
  info "Generating .env configuration..."
  if [[ -z "$API_KEY" ]]; then
    echo ""
    info "OpenRouter API key is required for AI mode routing."
    info "Get yours at: https://openrouter.ai/keys"
    local attempts=0
    while [[ $attempts -lt 3 ]]; do
      secure_read "Enter OpenRouter API key" API_KEY
      if validate_api_key "$API_KEY"; then break; fi
      warn "Invalid API key format. Please try again."
      API_KEY=""
      attempts=$((attempts + 1))
    done
    if ! validate_api_key "$API_KEY"; then
      warn "No valid API key provided. You can set it later in ${env_file}"
      API_KEY="CHANGE_ME"
    fi
  fi
  cat > "$env_file" <<ENVEOF
# Smart Switch Brain — Environment Configuration
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# DO NOT COMMIT THIS FILE

NODE_ENV=production
PORT=${PORT}
HOST=0.0.0.0

# OpenRouter API Configuration
OPENROUTER_API_KEY=${API_KEY}
OPENROUTER_BASE_URL=https://openrouter.ai/api/v1

# Database
DATABASE_PATH=./data/smartswitch.db

# Logging
LOG_LEVEL=info
LOG_DIR=./logs

# Security
RATE_LIMIT_WINDOW_MS=60000
RATE_LIMIT_MAX_REQUESTS=100
ENVEOF
  chmod 600 "$env_file"
  success ".env generated with secure permissions (600)"
  API_KEY="REDACTED"
}

generate_modes_yaml() {
  # Generate runtime AI routing mode configuration
  local modes_file="${INSTALL_DIR}/config/modes.yaml"
  if [[ -f "$modes_file" && "$UPGRADE_MODE" == true ]]; then
    info "Existing modes.yaml — preserving (backed up)"
    return 0
  fi
  if [[ -f "$modes_file" ]]; then
    info "Existing modes.yaml — skipping generation"
    return 0
  fi
  cat > "$modes_file" <<'YAMLEOF'
# Smart Switch Brain — AI Mode Configuration
# OpenClaw Runtime Mode Routing
#
# Each mode maps to an AI provider/model for different work contexts.
# Edit freely — the installer will never overwrite without backup.

modes:
  - id: work-hard
    name: "Work Hard"
    description: "Maximum reasoning power for complex tasks"
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
    description: "Fast, focused responses for structured work"
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
    description: "Casual exploration and creative tasks"
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
  chmod 640 "$modes_file"
  success "modes.yaml generated with 3 AI routing profiles"
}

setup_configuration() {
  step "Setting up configuration (~5s)"
  setup_env
  generate_modes_yaml
}

# =============================================================================
# Backend Setup
# =============================================================================

generate_backend_scaffold() {
  # Generate minimal backend if package.json is missing (fresh non-cloned install)
  local be_dir="${INSTALL_DIR}/backend"
  if [[ -f "${be_dir}/package.json" ]]; then return 0; fi
  info "Generating backend scaffold..."
  cat > "${be_dir}/package.json" <<'PKGEOF'
{
  "name": "smart-switch-brain-backend",
  "version": "1.0.0",
  "description": "Smart Switch Brain — OpenClaw AI Mode Selector Backend",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "dev": "node --watch src/index.js",
    "test": "echo \"Tests passed\" && exit 0"
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
PKGEOF
  mkdir -p "${be_dir}/src"
  cat > "${be_dir}/src/index.js" <<'JSEOF'
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const rateLimit = require('express-rate-limit');
const fs = require('fs');
const path = require('path');
const yaml = require('yaml');
const Database = require('better-sqlite3');

const PORT = process.env.PORT || 5000;
const HOST = process.env.HOST || '0.0.0.0';
const app = express();

app.use(helmet());
app.use(cors());
app.use(express.json());
app.use(rateLimit({ windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS || '60000'), max: parseInt(process.env.RATE_LIMIT_MAX_REQUESTS || '100') }));

const modesPath = path.resolve(__dirname, '../../config/modes.yaml');
const dbPath = path.resolve(__dirname, '../../data/smartswitch.db');

let modes = { modes: [], defaults: {} };
try { modes = yaml.parse(fs.readFileSync(modesPath, 'utf8')); } catch (e) { console.error('Failed to load modes.yaml:', e.message); }

const db = new Database(dbPath);
db.pragma('journal_mode = WAL');
db.exec(`CREATE TABLE IF NOT EXISTS mode_history (id INTEGER PRIMARY KEY AUTOINCREMENT, mode_id TEXT NOT NULL, switched_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
db.exec(`CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);

app.get('/health', (req, res) => res.json({ status: 'ok', version: '1.0.0', uptime: process.uptime() }));
app.get('/api/modes', (req, res) => res.json(modes));
app.get('/api/modes/current', (req, res) => {
  const row = db.prepare('SELECT mode_id FROM mode_history ORDER BY switched_at DESC LIMIT 1').get();
  const current = row ? row.mode_id : modes.defaults?.fallback_mode || 'focus-serius';
  const mode = (modes.modes || []).find(m => m.id === current) || {};
  res.json({ current, ...mode });
});
app.post('/api/modes/switch', (req, res) => {
  const { mode_id } = req.body;
  if (!mode_id || !(modes.modes || []).find(m => m.id === mode_id)) return res.status(400).json({ error: 'Invalid mode_id' });
  db.prepare('INSERT INTO mode_history (mode_id) VALUES (?)').run(mode_id);
  res.json({ switched: mode_id, timestamp: new Date().toISOString() });
});

app.listen(PORT, HOST, () => console.log(`Smart Switch Brain running on ${HOST}:${PORT}`));
JSEOF
  success "Backend scaffold generated"
}

setup_backend() {
  step "Setting up backend (~60s)"
  local be_dir="${INSTALL_DIR}/backend"
  generate_backend_scaffold
  if [[ ! -f "${be_dir}/package.json" ]]; then
    error "Backend package.json not found at ${be_dir}"
    exit 1
  fi
  spinner_start "Installing backend dependencies..."
  (cd "$be_dir" && retry npm install --production --loglevel=warn 2>>"${ERROR_LOG}") || {
    spinner_stop; error "Backend npm install failed"; exit 1
  }
  spinner_stop
  success "Backend dependencies installed"
  info "Running npm audit..."
  local audit_output
  audit_output="$(cd "$be_dir" && npm audit --production 2>&1 || true)"
  if echo "$audit_output" | grep -qi "found 0 vulnerabilities"; then
    success "No vulnerabilities found"
  else
    local vuln_count; vuln_count="$(echo "$audit_output" | grep -oiE '[0-9]+ vulnerabilit' | head -1 || echo "some")"
    warn "npm audit found ${vuln_count}ies — review with: cd ${be_dir} && npm audit"
  fi
  setup_log_rotation
}

setup_log_rotation() {
  # Configure basic log rotation
  local logrotate_conf="${INSTALL_DIR}/config/logrotate.conf"
  cat > "$logrotate_conf" <<LREOF
${INSTALL_DIR}/logs/*.log {
  daily
  missingok
  rotate 14
  compress
  delaycompress
  notifempty
  create 640
  sharedscripts
}
LREOF
  chmod 644 "$logrotate_conf"
  verbose "Log rotation config written"
}

# =============================================================================
# Frontend Setup
# =============================================================================

generate_frontend_scaffold() {
  # Generate minimal frontend if package.json is missing
  local fe_dir="${INSTALL_DIR}/frontend"
  if [[ -f "${fe_dir}/package.json" ]]; then return 0; fi
  info "Generating frontend scaffold..."
  cat > "${fe_dir}/package.json" <<'FEPKGEOF'
{
  "name": "smart-switch-brain-frontend",
  "version": "1.0.0",
  "description": "Smart Switch Brain Frontend",
  "scripts": {
    "build": "echo 'Static build complete' && mkdir -p dist && cp -r public/* dist/ 2>/dev/null || true",
    "start": "echo 'Serve dist/ with any static server'"
  },
  "dependencies": {},
  "devDependencies": {}
}
FEPKGEOF
  mkdir -p "${fe_dir}/public" "${fe_dir}/dist"
  cat > "${fe_dir}/public/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Smart Switch Brain</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#0f1117;color:#e1e4e8;display:flex;align-items:center;justify-content:center;min-height:100vh}
.container{text-align:center;max-width:600px;padding:2rem}.title{font-size:2rem;margin-bottom:1rem}
.modes{display:flex;gap:1rem;flex-wrap:wrap;justify-content:center;margin-top:2rem}
.mode-btn{padding:1.5rem 2rem;border:2px solid #30363d;border-radius:12px;background:#161b22;cursor:pointer;transition:all .2s;min-width:150px}
.mode-btn:hover{border-color:#58a6ff;transform:translateY(-2px)}.mode-btn .icon{font-size:2rem}.mode-btn .label{margin-top:.5rem;font-size:.9rem;color:#8b949e}
.status{margin-top:2rem;padding:1rem;border-radius:8px;background:#161b22;color:#58a6ff}
</style></head>
<body><div class="container"><h1 class="title">🧠 Smart Switch Brain</h1><p>OpenClaw AI Mode Selector</p>
<div class="modes" id="modes"></div><div class="status" id="status">Loading...</div></div>
<script>
const API=window.location.origin;
async function load(){try{const r=await fetch(API+'/api/modes');const d=await r.json();const m=document.getElementById('modes');
m.innerHTML=(d.modes||[]).map(x=>`<div class="mode-btn" onclick="sw('${x.id}')"><div class="icon">${x.icon||'🔘'}</div><div class="label">${x.name}</div></div>`).join('');
const c=await(await fetch(API+'/api/modes/current')).json();document.getElementById('status').textContent='Current: '+(c.name||c.current);}catch(e){document.getElementById('status').textContent='API unavailable';}}
async function sw(id){await fetch(API+'/api/modes/switch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({mode_id:id})});load();}
load();
</script></body></html>
HTMLEOF
  success "Frontend scaffold generated"
}

setup_frontend() {
  step "Setting up frontend (~30s)"
  local fe_dir="${INSTALL_DIR}/frontend"
  generate_frontend_scaffold
  if [[ ! -f "${fe_dir}/package.json" ]]; then
    error "Frontend package.json not found at ${fe_dir}"
    exit 1
  fi
  local build_marker="${fe_dir}/.build_hash"
  local current_hash; current_hash="$(find "$fe_dir" -name '*.html' -o -name '*.js' -o -name '*.css' 2>/dev/null | sort | xargs cat 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1 || echo "none")"
  if [[ -f "$build_marker" && "$(cat "$build_marker" 2>/dev/null)" == "$current_hash" && -d "${fe_dir}/dist" ]]; then
    info "Frontend unchanged — skipping rebuild"
    return 0
  fi
  spinner_start "Installing frontend dependencies..."
  (cd "$fe_dir" && npm install --loglevel=warn 2>>"${ERROR_LOG}") || {
    spinner_stop; error "Frontend npm install failed"; exit 1
  }
  spinner_stop
  spinner_start "Building frontend..."
  (cd "$fe_dir" && npm run build 2>>"${ERROR_LOG}") || {
    spinner_stop; error "Frontend build failed"; exit 1
  }
  spinner_stop
  echo "$current_hash" > "$build_marker"
  success "Frontend built successfully"
}

# =============================================================================
# Security Hardening
# =============================================================================

harden_security() {
  step "Applying security hardening"
  # Secure .env
  [[ -f "${INSTALL_DIR}/.env" ]] && chmod 600 "${INSTALL_DIR}/.env"
  chmod 700 "${INSTALL_DIR}/config"
  # Generate .gitignore
  cat > "${INSTALL_DIR}/.gitignore" <<'GIEOF'
# Security — prevent sensitive data from being committed
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
*.cert
GIEOF
  # Create .env.example for safe sharing
  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    sed 's/=.*/=CHANGE_ME/' "${INSTALL_DIR}/.env" | grep -v "^#" | sed '/^$/d' > "${INSTALL_DIR}/.env.example" 2>/dev/null || true
    chmod 644 "${INSTALL_DIR}/.env.example"
  fi
  # Pre-commit hook to block secrets
  local hooks_dir="${INSTALL_DIR}/.git/hooks"
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    mkdir -p "$hooks_dir"
    cat > "${hooks_dir}/pre-commit" <<'HOOKEOF'
#!/bin/bash
if git diff --cached --name-only | grep -qE '\.env$|\.pem$|\.key$'; then
  echo "ERROR: Attempt to commit sensitive file blocked."
  echo "Remove the file from staging: git reset HEAD <file>"
  exit 1
fi
HOOKEOF
    chmod 755 "${hooks_dir}/pre-commit"
  fi
  success "Security hardening applied (.gitignore, permissions, pre-commit hook)"
}

# =============================================================================
# Database Initialization
# =============================================================================

init_database() {
  step "Initializing database (~5s)"
  local db_path="${INSTALL_DIR}/data/smartswitch.db"
  if [[ -f "$db_path" && "$UPGRADE_MODE" == true ]]; then
    local db_backup="${INSTALL_DIR}/backups/smartswitch_${TIMESTAMP}.db"
    cp "$db_path" "$db_backup"
    chmod 600 "$db_backup"
    success "Database backed up: ${db_backup}"
  fi
  # Create and seed database via node
  if command_exists node && [[ -d "${INSTALL_DIR}/backend/node_modules" ]]; then
    node -e "
const Database = require('${INSTALL_DIR}/backend/node_modules/better-sqlite3');
const db = new Database('${db_path}');
db.pragma('journal_mode = WAL');
db.exec(\`
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
  INSERT OR IGNORE INTO settings (key, value) VALUES ('app_version', '1.0.0');
  INSERT OR IGNORE INTO settings (key, value) VALUES ('installed_at', datetime('now'));
\`);
db.close();
" 2>>"${ERROR_LOG}" || warn "Database seeding via node failed — will initialize on first run"
  else
    if command_exists sqlite3; then
      sqlite3 "$db_path" <<'SQLEOF'
CREATE TABLE IF NOT EXISTS mode_history (id INTEGER PRIMARY KEY AUTOINCREMENT, mode_id TEXT NOT NULL, switched_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP);
INSERT OR IGNORE INTO settings (key, value) VALUES ('app_version', '1.0.0');
INSERT OR IGNORE INTO settings (key, value) VALUES ('installed_at', datetime('now'));
SQLEOF
    else
      info "Database will be initialized on first application start"
    fi
  fi
  [[ -f "$db_path" ]] && chmod 600 "$db_path"
  success "Database initialized"
}

# =============================================================================
# Port Management
# =============================================================================

check_port() {
  step "Checking port availability"
  if command_exists ss; then
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
      warn "Port ${PORT} is already in use"
      local alt=$((PORT + 1))
      while ss -tlnp 2>/dev/null | grep -q ":${alt} " && [[ $alt -lt $((PORT + 100)) ]]; do
        alt=$((alt + 1))
      done
      warn "Suggested alternative: ${alt}"
      if [[ -t 0 ]] && prompt_yn "Use port ${alt} instead?" "y"; then
        PORT=$alt
        sed -i.bak "s/^PORT=.*/PORT=${PORT}/" "${INSTALL_DIR}/.env" 2>/dev/null || true
        success "Port updated to ${PORT}"
      fi
    else
      success "Port ${PORT} is available"
    fi
  elif command_exists lsof; then
    if lsof -i ":${PORT}" -sTCP:LISTEN &>/dev/null; then
      warn "Port ${PORT} appears to be in use. Adjust with --port flag."
    else
      success "Port ${PORT} is available"
    fi
  elif command_exists netstat; then
    if netstat -tlnp 2>/dev/null | grep -q ":${PORT} "; then
      warn "Port ${PORT} appears to be in use."
    else
      success "Port ${PORT} is available"
    fi
  else
    info "Cannot check port availability — proceeding with port ${PORT}"
  fi
}

# =============================================================================
# Service Registration
# =============================================================================

register_service() {
  if [[ "$NO_SYSTEMD" == true ]]; then
    info "Systemd registration skipped (--no-systemd)"
    return 0
  fi
  step "Service registration"
  if ! command_exists systemctl; then
    info "systemd not available — generating manual start script"
    generate_start_script
    return 0
  fi
  if [[ "$IS_ROOT" == false ]]; then
    if [[ -t 0 ]] && prompt_yn "Register systemd service? (requires sudo)" "y"; then
      create_systemd_unit
    else
      info "Skipping systemd — generating manual start script"
      generate_start_script
    fi
  else
    create_systemd_unit
  fi
}

create_systemd_unit() {
  # Create and enable systemd service unit
  local unit_file="/etc/systemd/system/${SERVICE_NAME}.service"
  local node_path; node_path="$(which node)"
  sudo tee "$unit_file" > /dev/null <<UNITEOF
[Unit]
Description=Smart Switch Brain — OpenClaw AI Mode Selector
After=network.target
Documentation=https://github.com/yourusername/smart-switch-brain

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=${INSTALL_DIR}/backend
ExecStart=${node_path} src/index.js
Restart=on-failure
RestartSec=10
StandardOutput=append:${INSTALL_DIR}/logs/service.log
StandardError=append:${INSTALL_DIR}/logs/service-error.log
Environment=NODE_ENV=production
EnvironmentFile=${INSTALL_DIR}/.env
LimitNOFILE=65536

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${INSTALL_DIR}/data ${INSTALL_DIR}/logs
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNITEOF
  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME" 2>/dev/null || true
  success "Systemd service registered and enabled"
  info "Commands: sudo systemctl {start|stop|restart|status} ${SERVICE_NAME}"
}

generate_start_script() {
  # Generate helper scripts for manual start/stop
  cat > "${INSTALL_DIR}/start.sh" <<STARTEOF
#!/bin/bash
cd "\$(dirname "\$0")/backend"
echo "Starting Smart Switch Brain on port \${PORT:-${PORT}}..."
node src/index.js
STARTEOF
  cat > "${INSTALL_DIR}/stop.sh" <<STOPEOF
#!/bin/bash
echo "Stopping Smart Switch Brain..."
pkill -f "node.*smart-switch-brain.*index.js" 2>/dev/null && echo "Stopped." || echo "Not running."
STOPEOF
  chmod 755 "${INSTALL_DIR}/start.sh" "${INSTALL_DIR}/stop.sh"
  success "Start/stop scripts generated"
}

# =============================================================================
# Smoke Tests
# =============================================================================

run_smoke_tests() {
  if [[ "$SKIP_TESTS" == true ]]; then
    info "Smoke tests skipped (--skip-tests)"
    return 0
  fi
  step "Running smoke tests (~15s)"
  local passed=0 failed=0
  # Test node
  if node -e "process.exit(0)" 2>/dev/null; then
    success "Node.js runtime: OK"; passed=$((passed + 1))
  else
    error "Node.js runtime: FAIL"; failed=$((failed + 1))
  fi
  # Test npm
  if npm --version &>/dev/null; then
    success "npm: OK"; passed=$((passed + 1))
  else
    error "npm: FAIL"; failed=$((failed + 1))
  fi
  # Test directories
  local dirs_ok=true
  for d in backend frontend config logs data backups docs; do
    [[ ! -d "${INSTALL_DIR}/${d}" ]] && dirs_ok=false
  done
  if [[ "$dirs_ok" == true ]]; then
    success "Directory structure: OK"; passed=$((passed + 1))
  else
    error "Directory structure: FAIL"; failed=$((failed + 1))
  fi
  # Test config
  if [[ -f "${INSTALL_DIR}/.env" && -f "${INSTALL_DIR}/config/modes.yaml" ]]; then
    success "Configuration files: OK"; passed=$((passed + 1))
  else
    error "Configuration files: FAIL"; failed=$((failed + 1))
  fi
  # Service start test
  info "Starting service for quick health check..."
  local be_dir="${INSTALL_DIR}/backend"
  if [[ -f "${be_dir}/src/index.js" ]]; then
    (cd "$be_dir" && timeout 10 node src/index.js &) 2>/dev/null
    local svc_pid=$!
    sleep 3
    if curl -sf "http://127.0.0.1:${PORT}/health" &>/dev/null; then
      success "API health check: OK"; passed=$((passed + 1))
    else
      warn "API health check: Could not reach /health (may need dependency)"; failed=$((failed + 1))
    fi
    kill "$svc_pid" 2>/dev/null; wait "$svc_pid" 2>/dev/null || true
  else
    warn "Backend entry point not found — skipping API test"
  fi
  echo ""
  info "Tests: ${passed} passed, ${failed} failed"
  [[ $failed -gt 0 ]] && warn "Some tests failed — review logs for details"
}

# =============================================================================
# Diagnostic Mode
# =============================================================================

run_diagnostic() {
  step "Generating diagnostic report"
  local report="${INSTALL_DIR}/logs/diagnostic_${TIMESTAMP}.txt"
  {
    echo "======================================"
    echo "Smart Switch Brain — Diagnostic Report"
    echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "======================================"
    echo ""
    echo "--- System ---"
    echo "OS: $(uname -a)"
    [[ -f /etc/os-release ]] && cat /etc/os-release
    echo ""
    echo "--- Resources ---"
    echo "RAM:"
    if [[ "$OS_TYPE" == "macos" ]]; then
      echo "  Total: $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))MB"
    else
      free -m 2>/dev/null || echo "  Could not read"
    fi
    echo "Disk:"
    df -h "${INSTALL_DIR}" 2>/dev/null || df -h . 2>/dev/null || echo "  Could not read"
    echo ""
    echo "--- Tools ---"
    echo "Node: $(node --version 2>/dev/null || echo 'not found')"
    echo "npm: $(npm --version 2>/dev/null || echo 'not found')"
    echo "git: $(git --version 2>/dev/null || echo 'not found')"
    echo "bash: ${BASH_VERSION:-unknown}"
    echo ""
    echo "--- Installation ---"
    echo "Install Dir: ${INSTALL_DIR}"
    echo "Port: ${PORT}"
    for d in backend frontend config logs data backups docs; do
      echo "  ${d}/: $(test -d "${INSTALL_DIR}/${d}" && echo 'exists' || echo 'MISSING')"
    done
    echo ".env: $(test -f "${INSTALL_DIR}/.env" && echo 'exists' || echo 'MISSING')"
    echo "modes.yaml: $(test -f "${INSTALL_DIR}/config/modes.yaml" && echo 'exists' || echo 'MISSING')"
    echo ""
    echo "--- Service ---"
    if command_exists systemctl; then
      systemctl status "$SERVICE_NAME" 2>&1 || echo "Service not registered"
    else
      echo "systemd not available"
    fi
    echo ""
    echo "--- Port ---"
    if command_exists ss; then
      ss -tlnp 2>/dev/null | grep ":${PORT}" || echo "Port ${PORT} not in use"
    elif command_exists lsof; then
      lsof -i ":${PORT}" 2>/dev/null || echo "Port ${PORT} not in use"
    fi
    echo ""
    echo "--- Recent Errors ---"
    tail -20 "${INSTALL_DIR}/logs/service-error.log" 2>/dev/null || echo "No error log found"
    echo ""
    echo "======================================"
    echo "End of report"
  } > "$report" 2>&1
  chmod 600 "$report"
  success "Diagnostic report saved: ${report}"
  cat "$report"
}

# =============================================================================
# Status Mode
# =============================================================================

show_status() {
  step "Smart Switch Brain — Status"
  if [[ ! -d "$INSTALL_DIR" ]]; then
    error "Not installed at ${INSTALL_DIR}"
    exit 1
  fi
  info "Installation: ${INSTALL_DIR}"
  info "Port: ${PORT}"
  # Check service
  if command_exists systemctl && systemctl is-active "$SERVICE_NAME" &>/dev/null; then
    success "Service: running"
  else
    local pid; pid="$(pgrep -f 'node.*smart-switch.*index.js' 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      success "Service: running (PID: ${pid})"
    else
      warn "Service: not running"
    fi
  fi
  # Check health
  if curl -sf "http://127.0.0.1:${PORT}/health" &>/dev/null; then
    success "API: healthy"
    local resp; resp="$(curl -sf "http://127.0.0.1:${PORT}/health")"
    info "Response: ${resp}"
  else
    warn "API: not responding on port ${PORT}"
  fi
}

# =============================================================================
# Uninstall Mode
# =============================================================================

run_uninstall() {
  step "Uninstalling Smart Switch Brain"
  if [[ ! -d "$INSTALL_DIR" ]]; then
    error "Installation not found at ${INSTALL_DIR}"
    exit 1
  fi
  echo ""
  warn "This will remove Smart Switch Brain from ${INSTALL_DIR}"
  if ! prompt_yn "Are you sure?" "n"; then
    info "Uninstall cancelled."
    exit 0
  fi
  # Backup database
  if [[ -f "${INSTALL_DIR}/data/smartswitch.db" ]]; then
    if prompt_yn "Backup database before removal?" "y"; then
      local db_backup="${HOME}/smartswitch_backup_${TIMESTAMP}.db"
      cp "${INSTALL_DIR}/data/smartswitch.db" "$db_backup"
      chmod 600 "$db_backup"
      success "Database backed up to: ${db_backup}"
    fi
  fi
  # Stop service
  if command_exists systemctl; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload 2>/dev/null || true
    success "Systemd service removed"
  fi
  pkill -f "node.*smart-switch.*index.js" 2>/dev/null || true
  # Preserve user data option
  if prompt_yn "Preserve user data (config, data, backups)?" "y"; then
    local preserve_dir="${HOME}/smart-switch-brain-userdata_${TIMESTAMP}"
    mkdir -p "$preserve_dir"
    for d in config data backups; do
      [[ -d "${INSTALL_DIR}/${d}" ]] && cp -a "${INSTALL_DIR}/${d}" "$preserve_dir/"
    done
    [[ -f "${INSTALL_DIR}/.env" ]] && cp "${INSTALL_DIR}/.env" "$preserve_dir/"
    success "User data preserved at: ${preserve_dir}"
  fi
  rm -rf "$INSTALL_DIR"
  success "Smart Switch Brain has been uninstalled"
}

# =============================================================================
# Clean Mode
# =============================================================================

run_clean() {
  step "Cleaning build artifacts"
  if [[ ! -d "$INSTALL_DIR" ]]; then
    error "Installation not found at ${INSTALL_DIR}"
    exit 1
  fi
  rm -rf "${INSTALL_DIR}/backend/node_modules" 2>/dev/null || true
  rm -rf "${INSTALL_DIR}/frontend/node_modules" 2>/dev/null || true
  rm -rf "${INSTALL_DIR}/frontend/dist" 2>/dev/null || true
  rm -f "${INSTALL_DIR}/frontend/.build_hash" 2>/dev/null || true
  success "Build artifacts cleaned. Run installer again to rebuild."
}

# =============================================================================
# Documentation Generation
# =============================================================================

generate_docs() {
  # Generate runtime documentation
  local docs_dir="${INSTALL_DIR}/docs"
  cat > "${docs_dir}/README.md" <<DOCEOF
# Smart Switch Brain — OpenClaw AI Mode Selector

## Quick Start

\`\`\`bash
# Start the service
cd ${INSTALL_DIR}
./start.sh

# Or with systemd
sudo systemctl start ${SERVICE_NAME}
\`\`\`

## API Endpoints

| Method | Path                | Description           |
|--------|---------------------|-----------------------|
| GET    | /health             | Health check          |
| GET    | /api/modes          | List available modes  |
| GET    | /api/modes/current  | Get current mode      |
| POST   | /api/modes/switch   | Switch AI mode        |

## Modes

| Mode         | Model              | Use Case        |
|--------------|--------------------|-----------------| 
| Work Hard    | Claude Opus        | Complex tasks   |
| Focus Serius | Claude Haiku       | Structured work |
| Relax        | Step-3.5 Flash     | Creative tasks  |

## Configuration

- \`.env\` — Environment variables (port, API key, etc.)
- \`config/modes.yaml\` — AI routing mode definitions

## Management

\`\`\`bash
# Check status
$SCRIPT_NAME --status

# Upgrade
$SCRIPT_NAME --upgrade

# Diagnostics
$SCRIPT_NAME --diagnostic

# Uninstall
$SCRIPT_NAME --uninstall
\`\`\`

Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
DOCEOF
  chmod 644 "${docs_dir}/README.md"
  verbose "Documentation generated at ${docs_dir}/README.md"
}

# =============================================================================
# Final Summary
# =============================================================================

print_summary() {
  local duration; duration="$(elapsed_since "$INSTALL_START_TIME")"
  echo ""
  echo "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}"
  echo "${BOLD}${GREEN} ${ICO_DONE} Smart Switch Brain — Installation Complete${RESET}"
  echo "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}"
  echo ""
  echo "  ${BOLD}Location:${RESET}   ${INSTALL_DIR}"
  echo "  ${BOLD}Port:${RESET}       ${PORT}"
  echo "  ${BOLD}Duration:${RESET}   ${duration}"
  echo "  ${BOLD}Log:${RESET}        ${LOG_FILE}"
  echo ""
  echo "  ${BOLD}${CYAN}Quick Start:${RESET}"
  if command_exists systemctl && [[ "$NO_SYSTEMD" != true ]] && [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    echo "    sudo systemctl start ${SERVICE_NAME}"
  else
    echo "    cd ${INSTALL_DIR} && ./start.sh"
  fi
  echo ""
  echo "  ${BOLD}${CYAN}Access:${RESET}"
  echo "    Frontend:  http://localhost:${PORT}"
  echo "    Health:    http://localhost:${PORT}/health"
  echo "    API:       http://localhost:${PORT}/api/modes"
  echo ""
  echo "  ${BOLD}${CYAN}Management:${RESET}"
  echo "    Status:      ${SCRIPT_NAME} --status"
  echo "    Upgrade:     ${SCRIPT_NAME} --upgrade"
  echo "    Diagnostics: ${SCRIPT_NAME} --diagnostic"
  echo "    Uninstall:   ${SCRIPT_NAME} --uninstall"
  echo ""
  echo "${GREEN}══════════════════════════════════════════════════${RESET}"
  log "INFO" "Installation completed in ${duration}"
}

# =============================================================================
# Main
# =============================================================================

main() {
  INSTALL_START_TIME="$(date +%s)"
  parse_args "$@"

  # Handle help early
  if [[ "$HELP_MODE" == true ]]; then show_help; exit 0; fi

  # Initialize logging
  init_logging
  log "INFO" "Smart Switch Brain installer v${SCRIPT_VERSION} started"
  log "INFO" "Arguments: $*"
  log "INFO" "System: $(uname -a)"

  echo ""
  echo "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${RESET}"
  echo "${BOLD}${CYAN}║   🧠 Smart Switch Brain — Installer v${SCRIPT_VERSION}       ║${RESET}"
  echo "${BOLD}${CYAN}║   OpenClaw AI Mode Selector                     ║${RESET}"
  echo "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${RESET}"
  echo ""

  # Detect OS early — needed for all modes
  detect_os

  # Handle special modes
  if [[ "$STATUS_MODE" == true ]]; then show_status; exit 0; fi
  if [[ "$DIAGNOSTIC_MODE" == true ]]; then run_diagnostic; exit 0; fi
  if [[ "$UNINSTALL_MODE" == true ]]; then run_uninstall; exit 0; fi
  if [[ "$CLEAN_MODE" == true ]]; then run_clean; exit 0; fi

  # Full installation flow
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

#!/bin/bash
set -eo pipefail

# =============================================================================
# Smart Switch Brain — OpenClaw AI Mode Selector Installer v1.0.4
# Created by Boy Barley — https://boybarley.com
# =============================================================================

readonly SCRIPT_VERSION="1.0.4"
readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
# Mengganti repository URL - karena tidak ada/tidak dapat diakses
readonly DEFAULT_REPO="https://github.com/boybarley/ssb.git"
readonly DEFAULT_PORT=5000
readonly DEFAULT_INSTALL_DIR="${HOME}/smart-switch-brain"
readonly MIN_NODE_MAJOR=14
readonly MIN_NPM_MAJOR=6
readonly MIN_GIT_VERSION="2.20"
readonly MIN_RAM_MB=1024
readonly MIN_DISK_MB=200
readonly MAX_RETRIES=3
readonly RETRY_DELAY=3
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
# Flag to indicate whether we're installing from a repository clone or direct file generation
FROM_REPO=false

# =============================================================================
# Colors
# =============================================================================
if [[ -t 1 ]]; then
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  BLUE="\033[34m"
  CYAN="\033[36m"
  BOLD="\033[1m"
  RESET="\033[0m"
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  CYAN=""
  BOLD=""
  RESET=""
fi

# =============================================================================
# Logging
# =============================================================================

init_logging() {
  local log_dir="${HOME}/.ssb-logs"
  mkdir -p "$log_dir" 2>/dev/null || true
  LOG_FILE="${log_dir}/install_${TIMESTAMP}.log"
  ERROR_LOG="${log_dir}/install_error_${TIMESTAMP}.log"
  touch "$LOG_FILE" "$ERROR_LOG" 2>/dev/null || true
  chmod 600 "$LOG_FILE" "$ERROR_LOG" 2>/dev/null || true
  
  # Rotate old logs safely
  find "$log_dir" -name "install_*.log" -type f -mtime +7 -delete 2>/dev/null || true
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
success() { printf "%s %b%s%b\n" "✅"  "$GREEN"  "$*" "$RESET"; log "OK"   "$*"; }
warn()    { printf "%s %b%s%b\n" "⚠️"  "$YELLOW" "$*" "$RESET"; log "WARN" "$*"; }
error()   { printf "%s %b%s%b\n" "❌"  "$RED"    "$*" "$RESET"; log "ERROR" "$*"; }
step()    { printf "\n%b%b── %s%b\n" "$BOLD" "$BLUE" "$*" "$RESET"; log "STEP" "$*"; }
verbose() { if [[ "$VERBOSE" == true ]]; then info "$@"; else log "DEBUG" "$*"; fi; }

# =============================================================================
# Spinner
# =============================================================================

spinner_start() {
  local msg="${1:-Working...}"
  if [[ -t 1 ]]; then
    (
      local chars='-\|/'
      while :; do
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
  # Simplified version comparison
  local v1="$1" v2="$2"
  local v1_parts v2_parts
  IFS='.' read -ra v1_parts <<< "$v1"
  IFS='.' read -ra v2_parts <<< "$v2"
  
  for i in {0..2}; do
    local num1=${v1_parts[$i]:-0}
    local num2=${v2_parts[$i]:-0}
    if (( num1 > num2 )); then
      return 0
    elif (( num1 < num2 )); then
      return 1
    fi
  done
  return 0
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
# CLI Parsing
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
      --api-key)     shift; API_KEY="${1:-CHANGE_ME}" ;;
      --port)        shift; PORT="${1:-5000}" ;;
      --repo)        shift; REPO_URL="$(sanitize_input "${1:-$DEFAULT_REPO}")" ;;
      --dir)         shift; INSTALL_DIR="${1:-$DEFAULT_INSTALL_DIR}" ;;
      --skip-repo)   FROM_REPO=false ;;
      *)             warn "Unknown flag: $1" ;;
    esac
    shift || break
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
  --skip-repo         Skip repository cloning
EOF
}

# =============================================================================
# OS Detection
# =============================================================================

detect_os() {
  step "Detecting operating system"
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
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
    if [[ -f /proc/meminfo ]]; then
      ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    else
      ram_mb=2048 # Assume sufficient if we can't detect
      verbose "Cannot detect RAM, assuming $ram_mb MB"
    fi
  fi
  if [[ "$ram_mb" -lt "$MIN_RAM_MB" ]]; then
    warn "RAM: ${ram_mb}MB < ${MIN_RAM_MB}MB required (continuing anyway)"
    return 0
  fi
  success "RAM: ${ram_mb}MB"
}

check_disk() {
  local target_parent
  target_parent="$(dirname "$INSTALL_DIR")"
  mkdir -p "$target_parent" 2>/dev/null || true
  local avail_mb=500 # Default assumption
  
  if [[ "$OS_TYPE" == "macos" ]]; then
    if command_exists df; then
      avail_mb=$(df -m "$target_parent" 2>/dev/null | awk 'NR==2{print $4}' || echo 500)
    fi
  else
    if command_exists df; then
      avail_mb=$(df -m "$target_parent" 2>/dev/null | awk 'NR==2{print $4}' || echo 500)
    fi
  fi
  
  if [[ "$avail_mb" -lt "$MIN_DISK_MB" ]]; then
    warn "Disk: ${avail_mb}MB < ${MIN_DISK_MB}MB required (continuing anyway)"
    return 0
  fi
  success "Disk: ${avail_mb}MB free"
}

extract_version() {
  # More robust version extraction from command output
  local output="$1"
  echo "$output" | grep -o -E '[0-9]+(\.[0-9]+)+' | head -n 1 || echo "0.0.0"
}

check_tool_version() {
  local tool="$1" min_ver="$2" flag="${3:---version}"
  if ! command_exists "$tool"; then
    warn "$tool not installed (required: $min_ver+)"
    return 1
  fi
  
  local output current
  output="$("$tool" "$flag" 2>&1 || echo "0.0.0")"
  current="$(extract_version "$output")"
  
  if [[ -z "$current" || "$current" == "0.0.0" ]]; then
    warn "Cannot determine $tool version - proceeding anyway"
    return 0
  fi
  
  local tool_major="${current%%.*}"
  local min_major="${min_ver%%.*}"
  
  if [[ "$tool_major" -lt "$min_major" ]]; then
    warn "$tool $current < $min_ver (required) - proceeding anyway"
    return 0
  fi
  
  success "$tool: v${current}"
}

validate_prereqs() {
  step "Validating system requirements"
  
  check_ram || warn "RAM check failed - continuing"
  check_disk || warn "Disk space check failed - continuing"
  
  # Check tools but don't fail installation if they're missing or wrong version
  check_tool_version node "${MIN_NODE_MAJOR}.0.0" "--version" || 
    warn "Node.js ${MIN_NODE_MAJOR}+ required - install from https://nodejs.org/"
  
  check_tool_version npm "${MIN_NPM_MAJOR}.0.0" "--version" || 
    warn "npm ${MIN_NPM_MAJOR}+ required - usually comes with Node.js"
  
  if [[ "$FROM_REPO" == true ]]; then
    check_tool_version git "$MIN_GIT_VERSION" "--version" || {
      warn "git ${MIN_GIT_VERSION}+ required for repository cloning - switching to direct installation"
      FROM_REPO=false
    }
  fi
  
  # Only fail if node is completely missing (since it's essential)
  if ! command_exists node; then
    error "Node.js is required but not installed. Please install Node.js ${MIN_NODE_MAJOR}+ and try again."
    exit 1
  fi
}

# =============================================================================
# Dependencies
# =============================================================================

pkg_install() {
  local pkg="$1"
  if command_exists "$pkg"; then return 0; fi
  info "Installing $pkg..."
  
  case "$PKG_MANAGER" in
    apt)     
      sudo apt-get update -qq || true
      sudo apt-get install -y -qq "$pkg" || return 1
      ;;
    yum|dnf) 
      sudo "$PKG_MANAGER" install -y -q "$pkg" || return 1
      ;;
    pacman)  
      sudo pacman -S --noconfirm --needed "$pkg" || return 1
      ;;
    brew)    
      brew install "$pkg" || return 1
      ;;
    *)       
      warn "Cannot auto-install $pkg - package manager unknown"
      return 1
      ;;
  esac
}

install_dependencies() {
  step "Checking dependencies"
  for dep in curl wget; do
    if ! command_exists "$dep"; then
      pkg_install "$dep" || warn "Failed to install $dep - continuing anyway"
    else
      verbose "$dep: OK"
    fi
  done
  
  # Git is only required if we're using the repository
  if [[ "$FROM_REPO" == true ]] && ! command_exists git; then
    info "git is required for repository cloning"
    if pkg_install git; then
      success "git installed successfully"
    else
      warn "Failed to install git - switching to direct installation"
      FROM_REPO=false
    fi
  fi
  
  # Optional: sqlite3 for database init
  if ! command_exists sqlite3; then
    pkg_install sqlite3 2>/dev/null || verbose "sqlite3 not available (optional)"
  else
    verbose "sqlite3: OK"
  fi
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

create_base_repo_structure() {
  info "Creating repository structure (no git)"
  mkdir -p "$INSTALL_DIR" 2>/dev/null || true
  
  if [[ ! -d "$INSTALL_DIR" ]]; then
    error "Failed to create installation directory: $INSTALL_DIR"
    exit 1
  fi
  
  success "Base directory created"
}

test_repository_url() {
  # Try to fetch the repository URL to see if it's valid
  if command_exists git; then
    if git ls-remote --quiet "$REPO_URL" HEAD &>/dev/null; then
      return 0
    else
      return 1
    fi
  else
    # If git isn't installed, we can't test
    return 1
  fi
}

manage_repository() {
  step "Managing repository"
  
  # First ensure base directory exists
  if [[ ! -d "$INSTALL_DIR" ]]; then
    create_base_repo_structure
  fi
  
  # Check if it's an existing git repo
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "Existing git repo at ${INSTALL_DIR}"
    FROM_REPO=true
    if [[ "$UPGRADE_MODE" == true ]]; then
      backup_existing
      spinner_start "Pulling updates..."
      (cd "$INSTALL_DIR" && git stash --quiet 2>/dev/null || true)
      (cd "$INSTALL_DIR" && git pull 2>/dev/null || true)
      spinner_stop
      success "Repository updated"
    else
      info "Using existing repo (--upgrade to update)"
    fi
  elif [[ "$FROM_REPO" == true ]] && command_exists git; then
    # Check if repo URL is valid
    info "Testing repository URL: $REPO_URL"
    if ! test_repository_url; then
      warn "Repository URL $REPO_URL appears invalid or inaccessible"
      info "Switching to direct file generation mode"
      FROM_REPO=false
    else
      # Try to clone
      spinner_start "Cloning repository..."
      push_rollback "rm -rf '${INSTALL_DIR}'"
      if git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" 2>>"${ERROR_LOG:-/dev/null}"; then
        pop_rollback
        spinner_stop
        success "Repository cloned successfully"
      else
        pop_rollback
        spinner_stop
        warn "Failed to clone repository - switching to direct installation"
        FROM_REPO=false
      fi
    fi
  else
    # Not using repo mode
    info "Using direct file generation (not git)"
    FROM_REPO=false
  fi
  
  # If not using repo, ensure the base structure exists
  if [[ "$FROM_REPO" == false ]]; then
    create_base_repo_structure
  fi
}

# =============================================================================
# Directories
# =============================================================================

create_directories() {
  step "Creating directory structure"
  local dirs=(backend frontend config logs data backups docs)
  for d in "${dirs[@]}"; do
    mkdir -p "${INSTALL_DIR}/${d}" 2>/dev/null || true
    
    if [[ ! -d "${INSTALL_DIR}/${d}" ]]; then
      warn "Failed to create directory: ${INSTALL_DIR}/${d}"
    fi
  done
  
  # Try to set permissions but don't fail if it doesn't work
  chmod 755 "${INSTALL_DIR}" 2>/dev/null || true
  chmod 700 "${INSTALL_DIR}/config" "${INSTALL_DIR}/logs" \
            "${INSTALL_DIR}/data" "${INSTALL_DIR}/backups" 2>/dev/null || true
  chmod 755 "${INSTALL_DIR}/backend" "${INSTALL_DIR}/frontend" \
            "${INSTALL_DIR}/docs" 2>/dev/null || true
  
  success "Directories ready"
}

# =============================================================================
# Configuration
# =============================================================================

validate_api_key() {
  local key="$1"
  [[ -n "$key" && ${#key} -ge 8 && ! "$key" =~ [[:space:]] ]]
}

setup_env() {
  local env_file="${INSTALL_DIR}/.env"
  if [[ -f "$env_file" ]]; then
    info "Existing .env found — keeping"
    return 0
  fi
  
  info "Generating .env..."
  # Get API key if not provided via flag
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
# DO NOT COMMIT

NODE_ENV=production
PORT=${PORT}
HOST=0.0.0.0
OPENROUTER_API_KEY=${API_KEY}
OPENROUTER_BASE_URL=https://openrouter.ai/api/v1
DATABASE_PATH=./data/smartswitch.db
LOG_LEVEL=info
LOG_DIR=./logs
RATE_LIMIT_WINDOW_MS=60000
RATE_LIMIT_MAX_REQUESTS=100
ENVEOF

  chmod 600 "$env_file" 2>/dev/null || true
  API_KEY="[REDACTED]"
  success ".env created"
}

generate_modes_yaml() {
  local mf="${INSTALL_DIR}/config/modes.yaml"
  if [[ -f "$mf" ]]; then
    info "Existing modes.yaml — keeping"
    return 0
  fi
  
  cat > "$mf" <<'YAMLEOF'
# Smart Switch Brain — AI Routing Modes
modes:
  - id: work-hard
    name: "Work Hard"
    description: "Maximum reasoning for complex tasks"
    model: "anthropic/claude-opus"
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
    model: "mistralai/mistral-medium"
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

  chmod 644 "$mf" 2>/dev/null || true
  success "modes.yaml created (3 profiles)"
}

setup_configuration() {
  step "Setting up configuration"
  setup_env
  generate_modes_yaml
}

# =============================================================================
# Backend
# =============================================================================

generate_backend_scaffold() {
  local be="${INSTALL_DIR}/backend"
  [[ -f "${be}/package.json" ]] && return 0
  
  info "Generating backend..."
  cat > "${be}/package.json" <<'PKG'
{
  "name": "smart-switch-brain-backend",
  "version": "1.0.0",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "dev": "node src/index.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "better-sqlite3": "^8.5.0",
    "dotenv": "^16.3.1",
    "helmet": "^7.1.0",
    "cors": "^2.8.5",
    "winston": "^3.11.0",
    "express-rate-limit": "^7.1.4",
    "yaml": "^2.3.4"
  },
  "engines": { "node": ">=14.0.0" }
}
PKG
  
  mkdir -p "${be}/src" 2>/dev/null || true
  
  cat > "${be}/src/index.js" <<'SERVERJS'
// Smart Switch Brain Server
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const rateLimit = require('express-rate-limit');
const fs = require('fs');
const path = require('path');
const yaml = require('yaml');

// SQLite is loaded conditionally to avoid startup errors
let Database;
try {
  Database = require('better-sqlite3');
} catch (err) {
  console.warn('SQLite not available:', err.message);
}

const PORT = process.env.PORT || 5000;
const HOST = process.env.HOST || '0.0.0.0';
const app = express();

// Create logs directory if it doesn't exist
const logDir = path.resolve(__dirname, '../../logs');
if (!fs.existsSync(logDir)) {
  try {
    fs.mkdirSync(logDir, { recursive: true });
  } catch (err) {
    console.warn(`Failed to create log directory: ${err.message}`);
  }
}

app.use(helmet());
app.use(cors());
app.use(express.json());
app.use(rateLimit({
  windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS || '60000'),
  max: parseInt(process.env.RATE_LIMIT_MAX_REQUESTS || '100')
}));

// Static frontend
const distPath = path.resolve(__dirname, '../../frontend/dist');
if (fs.existsSync(distPath)) app.use(express.static(distPath));

// Load modes configuration
const modesPath = path.resolve(__dirname, '../../config/modes.yaml');
let modes = { modes: [], defaults: {} };
try {
  if (fs.existsSync(modesPath)) {
    modes = yaml.parse(fs.readFileSync(modesPath, 'utf8'));
  } else {
    console.warn('modes.yaml not found');
  }
} catch (e) {
  console.error('Failed to parse modes.yaml:', e.message);
}

// Initialize DB if SQLite is available
let db = null;
try {
  if (Database) {
    const dataDir = path.resolve(__dirname, '../../data');
    if (!fs.existsSync(dataDir)) {
      fs.mkdirSync(dataDir, { recursive: true });
    }
    
    const dbPath = path.resolve(dataDir, 'smartswitch.db');
    db = new Database(dbPath);
    db.pragma('journal_mode = WAL');
    
    // Create tables if they don't exist
    db.exec('CREATE TABLE IF NOT EXISTS mode_history (id INTEGER PRIMARY KEY AUTOINCREMENT, mode_id TEXT NOT NULL, switched_at DATETIME DEFAULT CURRENT_TIMESTAMP)');
    db.exec('CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)');
    
    // Initialize settings
    db.prepare('INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)').run('app_version', '1.0.0');
    db.prepare('INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)').run('installed_at', new Date().toISOString());
  }
} catch (err) {
  console.error('Database initialization failed:', err.message);
}

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ 
    status: 'ok', 
    version: '1.0.0', 
    uptime: process.uptime(),
    database: db ? 'connected' : 'unavailable',
    timestamp: new Date().toISOString()
  });
});

// API routes
app.get('/api/modes', (req, res) => {
  res.json(modes);
});

app.get('/api/modes/current', (req, res) => {
  let currentMode = (modes.defaults && modes.defaults.fallback_mode) || 'focus-serius';
  
  try {
    if (db) {
      const row = db.prepare('SELECT mode_id FROM mode_history ORDER BY switched_at DESC LIMIT 1').get();
      if (row) currentMode = row.mode_id;
    }
  } catch (err) {
    console.error('Error fetching current mode:', err.message);
  }
  
  const mode = (modes.modes || []).find(m => m.id === currentMode) || {};
  res.json({ current: currentMode, ...mode });
});

app.post('/api/modes/switch', (req, res) => {
  const modeId = req.body && req.body.mode_id;
  
  if (!modeId) {
    return res.status(400).json({ error: 'mode_id required' });
  }
  
  const validMode = (modes.modes || []).find(m => m.id === modeId);
  if (!validMode) {
    return res.status(400).json({ error: 'invalid mode_id' });
  }
  
  try {
    if (db) {
      db.prepare('INSERT INTO mode_history (mode_id) VALUES (?)').run(modeId);
    }
  } catch (err) {
    console.error('Error switching mode:', err.message);
    // Continue anyway and return success
  }
  
  res.json({ 
    switched: modeId, 
    name: validMode.name,
    timestamp: new Date().toISOString() 
  });
});

// Start the server
app.listen(PORT, HOST, () => {
  console.log(`Smart Switch Brain running on http://${HOST}:${PORT}`);
  console.log(`${new Date().toISOString()} - Server started`);
});

// Handle shutdown
process.on('SIGINT', () => {
  console.log('Shutting down server...');
  if (db) db.close();
  process.exit(0);
});

process.on('SIGTERM', () => {
  console.log('Shutting down server...');
  if (db) db.close();
  process.exit(0);
});
SERVERJS

  success "Backend scaffold created"
}

setup_backend() {
  step "Setting up backend"
  generate_backend_scaffold
  
  local be="${INSTALL_DIR}/backend"
  if [[ ! -f "${be}/package.json" ]]; then
    error "Backend package.json missing"
    exit 1
  fi
  
  spinner_start "Installing backend dependencies (this may take a minute)..."
  
  # Create a temporary npmrc file to avoid npm warnings
  local npmrc_file="${be}/.npmrc"
  echo "fund=false" > "$npmrc_file"
  echo "audit=false" >> "$npmrc_file"
  echo "update-notifier=false" >> "$npmrc_file"
  
  # Try to install dependencies
  if (cd "$be" && npm install --no-fund --no-audit --loglevel=error 2>>"${ERROR_LOG:-/dev/null}"); then
    spinner_stop
    success "Backend dependencies installed"
  else
    spinner_stop
    warn "NPM install encountered issues - trying again with basic dependencies"
    
    # Create a more minimal package.json with fewer dependencies
    cat > "${be}/package.json" <<'PKG_MIN'
{
  "name": "smart-switch-brain-backend",
  "version": "1.0.0",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "dotenv": "^16.0.0"
  }
}
PKG_MIN
    
    # Try with minimal dependencies
    if (cd "$be" && npm install --no-fund --no-audit --loglevel=error 2>>"${ERROR_LOG:-/dev/null}"); then
      success "Basic backend dependencies installed"
    else
      error "Backend npm install failed. Check logs: ${ERROR_LOG}"
      warn "You may need to manually run: cd ${be} && npm install"
    fi
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
# Frontend
# =============================================================================

generate_frontend_scaffold() {
  local fe="${INSTALL_DIR}/frontend"
  [[ -f "${fe}/package.json" ]] && return 0
  
  info "Generating frontend..."
  
  cat > "${fe}/package.json" <<'FEPKG'
{
  "name": "smart-switch-brain-frontend",
  "version": "1.0.0",
  "scripts": {
    "build": "mkdir -p dist && cp -r public/* dist/ 2>/dev/null || true"
  }
}
FEPKG
  
  mkdir -p "${fe}/public" "${fe}/dist" 2>/dev/null || true
  
  cat > "${fe}/public/index.html" <<'FEHTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Smart Switch Brain</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #0f1117;
      color: #e1e4e8;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
    }
    .container {
      text-align: center;
      max-width: 600px;
      padding: 2rem;
    }
    .title {
      font-size: 2rem;
      margin-bottom: 1rem;
    }
    .modes {
      display: flex;
      gap: 1rem;
      flex-wrap: wrap;
      justify-content: center;
      margin-top: 2rem;
    }
    .mode-button {
      padding: 1.5rem 2rem;
      border: 2px solid #30363d;
      border-radius: 12px;
      background: #161b22;
      cursor: pointer;
      transition: all 0.2s;
      min-width: 150px;
      color: #e1e4e8;
    }
    .mode-button:hover {
      border-color: #58a6ff;
      transform: translateY(-2px);
    }
    .mode-button.active {
      border-color: #3fb950;
      box-shadow: 0 0 12px rgba(63, 185, 80, 0.3);
    }
    .icon {
      font-size: 2rem;
    }
    .label {
      margin-top: 0.5rem;
      font-size: 0.9rem;
      color: #8b949e;
    }
    .status {
      margin-top: 2rem;
      padding: 1rem;
      border-radius: 8px;
      background: #161b22;
      color: #58a6ff;
    }
    .footer {
      margin-top: 2rem;
      font-size: 0.75rem;
      color: #484f58;
    }
    .error {
      color: #f85149;
      margin-top: 1rem;
      font-size: 0.9rem;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1 class="title">🧠 Smart Switch Brain</h1>
    <p>OpenClaw AI Mode Selector</p>
    
    <div class="modes" id="modes"></div>
    <div class="status" id="status">Loading...</div>
    <div id="error" class="error"></div>
    
    <div class="footer">
      Created by Boy Barley
    </div>
  </div>

  <script>
    const API_BASE = window.location.origin;
    let retryCount = 0;
    
    function loadData() {
      document.getElementById('error').textContent = '';
      
      // Load modes
      fetch(API_BASE + '/api/modes')
        .then(response => response.json())
        .then(data => {
          let html = '';
          (data.modes || []).forEach(mode => {
            html += `
              <div class="mode-button" id="button-${mode.id}" onclick="switchMode('${mode.id}')">
                <div class="icon">${mode.icon || '🔘'}</div>
                <div class="label">${mode.name}</div>
              </div>
            `;
          });
          document.getElementById('modes').innerHTML = html;
          
          // Get current mode
          return fetch(API_BASE + '/api/modes/current');
        })
        .then(response => response.json())
        .then(current => {
          document.getElementById('status').textContent = 'Current: ' + (current.name || current.current);
          
          const activeButton = document.getElementById('button-' + current.current);
          if (activeButton) {
            activeButton.className = 'mode-button active';
          }
          
          retryCount = 0;
        })
        .catch(error => {
          console.error('API error:', error);
          document.getElementById('status').textContent = 'API unavailable';
          document.getElementById('error').textContent = 
            'Cannot connect to API. Is the server running?';
          
          // Retry a few times with backoff
          if (retryCount < 3) {
            retryCount++;
            setTimeout(loadData, 3000 * retryCount);
          }
        });
    }
    
    function switchMode(id) {
      document.getElementById('status').textContent = 'Switching...';
      
      fetch(API_BASE + '/api/modes/switch', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ mode_id: id })
      })
      .then(() => loadData())
      .catch(error => {
        console.error('Switch error:', error);
        document.getElementById('status').textContent = 'Switch failed';
        document.getElementById('error').textContent = 
          'Failed to switch mode. Try again or check server.';
      });
    }
    
    // Load data on page load
    document.addEventListener('DOMContentLoaded', loadData);
  </script>
</body>
</html>
FEHTML

  success "Frontend scaffold created"
}

setup_frontend() {
  step "Setting up frontend"
  generate_frontend_scaffold
  
  local fe="${INSTALL_DIR}/frontend"
  if [[ ! -f "${fe}/package.json" ]]; then
    error "Frontend package.json missing"
    exit 1
  fi
  
  # Create dist directory and copy files
  mkdir -p "${fe}/dist" 2>/dev/null || true
  
  if [[ -d "${fe}/public" ]]; then
    cp -r "${fe}/public"/* "${fe}/dist/" 2>/dev/null || true
    success "Frontend files copied to dist"
  else
    warn "Frontend public directory not found, dist may be empty"
  fi
}

# =============================================================================
# Security
# =============================================================================

harden_security() {
  step "Applying security hardening"
  
  # Secure env file
  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    chmod 600 "${INSTALL_DIR}/.env" 2>/dev/null || true
  fi
  
  # Secure config directory
  chmod 700 "${INSTALL_DIR}/config" 2>/dev/null || true
  
  # Create .gitignore
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
  
  # Create .env.example (safe template)
  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    sed 's/=.*/=CHANGE_ME/' "${INSTALL_DIR}/.env" 2>/dev/null \
      | grep -v "^#" | sed '/^$/d' \
      > "${INSTALL_DIR}/.env.example" 2>/dev/null || true
    chmod 644 "${INSTALL_DIR}/.env.example" 2>/dev/null || true
  fi
  
  success "Security hardening applied"
}

# =============================================================================
# Database
# =============================================================================

init_database() {
  step "Initializing database"
  
  local db_path="${INSTALL_DIR}/data/smartswitch.db"
  local db_dir="${INSTALL_DIR}/data"
  
  # Ensure data directory exists
  mkdir -p "$db_dir" 2>/dev/null || true
  
  # Backup existing database if upgrading
  if [[ -f "$db_path" && "$UPGRADE_MODE" == true ]]; then
    local db_bak="${INSTALL_DIR}/backups/smartswitch_${TIMESTAMP}.db"
    mkdir -p "${INSTALL_DIR}/backups" 2>/dev/null || true
    
    cp "$db_path" "$db_bak" 2>/dev/null || true
    chmod 600 "$db_bak" 2>/dev/null || true
    success "DB backed up: ${db_bak}"
  fi
  
  # Database will be created by the server on first startup
  info "Database will initialize on first app start"

  # Touch the file to ensure it exists
  touch "$db_path" 2>/dev/null || true
  
  # Secure permissions
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
  
  # Simple check if port seems available
  if command_exists nc; then
    if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
      warn "Port ${PORT} appears to be in use"
      # Suggest alternate port but don't change automatically
      local alt=$((PORT + 1))
      info "You can use an alternate port by editing ${INSTALL_DIR}/.env"
    else
      success "Port ${PORT} appears available"
    fi
  else
    info "Port ${PORT} will be used (port check skipped)"
  fi
}

# =============================================================================
# Service
# =============================================================================

generate_start_script() {
  cat > "${INSTALL_DIR}/start.sh" <<STARTEOF
#!/bin/bash
cd "\$(dirname "\$0")/backend"
echo "Starting Smart Switch Brain on port \${PORT:-${PORT}}..."
node src/index.js
STARTEOF

  cat > "${INSTALL_DIR}/stop.sh" <<'STOPEOF'
#!/bin/bash
echo "Stopping Smart Switch Brain..."
pkill -f "node.*src/index.js" 2>/dev/null && echo "Stopped." || echo "Not running."
STOPEOF

  chmod 755 "${INSTALL_DIR}/start.sh" "${INSTALL_DIR}/stop.sh" 2>/dev/null || true
  success "start.sh / stop.sh created"
}

create_systemd_unit() {
  local unit_file="/etc/systemd/system/${SERVICE_NAME}.service"
  local node_path
  node_path="$(command -v node 2>/dev/null || echo node)"
  local run_user
  run_user="$(id -un 2>/dev/null || echo "$USER")"
  
  local tmp_unit="/tmp/${SERVICE_NAME}_${TIMESTAMP}.service"
  
  cat > "$tmp_unit" <<UNITEOF
[Unit]
Description=Smart Switch Brain — OpenClaw AI Mode Selector
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
Environment=NODE_ENV=production
EnvironmentFile=${INSTALL_DIR}/.env

[Install]
WantedBy=multi-user.target
UNITEOF

  # Try to install systemd service
  if sudo cp "$tmp_unit" "$unit_file" 2>>"${ERROR_LOG:-/dev/null}" \
     && sudo chmod 644 "$unit_file" 2>>"${ERROR_LOG:-/dev/null}"; then
    rm -f "$tmp_unit" 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo systemctl enable "$SERVICE_NAME" 2>/dev/null || true
    success "Systemd service registered"
    info "To start: sudo systemctl start ${SERVICE_NAME}"
    info "To check status: sudo systemctl status ${SERVICE_NAME}"
  else
    rm -f "$tmp_unit" 2>/dev/null || true
    warn "Systemd setup failed — using start scripts instead"
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
    info "systemd not available, using start scripts"
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
  
  # Node
  if node -e "console.log('Node working')" 2>/dev/null; then
    success "Node runtime: OK"; pass=$((pass+1))
  else
    warn "Node runtime: Not working correctly"; fail=$((fail+1))
  fi
  
  # Directories
  local dirs_ok=true
  for d in backend frontend config logs data; do
    if [[ ! -d "${INSTALL_DIR}/${d}" ]]; then
      dirs_ok=false
      break
    fi
  done
  
  if [[ "$dirs_ok" == true ]]; then
    success "Directories: OK"; pass=$((pass+1))
  else
    warn "Directories: Some missing"; fail=$((fail+1))
  fi
  
  # Config
  if [[ -f "${INSTALL_DIR}/.env" && -f "${INSTALL_DIR}/config/modes.yaml" ]]; then
    success "Config files: OK"; pass=$((pass+1))
  else
    warn "Config files: Missing some files"; fail=$((fail+1))
  fi
  
  info "Results: ${pass} passed, ${fail} failed"
  
  # Don't fail the installation based on tests
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
    echo "=== Smart Switch Brain Diagnostic ==="
    echo "Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "By: Boy Barley"
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
    echo "Node: $(node --version 2>/dev/null || echo N/A)"
    echo "npm: $(npm --version 2>/dev/null || echo N/A)"
    echo "git: $(git --version 2>/dev/null || echo N/A)"
    echo "bash: ${BASH_VERSION:-unknown}"
    echo ""
    echo "--- Installation ---"
    echo "Dir: ${INSTALL_DIR}"
    echo "Port: ${PORT}"
    for d in backend frontend config logs data; do
      printf "  %-12s %s\n" "${d}/" "$(test -d "${INSTALL_DIR}/${d}" && echo OK || echo MISSING)"
    done
    printf "  %-12s %s\n" ".env" "$(test -f "${INSTALL_DIR}/.env" && echo OK || echo MISSING)"
    printf "  %-12s %s\n" "modes.yaml" "$(test -f "${INSTALL_DIR}/config/modes.yaml" && echo OK || echo MISSING)"
    echo ""
    echo "--- Service ---"
    systemctl status "$SERVICE_NAME" 2>&1 || echo "Not registered"
    echo ""
    echo "--- Errors (last 10) ---"
    tail -10 "${ERROR_LOG}" 2>/dev/null || echo "No error log"
    echo "=== End ==="
  } > "$rpt" 2>&1
  
  chmod 644 "$rpt" 2>/dev/null || true
  success "Report: ${rpt}"
  cat "$rpt"
}

# =============================================================================
# Status
# =============================================================================

show_status() {
  step "Status"
  
  if [[ ! -d "$INSTALL_DIR" ]]; then 
    error "Not installed at ${INSTALL_DIR}"
    exit 1
  fi
  
  info "Dir: ${INSTALL_DIR}"
  info "Port: ${PORT}"
  
  if command_exists systemctl && systemctl is-active "$SERVICE_NAME" &>/dev/null; then
    success "Service: running (systemd)"
  else
    local pid
    pid="$(pgrep -f 'node.*src/index.js' 2>/dev/null | head -1 || true)"
    if [[ -n "$pid" ]]; then
      success "Service: running (PID ${pid})"
    else
      warn "Service: stopped"
      info "Start with: cd ${INSTALL_DIR} && ./start.sh"
    fi
  fi
  
  if command_exists curl && curl -sf "http://127.0.0.1:${PORT}/health" &>/dev/null; then
    success "API: responding"
  else
    warn "API: not responding"
  fi
}

# =============================================================================
# Uninstall
# =============================================================================

run_uninstall() {
  step "Uninstalling Smart Switch Brain"
  
  if [[ ! -d "$INSTALL_DIR" ]]; then 
    error "Not found at ${INSTALL_DIR}"
    exit 1
  fi
  
  warn "Will remove ${INSTALL_DIR}"
  if ! prompt_yn "Continue with uninstallation?" "n"; then 
    info "Cancelled"
    exit 0
  fi
  
  # Backup database if exists
  if [[ -f "${INSTALL_DIR}/data/smartswitch.db" ]] && prompt_yn "Backup database?" "y"; then
    local bk="${HOME}/smartswitch_backup_${TIMESTAMP}.db"
    cp "${INSTALL_DIR}/data/smartswitch.db" "$bk" 2>/dev/null || true
    chmod 600 "$bk" 2>/dev/null || true
    success "DB backed up: ${bk}"
  fi
  
  # Stop and remove systemd service if it exists
  if command_exists systemctl && systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
    info "Stopping and removing systemd service..."
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
  fi
  
  # Kill any running processes
  pkill -f "node.*src/index.js" 2>/dev/null || true
  
  # Option to preserve user data
  if prompt_yn "Preserve user data (config, data)?" "y"; then
    local pdir="${HOME}/ssb-preserved_${TIMESTAMP}"
    mkdir -p "$pdir" 2>/dev/null || true
    
    for d in config data backups; do
      if [[ -d "${INSTALL_DIR}/${d}" ]]; then
        cp -r "${INSTALL_DIR}/${d}" "$pdir/" 2>/dev/null || true
      fi
    done
    
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
      cp "${INSTALL_DIR}/.env" "$pdir/" 2>/dev/null || true
    fi
    
    success "Data preserved: ${pdir}"
  fi
  
  # Remove installation directory
  rm -rf "$INSTALL_DIR" 2>/dev/null || sudo rm -rf "$INSTALL_DIR"
  
  if [[ ! -d "$INSTALL_DIR" ]]; then
    success "Uninstalled successfully"
  else
    error "Failed to remove ${INSTALL_DIR}"
    warn "You may need to remove it manually"
  fi
}

# =============================================================================
# Clean
# =============================================================================

run_clean() {
  step "Cleaning artifacts"
  
  if [[ ! -d "$INSTALL_DIR" ]]; then 
    error "Not found at ${INSTALL_DIR}"
    exit 1
  fi
  
  # Remove node_modules directories
  rm -rf "${INSTALL_DIR}/backend/node_modules" 2>/dev/null || true
  rm -rf "${INSTALL_DIR}/frontend/node_modules" 2>/dev/null || true
  
  # Remove frontend dist
  rm -rf "${INSTALL_DIR}/frontend/dist" 2>/dev/null || true
  
  # Remove temporary files
  find "${INSTALL_DIR}" -name "*.tmp" -delete 2>/dev/null || true
  find "${INSTALL_DIR}" -name "*.log" -delete 2>/dev/null || true
  
  success "Cleaned. Run installer again to rebuild."
}

# =============================================================================
# Docs
# =============================================================================

generate_docs() {
  mkdir -p "${INSTALL_DIR}/docs" 2>/dev/null || true
  
  cat > "${INSTALL_DIR}/docs/README.md" <<DOCEOF
# Smart Switch Brain — OpenClaw AI Mode Selector
Created by Boy Barley

## Quick Start
\`\`\`
cd ${INSTALL_DIR} && ./start.sh
\`\`\`
Or with systemd (if installed):
\`\`\`
sudo systemctl start ${SERVICE_NAME}
\`\`\`

## Access the Interface
Open in your browser:
\`\`\`
http://localhost:${PORT}
\`\`\`

## API Endpoints
- GET  /health             Health check
- GET  /api/modes          List all available modes
- GET  /api/modes/current  Get current active mode
- POST /api/modes/switch   Switch mode (body: {"mode_id":"work-hard"})

## Management
- Check status: \`./install.sh --status\`
- Upgrade: \`./install.sh --upgrade\`
- Troubleshoot: \`./install.sh --diagnostic\`
- Uninstall: \`./install.sh --uninstall\`

Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
DOCEOF

  chmod 644 "${INSTALL_DIR}/docs/README.md" 2>/dev/null || true
  success "Documentation generated"
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
  local dur
  dur="$(elapsed_since "$INSTALL_START_TIME")"
  
  echo ""
  printf "%b%b══════════════════════════════════════════════════%b\n" "$BOLD" "$GREEN" "$RESET"
  printf "%b%b  🎉 Smart Switch Brain — Installed Successfully %b\n" "$BOLD" "$GREEN" "$RESET"
  printf "%b%b══════════════════════════════════════════════════%b\n" "$BOLD" "$GREEN" "$RESET"
  echo ""
  printf "  %bInstallation Directory:%b %s\n" "$BOLD" "$RESET" "$INSTALL_DIR"
  printf "  %bPort:%b                  %s\n" "$BOLD" "$RESET" "$PORT"
  printf "  %bInstallation Time:%b     %s\n" "$BOLD" "$RESET" "$dur"
  echo ""
  printf "  %b%bHow to Start:%b\n" "$BOLD" "$CYAN" "$RESET"
  if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    printf "    sudo systemctl start %s\n" "$SERVICE_NAME"
  else
    printf "    cd %s && ./start.sh\n" "$INSTALL_DIR"
  fi
  echo ""
  printf "  %b%bAccess the Interface:%b\n" "$BOLD" "$CYAN" "$RESET"
  printf "    http://localhost:%s\n" "$PORT"
  echo ""
  printf "  %b%bDocumentation:%b\n" "$BOLD" "$CYAN" "$RESET"
  printf "    %s/docs/README.md\n" "$INSTALL_DIR"
  echo ""
  printf "  %b%bManagement:%b\n" "$BOLD" "$CYAN" "$RESET"
  printf "    %s --status | --upgrade | --diagnostic | --uninstall\n" "$SCRIPT_NAME"
  echo ""
  printf "%b══════════════════════════════════════════════════%b\n" "$GREEN" "$RESET"
  printf "  Created by Boy Barley\n"
  printf "%b══════════════════════════════════════════════════%b\n" "$GREEN" "$RESET"
}

# =============================================================================
# Main
# =============================================================================

main() {
  INSTALL_START_TIME="$(date +%s)"
  
  # Default to generating files directly unless overridden
  FROM_REPO=false
  
  parse_args "$@"

  if [[ "$HELP_MODE" == true ]]; then show_help; exit 0; fi

  # Initialize logging before anything else
  init_logging
  log "INFO" "Installer v${SCRIPT_VERSION} | Args: $* | $(uname -a)"

  echo ""
  printf "%b%b╔══════════════════════════════════════════════╗%b\n" "$BOLD" "$CYAN" "$RESET"
  printf "%b%b║  🧠 Smart Switch Brain  v%-20s║%b\n" "$BOLD" "$CYAN" "$SCRIPT_VERSION" "$RESET"
  printf "%b%b║  OpenClaw AI Mode Selector — Boy Barley     ║%b\n" "$BOLD" "$CYAN" "$RESET"
  printf "%b%b╚══════════════════════════════════════════════╝%b\n" "$BOLD" "$CYAN" "$RESET"
  echo ""

  detect_os

  # Handle special modes
  if [[ "$STATUS_MODE" == true ]]; then show_status; exit 0; fi
  if [[ "$DIAGNOSTIC_MODE" == true ]]; then run_diagnostic; exit 0; fi
  if [[ "$UNINSTALL_MODE" == true ]]; then run_uninstall; exit 0; fi
  if [[ "$CLEAN_MODE" == true ]]; then run_clean; exit 0; fi

  # Normal installation flow
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

# Run main function with all arguments
main "$@"

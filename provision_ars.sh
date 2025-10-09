#!/usr/bin/env bash
#
# provision_auto_start.sh
# Full automated provisioning for Pixel Streaming:
#  - install deps, download+extract archives, create tmux session with TURN/signaller/game instances
#
# Usage:
#   ./provision_auto_start.sh [-n NUM_INSTANCES] [--skip-download] [--session NAME] [--stop]
#
set -euo pipefail
IFS=$'\n\t'

# ---------- Config (tweak if needed) ----------
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
LOG_DIR="${LOG_DIR:-${WORKSPACE_DIR}/logs}"
INSTANCES="${INSTANCES:-3}"
SESSION_NAME="${SESSION_NAME:-pixel}"
GAME_LAUNCHER="${GAME_LAUNCHER:-${WORKSPACE_DIR}/Linux/AudioTestProject02.sh}"
SIGNALLER_DIR="${SIGNALLER_DIR:-${WORKSPACE_DIR}/PS_Next_Claude/WebServers/SignallingWebServer}"
SIGNALLER_START_SCRIPT="${SIGNALLER_START_SCRIPT:-${SIGNALLER_DIR}/platform_scripts/bash/start_with_turn.sh}"
SIGNALLER_REG_SCRIPT="${SIGNALLER_REG_SCRIPT:-${SIGNALLER_DIR}/platform_scripts/bash/fotonInstanceRegister_vast.sh}"
S3_PATH_LINUX="${S3_PATH_LINUX:-s3://psfiles2/Linux1002.7z}"
S3_PATH_PS="${S3_PATH_PS:-s3://psfiles2/PS_Next_Claude_904.7z}"
AUX_SCRIPT_URL="${AUX_SCRIPT_URL:-https://raw.githubusercontent.com/aaryansachdeva/vastStartupScripts/main/fotonInstanceRegister_vast.sh}"

# Ports (base values; each instance will increment)
BASE_PLAYER="${BASE_PLAYER:-81}"
BASE_STREAMER="${BASE_STREAMER:-8888}"
BASE_SFU="${BASE_SFU:-9888}"
TURN_LISTEN_PORT="${TURN_LISTEN_PORT:-19303}"

# TURN / registration creds
TURN_USER="${TURN_USER:-PixelStreamingUser}"
TURN_PASS="${TURN_PASS:-AnotherTURNintheroad}"
TURN_REALM="${TURN_REALM:-PixelStreaming}"

# Display & rendering
XVFB_BASE="${XVFB_BASE:-90}"
SCREEN_WIDTH="${SCREEN_WIDTH:-1920}"
SCREEN_HEIGHT="${SCREEN_HEIGHT:-1080}"
SCREEN_DEPTH="${SCREEN_DEPTH:-24}"

# Timing (seconds)
TURN_STARTUP_DELAY="${TURN_STARTUP_DELAY:-2}"
SIGNALLER_STARTUP_DELAY="${SIGNALLER_STARTUP_DELAY:-3}"
INSTANCE_STARTUP_DELAY="${INSTANCE_STARTUP_DELAY:-1}"

# Misc
FOTON_USER="${FOTON_USER:-foton}"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# ---------- Helpers ----------
log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
error() { log "ERROR: $*"; }
info() { log "INFO: $*"; }
warn() { log "WARN: $*"; }

mkdir -p "${LOG_DIR}" "${WORKSPACE_DIR}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -n, --instances NUM     Number of instances to start (default: ${INSTANCES})
  --skip-download         Skip S3 downloads and extraction
  --session NAME          Tmux session name (default: ${SESSION_NAME})
  --stop                  Stop all services and kill tmux session
  --status                Show status of running services
  -h, --help              Show this help message

Examples:
  $0 -n 3                 # Start 3 instances
  $0 --stop               # Stop all services
  $0 --status             # Check service status
EOF
  exit 0
}

# Parse args
SKIP_DOWNLOAD=0
STOP_MODE=0
STATUS_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--instances) INSTANCES="$2"; shift 2;;
    --skip-download) SKIP_DOWNLOAD=1; shift;;
    --session) SESSION_NAME="$2"; shift 2;;
    --stop) STOP_MODE=1; shift;;
    --status) STATUS_MODE=1; shift;;
    -h|--help) usage;;
    *) error "Unknown argument: $1"; usage;;
  esac
done

# ---------- Status mode ----------
if [[ "${STATUS_MODE}" -eq 1 ]]; then
  info "Checking status for session: ${SESSION_NAME}"
  if tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
    echo "Tmux session '${SESSION_NAME}' is running"
    echo "Windows:"
    tmux list-windows -t "${SESSION_NAME}"
    echo ""
    echo "To attach: tmux attach -t ${SESSION_NAME}"
  else
    echo "Tmux session '${SESSION_NAME}' is NOT running"
  fi
  exit 0
fi

# ---------- Stop mode ----------
if [[ "${STOP_MODE}" -eq 1 ]]; then
  info "Stopping session: ${SESSION_NAME}"
  if tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
    tmux kill-session -t "${SESSION_NAME}"
    info "Session killed successfully"
  else
    warn "Session '${SESSION_NAME}' does not exist"
  fi
  # Kill any stray processes
  pkill -f "turnserver.*${TURN_LISTEN_PORT}" || true
  pkill -f "AudioTestProject02" || true
  info "Cleanup complete"
  exit 0
fi

# ---------- Validation ----------
validate_environment() {
  local errors=0
  
  if [[ "${INSTANCES}" -lt 1 || "${INSTANCES}" -gt 20 ]]; then
    error "INSTANCES must be between 1 and 20 (got: ${INSTANCES})"
    ((errors++))
  fi
  
  if ! command -v tmux >/dev/null 2>&1; then
    error "tmux is required but not installed"
    ((errors++))
  fi
  
  if [[ "${errors}" -gt 0 ]]; then
    error "Validation failed with ${errors} error(s)"
    exit 1
  fi
}

validate_environment
info "Starting provisioning: session='${SESSION_NAME}', instances=${INSTANCES}"

# ---------- Network detection ----------
detect_network() {
  PUBLIC_IPADDR="${PUBLIC_IPADDR:-}"
  LOCAL_IP="${LOCAL_IP:-}"
  
  if [[ -z "${PUBLIC_IPADDR}" ]]; then
    info "Auto-detecting PUBLIC_IPADDR..."
    PUBLIC_IPADDR="$(curl -s --max-time 5 https://ipinfo.io/ip 2>/dev/null || \
                     curl -s --max-time 5 https://ifconfig.co 2>/dev/null || \
                     curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || \
                     echo '')"
  fi
  
  if [[ -z "${LOCAL_IP}" ]]; then
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '')"
  fi
  
  info "PUBLIC_IPADDR=${PUBLIC_IPADDR:-<not detected>}"
  info "LOCAL_IP=${LOCAL_IP:-<not detected>}"
  
  if [[ -z "${PUBLIC_IPADDR}" ]]; then
    warn "Could not detect PUBLIC_IPADDR - TURN may not work properly"
  fi
}

detect_network

# ---------- Package installation ----------
install_packages() {
  info "Updating package list..."
  if ! apt-get update -qq 2>&1 | grep -v "^Get:"; then
    warn "apt-get update had issues, but continuing..."
  fi
  
  local packages=(
    p7zip-full python3-pip curl wget tmux coturn
    xvfb x11-apps mesa-vulkan-drivers vulkan-tools
    libvulkan1 ffmpeg nodejs npm
  )
  
  info "Installing packages: ${packages[*]}"
  if ! apt-get install -y -qq "${packages[@]}" 2>&1 | grep -E "(Error|Failed)"; then
    info "Packages installed successfully"
  else
    warn "Some packages may have failed to install"
    apt-get install -y "${packages[@]}"
  fi
  
  # Verify critical tools
  if ! command -v 7z >/dev/null 2>&1; then
    error "7z is required but not available after install"
    exit 1
  fi
  
  # AWS CLI setup - always use pip to avoid urllib3 conflicts
  if [[ -n "${AWS_ACCESS_KEY:-}" && -n "${AWS_SECRET_KEY:-}" ]]; then
    if ! command -v aws >/dev/null 2>&1; then
      info "Installing awscli via pip (avoids urllib3 conflicts)..."
      # Remove apt version if it exists to prevent conflicts
      apt-get remove -y -qq awscli 2>/dev/null || true
      # Install via pip with compatible urllib3
      python3 -m pip install --upgrade --quiet 'awscli' 'urllib3<2' 'botocore' || {
        warn "pip install awscli failed, trying without urllib3 constraint..."
        python3 -m pip install --upgrade --quiet awscli
      }
      export PATH="$PATH:$(python3 -m site --user-base)/bin"
    else
      # Verify aws works, if not reinstall via pip
      if ! aws --version >/dev/null 2>&1; then
        warn "aws CLI exists but doesn't work, reinstalling via pip..."
        apt-get remove -y -qq awscli 2>/dev/null || true
        python3 -m pip uninstall -y awscli botocore urllib3 2>/dev/null || true
        python3 -m pip install --upgrade --quiet 'awscli' 'urllib3<2'
        export PATH="$PATH:$(python3 -m site --user-base)/bin"
      else
        info "aws CLI already working"
      fi
    fi
  else
    info "AWS credentials not set - S3 downloads will be skipped"
  fi
}

install_packages

# ---------- Download and extract ----------
download_from_s3() {
  local s3path="$1" dest="$2"
  
  if [[ ! -n "${AWS_ACCESS_KEY:-}" || ! -n "${AWS_SECRET_KEY:-}" ]]; then
    info "Skipping S3 download (no credentials): ${s3path}"
    return 1
  fi
  
  if ! command -v aws >/dev/null 2>&1; then
    warn "aws CLI not available, skipping: ${s3path}"
    return 1
  fi
  
  # Test aws CLI before attempting download
  if ! aws --version >/dev/null 2>&1; then
    error "aws CLI installed but not working (dependency issue)"
    info "Attempting to fix urllib3 compatibility..."
    python3 -m pip install --upgrade --quiet 'urllib3<2' 2>/dev/null || true
    if ! aws --version >/dev/null 2>&1; then
      error "Could not fix aws CLI. Please manually download: ${s3path}"
      return 1
    fi
  fi
  
  info "Downloading ${s3path} -> ${dest}"
  if AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY}" \
     AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY}" \
     aws --region "${AWS_REGION}" s3 cp "${s3path}" "${dest}" --no-progress 2>&1; then
    info "Download successful: $(basename "${s3path}")"
    return 0
  else
    error "Download failed: ${s3path}"
    error "Please verify: 1) AWS credentials are correct, 2) S3 path exists, 3) Permissions are set"
    return 1
  fi
}

extract_archive() {
  local archive="$1" outdir="${2:-${WORKSPACE_DIR}}"
  
  if [[ ! -f "${archive}" ]]; then
    warn "Archive not found, skipping: ${archive}"
    return 1
  fi
  
  info "Extracting: ${archive}"
  mkdir -p "${outdir}"
  
  if 7z x "${archive}" -o"${outdir}" -y >/dev/null 2>&1; then
    info "Extraction successful: $(basename "${archive}")"
    return 0
  else
    error "Extraction failed for: ${archive}"
    7z x "${archive}" -o"${outdir}" -y
    return 1
  fi
}

if [[ "${SKIP_DOWNLOAD}" -eq 0 ]]; then
  for s3path in "${S3_PATH_LINUX}" "${S3_PATH_PS}"; do
    fname="$(basename "${s3path}")"
    dest="${WORKSPACE_DIR}/${fname}"
    
    if [[ -f "${dest}" ]]; then
      info "Archive already exists: ${fname}"
    else
      download_from_s3 "${s3path}" "${dest}" || warn "Failed to download ${fname}"
    fi
    
    extract_archive "${dest}" "${WORKSPACE_DIR}" || warn "Failed to extract ${fname}"
  done
else
  info "Skipping downloads/extraction (--skip-download flag)"
fi

# ---------- Fetch auxiliary scripts ----------
fetch_registration_script() {
  mkdir -p "$(dirname "${SIGNALLER_REG_SCRIPT}")"
  
  if [[ -f "${SIGNALLER_REG_SCRIPT}" ]]; then
    info "Registration script already exists: ${SIGNALLER_REG_SCRIPT}"
    return 0
  fi
  
  info "Fetching registration script from: ${AUX_SCRIPT_URL}"
  if curl -fsSL "${AUX_SCRIPT_URL}" -o "${SIGNALLER_REG_SCRIPT}" 2>/dev/null || \
     wget -q -O "${SIGNALLER_REG_SCRIPT}" "${AUX_SCRIPT_URL}" 2>/dev/null; then
    chmod +x "${SIGNALLER_REG_SCRIPT}"
    info "Registration script fetched successfully"
    return 0
  else
    error "Failed to fetch registration script"
    return 1
  fi
}

fetch_registration_script

# Make all shell scripts executable
info "Setting executable permissions on shell scripts..."
find "${WORKSPACE_DIR}" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# ---------- User setup ----------
setup_user() {
  if ! id -u "${FOTON_USER}" >/dev/null 2>&1; then
    info "Creating user: ${FOTON_USER}"
    useradd -m -s /bin/bash "${FOTON_USER}" || warn "Failed to create user ${FOTON_USER}"
  else
    info "User already exists: ${FOTON_USER}"
  fi
  
  if [[ -d "${WORKSPACE_DIR}/Linux" ]]; then
    chown -R "${FOTON_USER}:${FOTON_USER}" "${WORKSPACE_DIR}/Linux" 2>/dev/null || \
      warn "Could not change ownership of Linux directory"
  fi
}

setup_user

# ---------- Tmux session setup ----------
setup_tmux_session() {
  if tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
    warn "Killing existing tmux session: ${SESSION_NAME}"
    tmux kill-session -t "${SESSION_NAME}"
    sleep 1
  fi
  
  info "Creating tmux session: ${SESSION_NAME}"
  tmux new-session -d -s "${SESSION_NAME}" -n turn
  tmux set-option -t "${SESSION_NAME}" remain-on-exit off 2>/dev/null || true
}

setup_tmux_session

# ---------- Start TURN server ----------
start_turn_server() {
  local turn_cmd="turnserver -n \
    --listening-port=${TURN_LISTEN_PORT} \
    --external-ip=${PUBLIC_IPADDR} \
    --relay-ip=${LOCAL_IP} \
    --user=${TURN_USER}:${TURN_PASS} \
    --realm=${TURN_REALM} \
    --no-tls --no-dtls -a -v"
  
  info "Starting TURN server on port ${TURN_LISTEN_PORT}"
  tmux send-keys -t "${SESSION_NAME}:turn" "${turn_cmd}" C-m
  sleep "${TURN_STARTUP_DELAY}"
}

start_turn_server

# ---------- Start instances ----------
start_instance() {
  local idx="$1"
  local pport=$((BASE_PLAYER + idx - 1))
  local sport=$((BASE_STREAMER + idx - 1))
  local sfup=$((BASE_SFU + idx - 1))
  local xvfb_display=$((XVFB_BASE + idx - 1))
  
  info "Configuring instance ${idx}: player=${pport}, streamer=${sport}, sfu=${sfup}, display=:${xvfb_display}"
  
  # Signalling server
  local sig_window="signaller${idx}"
  tmux new-window -t "${SESSION_NAME}" -n "${sig_window}"
  
  if [[ -x "${SIGNALLER_START_SCRIPT}" ]]; then
    local sign_cmd="cd '${SIGNALLER_DIR}' && '${SIGNALLER_START_SCRIPT}' \
      --player_port=${pport} --streamer_port=${sport} --sfu_port=${sfup} \
      > '${LOG_DIR}/signaller_${idx}.log' 2>&1"
    
    tmux send-keys -t "${SESSION_NAME}:${sig_window}" "${sign_cmd} & sleep 1 && tail -f '${LOG_DIR}/signaller_${idx}.log'" C-m
  else
    tmux send-keys -t "${SESSION_NAME}:${sig_window}" "echo 'ERROR: Signaller script not found: ${SIGNALLER_START_SCRIPT}'" C-m
  fi
  
  sleep "${SIGNALLER_STARTUP_DELAY}"
  
  # Game instance
  local game_window="game${idx}"
  tmux new-window -t "${SESSION_NAME}" -n "${game_window}"
  
  local game_cmd="sudo -H -u '${FOTON_USER}' bash -c '\
export DISPLAY=:${xvfb_display} && \
xvfb-run -n ${xvfb_display} -s \"-screen 0 ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}\" \
  \"${GAME_LAUNCHER}\" \
  -RenderOffscreen \
  -Vulkan \
  -PixelStreamingEncoderCodec=H264 \
  -PixelStreamingH264Profile=BASELINE \
  -PixelStreamingUrl=ws://localhost:${sport} \
  -PixelStreamingWebRTCStartBitrate=2000000 \
  -PixelStreamingWebRTCMinBitrate=1000000 \
  -PixelStreamingWebRTCMaxBitrate=4000000 \
  -PixelStreamingWebRTCMaxFps=30 \
  -ExecCmds=\"r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200\" \
  > \"${LOG_DIR}/game_${idx}.log\" 2>&1'"
  
  tmux send-keys -t "${SESSION_NAME}:${game_window}" "${game_cmd} & sleep 2 && tail -f '${LOG_DIR}/game_${idx}.log'" C-m
  
  # Registration
  local reg_window="reg${idx}"
  tmux new-window -t "${SESSION_NAME}" -n "${reg_window}"
  
  if [[ -x "${SIGNALLER_REG_SCRIPT}" ]]; then
    local reg_cmd="cd '$(dirname "${SIGNALLER_REG_SCRIPT}")' && \
'${SIGNALLER_REG_SCRIPT}' \
  --player_port=${pport} \
  --streamer_port=${sport} \
  --sfu_port=${sfup} \
  --publicip '${PUBLIC_IPADDR}' \
  --turn '${PUBLIC_IPADDR}:${TURN_LISTEN_PORT}' \
  --turn-user '${TURN_USER}' \
  --turn-pass '${TURN_PASS}' \
  --stun stun.l.google.com:19302 \
  > '${LOG_DIR}/register_${idx}.log' 2>&1"
    
    tmux send-keys -t "${SESSION_NAME}:${reg_window}" "${reg_cmd} & sleep 1 && tail -f '${LOG_DIR}/register_${idx}.log'" C-m
  else
    tmux send-keys -t "${SESSION_NAME}:${reg_window}" "echo 'ERROR: Registration script not found: ${SIGNALLER_REG_SCRIPT}'" C-m
  fi
  
  sleep "${INSTANCE_STARTUP_DELAY}"
}

# Start all instances
for i in $(seq 1 "${INSTANCES}"); do
  start_instance "${i}"
done

# ---------- Summary ----------
info "========================================="
info "Provisioning complete!"
info "Session: ${SESSION_NAME}"
info "Instances: ${INSTANCES}"
info "========================================="
info "Commands:"
info "  Attach:  tmux attach -t ${SESSION_NAME}"
info "  Status:  $0 --status"
info "  Stop:    $0 --stop"
info "========================================="
info "Logs directory: ${LOG_DIR}"
info "========================================="

# Show instance details
echo ""
echo "Instance Configuration:"
for i in $(seq 1 "${INSTANCES}"); do
  pport=$((BASE_PLAYER + i - 1))
  sport=$((BASE_STREAMER + i - 1))
  sfup=$((BASE_SFU + i - 1))
  echo "  Instance ${i}: Player=${pport}, Streamer=${sport}, SFU=${sfup}"
done
echo ""

info "Setup complete. Services starting in background..."

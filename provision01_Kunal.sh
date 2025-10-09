#!/usr/bin/env bash
#
# provision_auto_start.sh - FIXED VERSION
# Full automated provisioning for Pixel Streaming with proper wait logic
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

# Ports (matching your working manual process)
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

FOTON_USER="${FOTON_USER:-foton}"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# ---------- Helpers ----------
log() { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
mkdir -p "${LOG_DIR}" "${WORKSPACE_DIR}"

usage() {
  cat <<EOF
Usage: $0 [-n NUM_INSTANCES] [--skip-download] [--session NAME]
Example: $0 -n 2 --session pixel
EOF
  exit 1
}

# NEW: Wait for port to be listening
wait_for_port() {
  local port=$1
  local max_wait=${2:-30}
  local waited=0
  log "Waiting for port ${port} to be listening..."
  while ! netstat -tuln 2>/dev/null | grep -q ":${port} " && [ $waited -lt $max_wait ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if [ $waited -ge $max_wait ]; then
    log "WARNING: Port ${port} not ready after ${max_wait}s"
    return 1
  fi
  log "Port ${port} is ready (waited ${waited}s)"
  return 0
}

# NEW: Wait for HTTP endpoint
wait_for_http() {
  local url=$1
  local max_wait=${2:-30}
  local waited=0
  log "Waiting for HTTP endpoint ${url}..."
  while ! curl -sf "${url}" >/dev/null 2>&1 && [ $waited -lt $max_wait ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if [ $waited -ge $max_wait ]; then
    log "WARNING: HTTP endpoint ${url} not ready after ${max_wait}s"
    return 1
  fi
  log "HTTP endpoint ${url} is ready (waited ${waited}s)"
  return 0
}

# parse args
SKIP_DOWNLOAD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) INSTANCES="$2"; shift 2;;
    --skip-download) SKIP_DOWNLOAD=1; shift;;
    --session) SESSION_NAME="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

log "Starting provisioning: session='${SESSION_NAME}', instances=${INSTANCES}"

# Auto-detect PUBLIC_IPADDR and LOCAL_IP
PUBLIC_IPADDR="${PUBLIC_IPADDR:-}"
LOCAL_IP="${LOCAL_IP:-}"
if [ -z "${PUBLIC_IPADDR}" ]; then
  log "Auto-detecting PUBLIC_IPADDR..."
  PUBLIC_IPADDR="$(curl -s https://ipinfo.io/ip || curl -s https://ifconfig.co || echo '')"
  if [ -z "$PUBLIC_IPADDR" ]; then
    PUBLIC_IPADDR="$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || hostname -I | awk '{print $1}' || echo '')"
  fi
fi
if [ -z "${LOCAL_IP}" ]; then
  LOCAL_IP="$(hostname -I | awk '{print $1}' || echo '')"
fi
log "PUBLIC_IPADDR=${PUBLIC_IPADDR:-<empty>} LOCAL_IP=${LOCAL_IP:-<empty>}"

# ---------- Install required packages ----------
log "Installing required packages..."
apt-get update -qq || log "apt-get update warning (continuing)"
apt-get install -y -qq p7zip-full python3-pip curl wget tmux coturn xvfb x11-apps \
  mesa-vulkan-drivers vulkan-tools libvulkan1 ffmpeg nodejs npm netcat-openbsd || {
  log "Retrying package install with verbose output..."
  apt-get install -y p7zip-full python3-pip curl wget tmux coturn xvfb x11-apps \
    mesa-vulkan-drivers vulkan-tools libvulkan1 ffmpeg nodejs npm netcat-openbsd
}

# Install awscli via pip
if [[ -n "${AWS_ACCESS_KEY:-}" && -n "${AWS_SECRET_KEY:-}" ]]; then
  if ! command -v aws >/dev/null 2>&1; then
    log "Installing awscli via pip..."
    apt-get remove -y -qq awscli 2>/dev/null || true
    python3 -m pip install --upgrade --no-input 'awscli' 'urllib3<2' 'botocore' 2>&1 | grep -v "already satisfied" || {
      python3 -m pip install --upgrade --no-input awscli
    }
    export PATH="$PATH:$(python3 -m site --user-base 2>/dev/null)/bin"
  fi
fi

# ---------- Download and extract archives ----------
download_from_s3() {
  local s3path="$1"; local dest="$2"
  if [[ -n "${AWS_ACCESS_KEY:-}" && -n "${AWS_SECRET_KEY:-}" ]] && command -v aws >/dev/null 2>&1; then
    log "Downloading ${s3path} -> ${dest}"
    AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY}" \
      aws --region "${AWS_REGION}" s3 cp "${s3path}" "${dest}" --no-progress || return 1
    return 0
  else
    log "Skipping S3 download for ${s3path} (no aws or creds)"
    return 2
  fi
}

if [ "${SKIP_DOWNLOAD}" -eq 0 ]; then
  for s3 in "${S3_PATH_LINUX}" "${S3_PATH_PS}"; do
    fname="$(basename "${s3}")"
    dest="${WORKSPACE_DIR}/${fname}"
    if [[ -f "${dest}" ]]; then
      log "Archive already present: ${dest}"
      continue
    fi
    if download_from_s3 "${s3}" "${dest}"; then
      log "Downloaded ${fname}"
    else
      log "Warning: failed to download ${fname}"
    fi
  done

  extract_if_present() {
    local archive="$1" outdir="${2:-${WORKSPACE_DIR}}"
    if [[ -f "${archive}" ]]; then
      log "Extracting ${archive} -> ${outdir}"
      mkdir -p "${outdir}"
      7z x "${archive}" -o"${outdir}" -y >/dev/null 2>&1 || 7z x "${archive}" -o"${outdir}"
    fi
  }

  extract_if_present "${WORKSPACE_DIR}/$(basename "${S3_PATH_LINUX}")"
  extract_if_present "${WORKSPACE_DIR}/$(basename "${S3_PATH_PS}")"
fi

# Fetch registration script
mkdir -p "$(dirname "${SIGNALLER_REG_SCRIPT}")"
if [[ ! -f "${SIGNALLER_REG_SCRIPT}" ]]; then
  log "Fetching registration script..."
  curl -fsSL "${AUX_SCRIPT_URL}" -o "${SIGNALLER_REG_SCRIPT}" || \
    wget -q -O "${SIGNALLER_REG_SCRIPT}" "${AUX_SCRIPT_URL}"
  chmod +x "${SIGNALLER_REG_SCRIPT}" || true
fi

find /workspace/ -name "*.sh" -exec chmod +x {} \;

# Create foton user
if ! id -u "${FOTON_USER}" >/dev/null 2>&1; then
  log "Creating user ${FOTON_USER}"
  useradd -m "${FOTON_USER}" || true
fi
if [[ -d "${WORKSPACE_DIR}/Linux" ]]; then
  chown -R "${FOTON_USER}:${FOTON_USER}" "${WORKSPACE_DIR}/Linux" || true
fi

# ---------- FIXED: Proper startup sequence with waits ----------
if ! command -v tmux >/dev/null 2>&1; then
  log "tmux missing; installing..."
  apt-get install -y tmux
fi

# Kill existing session
if tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
  log "Killing existing tmux session ${SESSION_NAME}"
  tmux kill-session -t "${SESSION_NAME}"
fi

log "Creating tmux session ${SESSION_NAME}"
tmux new-session -d -s "${SESSION_NAME}" -n turn

# STEP 1: Start TURN server
TURN_CMD="turnserver -n --listening-port=${TURN_LISTEN_PORT} --external-ip=${PUBLIC_IPADDR:-} --relay-ip=${LOCAL_IP:-} --user=${TURN_USER}:${TURN_PASS} --realm=${TURN_REALM} --no-tls --no-dtls -a -v"
log "Starting TURN server..."
tmux send-keys -t "${SESSION_NAME}:turn" "${TURN_CMD}" C-m

# Wait for TURN to be ready
sleep 3
wait_for_port "${TURN_LISTEN_PORT}" 30 || log "TURN may not be ready, continuing anyway"

# STEP 2: Start signalling server (use base ports from first instance)
tmux new-window -t "${SESSION_NAME}" -n signaller
PLAYER_PORT_1="${BASE_PLAYER}"
STREAMER_PORT_1="${BASE_STREAMER}"
SFU_PORT_1="${BASE_SFU}"

if [[ -x "${SIGNALLER_START_SCRIPT}" ]]; then
  SIGN_CMD="${SIGNALLER_START_SCRIPT} --player_port=${PLAYER_PORT_1} --streamer_port=${STREAMER_PORT_1} --sfu_port=${SFU_PORT_1}"
  log "Starting signalling server (player=${PLAYER_PORT_1}, streamer=${STREAMER_PORT_1}, sfu=${SFU_PORT_1})..."
  tmux send-keys -t "${SESSION_NAME}:signaller" "cd ${SIGNALLER_DIR} && ${SIGN_CMD} 2>&1 | tee ${LOG_DIR}/signaller.log" C-m
  
  # CRITICAL: Wait for signalling server to be ready
  sleep 5
  wait_for_port "${PLAYER_PORT_1}" 60 || log "WARNING: Signaller player port not ready"
  wait_for_port "${STREAMER_PORT_1}" 60 || log "WARNING: Signaller streamer port not ready"
  
  # Additional wait to ensure full initialization
  sleep 3
  log "Signalling server ready"
else
  log "ERROR: Signaller start script not found: ${SIGNALLER_START_SCRIPT}"
  tmux send-keys -t "${SESSION_NAME}:signaller" "echo 'Signaller script missing'" C-m
fi

# STEP 3: Start game instances (with delays between each)
for i in $(seq 1 "${INSTANCES}"); do
  PPORT=$((BASE_PLAYER + i - 1))
  SPORT=$((BASE_STREAMER + i - 1))
  SFUP=$((BASE_SFU + i - 1))
  XVFB_DISPLAY=$((XVFB_BASE + i - 1))

  log "Starting instance ${i}/${INSTANCES} (player=${PPORT}, streamer=${SPORT}, sfu=${SFUP})..."

  # Create instance launcher script
  INSTANCE_SCRIPT="${WORKSPACE_DIR}/.ps_start_instance_${i}.sh"
  cat > "${INSTANCE_SCRIPT}" <<EOF
#!/usr/bin/env bash
export DISPLAY=":${XVFB_DISPLAY}"
echo "Instance ${i} starting at \$(date)"
echo "Connecting to ws://localhost:${SPORT}"

# Run as foton user with xvfb
sudo -H -u ${FOTON_USER} bash -lc "\
  xvfb-run -n ${XVFB_DISPLAY} -s '-screen 0 ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}' \
  '${GAME_LAUNCHER}' \
  -RenderOffscreen \
  -Vulkan \
  -PixelStreamingEncoderCodec=H264 \
  -PixelStreamingUrl=ws://localhost:${SPORT} \
  -PixelStreamingWebRTCStartBitrate=2000000 \
  -PixelStreamingWebRTCMinBitrate=1000000 \
  -PixelStreamingWebRTCMaxBitrate=4000000 \
  -PixelStreamingWebRTCMaxFps=30 \
  -ExecCmds='r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200' \
  2>&1 | tee ${LOG_DIR}/game_${i}.log"
EOF
  chmod +x "${INSTANCE_SCRIPT}"

  GW="game${i}"
  tmux new-window -t "${SESSION_NAME}" -n "${GW}"
  tmux send-keys -t "${SESSION_NAME}:${GW}" "bash ${INSTANCE_SCRIPT}" C-m

  # Wait for game instance to initialize before starting next one
  sleep 8
  log "Instance ${i} launched, waiting before next..."
done

# STEP 4: Register all instances (after ALL games have started)
log "Waiting 10s for all game instances to fully initialize before registration..."
sleep 10

for i in $(seq 1 "${INSTANCES}"); do
  PPORT=$((BASE_PLAYER + i - 1))
  SPORT=$((BASE_STREAMER + i - 1))
  SFUP=$((BASE_SFU + i - 1))

  log "Registering instance ${i}..."

  REG_SCRIPT="${WORKSPACE_DIR}/.ps_register_${i}.sh"
  cat > "${REG_SCRIPT}" <<EOF
#!/usr/bin/env bash
echo "Registering instance ${i} at \$(date)"
cd \$(dirname "${SIGNALLER_REG_SCRIPT}") || exit 1

${SIGNALLER_REG_SCRIPT} \
  --player_port=${PPORT} \
  --streamer_port=${SPORT} \
  --sfu_port=${SFUP} \
  --publicip ${PUBLIC_IPADDR:-} \
  --turn ${PUBLIC_IPADDR:-}:${TURN_LISTEN_PORT} \
  --turn-user ${TURN_USER} \
  --turn-pass ${TURN_PASS} \
  --stun stun.l.google.com:19302 \
  2>&1 | tee ${LOG_DIR}/register_${i}.log

echo "Registration complete for instance ${i}"
tail -f ${LOG_DIR}/register_${i}.log
EOF
  chmod +x "${REG_SCRIPT}"

  RW="reg${i}"
  tmux new-window -t "${SESSION_NAME}" -n "${RW}"
  tmux send-keys -t "${SESSION_NAME}:${RW}" "bash ${REG_SCRIPT}" C-m

  # Small delay between registrations
  sleep 2
done

log "=========================================="
log "Provisioning complete!"
log "Session: ${SESSION_NAME}"
log "Instances: ${INSTANCES}"
log "Player URL base: http://${PUBLIC_IPADDR}:${BASE_PLAYER}"
log "=========================================="
log "Attach: tmux attach -t ${SESSION_NAME}"
log "Windows: tmux list-windows -t ${SESSION_NAME}"
log "Logs: ${LOG_DIR}/"
log "=========================================="

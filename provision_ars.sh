#!/usr/bin/env bash
#
# provision_auto_start.sh
# Full automated provisioning for Pixel Streaming:
#  - install deps, download+extract archives, create tmux session with TURN/signaller/game instances
#
# Usage:
#   ./provision_auto_start.sh -n NUM_INSTANCES
#
set -euo pipefail
IFS=$'\n\t'

# ---------- Config (tweak if needed) ----------
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
LOG_DIR="${LOG_DIR:-${WORKSPACE_DIR}/logs}"
INSTANCES="${INSTANCES:-3}"              # default instances (can override with -n)
SESSION_NAME="${SESSION_NAME:-pixel}"    # tmux session
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

# Pixel flags (optional)
PIXEL_FLAGS='-RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingH264Profile=AUTO -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30'

# Misc
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

# Auto-detect PUBLIC_IPADDR and LOCAL_IP (best-effort)
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
log "Updating apt and installing packages (p7zip, python3-pip, curl, wget, tmux, coturn, xvfb, ffmpeg, nodejs)..."
if ! apt-get update -qq; then
  log "apt-get update failed (network?) — continuing and attempting installs"
fi
apt-get install -y -qq p7zip-full python3-pip curl wget tmux coturn xvfb x11-apps mesa-vulkan-drivers vulkan-tools libvulkan1 ffmpeg nodejs npm || {
  log "apt install returned non-zero; retrying with verbose apt..."
  apt-get install -y p7zip-full python3-pip curl wget tmux coturn xvfb x11-apps mesa-vulkan-drivers vulkan-tools libvulkan1 ffmpeg nodejs npm
}

# ensure 7z
if ! command -v 7z >/dev/null 2>&1; then
  log "7z missing after install; aborting."
  exit 1
fi

# awscli: ALWAYS use pip to avoid urllib3 conflicts with apt version
if [[ -n "${AWS_ACCESS_KEY:-}" && -n "${AWS_SECRET_KEY:-}" ]]; then
  if ! command -v aws >/dev/null 2>&1; then
    log "Installing awscli via pip (avoids urllib3 conflicts)..."
    # Remove apt version if it got installed
    apt-get remove -y -qq awscli 2>/dev/null || true
    # Install via pip with compatible urllib3 version
    python3 -m pip install --upgrade --no-input 'awscli' 'urllib3<2' 'botocore' 2>&1 | grep -v "already satisfied" || {
      log "First attempt failed, trying without version constraints..."
      python3 -m pip install --upgrade --no-input awscli
    }
    export PATH="$PATH:$(python3 -m site --user-base 2>/dev/null)/bin"
    log "Installed awscli via pip."
  else
    # Verify aws CLI actually works
    if ! aws --version >/dev/null 2>&1; then
      log "aws CLI exists but doesn't work, reinstalling via pip..."
      apt-get remove -y -qq awscli 2>/dev/null || true
      python3 -m pip uninstall -y awscli botocore urllib3 2>/dev/null || true
      python3 -m pip install --upgrade --no-input 'awscli' 'urllib3<2' 'botocore'
      export PATH="$PATH:$(python3 -m site --user-base 2>/dev/null)/bin"
      log "Reinstalled awscli via pip."
    else
      log "aws CLI already present and working."
    fi
  fi
else
  log "AWS creds not in env — will skip S3 downloads unless credentials are provided."
fi

# ---------- Download and extract archives (if requested) ----------
download_from_s3() {
  local s3path="$1"; local dest="$2"
  if [[ -n "${AWS_ACCESS_KEY:-}" && -n "${AWS_SECRET_KEY:-}" ]] && command -v aws >/dev/null 2>&1; then
    # Double-check aws works before attempting download
    if ! aws --version >/dev/null 2>&1; then
      log "ERROR: aws CLI not working, attempting quick fix..."
      python3 -m pip install --upgrade --quiet 'urllib3<2' 2>/dev/null || true
      if ! aws --version >/dev/null 2>&1; then
        log "ERROR: Could not fix aws CLI. Skipping ${s3path}"
        return 1
      fi
    fi
    
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
      log "Warning: failed to download ${fname} (continuing)"
    fi
  done

  extract_if_present() {
    local archive="$1" outdir="${2:-${WORKSPACE_DIR}}"
    if [[ -f "${archive}" ]]; then
      log "Extracting ${archive} -> ${outdir}"
      mkdir -p "${outdir}"
      if 7z x "${archive}" -o"${outdir}" -y >/dev/null 2>&1; then
        log "Extraction OK: ${archive}"
      else
        log "Extraction failed for ${archive} — retrying verbosely to show error"
        7z x "${archive}" -o"${outdir}"
      fi
    else
      log "Archive not found: ${archive} (skip)"
    fi
  }

  extract_if_present "${WORKSPACE_DIR}/$(basename "${S3_PATH_LINUX}")" "${WORKSPACE_DIR}"
  extract_if_present "${WORKSPACE_DIR}/$(basename "${S3_PATH_PS}")" "${WORKSPACE_DIR}"
else
  log "Skipping downloads/extraction (SKIP_DOWNLOAD set)"
fi

# ---------- Fetch registration script if missing ----------
mkdir -p "$(dirname "${SIGNALLER_REG_SCRIPT}")"
if [[ ! -f "${SIGNALLER_REG_SCRIPT}" ]]; then
  log "Fetching registration script -> ${SIGNALLER_REG_SCRIPT}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${AUX_SCRIPT_URL}" -o "${SIGNALLER_REG_SCRIPT}" || wget -q -O "${SIGNALLER_REG_SCRIPT}" "${AUX_SCRIPT_URL}" || log "Failed to fetch registration script"
  else
    wget -q -O "${SIGNALLER_REG_SCRIPT}" "${AUX_SCRIPT_URL}" || log "Failed to fetch registration script"
  fi
  chmod +x "${SIGNALLER_REG_SCRIPT}" || true
fi

find /workspace/ -name "*.sh" -exec chmod +x {} \;


# ---------- Ensure foton user and ownership ----------
if ! id -u "${FOTON_USER}" >/dev/null 2>&1; then
  log "Creating user ${FOTON_USER}"
  useradd -m "${FOTON_USER}" || true
fi
if [[ -d "${WORKSPACE_DIR}/Linux" ]]; then
  chown -R "${FOTON_USER}:${FOTON_USER}" "${WORKSPACE_DIR}/Linux" || true
fi

# ---------- tmux orchestration ----------
if ! command -v tmux >/dev/null 2>&1; then
  log "tmux missing; please install tmux (apt-get install tmux)"; exit 1
fi

# kill existing session if any
if tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
  log "Killing existing tmux session ${SESSION_NAME}"
  tmux kill-session -t "${SESSION_NAME}"
fi

log "Creating tmux session ${SESSION_NAME}"
tmux new-session -d -s "${SESSION_NAME}" -n turn

# Start turnserver in its window (keeps output in window)
TURN_CMD="turnserver -n --listening-port=${TURN_LISTEN_PORT} --external-ip=${PUBLIC_IPADDR:-} --relay-ip=${LOCAL_IP:-} --user=${TURN_USER}:${TURN_PASS} --realm=${TURN_REALM} --no-tls --no-dtls -a -v"
log "Starting TURN via tmux: ${TURN_CMD}"
tmux send-keys -t "${SESSION_NAME}:turn" "echo 'Starting coturn...'; ${TURN_CMD}" C-m
sleep 1

# Start single signaller (use base ports from instance 1)
tmux new-window -t "${SESSION_NAME}" -n signaller
STREAMER_PORT_1="${BASE_STREAMER}"
PLAYER_PORT_1="${BASE_PLAYER}"
SFU_PORT_1="${BASE_SFU}"
if [[ -x "${SIGNALLER_START_SCRIPT}" ]]; then
  SIGN_CMD="${SIGNALLER_START_SCRIPT} --player_port=${PLAYER_PORT_1} --streamer_port=${STREAMER_PORT_1} --sfu_port=${SFU_PORT_1}"
  log "Starting signaller in tmux: ${SIGN_CMD}"
  # run via nohup so signaller keeps running even if it forks
  tmux send-keys -t "${SESSION_NAME}:signaller" "cd ${SIGNALLER_DIR} || true; echo 'Starting signaller...'; nohup bash -lc '${SIGN_CMD}' > ${LOG_DIR}/signaller.log 2>&1 &; echo signaller-started; tail -n +1 ${LOG_DIR}/signaller.log" C-m
else
  tmux send-keys -t "${SESSION_NAME}:signaller" "echo 'Signaller start script missing: ${SIGNALLER_START_SCRIPT}'" C-m
fi

# Create per-instance wrapper scripts and tmux windows
for i in $(seq 1 "${INSTANCES}"); do
  PPORT=$((BASE_PLAYER + i - 1))
  SPORT=$((BASE_STREAMER + i - 1))
  SFUP=$((BASE_SFU + i - 1))
  XVFB_DISPLAY=$((XVFB_BASE + i - 1))

  # create instance start script to avoid tricky quoting
  INSTANCE_SCRIPT="${WORKSPACE_DIR}/.ps_start_instance_${i}.sh"
  cat > "${INSTANCE_SCRIPT}" <<EOF
#!/usr/bin/env bash
# instance ${i} launcher
XVFB_DISPLAY=${XVFB_DISPLAY}
export DISPLAY=":${XVFB_DISPLAY}"
echo "Instance ${i} - starting game (player=${PPORT} streamer=${SPORT} sfu=${SFUP})"
# run as foton - xvfb-run ensures a virtual display for the game
sudo -H -u ${FOTON_USER} bash -lc "xvfb-run -n ${XVFB_DISPLAY} -s '-screen 0 ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}' '${GAME_LAUNCHER}' -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingUrl=ws://localhost:${SPORT} -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30 -ExecCmds='r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200'"
EOF
  chmod +x "${INSTANCE_SCRIPT}"

  GW="game${i}"
  tmux new-window -t "${SESSION_NAME}" -n "${GW}"
  tmux send-keys -t "${SESSION_NAME}:${GW}" "echo 'Launching instance ${i} (see ${WORKSPACE_DIR}/.ps_start_instance_${i}.sh)'; bash ${INSTANCE_SCRIPT}" C-m

  # registration wrapper script (runs registration and writes to log)
  REG_SCRIPT="${WORKSPACE_DIR}/.ps_register_${i}.sh"
  cat > "${REG_SCRIPT}" <<EOF
#!/usr/bin/env bash
echo "Registering instance ${i}"
cd \$(dirname "${SIGNALLER_REG_SCRIPT}") || true
# run the registration script - log output
nohup bash -lc '${SIGNALLER_REG_SCRIPT} --player_port=${PPORT} --streamer_port=${SPORT} --sfu_port=${SFUP} --publicip ${PUBLIC_IPADDR:-} --turn ${PUBLIC_IPADDR:-}:${TURN_LISTEN_PORT} --turn-user ${TURN_USER} --turn-pass ${TURN_PASS} --stun stun.l.google.com:19302' > ${LOG_DIR}/register_${i}.log 2>&1 &
# tail registration log to make it visible in tmux window
sleep 1
tail -n +1 -f ${LOG_DIR}/register_${i}.log
EOF
  chmod +x "${REG_SCRIPT}"

  RW="reg${i}"
  tmux new-window -t "${SESSION_NAME}" -n "${RW}"
  tmux send-keys -t "${SESSION_NAME}:${RW}" "bash ${REG_SCRIPT}" C-m

  sleep 0.5
done

log "All ${INSTANCES} instance(s) launched in tmux session '${SESSION_NAME}'."
log "Attach to view: tmux attach -t ${SESSION_NAME}"
log "List windows: tmux list-windows -t ${SESSION_NAME}"

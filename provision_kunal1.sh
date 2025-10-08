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
INSTANCES="${INSTANCES:-1}"              
SESSION_NAME="${SESSION_NAME:-pixel}"    
GAME_LAUNCHER="${GAME_LAUNCHER:-${WORKSPACE_DIR}/Linux/AudioTestProject02.sh}"
SIGNALLER_DIR="${SIGNALLER_DIR:-${WORKSPACE_DIR}/PS_Next_Claude/WebServers/SignallingWebServer}"
SIGNALLER_START_SCRIPT="${SIGNALLER_START_SCRIPT:-${SIGNALLER_DIR}/platform_scripts/bash/start_with_turn.sh}"
SIGNALLER_REG_SCRIPT="${SIGNALLER_REG_SCRIPT:-${SIGNALLER_DIR}/platform_scripts/bash/fotonInstanceRegister_vast.sh}"
S3_PATH_LINUX="${S3_PATH_LINUX:-s3://psfiles2/Linux1002.7z}"
S3_PATH_PS="${S3_PATH_PS:-s3://psfiles2/PS_Next_Claude_904.7z}"
AUX_SCRIPT_URL="${AUX_SCRIPT_URL:-https://raw.githubusercontent.com/aaryansachdeva/vastStartupScripts/main/fotonInstanceRegister_vast.sh}"

BASE_PLAYER="${BASE_PLAYER:-81}"
BASE_STREAMER="${BASE_STREAMER:-8888}"
BASE_SFU="${BASE_SFU:-9888}"
TURN_LISTEN_PORT="${TURN_LISTEN_PORT:-19303}"

TURN_USER="${TURN_USER:-PixelStreamingUser}"
TURN_PASS="${TURN_PASS:-AnotherTURNintheroad}"
TURN_REALM="${TURN_REALM:-PixelStreaming}"

XVFB_BASE="${XVFB_BASE:-90}"
SCREEN_WIDTH="${SCREEN_WIDTH:-1920}"
SCREEN_HEIGHT="${SCREEN_HEIGHT:-1080}"
SCREEN_DEPTH="${SCREEN_DEPTH:-24}"

PIXEL_FLAGS='-RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30'

FOTON_USER="${FOTON_USER:-foton}"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

log() { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
mkdir -p "${LOG_DIR}" "${WORKSPACE_DIR}"

usage() {
  cat <<EOF
Usage: $0 [-n NUM_INSTANCES] [--skip-download] [--session NAME]
Example: $0 -n 2 --session pixel
EOF
  exit 1
}

# ---------- Argument parser ----------
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

# ---------- Auto-detect IPs ----------
PUBLIC_IPADDR="${PUBLIC_IPADDR:-$(curl -s https://ipinfo.io/ip || hostname -I | awk '{print $1}' || echo '')}"
LOCAL_IP="${LOCAL_IP:-$(hostname -I | awk '{print $1}' || echo '')}"
log "PUBLIC_IPADDR=${PUBLIC_IPADDR:-<empty>} LOCAL_IP=${LOCAL_IP:-<empty>}"

# ---------- Install dependencies ----------
log "Installing system dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y -qq p7zip-full python3-pip curl wget tmux coturn xvfb x11-apps mesa-vulkan-drivers vulkan-tools libvulkan1 ffmpeg nodejs npm awscli || true

# ---------- Download + extract archives ----------
download_from_s3() {
  local s3path="$1"; local dest="$2"
  if [[ -n "${AWS_ACCESS_KEY:-}" && -n "${AWS_SECRET_KEY:-}" ]] && command -v aws >/dev/null 2>&1; then
    log "Downloading ${s3path} -> ${dest}"
    AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY}" \
      aws --region "${AWS_REGION}" s3 cp "${s3path}" "${dest}" --no-progress || log "⚠️ Failed to download ${s3path}"
  else
    log "Skipping ${s3path} (no AWS credentials)"
  fi
}

extract_if_present() {
  local archive="$1" outdir="${2:-${WORKSPACE_DIR}}"
  if [[ -f "${archive}" ]]; then
    log "Extracting ${archive} -> ${outdir}"
    mkdir -p "${outdir}"
    7z x "${archive}" -o"${outdir}" -y >/dev/null 2>&1 && log "Extracted ${archive}"
  else
    log "Archive not found: ${archive}"
  fi
}

if [ "${SKIP_DOWNLOAD}" -eq 0 ]; then
  download_from_s3 "${S3_PATH_LINUX}" "${WORKSPACE_DIR}/$(basename "${S3_PATH_LINUX}")"
  download_from_s3 "${S3_PATH_PS}" "${WORKSPACE_DIR}/$(basename "${S3_PATH_PS}")"
  extract_if_present "${WORKSPACE_DIR}/$(basename "${S3_PATH_LINUX}")"
  extract_if_present "${WORKSPACE_DIR}/$(basename "${S3_PATH_PS}")"
fi

# ---------- FIX: Ensure every .sh file is executable ----------
log "Ensuring all shell scripts are executable..."
find "${WORKSPACE_DIR}" -type f -name "*.sh" -exec chmod +x {} \; || true
log "All .sh files chmodded ✅"

# ---------- FIX: Ensure Node dependencies installed ----------
if [[ -d "${SIGNALLER_DIR}" && -f "${SIGNALLER_DIR}/package.json" ]]; then
  log "Installing Node dependencies in ${SIGNALLER_DIR}..."
  cd "${SIGNALLER_DIR}" && npm ci || npm install || log "⚠️ npm install failed, continuing..."
fi

# ---------- Ensure foton user ----------
if ! id -u "${FOTON_USER}" >/dev/null 2>&1; then
  log "Creating user ${FOTON_USER}"
  useradd -m "${FOTON_USER}" || true
fi
if [[ -d "${WORKSPACE_DIR}/Linux" ]]; then
  chown -R "${FOTON_USER}:${FOTON_USER}" "${WORKSPACE_DIR}/Linux" || true
fi

# ---------- tmux orchestration ----------
if tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
  log "Killing old tmux session ${SESSION_NAME}"
  tmux kill-session -t "${SESSION_NAME}"
fi

log "Creating tmux session ${SESSION_NAME}"
tmux new-session -d -s "${SESSION_NAME}" -n turn

TURN_CMD="turnserver -n --listening-port=${TURN_LISTEN_PORT} --external-ip=${PUBLIC_IPADDR:-} --relay-ip=${LOCAL_IP:-} --user=${TURN_USER}:${TURN_PASS} --realm=${TURN_REALM} --no-tls --no-dtls -a -v"
log "Starting TURN via tmux: ${TURN_CMD}"
tmux send-keys -t "${SESSION_NAME}:turn" "echo 'Starting coturn...'; ${TURN_CMD}" C-m
sleep 1

# ---------- Start signaller ----------
tmux new-window -t "${SESSION_NAME}" -n signaller
if [[ -x "${SIGNALLER_START_SCRIPT}" ]]; then
  SIGN_CMD="${SIGNALLER_START_SCRIPT} --player_port=${BASE_PLAYER} --streamer_port=${BASE_STREAMER} --sfu_port=${BASE_SFU}"
  log "Launching signaller: ${SIGN_CMD}"
  tmux send-keys -t "${SESSION_NAME}:signaller" "cd ${SIGNALLER_DIR} || true; echo 'Starting signaller...'; nohup bash -lc '${SIGN_CMD}' > ${LOG_DIR}/signaller.log 2>&1 & tail -f ${LOG_DIR}/signaller.log" C-m
else
  tmux send-keys -t "${SESSION_NAME}:signaller" "echo '⚠️ Signaller script missing or not executable: ${SIGNALLER_START_SCRIPT}'" C-m
fi

# ---------- Game + registration ----------
for i in $(seq 1 "${INSTANCES}"); do
  PPORT=$((BASE_PLAYER + i - 1))
  SPORT=$((BASE_STREAMER + i - 1))
  SFUP=$((BASE_SFU + i - 1))
  XVFB_DISPLAY=$((XVFB_BASE + i - 1))

  INSTANCE_SCRIPT="${WORKSPACE_DIR}/.ps_start_instance_${i}.sh"
  cat > "${INSTANCE_SCRIPT}" <<EOF
#!/usr/bin/env bash
export DISPLAY=":${XVFB_DISPLAY}"
echo "Instance ${i} starting (player=${PPORT} streamer=${SPORT} sfu=${SFUP})"
sudo -H -u ${FOTON_USER} bash -lc "xvfb-run -n ${XVFB_DISPLAY} -s '-screen 0 ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}' '${GAME_LAUNCHER}' ${PIXEL_FLAGS} -PixelStreamingUrl=ws://localhost:${SPORT} -ExecCmds='r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200'"
EOF
  chmod +x "${INSTANCE_SCRIPT}"

  tmux new-window -t "${SESSION_NAME}" -n "game${i}"
  tmux send-keys -t "${SESSION_NAME}:game${i}" "bash ${INSTANCE_SCRIPT}" C-m

  REG_SCRIPT="${WORKSPACE_DIR}/.ps_register_${i}.sh"
  cat > "${REG_SCRIPT}" <<EOF
#!/usr/bin/env bash
echo "Registering instance ${i}"
cd \$(dirname "${SIGNALLER_REG_SCRIPT}") || true
nohup bash -lc '${SIGNALLER_REG_SCRIPT} --player_port=${PPORT} --streamer_port=${SPORT} --sfu_port=${SFUP} --publicip ${PUBLIC_IPADDR:-} --turn ${PUBLIC_IPADDR:-}:${TURN_LISTEN_PORT} --turn-user ${TURN_USER} --turn-pass ${TURN_PASS} --stun stun.l.google.com:19302' > ${LOG_DIR}/register_${i}.log 2>&1 &
sleep 1
tail -f ${LOG_DIR}/register_${i}.log
EOF
  chmod +x "${REG_SCRIPT}"

  tmux new-window -t "${SESSION_NAME}" -n "reg${i}"
  tmux send-keys -t "${SESSION_NAME}:reg${i}" "bash ${REG_SCRIPT}" C-m

  sleep 0.5
done

log "✅ All ${INSTANCES} instance(s) launched in tmux session '${SESSION_NAME}'."
log "Attach: tmux attach -t ${SESSION_NAME}"
log "List windows: tmux list-windows -t ${SESSION_NAME}"

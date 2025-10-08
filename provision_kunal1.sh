#!/usr/bin/env bash
#
# provision_auto_start.sh — Full automated provisioning for Pixel Streaming on Vast.ai
# Replaces previous script; includes a global chmod +x sweep for all .sh files in /workspace.
set -euo pipefail
IFS=$'\n\t'

# ---------- Config ----------
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
LOG_DIR="${LOG_DIR:-${WORKSPACE_DIR}/logs}"
INSTANCES="${INSTANCES:-2}"
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

FOTON_USER="${FOTON_USER:-foton}"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

log() { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
mkdir -p "${LOG_DIR}" "${WORKSPACE_DIR}"

# ---------- Detect IPs ----------
PUBLIC_IPADDR="${PUBLIC_IPADDR:-$(curl -s https://ipinfo.io/ip || hostname -I | awk '{print $1}' || echo '')}"
LOCAL_IP="${LOCAL_IP:-$(hostname -I | awk '{print $1}' || echo '')}"
log "PUBLIC_IPADDR=${PUBLIC_IPADDR:-<empty>} LOCAL_IP=${LOCAL_IP:-<empty>}"

# ---------- Install Packages ----------
log "Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y -qq p7zip-full python3-pip curl wget tmux coturn xvfb x11-apps mesa-vulkan-drivers vulkan-tools libvulkan1 ffmpeg nodejs npm awscli || true

# ---------- Download and Extract ----------
download_from_s3() {
  local s3path="$1" dest="$2"
  if [[ -n "${AWS_ACCESS_KEY:-}" && -n "${AWS_SECRET_KEY:-}" ]]; then
    log "Downloading ${s3path}..."
    AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY}" aws --region "${AWS_REGION}" s3 cp "${s3path}" "${dest}" --no-progress || log "aws cp failed for ${s3path}"
  else
    log "Skipping ${s3path} (no AWS creds)"
  fi
}
extract_if_present() {
  local archive="$1"
  [[ -f "$archive" ]] && log "Extracting $(basename "$archive")..." && 7z x "$archive" -o"${WORKSPACE_DIR}" -y >/dev/null 2>&1 && log "Extracted $(basename "$archive")"
}

download_from_s3 "${S3_PATH_LINUX}" "${WORKSPACE_DIR}/$(basename "${S3_PATH_LINUX}")"
download_from_s3 "${S3_PATH_PS}" "${WORKSPACE_DIR}/$(basename "${S3_PATH_PS}")"
extract_if_present "${WORKSPACE_DIR}/$(basename "${S3_PATH_LINUX}")"
extract_if_present "${WORKSPACE_DIR}/$(basename "${S3_PATH_PS}")"

# ---------- Ensure all .sh in workspace are executable (KEY FIX) ----------
log "Making all .sh files under ${WORKSPACE_DIR} executable (fixes missing exec bits)..."
# This will set the +x bit for every .sh found under /workspace
find "${WORKSPACE_DIR}" -type f -name "*.sh" -exec chmod +x {} \; || log "find+chmod had issues"

# Also make sure the signaller reg script (fetched earlier) is executable
chmod +x "${SIGNALLER_REG_SCRIPT}" 2>/dev/null || true

# ---------- Permission & Dependency Fixes (extra) ----------
log "Ensuring core scripts are executable and dependencies installed (extra checks)..."
chmod +x "${GAME_LAUNCHER}" 2>/dev/null || log "⚠️  Game launcher missing or not executable: ${GAME_LAUNCHER}"
chmod +x "${SIGNALLER_DIR}/platform_scripts/bash/start.sh" 2>/dev/null || log "⚠️  start.sh missing or not executable"
chmod +x "${SIGNALLER_DIR}/platform_scripts/bash/start_with_turn.sh" 2>/dev/null || log "⚠️  start_with_turn.sh missing or not executable"

# Ensure node deps for signaller
if [[ -f "${SIGNALLER_DIR}/package.json" ]]; then
  log "Installing npm dependencies for SignallingWebServer..."
  pushd "${SIGNALLER_DIR}" >/dev/null 2>&1 || true
  npm ci || npm install || log "⚠️ npm install failed!"
  popd >/dev/null 2>&1 || true
else
  log "No package.json in ${SIGNALLER_DIR}; skipping npm install"
fi

# ---------- Create foton user & fix ownership ----------
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

if tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
  log "Killing existing tmux session ${SESSION_NAME}"
  tmux kill-session -t "${SESSION_NAME}"
fi

log "Creating tmux session ${SESSION_NAME}"
tmux new-session -d -s "${SESSION_NAME}" -n turn

# Start turnserver and log to file, then tail so tmux pane shows the log
TURN_CMD="turnserver -n --listening-port=${TURN_LISTEN_PORT} --external-ip=${PUBLIC_IPADDR:-} --relay-ip=${LOCAL_IP:-} --user=${TURN_USER}:${TURN_PASS} --realm=${TURN_REALM} --no-tls --no-dtls -a -v"
tmux send-keys -t "${SESSION_NAME}:turn" "echo 'Starting coturn...'; nohup ${TURN_CMD} > ${LOG_DIR}/turnserver.out 2>&1 & sleep 1; tail -f ${LOG_DIR}/turnserver.out" C-m

# Start Signaller window
tmux new-window -t "${SESSION_NAME}" -n signaller
if [[ -x "${SIGNALLER_START_SCRIPT}" ]]; then
  SIGN_CMD="${SIGNALLER_START_SCRIPT} --player_port=${BASE_PLAYER} --streamer_port=${BASE_STREAMER} --sfu_port=${BASE_SFU}"
  tmux send-keys -t "${SESSION_NAME}:signaller" "cd ${SIGNALLER_DIR} || true; echo 'Starting signaller...'; nohup bash -lc '${SIGN_CMD}' > ${LOG_DIR}/signaller.log 2>&1 & sleep 1; tail -f ${LOG_DIR}/signaller.log" C-m
else
  tmux send-keys -t "${SESSION_NAME}:signaller" "echo '⚠️ Signaller start script missing or not executable: ${SIGNALLER_START_SCRIPT}'" C-m
fi

# ---------- Launch instances and registration windows ----------
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
# run as foton - xvfb-run ensures a virtual display for the game
sudo -H -u ${FOTON_USER} bash -lc "xvfb-run -n ${XVFB_DISPLAY} -s '-screen 0 ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}' '${GAME_LAUNCHER}' -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingUrl=ws://localhost:${SPORT} -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30 -ExecCmds='r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200'"
EOF
  chmod +x "${INSTANCE_SCRIPT}" || true

  GW="game${i}"
  tmux new-window -t "${SESSION_NAME}" -n "${GW}"
  tmux send-keys -t "${SESSION_NAME}:${GW}" "echo 'Launching instance ${i} (see ${INSTANCE_SCRIPT})'; bash ${INSTANCE_SCRIPT}" C-m

  REG_SCRIPT="${WORKSPACE_DIR}/.ps_register_${i}.sh"
  cat > "${REG_SCRIPT}" <<EOF
#!/usr/bin/env bash
cd \$(dirname "${SIGNALLER_REG_SCRIPT}") || exit 1
nohup bash -lc '${SIGNALLER_REG_SCRIPT} --player_port=${PPORT} --streamer_port=${SPORT} --sfu_port=${SFUP} --publicip ${PUBLIC_IPADDR} --turn ${PUBLIC_IPADDR}:${TURN_LISTEN_PORT} --turn-user ${TURN_USER} --turn-pass ${TURN_PASS} --stun stun.l.google.com:19302' > ${LOG_DIR}/register_${i}.log 2>&1 &
sleep 1
tail -f ${LOG_DIR}/register_${i}.log
EOF
  chmod +x "${REG_SCRIPT}" || true

  RW="reg${i}"
  tmux new-window -t "${SESSION_NAME}" -n "${RW}"
  tmux send-keys -t "${SESSION_NAME}:${RW}" "bash ${REG_SCRIPT}" C-m

  sleep 0.5
done

log "✅ All ${INSTANCES} instance(s) launched in tmux session '${SESSION_NAME}'."
log "Attach: tmux attach -t ${SESSION_NAME}"
log "Windows: tmux list-windows -t ${SESSION_NAME}"

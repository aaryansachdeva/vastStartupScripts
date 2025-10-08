#!/usr/bin/env bash
# provision01_Kunal.sh - FULL automated provisioning for Pixel Streaming on Vast.ai
# - Installs packages, downloads/extracts assets, starts coturn, signaller, registers instance,
#   creates foton user, starts headless Unreal game, and writes logs.
set -euo pipefail
IFS=$'\n\t'

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
LOG_DIR="${WORKSPACE_DIR}/logs"
TURN_LISTEN_PORT="${TURN_LISTEN_PORT:-19303}"
TURN_USER="${TURN_USER:-${TURN_USER:-PixelStreamingUser}}"
TURN_PASS="${TURN_PASS:-${TURN_PASS:-AnotherTURNintheroad}}"
TURN_REALM="${TURN_REALM:-PixelStreaming}"
GAME_LAUNCHER="${GAME_LAUNCHER:-${WORKSPACE_DIR}/Linux/AudioTestProject02.sh}"
SIGNALLER_DIR="${SIGNALLER_DIR:-${WORKSPACE_DIR}/PS_Next_Claude/WebServers/SignallingWebServer}"
SIGNALLER_START_SCRIPT="${SIGNALLER_START_SCRIPT:-${SIGNALLER_DIR}/platform_scripts/bash/start_with_turn.sh}"
SIGNALLER_REG_SCRIPT="${SIGNALLER_REG_SCRIPT:-${WORKSPACE_DIR}/vastStartupScripts/fotonInstanceRegister_vast.sh}"
STREAMER_PORT="${STREAMER_PORT:-8888}"
PLAYER_PORT="${PLAYER_PORT:-81}"
SFU_PORT="${SFU_PORT:-9888}"
FOTON_USER="${FOTON_USER:-foton}"
XVFB_DISPLAY_NUM="${XVFB_DISPLAY_NUM:-90}"
SCREEN_WIDTH="${SCREEN_WIDTH:-1920}"
SCREEN_HEIGHT="${SCREEN_HEIGHT:-1080}"
SCREEN_DEPTH="${SCREEN_DEPTH:-24}"
PIXEL_FLAGS='-RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingUrl=ws://localhost:8888 -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30 -ExecCmds="r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200"'

mkdir -p "${LOG_DIR}"
log(){ printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
log "Provision started"

# Auto-detect public/local IPs if not set
PUBLIC_IPADDR="${PUBLIC_IPADDR:-}"
if [ -z "${PUBLIC_IPADDR}" ]; then
  log "PUBLIC_IPADDR not set — attempting auto-detect"
  PUBLIC_IPADDR="$(curl -s https://ipinfo.io/ip || curl -s https://ifconfig.co || echo '')"
fi
LOCAL_IP="${LOCAL_IP:-$(hostname -I | awk '{print $1}' || echo '')}"
log "PUBLIC_IPADDR=${PUBLIC_IPADDR:-<empty>} LOCAL_IP=${LOCAL_IP:-<empty>}"

# Snapshot env useful for debugging
env | egrep 'PUBLIC_IPADDR|LOCAL_IP|AWS|TURN' > "${LOG_DIR}/prov_env_snapshot.txt" || true

# apt prerequisites
log "Updating apt and installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq p7zip-full xvfb x11-apps mesa-vulkan-drivers vulkan-tools libvulkan1 coturn curl git python3-pip nodejs npm ffmpeg >/dev/null 2>&1 || true

# pip awscli
if ! command -v aws >/dev/null 2>&1; then
  log "Installing awscli via pip3"
  pip3 install --no-input awscli >/dev/null 2>&1 || true
fi

# Ensure workspace exists
mkdir -p "${WORKSPACE_DIR}"
cd "${WORKSPACE_DIR}"

# Try to download .7z files from S3 if present (AWS creds must be set in env)
if [ -n "${AWS_ACCESS_KEY:-}" ] && [ -n "${AWS_SECRET_KEY:-}" ]; then
  log "AWS creds set — attempting to download archives from s3://psfiles2"
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY}"
  export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY}"
  aws s3 ls s3://psfiles2/ > "${LOG_DIR}/s3_list.txt" 2>&1 || true
  aws s3 cp s3://psfiles2/Linux1002.7z "${WORKSPACE_DIR}/" >> "${LOG_DIR}/s3_downloads.log" 2>&1 || log "Warning: failed to download Linux1002.7z"
  aws s3 cp s3://psfiles2/PS_Next_Claude_904.7z "${WORKSPACE_DIR}/" >> "${LOG_DIR}/s3_downloads.log" 2>&1 || log "Warning: failed to download PS_Next_Claude_904.7z"
else
  log "AWS creds not provided — skipping S3 download (ensure archives exist in ${WORKSPACE_DIR} if skipping)"
fi

# If local copies exist, skip download; show what's present
ls -la "${WORKSPACE_DIR}" | sed -n '1,200p' > "${LOG_DIR}/workspace_listing.txt" || true

# Extract archives if present
if [ -f "${WORKSPACE_DIR}/Linux1002.7z" ]; then
  log "Extracting Linux1002.7z (this may take a few minutes)..."
  7z x "${WORKSPACE_DIR}/Linux1002.7z" -o"${WORKSPACE_DIR}/" > "${LOG_DIR}/extract_linux_head.txt" 2>&1 || log "Warning: extraction of Linux1002.7z had an issue"
else
  log "Linux1002.7z not present in ${WORKSPACE_DIR}"
fi

if [ -f "${WORKSPACE_DIR}/PS_Next_Claude_904.7z" ]; then
  log "Extracting PS_Next_Claude_904.7z (this may take a few minutes)..."
  7z x "${WORKSPACE_DIR}/PS_Next_Claude_904.7z" -o"${WORKSPACE_DIR}/" > "${LOG_DIR}/extract_ps_head.txt" 2>&1 || log "Warning: extraction of PS_Next_Claude_904.7z had an issue"
else
  log "PS_Next_Claude_904.7z not present in ${WORKSPACE_DIR}"
fi

# Make scripts executable generally
find "${WORKSPACE_DIR}" -name "*.sh" -exec chmod +x {} \; || true

# ---------- Start TURN server ----------
start_turnserver(){
  log "Starting coturn (turnserver) on port ${TURN_LISTEN_PORT}..."
  turnserver -n --listening-port="${TURN_LISTEN_PORT}" --external-ip="${PUBLIC_IPADDR:-}" --relay-ip="${LOCAL_IP:-}" --user="${TURN_USER}:${TURN_PASS}" --realm="${TURN_REALM}" --no-tls --no-dtls -a -v > "${LOG_DIR}/turnserver.out" 2>&1 &
  sleep 1
  log "TURN server launched (logs -> ${LOG_DIR}/turnserver.out)"
}
start_turnserver || log "TURN start attempted"

# ---------- Start Signalling (Wilbur) ----------
start_signaller(){
  # Prefer the start script under PS_Next_Claude if present; fallback to any found start script
  if [ -x "${SIGNALLER_START_SCRIPT}" ]; then
    log "Using signaller start script: ${SIGNALLER_START_SCRIPT}"
    nohup bash -lc "${SIGNALLER_START_SCRIPT} --player_port=${PLAYER_PORT} --streamer_port=${STREAMER_PORT} --sfu_port=${SFU_PORT}" > "${LOG_DIR}/signaller.out" 2>&1 &
    sleep 2
    log "Signalling start requested (logs -> ${LOG_DIR}/signaller.out)"
    return 0
  fi

  # try to detect signaller dir and run node if dist exists
  if [ -d "${SIGNALLER_DIR}" ]; then
    log "Attempting to start signaller directly from ${SIGNALLER_DIR}"
    pushd "${SIGNALLER_DIR}" >/dev/null 2>&1 || return 1
    # ensure node modules
    if [ -f package.json ] && [ ! -d node_modules ]; then
      log "Installing signaller node modules..."
      npm ci --silent || npm install --silent || true
    fi
    # try to run npm start or node dist
    if npm run start --silent -- --player_port="${PLAYER_PORT}" --streamer_port="${STREAMER_PORT}" --sfu_port="${SFU_PORT}" > "${LOG_DIR}/signaller.out" 2>&1 &; then
      sleep 2
      popd >/dev/null 2>&1 || true
      log "Signaller started via npm (logs -> ${LOG_DIR}/signaller.out)"
      return 0
    fi
    popd >/dev/null 2>&1 || true
  fi

  log "Signaller start script not found. Please ensure ${SIGNALLER_START_SCRIPT} exists or ${SIGNALLER_DIR} contains start script."
  return 1
}
start_signaller || log "Signaller start attempted"

# Wait briefly for signaller to open port
log "Waiting for signaller port ${STREAMER_PORT}..."
for i in {1..12}; do
  ss -ltn | egrep "${STREAMER_PORT}" >/dev/null 2>&1 && break
  sleep 1
done
if ss -ltn | egrep "${STREAMER_PORT}" >/dev/null 2>&1; then
  log "Signaller listening on ${STREAMER_PORT}"
else
  log "Timeout waiting for signaller on ${STREAMER_PORT}"
fi

# ---------- Prepare user foton and ownership ----------
if id -u "${FOTON_USER}" >/dev/null 2>&1; then
  log "User ${FOTON_USER} exists"
else
  log "Creating user ${FOTON_USER}"
  useradd -m "${FOTON_USER}" || true
fi
log "Setting ownership for ${WORKSPACE_DIR}/Linux -> ${FOTON_USER}:${FOTON_USER}"
chown -R "${FOTON_USER}:${FOTON_USER}" "${WORKSPACE_DIR}/Linux" || true
# Ensure logs writable by foton
chown -R "${FOTON_USER}:${FOTON_USER}" "${LOG_DIR}" || true
chmod -R 775 "${LOG_DIR}" || true

# ---------- Register instance (if script exists) ----------
if [ -x "${SIGNALLER_REG_SCRIPT}" ]; then
  log "Running registration script: ${SIGNALLER_REG_SCRIPT}"
  PUBLIC_IP="${PUBLIC_IPADDR:-$(curl -s ifconfig.co)}"
  nohup bash -lc "cd $(dirname "${SIGNALLER_REG_SCRIPT}") && ./$(basename "${SIGNALLER_REG_SCRIPT}") --player_port=${PLAYER_PORT} --streamer_port=${STREAMER_PORT} --sfu_port=${SFU_PORT} --publicip ${PUBLIC_IP} --turn ${PUBLIC_IP}:${TURN_LISTEN_PORT} --turn-user ${TURN_USER} --turn-pass ${TURN_PASS} --stun stun.l.google.com:19302" > "${LOG_DIR}/register.out" 2>&1 &
  sleep 2
  log "Registration script launched (logs -> ${LOG_DIR}/register.out)"
else
  log "Registration script ${SIGNALLER_REG_SCRIPT} not found/executable. Skipping registration step."
fi

# ---------- Start headless game (as foton) ----------
start_game(){
  if [ ! -x "${GAME_LAUNCHER}" ]; then
    log "Game launcher not found/executable: ${GAME_LAUNCHER}. Skipping game start."
    return 1
  fi
  log "Starting game as ${FOTON_USER} (headless xvfb-run). Logs -> ${LOG_DIR}/game_*"
  cmd="xvfb-run -n ${XVFB_DISPLAY_NUM} -s \"-screen 0 ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}\" \"${GAME_LAUNCHER}\" ${PIXEL_FLAGS}"
  sudo -H -u "${FOTON_USER}" bash -lc "nohup bash -lc '${cmd}' > '${LOG_DIR}/game_stdout.log' 2> '${LOG_DIR}/game_stderr.log' &"
  sleep 2
  log "Game launched (logs -> ${LOG_DIR}/game_stdout.log, ${LOG_DIR}/game_stderr.log)"
}
start_game || true

# ---------- Final status & tips ----------
log "Provisioning finished. Check logs in ${LOG_DIR}:"
log "  turnserver: ${LOG_DIR}/turnserver.out"
log "  signaller: ${LOG_DIR}/signaller.out"
log "  register: ${LOG_DIR}/register.out"
log "  game stdout: ${LOG_DIR}/game_stdout.log"
log "  game stderr: ${LOG_DIR}/game_stderr.log"
log "If the game reports 'Could not setup hardware encoder' check 'nvidia-smi' and GPU drivers."

exit 0

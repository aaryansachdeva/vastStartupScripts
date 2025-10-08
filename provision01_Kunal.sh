#!/usr/bin/env bash
# provision.sh - FULL automated provisioning for Pixel Streaming on Vast.ai
set -euo pipefail
IFS=$'\n\t'

# ---------- Config (edit if needed) ----------
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
LOG_DIR="${WORKSPACE_DIR}/logs"
TURN_LISTEN_PORT="${TURN_LISTEN_PORT:-19303}"
TURN_USER="${TURN_USER:-PixelStreamingUser}"
TURN_PASS="${TURN_PASS:-AnotherTURNintheroad}"
TURN_REALM="${TURN_REALM:-PixelStreaming}"
GAME_LAUNCHER="${GAME_LAUNCHER:-${WORKSPACE_DIR}/Linux/AudioTestProject02.sh}"
SIGNALLER_DIR="${SIGNALLER_DIR:-${WORKSPACE_DIR}/PS_Next_Claude/WebServers/SignallingWebServer}"
SIGNALLER_START_SCRIPT="${SIGNALLER_START_SCRIPT:-${SIGNALLER_DIR}/platform_scripts/bash/start_with_turn.sh}"
SIGNALLER_REG_SCRIPT="${SIGNALLER_REG_SCRIPT:-${SIGNALLER_DIR}/platform_scripts/bash/fotonInstanceRegister_vast.sh}"
STREAMER_PORT="${STREAMER_PORT:-8888}"
PLAYER_PORT="${PLAYER_PORT:-81}"
SFU_PORT="${SFU_PORT:-9888}"
FOTON_USER="${FOTON_USER:-foton}"
XVFB_DISPLAY_NUM="${XVFB_DISPLAY_NUM:-90}"
SCREEN_WIDTH="${SCREEN_WIDTH:-1920}"
SCREEN_HEIGHT="${SCREEN_HEIGHT:-1080}"
SCREEN_DEPTH="${SCREEN_DEPTH:-24}"
PIXEL_FLAGS='-RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingUrl=ws://localhost:8888 -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30 -ExecCmds="r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200"'

# ---------- Helpers ----------
log() { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
mkdir -p "${LOG_DIR}"

# Auto-detect PUBLIC_IPADDR and LOCAL_IP if not provided
: "${PUBLIC_IPADDR:=${PUBLIC_IPADDR:-}}"
: "${LOCAL_IP:=${LOCAL_IP:-}}"
if [ -z "${PUBLIC_IPADDR}" ]; then
  log "PUBLIC_IPADDR not provided; trying auto-detect..."
  PUBLIC_IPADDR="$(curl -s https://ipinfo.io/ip || curl -s https://ifconfig.co || echo '')"
  if [ -z "$PUBLIC_IPADDR" ]; then
    PUBLIC_IPADDR="$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || hostname -I | awk '{print $1}' || echo '')"
  fi
fi
if [ -z "${LOCAL_IP}" ]; then
  LOCAL_IP="$(hostname -I | awk '{print $1}' || echo '')"
fi

log "PUBLIC_IPADDR=${PUBLIC_IPADDR:-<empty>} LOCAL_IP=${LOCAL_IP:-<empty>}"
env | egrep 'PUBLIC_IPADDR|LOCAL_IP|AWS|TURN' > "${LOG_DIR}/prov_env_snapshot.txt" || true

# -------- Optional: S3 download & extract (if AWS creds present) --------
if [ -n "${AWS_ACCESS_KEY:-}" ] && [ -n "${AWS_SECRET_KEY:-}" ]; then
  log "AWS creds found -> downloading 7z files from s3..."
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY}"
  export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY}"
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
  if ! command -v aws >/dev/null 2>&1; then
    pip3 install --no-input awscli || true
  fi
  aws s3 cp s3://psfiles2/Linux1002.7z "${WORKSPACE_DIR}/" || log "Warning: failed to download Linux1002.7z"
  aws s3 cp s3://psfiles2/PS_Next_Claude_904.7z "${WORKSPACE_DIR}/" || log "Warning: failed to download PS_Next_Claude_904.7z"
  if [ -f "${WORKSPACE_DIR}/Linux1002.7z" ]; then
    log "Extracting Linux1002.7z..."
    7z x "${WORKSPACE_DIR}/Linux1002.7z" -o"${WORKSPACE_DIR}/" || log "7z extract failed for Linux1002.7z"
  fi
  if [ -f "${WORKSPACE_DIR}/PS_Next_Claude_904.7z" ]; then
    log "Extracting PS_Next_Claude_904.7z..."
    7z x "${WORKSPACE_DIR}/PS_Next_Claude_904.7z" -o"${WORKSPACE_DIR}/" || log "7z extract failed for PS_Next_Claude_904.7z"
  fi
else
  log "AWS_ACCESS_KEY/AWS_SECRET_KEY not set - skipping S3 downloads (ensure files are extracted already)"
fi

# -------- Package install (best-effort) --------
export DEBIAN_FRONTEND=noninteractive
log "Updating apt and installing packages..."
apt-get update -qq
apt-get install -y -qq p7zip-full xvfb x11-apps mesa-vulkan-drivers vulkan-tools libvulkan1 coturn curl git python3-pip ffmpeg nodejs npm || true
if ! command -v aws >/dev/null 2>&1; then
  pip3 install --no-input awscli || true
fi

# -------- GPU check (informational) --------
if command -v nvidia-smi >/dev/null 2>&1; then
  log "nvidia-smi present — saving output"
  nvidia-smi > "${LOG_DIR}/nvidia-smi.txt" || true
else
  log "nvidia-smi not found — GPU/driver missing or not passed through. If you expect GPU, install drivers or pick GPU-enabled Vast.ai template."
fi

# -------- Utility: wait_for_port (tcp probe) --------
wait_for_port() {
  local host="${1:-localhost}"; local port="${2}"; local timeout="${3:-20}"; local start ts
  start=$(date +%s)
  log "Waiting up to ${timeout}s for ${host}:${port}..."
  while true; do
    if ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q LISTEN; then
      log "${host}:${port} is listening (tcp)."
      return 0
    fi
    # HTTP probe
    if curl -s "http://${host}:${port}" >/dev/null 2>&1; then
      log "${host}:${port} answered to HTTP probe."
      return 0
    fi
    ts=$(($(date +%s) - start))
    if [ "${ts}" -ge "${timeout}" ]; then
      log "Timeout waiting for ${host}:${port} after ${timeout}s."
      return 1
    fi
    sleep 1
  done
}

# -------- Start coturn (turnserver) --------
start_turnserver() {
  log "Starting coturn (turnserver) on port ${TURN_LISTEN_PORT}..."
  nohup turnserver -n --listening-port="${TURN_LISTEN_PORT}" --external-ip="${PUBLIC_IPADDR}" --relay-ip="${LOCAL_IP}" --user="${TURN_USER}:${TURN_PASS}" --realm="${TURN_REALM}" --no-tls --no-dtls -a -v > "${LOG_DIR}/turnserver.out" 2>&1 &
  sleep 1
  log "turnserver started -> ${LOG_DIR}/turnserver.out"
}
start_turnserver
wait_for_port 0.0.0.0 "${TURN_LISTEN_PORT}" 12 || log "turnserver port not confirmed (continuing anyway)"

# -------- Start signalling server if present --------
start_signaller_if_present() {
  if [ -x "${SIGNALLER_START_SCRIPT}" ]; then
    log "Found signaller start script -> starting..."
    mkdir -p "${SIGNALLER_DIR}/logs"
    nohup bash -lc "${SIGNALLER_START_SCRIPT} --player_port=${PLAYER_PORT} --streamer_port=${STREAMER_PORT} --sfu_port=${SFU_PORT}" > "${LOG_DIR}/signaller.out" 2>&1 &
    sleep 2
    log "Signaller start requested -> ${LOG_DIR}/signaller.out"
  else
    log "Signaller start script not found/executable: ${SIGNALLER_START_SCRIPT}"
    if [ -f "${SIGNALLER_DIR}/package.json" ]; then
      log "Detected package.json in signaller dir - attempting npm install"
      pushd "${SIGNALLER_DIR}" >/dev/null 2>&1 || return
      npm ci || npm install || true
      popd >/dev/null 2>&1 || true
      log "Try starting signaller manually if it still does not run."
    fi
  fi
}
start_signaller_if_present
wait_for_port localhost "${STREAMER_PORT}" 12 || log "Signalling server not answering on ${STREAMER_PORT} (game may log connection failures)"

# -------- Ensure foton user and ownership --------
if id -u "${FOTON_USER}" >/dev/null 2>&1; then
  log "User ${FOTON_USER} exists."
else
  log "Creating user ${FOTON_USER}..."
  useradd -m "${FOTON_USER}" || true
fi
log "Setting ownership for ${WORKSPACE_DIR}/Linux -> ${FOTON_USER}:${FOTON_USER}"
chown -R "${FOTON_USER}:${FOTON_USER}" "${WORKSPACE_DIR}/Linux" || true

# -------- Start headless game as foton --------
start_game_as_foton() {
  if [ ! -x "${GAME_LAUNCHER}" ]; then
    log "Game launcher not found/executable: ${GAME_LAUNCHER}. Skipping game start."
    return 1
  fi
  mkdir -p "${LOG_DIR}"
  log "Starting game as ${FOTON_USER} (headless xvfb-run). Logs: ${LOG_DIR}/game_*.log"
  cmd="xvfb-run -n ${XVFB_DISPLAY_NUM} -s \"-screen 0 ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}\" \"${GAME_LAUNCHER}\" ${PIXEL_FLAGS}"
  sudo -H -u "${FOTON_USER}" bash -lc "nohup bash -lc '${cmd}' > '${LOG_DIR}/game_stdout.log' 2> '${LOG_DIR}/game_stderr.log' &"
  sleep 2
}
start_game_as_foton || true

# -------- Register instance with signaller --------
if [ -x "${SIGNALLER_REG_SCRIPT}" ]; then
  log "Running instance registration script..."
  cd "$(dirname "${SIGNALLER_REG_SCRIPT}")"
  nohup bash -lc "./$(basename "${SIGNALLER_REG_SCRIPT}") --player_port=${PLAYER_PORT} --streamer_port=${STREAMER_PORT} --sfu_port=${SFU_PORT} --publicip ${PUBLIC_IPADDR} --turn ${PUBLIC_IPADDR}:${TURN_LISTEN_PORT} --turn-user ${TURN_USER} --turn-pass ${TURN_PASS} --stun stun.l.google.com:19302" > "${LOG_DIR}/register.out" 2>&1 &
  sleep 1
  log "Registration script started -> ${LOG_DIR}/register.out"
else
  log "Registration script not found/executable: ${SIGNALLER_REG_SCRIPT}"
fi

# -------- Done ----------
log "Provisioning finished. Logs in ${LOG_DIR}: turnserver.out signaller.out game_stdout.log game_stderr.log register.out"
log "If you see 'Could not setup hardware encoder' -> check nvidia-smi output and ensure the VM has GPU passthrough and drivers."
exit 0

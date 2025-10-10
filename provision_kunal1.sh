#!/usr/bin/env bash
# Quick fix: Run this first to create the complete script

cat > /workspace/provision_pixel.sh << 'ENDOFSCRIPT'
#!/usr/bin/env bash
#
# provision_auto_start.sh
# Full automated provisioning for Pixel Streaming on Vast.ai
# - Uses GNU Screen (reliable for automated scripts)
# - Installs Node.js 20 LTS for signalling server
# - Robust: fixes urllib3/botocore issues by using a venv awscli
# - Ensures all .sh under /workspace are executable
# - Installs npm deps for signaller
# - Starts coturn, signaller, game instances, and registers them
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

# Ports
SIGNALLER_PLAYER_PORT="${SIGNALLER_PLAYER_PORT:-79}"
SIGNALLER_STREAMER_PORT="${SIGNALLER_STREAMER_PORT:-8887}"
SIGNALLER_SFU_PORT="${SIGNALLER_SFU_PORT:-9887}"
BASE_PLAYER="${BASE_PLAYER:-81}"
BASE_STREAMER="${BASE_STREAMER:-8888}"
BASE_SFU="${BASE_SFU:-9888}"
TURN_LISTEN_PORT="${TURN_LISTEN_PORT:-19303}"

if [[ -n "${VAST_UDP_PORT_19303:-}" ]]; then
  TURN_PUBLIC_PORT="${VAST_UDP_PORT_19303}"
else
  TURN_PUBLIC_PORT="${TURN_LISTEN_PORT}"
fi

# TURN creds
TURN_USER="${TURN_USER:-PixelStreamingUser}"
TURN_PASS="${TURN_PASS:-AnotherTURNintheroad}"
TURN_REALM="${TURN_REALM:-PixelStreaming}"

# Display
XVFB_BASE="${XVFB_BASE:-90}"
SCREEN_WIDTH="${SCREEN_WIDTH:-1920}"
SCREEN_HEIGHT="${SCREEN_HEIGHT:-1080}"
SCREEN_DEPTH="${SCREEN_DEPTH:-24}"

PIXEL_FLAGS='-RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30'

FOTON_USER="${FOTON_USER:-foton}"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_VENV_DIR="${WORKSPACE_DIR}/.venv_aws"
AWS_VENV_BIN="${AWS_VENV_DIR}/bin/aws"

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

# ---------- Arg parsing ----------
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

# ---------- Ensure awscli ----------
ensure_aws_in_venv() {
  if command -v aws >/dev/null 2>&1; then
    if aws --version >/dev/null 2>&1; then
      AWS_VENV_BIN="$(command -v aws)"
      log "Using system aws: ${AWS_VENV_BIN}"
      return 0
    fi
  fi

  if [[ ! -x "${AWS_VENV_BIN}" ]]; then
    log "Creating venv for awscli..."
    python3 -m venv "${AWS_VENV_DIR}" || return 1
    source "${AWS_VENV_DIR}/bin/activate"
    python3 -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
    python3 -m pip install --no-cache-dir "awscli==1.42.48" "urllib3<2" >/dev/null 2>&1 || \
      python3 -m pip install --no-cache-dir awscli >/dev/null 2>&1 || { deactivate 2>/dev/null || true; return 1; }
    deactivate 2>/dev/null || true
  fi

  if [[ -x "${AWS_VENV_BIN}" ]]; then
    log "Using venv aws at ${AWS_VENV_BIN}"
    return 0
  fi
  return 1
}

ensure_aws_in_venv || log "Warning: aws venv not available"

# ---------- Download helper ----------
download_from_s3() {
  local s3path="$1"; local dest="$2"
  if [[ -z "${AWS_ACCESS_KEY:-}" || -z "${AWS_SECRET_KEY:-}" ]]; then
    log "Skipping S3 download (no creds)"
    return 2
  fi

  if [[ -x "${AWS_VENV_BIN}" ]]; then
    AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY}" \
      "${AWS_VENV_BIN}" --region "${AWS_REGION}" s3 cp "${s3path}" "${dest}" --no-progress || return 1
    return 0
  fi
  return 2
}

# ---------- Install packages ----------
log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y -qq p7zip-full python3-pip curl wget screen coturn xvfb x11-apps mesa-vulkan-drivers vulkan-tools libvulkan1 ffmpeg ca-certificates gnupg || \
  apt-get install -y p7zip-full python3-pip curl wget screen coturn xvfb x11-apps mesa-vulkan-drivers vulkan-tools libvulkan1 ffmpeg ca-certificates gnupg

# ---------- Install Node.js 20 ----------
log "Checking Node.js version..."
CURRENT_NODE_VERSION=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")

if [ "$CURRENT_NODE_VERSION" -lt 18 ]; then
  log "Installing Node.js 20 LTS..."
  apt-get remove -y nodejs npm 2>/dev/null || true
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || {
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq
  }
  apt-get install -y nodejs
  export PATH="/usr/local/bin:$PATH"
  hash -r 2>/dev/null || true
  log "Node.js: $(node --version 2>/dev/null || echo 'FAILED')"
  log "npm: $(npm --version 2>/dev/null || echo 'FAILED')"
else
  log "Node.js v${CURRENT_NODE_VERSION} OK"
fi

# ---------- Download and extract ----------
if [ "${SKIP_DOWNLOAD:-0}" -eq 0 ]; then
  for s3 in "${S3_PATH_LINUX}" "${S3_PATH_PS}"; do
    fname="$(basename "${s3}")"
    dest="${WORKSPACE_DIR}/${fname}"
    [[ -f "${dest}" ]] && continue
    download_from_s3 "${s3}" "${dest}" && log "Downloaded ${fname}" || log "Failed ${fname}"
  done

  extract_if_present() {
    local archive="$1" outdir="${2:-${WORKSPACE_DIR}}"
    [[ -f "${archive}" ]] || return
    log "Extracting ${archive}..."
    mkdir -p "${outdir}"
    7z x "${archive}" -o"${outdir}" -y >/dev/null 2>&1 || 7z x "${archive}" -o"${outdir}"
  }

  extract_if_present "${WORKSPACE_DIR}/$(basename "${S3_PATH_LINUX}")"
  extract_if_present "${WORKSPACE_DIR}/$(basename "${S3_PATH_PS}")"
fi

# ---------- Fetch registration script ----------
mkdir -p "$(dirname "${SIGNALLER_REG_SCRIPT}")"
if [[ ! -f "${SIGNALLER_REG_SCRIPT}" ]]; then
  log "Fetching registration script..."
  curl -fsSL "${AUX_SCRIPT_URL}" -o "${SIGNALLER_REG_SCRIPT}" || wget -q -O "${SIGNALLER_REG_SCRIPT}" "${AUX_SCRIPT_URL}"
  chmod +x "${SIGNALLER_REG_SCRIPT}" || true
fi

# ---------- Make scripts executable ----------
log "Making scripts executable..."
find "${WORKSPACE_DIR}" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# ---------- Install npm deps ----------
if [[ -d "${SIGNALLER_DIR}" && -f "${SIGNALLER_DIR}/package.json" ]]; then
  log "Installing npm dependencies..."
  pushd "${SIGNALLER_DIR}" >/dev/null || true
  NODE_VER=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")
  if [ "$NODE_VER" -ge 18 ]; then
    npm ci 2>&1 | grep -v "EBADENGINE" || npm install 2>&1 | grep -v "EBADENGINE"
    log "npm install complete"
  else
    log "WARNING: Node.js v${NODE_VER} too old!"
  fi
  popd >/dev/null || true
fi

# ---------- Create foton user ----------
if ! id -u "${FOTON_USER}" >/dev/null 2>&1; then
  log "Creating user ${FOTON_USER}"
  useradd -m "${FOTON_USER}" || true
fi
[[ -d "${WORKSPACE_DIR}/Linux" ]] && chown -R "${FOTON_USER}:${FOTON_USER}" "${WORKSPACE_DIR}/Linux" || true

# ---------- Screen session ----------
if ! command -v screen >/dev/null 2>&1; then
  log "ERROR: screen not installed!"
  exit 1
fi

if screen -ls | grep -q "\.${SESSION_NAME}"; then
  log "Killing existing session ${SESSION_NAME}"
  screen -S "${SESSION_NAME}" -X quit 2>/dev/null || true
  sleep 1
fi

log "Creating screen session ${SESSION_NAME}"
screen -dmS "${SESSION_NAME}"

# Start TURN
screen -S "${SESSION_NAME}" -X title "turn"
TURN_CMD="turnserver -n --listening-port=${TURN_LISTEN_PORT} --external-ip=${PUBLIC_IPADDR:-} --relay-ip=${LOCAL_IP:-} --user=${TURN_USER}:${TURN_PASS} --realm=${TURN_REALM} --no-tls --no-dtls -a -v"
log "Starting TURN..."
screen -S "${SESSION_NAME}" -p "turn" -X stuff "${TURN_CMD} > ${LOG_DIR}/turnserver.out 2>&1 & echo 'TURN started'; sleep 2; tail -f ${LOG_DIR}/turnserver.out^M"
sleep 3

# Start signaller
screen -S "${SESSION_NAME}" -X screen -t "signaller"
if [[ -x "${SIGNALLER_START_SCRIPT}" ]]; then
  SIGN_CMD="${SIGNALLER_START_SCRIPT} --player_port=${SIGNALLER_PLAYER_PORT} --streamer_port=${SIGNALLER_STREAMER_PORT} --sfu_port=${SIGNALLER_SFU_PORT}"
  log "Starting signaller..."
  screen -S "${SESSION_NAME}" -p "signaller" -X stuff "cd ${SIGNALLER_DIR} && ${SIGN_CMD} 2>&1 | tee ${LOG_DIR}/signaller.log^M"
  sleep 5
else
  log "ERROR: Signaller not found!"
fi

# nvidia monitoring
screen -S "${SESSION_NAME}" -X screen -t "nvidia"
screen -S "${SESSION_NAME}" -p "nvidia" -X stuff "nvidia-smi dmon -s um -d 1^M"

# Launch game instances
for i in $(seq 1 "${INSTANCES}"); do
  PPORT=$((BASE_PLAYER + i - 1))
  SPORT=$((BASE_STREAMER + i - 1))
  SFUP=$((BASE_SFU + i - 1))
  XVFB_DISPLAY=$((XVFB_BASE + i - 1))

  log "Starting instance ${i}..."

  INSTANCE_SCRIPT="${WORKSPACE_DIR}/.ps_start_${i}.sh"
  cat > "${INSTANCE_SCRIPT}" <<EOF
#!/usr/bin/env bash
export DISPLAY=":${XVFB_DISPLAY}"
echo "Instance ${i} starting..."
sudo -H -u ${FOTON_USER} bash -lc "xvfb-run -n ${XVFB_DISPLAY} -s '-screen 0 ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}' '${GAME_LAUNCHER}' -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingUrl=ws://localhost:${SPORT} -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30 -ExecCmds='r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200' 2>&1 | tee ${LOG_DIR}/game_${i}.log"
EOF
  chmod +x "${INSTANCE_SCRIPT}"

  screen -S "${SESSION_NAME}" -X screen -t "game${i}"
  screen -S "${SESSION_NAME}" -p "game${i}" -X stuff "bash ${INSTANCE_SCRIPT}^M"
  sleep 5
done

log "Waiting 10s for games to initialize..."
sleep 10

# Register instances
for i in $(seq 1 "${INSTANCES}"); do
  PPORT=$((BASE_PLAYER + i - 1))
  SPORT=$((BASE_STREAMER + i - 1))
  SFUP=$((BASE_SFU + i - 1))

  log "Registering instance ${i}..."

  REG_SCRIPT="${WORKSPACE_DIR}/.ps_register_${i}.sh"
  cat > "${REG_SCRIPT}" <<EOF
#!/usr/bin/env bash
cd \$(dirname "${SIGNALLER_REG_SCRIPT}") || exit 1
${SIGNALLER_REG_SCRIPT} --player_port=${PPORT} --streamer_port=${SPORT} --sfu_port=${SFUP} --publicip ${PUBLIC_IPADDR} --turn ${PUBLIC_IPADDR}:${TURN_PUBLIC_PORT} --turn-user ${TURN_USER} --turn-pass ${TURN_PASS} --stun stun.l.google.com:19302 2>&1 | tee ${LOG_DIR}/register_${i}.log
tail -f ${LOG_DIR}/register_${i}.log
EOF
  chmod +x "${REG_SCRIPT}"

  screen -S "${SESSION_NAME}" -X screen -t "reg${i}"
  screen -S "${SESSION_NAME}" -p "reg${i}" -X stuff "bash ${REG_SCRIPT}^M"
  sleep 2
done

log "✅ Provisioning complete!"
log ""
log "Attach: screen -r ${SESSION_NAME}"
log "Player: http://${PUBLIC_IPADDR}:${BASE_PLAYER}"
log "TURN: ${PUBLIC_IPADDR}:${TURN_PUBLIC_PORT}"
log ""
log "Logs: ${LOG_DIR}/"
ENDOFSCRIPT

chmod +x /workspace/provision_pixel.sh
echo "✅ Script created at /workspace/provision_pixel.sh"
echo ""
echo "Run it with:"
echo "  /workspace/provision_pixel.sh -n 3"

#!/usr/bin/env bash
#
# provision_auto_start.sh
# Full automated provisioning for Pixel Streaming on Vast.ai
# - Uses tmux (byobu has terminal issues in automated scripts)
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
INSTANCES="${INSTANCES:-1}"              # default instances (can override with -n)
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
PIXEL_FLAGS='-RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30'

# Misc
FOTON_USER="${FOTON_USER:-foton}"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# aws venv location (used when system aws is broken or missing)
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

# ---------- Auto-detect PUBLIC_IPADDR and LOCAL_IP (best-effort) ----------
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

# ---------- Ensure Python venv with compatible awscli (fix botocore/urllib3 issues) ----------
ensure_aws_in_venv() {
  # Prefer working system aws if present
  if command -v aws >/dev/null 2>&1; then
    if aws --version >/dev/null 2>&1; then
      AWS_VENV_BIN="$(command -v aws)"
      log "Using system aws: ${AWS_VENV_BIN}"
      return 0
    fi
  fi

  # Create venv if missing or broken
  if [[ ! -x "${AWS_VENV_BIN}" ]]; then
    log "Creating isolated venv for awscli at ${AWS_VENV_DIR}..."
    python3 -m venv "${AWS_VENV_DIR}" || { log "python3 -m venv failed"; return 1; }
    # shellcheck disable=SC1090
    source "${AWS_VENV_DIR}/bin/activate"
    python3 -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
    # pin awscli v1 and keep urllib3 < 2 to avoid DEFAULT_CIPHERS incompatibility
    python3 -m pip install --no-cache-dir "awscli==1.42.48" "urllib3<2" >/dev/null 2>&1 || {
      log "Failed to install awscli into venv; attempting unpinned install..."
      python3 -m pip install --no-cache-dir awscli >/dev/null 2>&1 || { log "awscli install failed"; deactivate 2>/dev/null || true; return 1; }
    }
    deactivate 2>/dev/null || true
  fi

  if [[ -x "${AWS_VENV_BIN}" ]]; then
    log "Using venv aws at ${AWS_VENV_BIN}"
    return 0
  fi

  log "No usable aws CLI available"
  return 1
}

# Prepare venv/aws before any S3 work
ensure_aws_in_venv || log "Warning: aws venv not available; S3 downloads may be skipped"

# ---------- Download helper using venv/aws when possible ----------
download_from_s3() {
  local s3path="$1"; local dest="$2"
  if [[ -z "${AWS_ACCESS_KEY:-}" || -z "${AWS_SECRET_KEY:-}" ]]; then
    log "Skipping S3 download for ${s3path} (no AWS_ACCESS_KEY/AWS_SECRET_KEY in env)"
    return 2
  fi

  if [[ -x "${AWS_VENV_BIN}" ]]; then
    log "Downloading ${s3path} -> ${dest} using ${AWS_VENV_BIN}"
    AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY}" \
      "${AWS_VENV_BIN}" --region "${AWS_REGION}" s3 cp "${s3path}" "${dest}" --no-progress || { log "aws s3 cp failed for ${s3path}"; return 1; }
    return 0
  elif command -v aws >/dev/null 2>&1; then
    log "Downloading ${s3path} -> ${dest} using system aws"
    AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY}" \
      aws --region "${AWS_REGION}" s3 cp "${s3path}" "${dest}" --no-progress || { log "system aws s3 cp failed for ${s3path}"; return 1; }
    return 0
  else
    log "No aws CLI available to download ${s3path}"
    return 2
  fi
}

# ---------- Install required packages (best-effort) ----------
log "Updating apt and installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || log "apt-get update failed"
apt-get install -y -qq p7zip-full python3-pip curl wget screen coturn xvfb x11-apps mesa-vulkan-drivers vulkan-tools libvulkan1 ffmpeg ca-certificates gnupg || {
  log "apt install returned non-zero; retrying without -qq for visibility..."
  apt-get install -y p7zip-full python3-pip curl wget screen coturn xvfb x11-apps mesa-vulkan-drivers vulkan-tools libvulkan1 ffmpeg ca-certificates gnupg || log "apt-get install failed"
}

# ensure 7z present
if ! command -v 7z >/dev/null 2>&1; then
  log "7z missing after install; will skip extraction"
fi

# ---------- Install Node.js 20 LTS (CRITICAL for signalling server) ----------
log "Checking Node.js version..."
CURRENT_NODE_VERSION=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")

if [ "$CURRENT_NODE_VERSION" -lt 18 ]; then
  log "Node.js v${CURRENT_NODE_VERSION} is too old. Installing Node.js 20 LTS..."
  
  # Remove old nodejs/npm
  apt-get remove -y nodejs npm 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
  
  # Install Node.js 20 LTS using NodeSource
  log "Installing Node.js 20 LTS from NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || {
    log "NodeSource setup failed, trying manual method..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq
  }
  
  apt-get install -y nodejs || {
    log "Failed to install Node.js from NodeSource, trying alternative..."
    # Try using n version manager as fallback
    npm install -g n 2>/dev/null && n lts || log "All Node.js install methods failed"
  }
  
  # Update PATH
  export PATH="/usr/local/bin:$PATH"
  hash -r 2>/dev/null || true
  
  # Verify installation
  NEW_NODE_VERSION=$(node --version 2>/dev/null || echo "not installed")
  log "Node.js version after install: ${NEW_NODE_VERSION}"
  log "npm version after install: $(npm --version 2>/dev/null || echo 'not installed')"
  
  if ! command -v node >/dev/null 2>&1 || [ "$(node --version | sed 's/v//' | cut -d. -f1)" -lt 18 ]; then
    log "⚠️  CRITICAL: Node.js 18+ installation FAILED!"
    log "⚠️  Signalling server will NOT work. Please install Node.js 18+ manually."
  else
    log "✅ Node.js $(node --version) installed successfully"
  fi
else
  log "✅ Node.js v${CURRENT_NODE_VERSION} is acceptable (>= 18)"
fi

# ---------- Download and extract archives (if requested) ----------
if [ "${SKIP_DOWNLOAD:-0}" -eq 0 ]; then
  for s3 in "${S3_PATH_LINUX}" "${S3_PATH_PS}"; do
    fname="$(basename "${s3}")"
    dest="${WORKSPACE_DIR}/${fname}"
    if [[ -f "${dest}" ]]; then
      log "Archive already present: ${dest}"
      continue
    fi
    if download_from_s3 "${s3}" "${dest}"; then
      log "Downloaded ${fname}."
    else
      log "⚠️ Failed to download ${fname}"
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
        log "Extraction failed for ${archive} — retrying verbosely"
        7z x "${archive}" -o"${outdir}"
      fi
    else
      log "Archive not found: ${archive} (skip)"
    fi
  }

  extract_if_present "${WORKSPACE_DIR}/$(basename "${S3_PATH_LINUX}")"
  extract_if_present "${WORKSPACE_DIR}/$(basename "${S3_PATH_PS}")"
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

# ---------- Ensure all .sh in workspace are executable ----------
log "Making all .sh files under ${WORKSPACE_DIR} executable..."
find "${WORKSPACE_DIR}" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || log "find+chmod had issues"
log "All .sh files chmodded ✅"

# ---------- Ensure signaller npm deps ----------
if [[ -d "${SIGNALLER_DIR}" && -f "${SIGNALLER_DIR}/package.json" ]]; then
  log "Installing npm dependencies for SignallingWebServer..."
  pushd "${SIGNALLER_DIR}" >/dev/null 2>&1 || true
  
  # Verify Node.js version before npm install
  NODE_VER=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")
  if [ "$NODE_VER" -ge 18 ]; then
    log "Node.js $(node --version) - installing npm packages..."
    
    # Try npm ci first (faster, more reliable), fall back to npm install
    # Suppress EBADENGINE warnings as they're just noise
    if npm ci 2>&1 | grep -v "EBADENGINE" | tee /tmp/npm_install.log | grep -q "added\|up to date"; then
      log "✅ npm ci completed"
    elif npm install 2>&1 | grep -v "EBADENGINE" | tee /tmp/npm_install.log | grep -q "added\|up to date"; then
      log "✅ npm install completed"
    else
      log "⚠️  npm install had issues but continuing..."
      tail -20 /tmp/npm_install.log 2>/dev/null || true
    fi
  else
    log "⚠️  CRITICAL: Node.js v${NODE_VER} is too old (need >=18)"
    log "    Skipping npm install - signalling server WILL FAIL!"
  fi
  
  popd >/dev/null 2>&1 || true
else
  log "No package.json found in ${SIGNALLER_DIR}; skipping npm install"
fi

# ---------- Ensure foton user and ownership ----------
if ! id -u "${FOTON_USER}" >/dev/null 2>&1; then
  log "Creating user ${FOTON_USER}"
  useradd -m "${FOTON_USER}" || true
fi
if [[ -d "${WORKSPACE_DIR}/Linux" ]]; then
  chown -R "${FOTON_USER}:${FOTON_USER}" "${WORKSPACE_DIR}/Linux" || true
fi

# ---------- Screen orchestration ----------
if ! command -v screen >/dev/null 2>&1; then
  log "screen missing; please install screen"; exit 1
fi

# Kill existing session if any
if screen -ls | grep -q "\.${SESSION_NAME}[[:space:]]"; then
  log "Killing existing screen session ${SESSION_NAME}"
  screen -S "${SESSION_NAME}" -X quit 2>/dev/null || true
  sleep 1
fi

log "Creating screen session ${SESSION_NAME}"
# Create detached screen session
screen -dmS "${SESSION_NAME}"

# Start turnserver in first window (rename it to 'turn')
TURN_CMD="turnserver -n --listening-port=${TURN_LISTEN_PORT} --external-ip=${PUBLIC_IPADDR:-} --relay-ip=${LOCAL_IP:-} --user=${TURN_USER}:${TURN_PASS} --realm=${TURN_REALM} --no-tls --no-dtls -a -v"
log "Starting TURN via screen: ${TURN_CMD}"
screen -S "${SESSION_NAME}" -X title "turn"
screen -S "${SESSION_NAME}" -p "turn" -X stuff "echo 'Starting coturn...'; nohup ${TURN_CMD} > ${LOG_DIR}/turnserver.out 2>&1 & sleep 1; tail -f ${LOG_DIR}/turnserver.out^M"
sleep 1

# Create new window for signaller
screen -S "${SESSION_NAME}" -X screen -t "signaller"
STREAMER_PORT_1="${BASE_STREAMER}"
PLAYER_PORT_1="${BASE_PLAYER}"
SFU_PORT_1="${BASE_SFU}"
if [[ -x "${SIGNALLER_START_SCRIPT}" ]]; then
  SIGN_CMD="${SIGNALLER_START_SCRIPT} --player_port=${PLAYER_PORT_1} --streamer_port=${STREAMER_PORT_1} --sfu_port=${SFU_PORT_1}"
  log "Starting signaller in screen: ${SIGN_CMD}"
  screen -S "${SESSION_NAME}" -p "signaller" -X stuff "cd ${SIGNALLER_DIR} || true; echo 'Starting signaller...'; nohup bash -lc '${SIGN_CMD}' > ${LOG_DIR}/signaller.log 2>&1 & sleep 1; tail -f ${LOG_DIR}/signaller.log^M"
else
  screen -S "${SESSION_NAME}" -p "signaller" -X stuff "echo 'Signaller start script missing: ${SIGNALLER_START_SCRIPT}'^M"
fi

# ---------- Launch instances and registration windows ----------
for i in $(seq 1 "${INSTANCES}"); do
  PPORT=$((BASE_PLAYER + i - 1))
  SPORT=$((BASE_STREAMER + i - 1))
  SFUP=$((BASE_SFU + i - 1))
  XVFB_DISPLAY=$((XVFB_BASE + i - 1))

  # create instance start script
  INSTANCE_SCRIPT="${WORKSPACE_DIR}/.ps_start_instance_${i}.sh"
  cat > "${INSTANCE_SCRIPT}" <<EOF
#!/usr/bin/env bash
export DISPLAY=":${XVFB_DISPLAY}"
echo "Instance ${i} - starting game (player=${PPORT} streamer=${SPORT} sfu=${SFUP})"
sudo -H -u ${FOTON_USER} bash -lc "xvfb-run -n ${XVFB_DISPLAY} -s '-screen 0 ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}' '${GAME_LAUNCHER}' ${PIXEL_FLAGS} -PixelStreamingUrl=ws://localhost:${SPORT} -ExecCmds='r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200'"
EOF
  chmod +x "${INSTANCE_SCRIPT}" || true

  # Create new window for game instance
  GW="game${i}"
  screen -S "${SESSION_NAME}" -X screen -t "${GW}"
  screen -S "${SESSION_NAME}" -p "${GW}" -X stuff "echo 'Launching instance ${i} (see ${INSTANCE_SCRIPT})'; bash ${INSTANCE_SCRIPT}^M"

  # registration wrapper script
  REG_SCRIPT="${WORKSPACE_DIR}/.ps_register_${i}.sh"
  cat > "${REG_SCRIPT}" <<EOF
#!/usr/bin/env bash
echo "Registering instance ${i}"
cd \$(dirname "${SIGNALLER_REG_SCRIPT}") || true
nohup bash -lc '${SIGNALLER_REG_SCRIPT} --player_port=${PPORT} --streamer_port=${SPORT} --sfu_port=${SFUP} --publicip ${PUBLIC_IPADDR:-} --turn ${PUBLIC_IPADDR:-}:${TURN_LISTEN_PORT} --turn-user ${TURN_USER} --turn-pass ${TURN_PASS} --stun stun.l.google.com:19302' > ${LOG_DIR}/register_${i}.log 2>&1 &
sleep 1
tail -f ${LOG_DIR}/register_${i}.log
EOF
  chmod +x "${REG_SCRIPT}" || true

  # Create new window for registration
  RW="reg${i}"
  screen -S "${SESSION_NAME}" -X screen -t "${RW}"
  screen -S "${SESSION_NAME}" -p "${RW}" -X stuff "bash ${REG_SCRIPT}^M"

  sleep 0.5
done

log "✅ All ${INSTANCES} instance(s) launched in screen session '${SESSION_NAME}'."
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "📺 SCREEN COMMANDS"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""
log "🔗 Attach to session:"
log "   screen -r ${SESSION_NAME}"
log ""
log "📋 List all sessions:"
log "   screen -ls"
log ""
log "🪟 List windows in session:"
log "   screen -S ${SESSION_NAME} -X windows"
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "⌨️  INSIDE SCREEN SESSION - KEYBOARD SHORTCUTS"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""
log "   Ctrl+a c     - Create new window"
log "   Ctrl+a n     - Next window"
log "   Ctrl+a p     - Previous window"
log "   Ctrl+a \"     - List all windows (interactive)"
log "   Ctrl+a S     - Split horizontal"
log "   Ctrl+a |     - Split vertical"
log "   Ctrl+a d     - Detach session"
log "   Ctrl+a A     - Rename current window"
log "   Ctrl+a Tab   - Switch between splits"
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "📁 LOG FILES"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""
log "   ${LOG_DIR}/turnserver.out"
log "   ${LOG_DIR}/signaller.log"
for i in $(seq 1 "${INSTANCES}"); do
log "   ${LOG_DIR}/register_${i}.log"
done
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "🌐 ACCESS"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""
log "   Player URL: http://${PUBLIC_IPADDR}:${BASE_PLAYER}"
log "   TURN: ${PUBLIC_IPADDR}:${TURN_LISTEN_PORT}"
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

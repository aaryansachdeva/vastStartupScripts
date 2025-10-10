#!/usr/bin/env bash
#
# provision_auto_start.sh
# Full automated provisioning for Pixel Streaming on Vast.ai
# - Uses GNU Screen instead of tmux
# - Robust: fixes urllib3/botocore issues by using a venv awscli
# - Ensures all .sh under /workspace are executable
# - Installs npm deps for signaller
# - Starts coturn, signaller, game instances, and registers them (screen)
#
set -euo pipefail
IFS=$'\n\t'

# ---------- Config (tweak if needed) ----------
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
LOG_DIR="${LOG_DIR:-${WORKSPACE_DIR}/logs}"
INSTANCES="${INSTANCES:-1}"              # default instances (can override with -n)
SESSION_NAME="${SESSION_NAME:-pixel}"    # screen session
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
log "Updating apt and installing packages (p7zip, python3-pip, curl, wget, screen, coturn, xvfb, ffmpeg, nodejs)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || log "apt-get update failed"
apt-get install -y -qq p7zip-full python3-pip curl wget screen coturn xvfb x11-apps mesa-vulkan-drivers vulkan-tools libvulkan1 ffmpeg nodejs npm || {
  log "apt install returned non-zero; retrying without -qq for visibility..."
  apt-get install -y p7zip-full python3-pip curl wget screen coturn xvfb x11-apps mesa-vulkan-drivers vulkan-tools libvulkan1 ffmpeg nodejs npm || log "apt-get install failed"
}

# ensure 7z present
if ! command -v 7z >/dev/null 2>&1; then
  log "7z missing after install; aborting extraction step"
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

# ---------- Ensure all .sh in workspace are executable (KEY FIX) ----------
log "Making all .sh files under ${WORKSPACE_DIR} executable..."
find "${WORKSPACE_DIR}" -type f -name "*.sh" -exec chmod +x {} \; || log "find+chmod had issues"
log "All .sh files chmodded ✅"

# ---------- Ensure signaller npm deps ----------
if [[ -d "${SIGNALLER_DIR}" && -f "${SIGNALLER_DIR}/package.json" ]]; then
  log "Installing npm dependencies for SignallingWebServer..."
  pushd "${SIGNALLER_DIR}" >/dev/null 2>&1 || true
  npm ci || npm install || log "npm install failed (continuing)"
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
  log "screen missing; please install screen (apt-get install screen)"; exit 1
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
log "Screen commands:"
log "  Attach:        screen -r ${SESSION_NAME}"
log "  List sessions: screen -ls"
log "  List windows:  screen -S ${SESSION_NAME} -X windows"
log ""
log "Inside screen session:"
log "  Switch window: Ctrl+a \" (shows list)"
log "  Next window:   Ctrl+a n"
log "  Prev window:   Ctrl+a p"
log "  Detach:        Ctrl+a d"
log ""
log "Logs available in: ${LOG_DIR}/"

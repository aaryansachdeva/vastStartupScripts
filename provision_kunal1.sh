#!/usr/bin/env bash
# Simple Pixel Streaming Auto-Provisioning
# Matches your working manual process exactly
set -euo pipefail

# ========== CONFIG ==========
WORKSPACE_DIR="/workspace"
LOG_DIR="${WORKSPACE_DIR}/logs"
INSTANCES="${1:-3}"  # Default 1 instance, override with: ./script.sh 3
SESSION_NAME="pixel"

# Paths
GAME_LAUNCHER="${WORKSPACE_DIR}/Linux/AudioTestProject02.sh"
SIGNALLER_DIR="${WORKSPACE_DIR}/PS_Next_Claude/WebServers/SignallingWebServer"
SIGNALLER_SCRIPT="${SIGNALLER_DIR}/platform_scripts/bash/start_with_turn.sh"
REG_SCRIPT="${SIGNALLER_DIR}/platform_scripts/bash/fotonInstanceRegister_vast.sh"

# S3 downloads
S3_LINUX="s3://psfiles2/Linux1002.7z"
S3_PS="s3://psfiles2/PS_Next_Claude_904.7z"
REG_SCRIPT_URL="https://raw.githubusercontent.com/aaryansachdeva/vastStartupScripts/main/fotonInstanceRegister_vast.sh"

# Ports (EXACTLY like your manual process)
SIGNALLER_PLAYER_PORT=79
SIGNALLER_STREAMER_PORT=8887
SIGNALLER_SFU_PORT=9887
GAME_STREAMER_PORT=8888  # Game connects here
GAME_PLAYER_PORT=81      # Registration uses this
GAME_SFU_PORT=9888       # Registration uses this
TURN_PORT=19303

# TURN config
TURN_USER="PixelStreamingUser"
TURN_PASS="AnotherTURNintheroad"
TURN_REALM="PixelStreaming"

# Display
XVFB_DISPLAY=90
SCREEN_RES="1920x1080x24"

# User
FOTON_USER="foton"

# ========== HELPERS ==========
log() { echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $*"; }
mkdir -p "${LOG_DIR}"

# ========== DETECT IPs ==========
log "Detecting IPs..."
PUBLIC_IPADDR="${PUBLIC_IPADDR:-$(curl -s https://ipinfo.io/ip || hostname -I | awk '{print $1}')}"
LOCAL_IP="${LOCAL_IP:-$(hostname -I | awk '{print $1}')}"
TURN_PUBLIC_PORT="${VAST_UDP_PORT_19303:-$TURN_PORT}"  # Use Vast.ai mapped port if available
log "Public IP: $PUBLIC_IPADDR | Local IP: $LOCAL_IP | TURN Port: $TURN_PUBLIC_PORT"

# ========== INSTALL PACKAGES ==========
log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq \
  p7zip-full curl wget screen coturn xvfb x11-apps \
  mesa-vulkan-drivers vulkan-tools libvulkan1 ca-certificates gnupg \
  2>&1 | grep -v "^debconf:" || true

# ========== INSTALL NODE.JS 20 ==========
log "Installing Node.js 20..."
NODE_VER=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")
if [ "$NODE_VER" -lt 18 ]; then
  apt-get remove -y nodejs npm 2>/dev/null || true
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>&1 | tail -5
  apt-get install -y nodejs 2>&1 | tail -3
  log "Node.js installed: $(node --version)"
else
  log "Node.js OK: v${NODE_VER}"
fi

# ========== DOWNLOAD FROM S3 ==========
if [[ -n "${AWS_ACCESS_KEY:-}" && -n "${AWS_SECRET_KEY:-}" ]]; then
  # Install awscli if needed
  if ! command -v aws &>/dev/null; then
    log "Installing awscli..."
    pip3 install --quiet awscli 2>&1 | tail -1
  fi
  
  # Download files
  for s3path in "$S3_LINUX" "$S3_PS"; do
    fname=$(basename "$s3path")
    [[ -f "${WORKSPACE_DIR}/${fname}" ]] && continue
    log "Downloading ${fname}..."
    AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY" \
      aws s3 cp "$s3path" "${WORKSPACE_DIR}/${fname}" --no-progress 2>&1 | tail -1
  done
  
  # Extract archives
  for archive in "${WORKSPACE_DIR}/Linux1002.7z" "${WORKSPACE_DIR}/PS_Next_Claude_904.7z"; do
    [[ ! -f "$archive" ]] && continue
    log "Extracting $(basename $archive)..."
    7z x "$archive" -o"${WORKSPACE_DIR}" -y 2>&1 | tail -3
  done
else
  log "Skipping S3 downloads (no AWS creds)"
fi

# ========== FETCH REGISTRATION SCRIPT ==========
if [[ ! -f "$REG_SCRIPT" ]]; then
  log "Downloading registration script..."
  mkdir -p "$(dirname "$REG_SCRIPT")"
  curl -fsSL "$REG_SCRIPT_URL" -o "$REG_SCRIPT" 2>&1 | tail -1
fi

# ========== MAKE SCRIPTS EXECUTABLE ==========
log "Making scripts executable..."
find "${WORKSPACE_DIR}" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# ========== INSTALL NPM DEPENDENCIES ==========
if [[ -f "${SIGNALLER_DIR}/package.json" ]]; then
  log "Installing npm dependencies..."
  cd "${SIGNALLER_DIR}"
  npm ci 2>&1 | grep -E "added|removed|audited" || npm install 2>&1 | tail -3
  cd - >/dev/null
fi

# ========== CREATE FOTON USER ==========
if ! id -u "$FOTON_USER" &>/dev/null; then
  log "Creating user ${FOTON_USER}..."
  useradd -m "$FOTON_USER" 2>&1 | tail -1
fi
[[ -d "${WORKSPACE_DIR}/Linux" ]] && chown -R "${FOTON_USER}:${FOTON_USER}" "${WORKSPACE_DIR}/Linux" 2>/dev/null || true

# ========== KILL OLD SCREEN SESSION ==========
if screen -ls | grep -q "\.${SESSION_NAME}"; then
  log "Killing old screen session..."
  screen -S "$SESSION_NAME" -X quit 2>/dev/null || true
  sleep 1
fi

# ========== CREATE SCREEN SESSION ==========
log "Creating screen session: $SESSION_NAME"
screen -dmS "$SESSION_NAME"

# ========== WINDOW 1: TURN SERVER ==========
log "Starting TURN server..."
screen -S "$SESSION_NAME" -X title "turn"
TURN_CMD="turnserver -n --listening-port=${TURN_PORT} --external-ip=${PUBLIC_IPADDR} --relay-ip=${LOCAL_IP} --user=${TURN_USER}:${TURN_PASS} --realm=${TURN_REALM} --no-tls --no-dtls -a -v"
screen -S "$SESSION_NAME" -p "turn" -X stuff "${TURN_CMD} 2>&1 | tee ${LOG_DIR}/turn.log^M"
sleep 2

# ========== WINDOW 2: SIGNALLING SERVER (EXACTLY like your manual command) ==========
log "Starting signalling server (player=${SIGNALLER_PLAYER_PORT}, streamer=${SIGNALLER_STREAMER_PORT}, sfu=${SIGNALLER_SFU_PORT})..."
screen -S "$SESSION_NAME" -X screen -t "signaller"
screen -S "$SESSION_NAME" -p "signaller" -X stuff "cd ${SIGNALLER_DIR} && ${SIGNALLER_SCRIPT} --player_port=${SIGNALLER_PLAYER_PORT} --streamer_port=${SIGNALLER_STREAMER_PORT} --sfu_port=${SIGNALLER_SFU_PORT} 2>&1 | tee ${LOG_DIR}/signaller.log^M"
sleep 5

# ========== WINDOW 3: NVIDIA STATS ==========
log "Starting nvidia monitoring..."
screen -S "$SESSION_NAME" -X screen -t "nvidia"
screen -S "$SESSION_NAME" -p "nvidia" -X stuff "nvidia-smi dmon -s um -d 1^M"

# ========== LAUNCH GAME INSTANCES ==========
for i in $(seq 1 "$INSTANCES"); do
  INSTANCE_NUM=$i
  GAME_DISPLAY=$((XVFB_DISPLAY + i - 1))
  
  log "Starting game instance ${i}/${INSTANCES}..."
  
  # Create game launcher script (EXACTLY like your manual command)
  cat > "${WORKSPACE_DIR}/.game_${i}.sh" <<EOF
#!/usr/bin/env bash
export DISPLAY=":${GAME_DISPLAY}"
echo "Game instance ${i} starting..."
sudo -H -u ${FOTON_USER} bash -c "xvfb-run -n ${GAME_DISPLAY} -s '-screen 0 ${SCREEN_RES}' ${GAME_LAUNCHER} -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingUrl=ws://localhost:${GAME_STREAMER_PORT} -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30 -ExecCmds='r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200' 2>&1 | tee ${LOG_DIR}/game_${i}.log"
EOF
  chmod +x "${WORKSPACE_DIR}/.game_${i}.sh"
  
  # Launch in screen window
  screen -S "$SESSION_NAME" -X screen -t "game${i}"
  screen -S "$SESSION_NAME" -p "game${i}" -X stuff "bash ${WORKSPACE_DIR}/.game_${i}.sh^M"
  sleep 3
done

# Wait for games to initialize
log "Waiting for games to initialize..."
sleep 10

# ========== REGISTER INSTANCES ==========
for i in $(seq 1 "$INSTANCES"); do
  INSTANCE_NUM=$i
  REG_PLAYER_PORT=$((GAME_PLAYER_PORT + i - 1))
  REG_STREAMER_PORT=$((GAME_STREAMER_PORT + i - 1))
  REG_SFU_PORT=$((GAME_SFU_PORT + i - 1))
  
  log "Registering instance ${i}..."
  
  # Create registration script (EXACTLY like your manual command)
  cat > "${WORKSPACE_DIR}/.register_${i}.sh" <<EOF
#!/usr/bin/env bash
cd ${SIGNALLER_DIR}/platform_scripts/bash
./fotonInstanceRegister_vast.sh --player_port=${REG_PLAYER_PORT} --streamer_port=${REG_STREAMER_PORT} --sfu_port=${REG_SFU_PORT} --publicip ${PUBLIC_IPADDR} --turn ${PUBLIC_IPADDR}:${TURN_PUBLIC_PORT} --turn-user ${TURN_USER} --turn-pass ${TURN_PASS} --stun stun.l.google.com:19302 --server_url=https://test.fotonlabs.com 2>&1 | tee ${LOG_DIR}/register_${i}.log
tail -f ${LOG_DIR}/register_${i}.log
EOF
  chmod +x "${WORKSPACE_DIR}/.register_${i}.sh"
  
  # Launch in screen window
  screen -S "$SESSION_NAME" -X screen -t "reg${i}"
  screen -S "$SESSION_NAME" -p "reg${i}" -X stuff "bash ${WORKSPACE_DIR}/.register_${i}.sh^M"
  sleep 2
done

# ========== DONE ==========
log ""
log "=========================================="
log "✅ PROVISIONING COMPLETE!"
log "=========================================="
log ""
log "Screen session: $SESSION_NAME"
log "Attach: screen -r $SESSION_NAME"
log "List windows: screen -S $SESSION_NAME -X windows"
log ""
log "Player URL: http://${PUBLIC_IPADDR}:${GAME_PLAYER_PORT}"
log "TURN Server: ${PUBLIC_IPADDR}:${TURN_PUBLIC_PORT}"
log ""
log "Logs:"
log "  - TURN:      ${LOG_DIR}/turn.log"
log "  - Signaller: ${LOG_DIR}/signaller.log"
for i in $(seq 1 "$INSTANCES"); do
log "  - Game ${i}:    ${LOG_DIR}/game_${i}.log"
log "  - Register ${i}: ${LOG_DIR}/register_${i}.log"
done
log ""
log "Debug commands:"
log "  tail -f ${LOG_DIR}/signaller.log  # Check signaller"
log "  tail -f ${LOG_DIR}/game_1.log     # Check game"
log "  screen -r $SESSION_NAME            # Attach to session"
log ""
log "=========================================="

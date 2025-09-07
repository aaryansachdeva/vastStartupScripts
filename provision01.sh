#!/usr/bin/env bash
# Provision script for Vast.ai
# - Idempotent
# - Non-interactive apt
# - Uses env vars for secrets (AWS_ACCESS_KEY, AWS_SECRET_KEY, AWS_REGION)
# - Safe: avoids echoing secrets

set -euo pipefail

# Non-interactive apt
export DEBIAN_FRONTEND=noninteractive

# Useful paths
WORKSPACE=${WORKSPACE:-/workspace}
VENV_PATH=${VENV_PATH:-/venv/main}   # override via env if you use a different venv
S3_BUCKET_PREFIX="s3://psfiles2"
FILES_TO_PULL=("Linux904.7z" "PS_Next_Claude_904.7z")

# Choose sudo if not root
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Running as non-root and sudo not available. Some operations may fail." >&2
  fi
fi

# Ensure workspace exists and cd there
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

# 1) Update & install system packages (only what we need)
$SUDO apt-get update -y
$SUDO apt-get install -y --no-install-recommends \
    mesa-vulkan-drivers vulkan-tools libvulkan1 \
    xvfb x11-apps p7zip-full python3-pip

# 2) Start Xvfb on :0 if not already running (headless X)
if ! pgrep -f "Xvfb :0" >/dev/null 2>&1; then
  nohup Xvfb :0 -screen 0 1280x720x24 >/var/log/xvfb.log 2>&1 &
  # give it a moment to come up
  sleep 1
fi
export DISPLAY=${DISPLAY:-:0}

# 3) Activate virtualenv if present
if [ -f "${VENV_PATH}/bin/activate" ]; then
  # shellcheck disable=SC1091
  . "${VENV_PATH}/bin/activate"
fi

# 4) Ensure pip/tools are up-to-date and install python packages
python3 -m pip install --upgrade pip setuptools wheel
# allow adding extra pip packages via EXTRA_PIP_PACKAGES env (space-separated)
PIP_PKGS=(awscli)
if [ -n "${EXTRA_PIP_PACKAGES:-}" ]; then
  # split into array
  read -r -a _extra <<< "$EXTRA_PIP_PACKAGES"
  PIP_PKGS+=("${_extra[@]}")
fi
python3 -m pip install --no-input "${PIP_PKGS[@]}"

# 5) Configure AWS CLI only if credentials were provided via env vars.
# Do NOT echo these values anywhere.
if [ -n "${AWS_ACCESS_KEY:-}" ] && [ -n "${AWS_SECRET_KEY:-}" ]; then
  aws configure set aws_access_key_id "$AWS_ACCESS_KEY"
  aws configure set aws_secret_access_key "$AWS_SECRET_KEY"
  if [ -n "${AWS_REGION:-}" ]; then
    aws configure set region "$AWS_REGION"
  fi
  aws configure set output json
else
  echo "Warning: AWS_ACCESS_KEY/AWS_SECRET_KEY not provided; skipping S3 download." >&2
fi

# 6) Download files from S3 (skip if already present)
if command -v aws >/dev/null 2>&1 && [ -n "${AWS_ACCESS_KEY:-}" ]; then
  for f in "${FILES_TO_PULL[@]}"; do
    if [ -f "${WORKSPACE}/${f}" ]; then
      echo "Skipping download; ${WORKSPACE}/${f} already exists."
    else
      aws s3 cp "${S3_BUCKET_PREFIX}/${f}" "${WORKSPACE}/" || {
        echo "Warning: failed to download ${f} from S3" >&2
      }
    fi
  done
fi

# 7) Extract archives if present
for f in "${FILES_TO_PULL[@]}"; do
  src="${WORKSPACE}/${f}"
  if [ -f "$src" ]; then
    echo "Extracting $src ..."
    7z x "$src" -o"$WORKSPACE/" || echo "7z extraction of $f failed" >&2
  fi
done

# 8) Create user 'foton' if missing and fix permissions (idempotent)
if ! id -u foton >/dev/null 2>&1; then
  $SUDO useradd -m -s /bin/bash foton || true
fi

# chown extracted folders if they exist
if [ -d "${WORKSPACE}/Linux" ]; then
  $SUDO chown -R foton:foton "${WORKSPACE}/Linux" || true
fi
if [ -d "${WORKSPACE}/PS_Next_Claude" ]; then
  $SUDO chown -R foton:foton "${WORKSPACE}/PS_Next_Claude" || true
fi

# 9) (Optional) Write PORTAL_CONFIG to /etc/portal.yaml if provided.
# This will reconfigure the Instance Portal if you want links (Jupyter/Tensorboard/etc).
if [ -n "${PORTAL_CONFIG:-}" ]; then
  echo "Writing PORTAL_CONFIG to /etc/portal.yaml"
  printf '%s\n' "$PORTAL_CONFIG" | $SUDO tee /etc/portal.yaml >/dev/null
fi

# 10) Reload supervisor if available (safe no-op if not)
if command -v supervisorctl >/dev/null 2>&1; then
  $SUDO supervisorctl reload || true
fi

echo "Provisioning finished at $(date)."

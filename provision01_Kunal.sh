#!/usr/bin/env bash
# provision_fixed.sh - Simplified + robust provisioning (focus: install -> download -> extract)
set -euo pipefail
IFS=$'\n\t'

LOG_PREFIX() { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# Basic config (edit if you want)
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
S3_PATH_LINUX="s3://psfiles2/Linux1002.7z"
S3_PATH_PS="s3://psfiles2/PS_Next_Claude_904.7z"
AUX_SCRIPT_URL="https://raw.githubusercontent.com/aaryansachdeva/vastStartupScripts/main/fotonInstanceRegister_vast.sh"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

mkdir -p "${WORKSPACE_DIR}"
cd "${WORKSPACE_DIR}"

# Ensure apt caches are available and minimal tools are installed first
LOG_PREFIX "Updating apt and installing core packages (p7zip, curl, python3-pip)..."
if ! sudo apt-get update -qq; then
  LOG_PREFIX "apt-get update failed — continuing but network required for installations."
fi

# Install the minimal packages required for downloads and extraction.
# Use '|| true' only for best-effort installs in constrained images; failures will still surface for missing commands later.
sudo apt-get install -y -qq p7zip-full python3-pip curl wget || {
  LOG_PREFIX "apt install had issues — retrying with apt-get install verbose..."
  sudo apt-get install -y p7zip-full python3-pip curl wget
}

# Ensure 7z is available
if ! command -v 7z >/dev/null 2>&1; then
  LOG_PREFIX "7z not found after apt install — trying to locate p7zip alternatives..."
  if command -v 7zr >/dev/null 2>&1; then
    alias 7z=7zr
    LOG_PREFIX "Using 7zr as 7z alias."
  else
    LOG_PREFIX "7z/7zr still missing — extraction will fail. Aborting."
    exit 1
  fi
fi

# Ensure awscli is installed if AWS creds present
if [[ -n "${AWS_ACCESS_KEY:-}" && -n "${AWS_SECRET_KEY:-}" ]]; then
  LOG_PREFIX "AWS credentials detected in environment -> ensuring aws CLI is present..."
  if ! command -v aws >/dev/null 2>&1; then
    # prefer system package if available, else pip
    if sudo apt-get install -y -qq awscli 2>/dev/null; then
      LOG_PREFIX "Installed awscli from apt."
    else
      LOG_PREFIX "apt install awscli failed or not available -> installing via pip3 (user/system depending)..."
      python3 -m pip install --upgrade --no-input awscli || {
        LOG_PREFIX "pip install awscli failed. Will still try but S3 download may fail."
      }
      # ensure aws is on PATH (pip install --user may put it under ~/.local/bin)
      export PATH="$PATH:$(python3 -m site --user-base)/bin"
    fi
  else
    LOG_PREFIX "aws CLI already present."
  fi
else
  LOG_PREFIX "AWS_ACCESS_KEY/AWS_SECRET_KEY not found -> skipping S3 download stage."
fi

# Helper: attempt download from S3 if aws present and creds set
download_from_s3() {
  local s3path="$1"; local dest="$2"
  if [[ -n "${AWS_ACCESS_KEY:-}" && -n "${AWS_SECRET_KEY:-}" ]] && command -v aws >/dev/null 2>&1; then
    LOG_PREFIX "Downloading ${s3path} -> ${dest} ..."
    # set env for this invocation (do not persist)
    AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY}" \
      aws --region "${AWS_REGION}" s3 cp "${s3path}" "${dest}" --no-progress && return 0
    LOG_PREFIX "aws s3 cp failed for ${s3path} -> will return non-zero."
    return 1
  else
    LOG_PREFIX "Skipping S3 download for ${s3path} because aws CLI or credentials missing."
    return 2
  fi
}

# Attempt downloads (best-effort); if they already exist, skip download
for s3 in "${S3_PATH_LINUX}" "${S3_PATH_PS}"; do
  fname="$(basename "${s3}")"
  dest="${WORKSPACE_DIR}/${fname}"
  if [[ -f "${dest}" ]]; then
    LOG_PREFIX "File already exists: ${dest} (skipping download)."
    continue
  fi

  if download_from_s3 "${s3}" "${dest}"; then
    LOG_PREFIX "Downloaded ${fname}."
  else
    LOG_PREFIX "Failed to download ${fname} from S3. If you expect these files present, ensure they are already extracted in ${WORKSPACE_DIR}."
  fi
done

# Extract archives if present
extract_if_present() {
  local archive="$1"; local outdir="$2"
  if [[ -f "${archive}" ]]; then
    LOG_PREFIX "Extracting ${archive} -> ${outdir} ..."
    mkdir -p "${outdir}"
    if 7z x "${archive}" -o"${outdir}" -y >/dev/null 2>&1; then
      LOG_PREFIX "Extraction successful: ${archive}"
    else
      LOG_PREFIX "7z extraction failed for ${archive} — trying with verbose output for debugging."
      7z x "${archive}" -o"${outdir}"
    fi
  else
    LOG_PREFIX "Archive not present: ${archive} (skipping)."
  fi
}

extract_if_present "${WORKSPACE_DIR}/Linux1002.7z" "${WORKSPACE_DIR}"
extract_if_present "${WORKSPACE_DIR}/PS_Next_Claude_904.7z" "${WORKSPACE_DIR}"

# Download auxiliary registration script if not present
REG_PATH="${WORKSPACE_DIR}/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash/fotonInstanceRegister_vast.sh"
mkdir -p "$(dirname "${REG_PATH}")"
if [[ ! -f "${REG_PATH}" ]]; then
  LOG_PREFIX "Fetching auxiliary script from repo -> ${REG_PATH}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${AUX_SCRIPT_URL}" -o "${REG_PATH}" || {
      LOG_PREFIX "curl failed to fetch ${AUX_SCRIPT_URL}. Trying wget..."
      wget -q -O "${REG_PATH}" "${AUX_SCRIPT_URL}" || LOG_PREFIX "wget failed too."
    }
  else
    LOG_PREFIX "curl not available -> trying wget..."
    wget -q -O "${REG_PATH}" "${AUX_SCRIPT_URL}" || LOG_PREFIX "wget failed to fetch aux script."
  fi
else
  LOG_PREFIX "Registration script already exists: ${REG_PATH}"
fi

# Make shell scripts executable (helpful after extraction)
LOG_PREFIX "Making any discovered .sh files executable under ${WORKSPACE_DIR} ..."
find "${WORKSPACE_DIR}" -type f -name "*.sh" -exec chmod +x {} \; || true

LOG_PREFIX "Provisioning (install/download/extract) finished. Check ${WORKSPACE_DIR} for files."
ls -la "${WORKSPACE_DIR}" | sed -n '1,200p'

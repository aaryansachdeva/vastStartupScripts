#!/usr/bin/env bash
# Vast.ai Startup Script for Pixel Streaming Setup
set -eo pipefail
IFS=$'\n\t'

cd /workspace/

# Prevent interactive prompts during package installation
export DEBIAN_FRONTEND=noninteractive

# Update system packages
echo "Updating system packages..."
sudo apt-get update -qq

# Install Vulkan drivers and tools
echo "Installing Vulkan drivers and tools..."
sudo apt-get install -y -qq mesa-vulkan-drivers vulkan-tools libvulkan1

# Install Xvfb and X11 applications
echo "Installing Xvfb and X11 tools..."
sudo apt-get install -y -qq xvfb x11-apps

# Install 7zip for archive extraction
echo "Installing p7zip..."
sudo apt install -y -qq p7zip-full

# Install AWS CLI (if not already available)
echo "Installing AWS CLI..."
pip install --no-input awscli

# Configure AWS using environment variables
echo "Configuring AWS CLI..."
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY:-}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY:-}"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_DEFAULT_OUTPUT="json"

# Download files from S3
echo "Downloading files from S3..."
aws s3 cp s3://psfiles2/Linux1002.7z /workspace/ || echo "Warning: failed to download Linux1002.7z"
aws s3 cp s3://psfiles2/PS_Next_Claude_904.7z /workspace/ || echo "Warning: failed to download PS_Next_Claude_904.7z"

# Extract archives
echo "Extracting UE Application..."
7z x /workspace/Linux1002.7z -o/workspace/ || echo "Warning: extraction failed for Linux1002.7z"

echo "Extracting PS_Next_Claude..."
7z x /workspace/PS_Next_Claude_904.7z -o/workspace/ || echo "Warning: extraction failed for PS_Next_Claude_904.7z"

# Download fotonInstanceRegister_vast
cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash || {
  echo "Signalling script directory not found: /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash"
}
if [ -d "$(pwd)" ]; then
  wget -q https://raw.githubusercontent.com/aaryansachdeva/vastStartupScripts/refs/heads/main/fotonInstanceRegister_vast.sh -O fotonInstanceRegister_vast.sh && \
    echo "Downloaded fotonInstanceRegister_vast"
fi

# Make extracted files executable (if needed)
find /workspace/ -name "*.sh" -exec chmod +x {} \; || echo "Warning: chmod failed on /workspace/*.sh"

echo "Setup completed successfully!"
echo "All files are available in /workspace/"

# Optional: List contents to verify
ls -la /workspace/ || true

#!/bin/bash

# Vast.ai Startup Script for Pixel Streaming Setup
cd /workspace/

# Cause the script to exit on failure
set -eo pipefail

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
pip install awscli

# Configure AWS using environment variables
echo "Configuring AWS CLI..."
export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY
export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_KEY
export AWS_DEFAULT_REGION="us-east-1"
export AWS_DEFAULT_OUTPUT="json"

# Download files from S3
echo "Downloading files from S3..."
aws s3 cp s3://psfiles2/Linux908.1.7z /workspace/
aws s3 cp s3://psfiles2/PS_Next_Claude_904.7z /workspace/

# Extract archives
echo "Extracting Linux904.7z..."
7z x /workspace/Linux908.1.7z -o/workspace/

echo "Extracting PS_Next_Claude_904.7z..."
7z x /workspace/PS_Next_Claude_904.7z -o/workspace/

# Make extracted files executable (if needed)
find /workspace/ -name "*.sh" -exec chmod +x {} \;

echo "Setup completed successfully!"
echo "All files are available in /workspace/"

# Optional: List contents to verify
ls -la /workspace/

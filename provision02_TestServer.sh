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

# Install tmux
echo "Installing tmux..."
sudo apt-get install -y -qq tmux

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
aws s3 cp s3://psfiles2/Linux1002.7z /workspace/
aws s3 cp s3://psfiles2/PS_Next_Claude_904.7z /workspace/

# Extract archives
echo "Extracting UE Application..."
7z x /workspace/Linux1002.7z -o/workspace/
echo "Extracting PS_Next_Claude..."
7z x /workspace/PS_Next_Claude_904.7z -o/workspace/

# Download fotonInstanceRegister_vast
cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash
wget https://raw.githubusercontent.com/aaryansachdeva/vastStartupScripts/refs/heads/main/fotonInstanceRegister_vast.sh
echo "Downloaded fotonInstanceRegister_vast"

# Make extracted files executable
find /workspace/ -name "*.sh" -exec chmod +x {} \;

# Create foton user and set permissions
echo "Creating foton user..."
useradd -m foton
chown -R foton:foton /workspace/Linux

echo "Setup completed successfully!"
echo "Starting services in tmux sessions..."

# Start new tmux session for signalling web server
tmux new-session -d -s signalling "cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./start_with_turn.sh --player_port=79 --streamer_port=8887 --sfu_port=9887"

# Wait for signalling server to initialize
sleep 10

# Start TURN server in tmux
tmux new-session -d -s turnserver "turnserver -n --listening-port=19303 --external-ip=$PUBLIC_IPADDR --relay-ip=$LOCAL_IP --user=PixelStreamingUser:AnotherTURNintheroad --realm=PixelStreaming --no-tls --no-dtls -a -v"

# Start first Unreal Engine instance
tmux new-session -d -s ue-instance-1 "sudo -u foton xvfb-run -n 90 -s '-screen 0 1920x1080x24' /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingH264Profile=AUTO -PixelStreamingUrl=ws://localhost:8888 -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30 -ExecCmds='r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200'"

# Start second Unreal Engine instance
tmux new-session -d -s ue-instance-2 "sudo -u foton xvfb-run -n 91 -s '-screen 0 1920x1080x24' /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingH264Profile=AUTO -PixelStreamingUrl=ws://localhost:8889 -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30 -ExecCmds='r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200'"

# Start third Unreal Engine instance
tmux new-session -d -s ue-instance-3 "sudo -u foton xvfb-run -n 94 -s '-screen 0 1920x1080x24' /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingH264Profile=AUTO -PixelStreamingUrl=ws://localhost:8890 -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30 -ExecCmds='r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200'"

# Register first instance with foton server
tmux new-session -d -s register-1 "cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=81 --streamer_port=8888 --sfu_port=9888 --publicip $PUBLIC_IPADDR --turn $PUBLIC_IPADDR:$VAST_UDP_PORT_19303 --turn-user PixelStreamingUser --turn-pass AnotherTURNintheroad --stun stun.l.google.com:19302 --server_url=https://test.fotonlabs.com"

# Register second instance with foton server
tmux new-session -d -s register-2 "cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=82 --streamer_port=8889 --sfu_port=9889 --publicip $PUBLIC_IPADDR --turn $PUBLIC_IPADDR:$VAST_UDP_PORT_19303 --turn-user PixelStreamingUser --turn-pass AnotherTURNintheroad --stun stun.l.google.com:19302 --server_url=https://test.fotonlabs.com"

# Register third instance with foton server
tmux new-session -d -s register-3 "cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=83 --streamer_port=8890 --sfu_port=9890 --publicip $PUBLIC_IPADDR --turn $PUBLIC_IPADDR:$VAST_UDP_PORT_19303 --turn-user PixelStreamingUser --turn-pass AnotherTURNintheroad --stun stun.l.google.com:19302 --server_url=https://test.fotonlabs.com"

echo "All services started in tmux sessions!"
echo "Use 'tmux ls' to list sessions and 'tmux attach -t <session-name>' to connect"

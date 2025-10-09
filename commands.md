SESSION START

sudo apt-get update

sudo apt-get install -y mesa-vulkan-drivers vulkan-tools libvulkan1

sudo apt-get install -y xvfb x11-apps

	Xvfb :0 -screen 0 1280x720x24 &

	ctrl+c to get out of The XKEYBOARD keymap compiler (xkbcomp) reports:

	export DISPLAY=:0

sudo apt install p7zip-full

pip install awscli

aws configure
	Access Key - 
	Secret Access Key - 
	Region - 
	Output - 

aws s3 cp s3://psfiles2/Linux904.7z .

aws s3 cp s3://psfiles2/PS_Next_Claude_904.7z .

7z x Linux904.7z

7z x PS_Next_Claude_904.7z

---- Automation ENDS ----

useradd -m foton

chown -R foton:foton /workspace/Linux

	chown -R foton:foton /workspace/PS_Next_Claude

su - foton

	(once) chmod +x /workspace/Linux/AudioTestProject02.sh

	xvfb-run ./AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8888

xvfb-run -n 90 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingUrl=ws://localhost:8888 -PixelStreamingWebRTCMaxFps=30 -ExecCmds="r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200"
xvfb-run -n 91 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingUrl=ws://localhost:8889 -PixelStreamingWebRTCMaxFps=30 -ExecCmds="r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200"
xvfb-run -n 92 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingUrl=ws://localhost:8890 -PixelStreamingWebRTCMaxFps=30 -ExecCmds="r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200"
xvfb-run -n 93 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingUrl=ws://localhost:8891 -PixelStreamingWebRTCMaxFps=30 -ExecCmds="r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200" -graphicsadapter=2
xvfb-run -n 94 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingUrl=ws://localhost:8892 -PixelStreamingWebRTCMaxFps=30 -ExecCmds="r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200" -graphicsadapter=2
xvfb-run -n 95 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingUrl=ws://localhost:8893 -PixelStreamingWebRTCMaxFps=30 -ExecCmds="r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200" -graphicsadapter=2

xvfb-run -n 90 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=h264 -PixelStreamingHWEncode=true -PixelStreamingEncoderTarget=nvenc -PixelStreamingUrl=ws://localhost:8888

xvfb-run -n 90 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=AV1 -PixelStreamingUrl=ws://localhost:8888

xvfb-run -n 91 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8889
xvfb-run -n 92 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8890
xvfb-run -n 93 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8891
xvfb-run -n 94 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8892
xvfb-run -n 95 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8893
xvfb-run -n 96 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8894



------

	Path for server 
	cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash

	(once) chmod +x /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash/start_with_turn.sh

/workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash/start_with_turn.sh --player_port=79 --streamer_port=8887 --sfu_port=9887
/workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash/start_with_turn.sh --player_port=81 --streamer_port=8889 --sfu_port=9889
/workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash/start_with_turn.sh --player_port=82 --streamer_port=8890 --sfu_port=9890
/workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash/start_with_turn.sh --player_port=83 --streamer_port=8891 --sfu_port=9891
/workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash/start_with_turn.sh --player_port=84 --streamer_port=8892 --sfu_port=9892
/workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash/start_with_turn.sh --player_port=85 --streamer_port=8893 --sfu_port=9893
/workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash/start_with_turn.sh --player_port=86 --streamer_port=8894 --sfu_port=9894

cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=80 --streamer_port=8888 --sfu_port=9888
cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=81 --streamer_port=8889 --sfu_port=9889
cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=82 --streamer_port=8890 --sfu_port=9890
cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=83 --streamer_port=8891 --sfu_port=9891
cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=84 --streamer_port=8892 --sfu_port=9892
cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=85 --streamer_port=8893 --sfu_port=9893
cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=86 --streamer_port=8894 --sfu_port=9894

FOR TESTING

nvidia-smi dmon -s um -d 1

xvfb-run -n 90 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8888
xvfb-run -n 91 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8889
xvfb-run -n 92 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8890

xvfb-run -n 90 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingUrl=ws://localhost:8888

xvfb-run -n 90 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -PixelStreamingEncoderCodec=AV1 -PixelStreamingUrl=ws://localhost:8888

cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=80 --streamer_port=8888 --sfu_port=9888

GraceOS OLD DOCKER OPTIONS
-p 1111:1111 -p 6006:6006 -p 8080:8080 -p 8384:8384 -p 72299:72299 -p 8888:8888/udp -p 80:80 -p 19303:19303/udp -p 443:443 -p 81:81 -p 82:82 -p 83:83 -p 84:84 -p 85:85 -p 86:86 -p 87:87 -p 88:88 -p 89:89 -p 90:90 -p 8889:8889/udp -e OPEN_BUTTON_PORT=1111 -e OPEN_BUTTON_TOKEN=1 -e JUPYTER_DIR=/ -e DATA_DIRECTORY=/workspace/ -e PORTAL_CONFIG="localhost:1111:11111:/:Instance Portal|localhost:8080:18080:/:Jupyter|localhost:8080:8080:/terminals/1:Jupyter Terminal|localhost:8384:18384:/:Syncthing|localhost:6006:16006:/:Tensorboard" -e AWS_ACCESS_KEY= -e AWS_SECRET_KEY= -e AWS_REGION=us-east-1 -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/aaryansachdeva/vastStartupScripts/refs/heads/main/provision01.sh

# Test encoding with ffmpeg
ffmpeg -f lavfi -i testsrc=duration=10:size=1920x1080:rate=30 \
       -c:v h264_nvenc -preset p4 -tune hq test.mp4

#TURN SERVER!
LOCAL_IP=$(hostname -I | awk '{print $1}')

turnserver \
  -n \
  --listening-port=19303 \
  --external-ip=$PUBLIC_IPADDR \
  --relay-ip=$LOCAL_IP \
  --user=PixelStreamingUser:AnotherTURNintheroad \
  --realm=PixelStreaming \
  --no-tls \
  --no-dtls \
  -a \
  -v &






















cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=81 --streamer_port=8888 --sfu_port=9888 --publicip $PUBLIC_IPADDR --turn $PUBLIC_IPADDR:$VAST_UDP_PORT_19303 --turn-user PixelStreamingUser --turn-pass AnotherTURNintheroad --stun stun.l.google.com:19302

cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=82 --streamer_port=8889 --sfu_port=9889 --publicip $PUBLIC_IPADDR --turn $PUBLIC_IPADDR:$VAST_UDP_PORT_19303 --turn-user PixelStreamingUser --turn-pass AnotherTURNintheroad --stun stun.l.google.com:19302

cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash && ./fotonInstanceRegister_vast.sh --player_port=83 --streamer_port=8890 --sfu_port=9890 --publicip $PUBLIC_IPADDR --turn $PUBLIC_IPADDR:$VAST_UDP_PORT_19303 --turn-user PixelStreamingUser --turn-pass AnotherTURNintheroad --stun stun.l.google.com:19302

--- 


xvfb-run -n 90 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingH264Profile=BASELINE -PixelStreamingUrl=ws://localhost:8888 -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30 -ExecCmds="r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200"

xvfb-run -n 91 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingH264Profile=BASELINE -PixelStreamingUrl=ws://localhost:8889 -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30 -ExecCmds="r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200"

xvfb-run -n 92 -s "-screen 0 1920x1080x24" /workspace/Linux/AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingEncoderCodec=H264 -PixelStreamingH264Profile=BASELINE -PixelStreamingUrl=ws://localhost:8890 -PixelStreamingWebRTCStartBitrate=2000000 -PixelStreamingWebRTCMinBitrate=1000000 -PixelStreamingWebRTCMaxBitrate=4000000 -PixelStreamingWebRTCMaxFps=30 -ExecCmds="r.TemporalAA.Upsampling 1,r.ScreenPercentage 50,r.TemporalAA.HistoryScreenPercentage 200"







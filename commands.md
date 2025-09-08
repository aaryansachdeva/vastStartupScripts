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

useradd -m foton

chown -R foton:foton /workspace/Linux

chown -R foton:foton /workspace/PS_Next_Claude

su - foton

cd /workspace/Linux

(once) chmod +x ./AudioTestProject02.sh

	xvfb-run ./AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8888

xvfb-run -n 90 -s "-screen 0 1920x1080x24" ./AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8888
xvfb-run -n 91 -s "-screen 0 1920x1080x24" ./AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8889
xvfb-run -n 92 -s "-screen 0 1920x1080x24" ./AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8890
xvfb-run -n 93 -s "-screen 0 1920x1080x24" ./AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8891
xvfb-run -n 94 -s "-screen 0 1920x1080x24" ./AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8892
xvfb-run -n 95 -s "-screen 0 1920x1080x24" ./AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8893
xvfb-run -n 96 -s "-screen 0 1920x1080x24" ./AudioTestProject02.sh -RenderOffscreen -Vulkan -PixelStreamingUrl=ws://localhost:8894



------

Path for server 
cd /workspace/PS_Next_Claude/WebServers/SignallingWebServer/platform_scripts/bash

(once) chmod +x ./start_with_turn.sh

./start_with_turn.sh --player_port=80 --streamer_port=8888 --sfu_port=9888
./start_with_turn.sh --player_port=81 --streamer_port=8889 --sfu_port=9889
./start_with_turn.sh --player_port=82 --streamer_port=8890 --sfu_port=9890
./start_with_turn.sh --player_port=83 --streamer_port=8891 --sfu_port=9891
./start_with_turn.sh --player_port=84 --streamer_port=8892 --sfu_port=9892
./start_with_turn.sh --player_port=85 --streamer_port=8893 --sfu_port=9893
./start_with_turn.sh --player_port=86 --streamer_port=8894 --sfu_port=9894

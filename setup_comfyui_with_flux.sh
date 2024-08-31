# Spin-up Docker container on Vast
#vastai create instance XXXXXXXXXXXX --price 0.96 --disk 128 --image nvidia/cuda:12.4.1-devel-ubuntu22.04 --env '-e HF_TOKEN=hf_XXXXXXXXXXX -p 8081-p 8082 -p 8083 -p 8084' --onstart-cmd "wget -qO- https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/setup_comfyui_with_flux.sh | bash"

# Run setup in container
#wget -qO- https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/setup_comfyui_with_flux.sh | bash

# Start ComfyUI if the provision setup has completed before
if [ -f "/ComfuUI/setup_ready" ]; then
  # Start ComfyUI instance for every GPU
  ./comfyui_launcher.sh
  exit 1
fi

# Update and Upgrade
apt update -y && apt upgrade -y

# Install Git, Python and Nano
apt install -y git python3-pip libgl1-mesa-dev libglib2.0-0 nano

# Install PyTorch
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124

# Install ComfyUI
git clone https://github.com/comfyanonymous/ComfyUI.git /ComfyUI
cd /ComfyUI
pip install -r requirements.txt

# Install ComfyUI Manager
cd /ComfyUI/custom_nodes
git clone https://github.com/ltdrdata/ComfyUI-Manager.git /ComfyUI/custom_nodesComfyUI-Manager

# At this point the HF_TOKEN shuold have been set as environment variable!

# Provision FLUX on CompyUI
wget -qO- https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/provision_comfyui_flux.py | python3

# Download ComfyUI launcher script
cd /ComfyUI
wget -N -O comfyui_launcher.sh https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/comfyui_launcher.sh && sudo chmod +x comfyui_launcher.sh

# Flag the setup as complete to avoid instance running the setup again
touch setup_ready

# Start ComfyUI instance for every GPU
./comfyui_launcher.sh

ComfyUI docker setup
-----------------------
# Spin-up Docker container on Vast
#vastai create instance INSTANCE_ID --price 0.72 --disk 128 --image nvidia/cuda:12.3.2-devel-ubuntu22.04 --env '-p 8202:8202 -e HF_TOKEN=xxxxxxxxxx'

# Run setup in container
#wget -qO- https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/setup_comfyui_with_flux.sh | bash

# Update and Upgrade
apt update -y && apt upgrade -y

# Install Git, Python and Nano
apt install -y git python3-pip libgl1-mesa-dev libglib2.0-0 nano

# Install PyTorch
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124

# Install ComfyUI
git clone https://github.com/comfyanonymous/ComfyUI.git
cd /ComfyUI
pip install -r requirements.txt

# Install ComfyUI Manager
cd /ComfyUI/custom_nodes
git clone https://github.com/ltdrdata/ComfyUI-Manager.git

# At this point the HF_TOKEN shuold have been set!

# Provision FLUX on CompyUI
cd /ComfyUI/
wget https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/provision_comfyui_flux.py
python3 provision_comfyui_flux.py

python3 main.py --listen 0.0.0.0 --port 8082 --cuda_device $CUDA_DEVICE

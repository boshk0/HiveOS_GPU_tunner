import os
from huggingface_hub import hf_hub_download

HF_TOKEN=os.environ['HF_TOKEN']

# Download flux1-dev.safetensors
hf_hub_download(
    repo_id="black-forest-labs/FLUX.1-dev",
    filename="flux1-dev.safetensors",
    local_dir="/ComfyUI/models/unet/",
    token=HF_TOKEN
)

# Download clip_l.safetensors
hf_hub_download(
    repo_id="comfyanonymous/flux_text_encoders",
    filename="clip_l.safetensors",
    local_dir="/ComfyUI/models/clip/",
    token=HF_TOKEN
)

# Download t5xxl_fp16.safetensors
hf_hub_download(
    repo_id="comfyanonymous/flux_text_encoders",
    filename="t5xxl_fp16.safetensors",
    local_dir="/ComfyUI/models/clip/",
    token=HF_TOKEN
)

# Download ae.safetensors
hf_hub_download(
    repo_id="black-forest-labs/FLUX.1-dev",
    filename="ae.safetensors",
    local_dir="/ComfyUI/models/vae/",
    token=HF_TOKEN
)

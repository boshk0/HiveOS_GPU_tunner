#!/bin/bash

gpu_ids=$(nvidia-smi --query-gpu=index --format=csv,nounits,noheader)

for i in $(echo "$gpu_ids" | tr '\n' ' '); do
  gpu_id=$i
  port=$((8080 + i + 1))

  echo "Starting ComfyUI on GPU $gpu_id..."
  
  # Check if Tmux session is already created
  tmux ls | grep -q "$port" && {
    echo "Tmux session for GPU $gpu_id and port $port already exists. Skipping..."
    continue
  }

  # Create new Tmux session
  if ! tmux new-session -d "python3 main.py --listen 0.0.0.0 --port $port --cuda-device $gpu_id"; then
    echo "Error creating Tmux session: $?"
    continue
  fi
done

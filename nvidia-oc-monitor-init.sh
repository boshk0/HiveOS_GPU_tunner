#wget -qO- https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/nvidia-oc-monitor-init.sh | bash

cat << 'EOF' | sudo tee /usr/local/bin/nvidia-oc-monitor
#!/bin/bash

# ============================================================  
# Operating mode: thermal  
# ============================================================  
MODE="thermal"  
# ============================================================  
# Thermal power control settings  
# ============================================================  
TEMP_HIGH=71  
TEMP_CRITICAL=83  
TEMP_RECOVER=65  
TEMP_EMERGENCY=85  
PL_STEP_DOWN=10  
PL_STEP_UP=15  
CHECK_INTERVAL=5  
# Global power limit in Watts (3500 W = 3.5 kW)  
TOTAL_POWER_LIMIT=3500  
declare -A CURRENT_PL  
# ============================================================  
# Fan control settings  
# ============================================================  
TEMP_FAN_ON=65  
TEMP_FAN_OFF=50  
FAN_ON_SPEED=80  
FAN_CMD="/home/miner/set_fan_speed"  
declare -A FAN_STATE   # auto | manual  
# ============================================================  
# GPU discovery (robust)  
# ============================================================  
fetch_gpu_indices() {  
    local retries=0  
    local max_retries=5  
    while true; do  
        if output=$(timeout 5 nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null); then  
            echo "$output"  
            return 0  
        fi  
        retries=$((retries + 1))  
        sleep 1  
        if [[ $retries -ge $max_retries ]]; then  
            exit 1  
        fi  
    done  
}  
# ============================================================  
# Fan controller with hysteresis  
# ============================================================  
fan_control() {  
    local gpu_id=$1  
    local temp=$2  
    [[ -z "${FAN_STATE[$gpu_id]}" ]] && FAN_STATE[$gpu_id]="auto"  
    if (( temp >= TEMP_FAN_ON )) && [[ "${FAN_STATE[$gpu_id]}" != "manual" ]]; then  
        $FAN_CMD "$FAN_ON_SPEED" -i "$gpu_id" > /dev/null 2>&1  
        FAN_STATE[$gpu_id]="manual"  
    elif (( temp <= TEMP_FAN_OFF )) && [[ "${FAN_STATE[$gpu_id]}" != "auto" ]]; then  
        $FAN_CMD auto -i "$gpu_id" > /dev/null 2>&1  
        FAN_STATE[$gpu_id]="auto"  
    fi  
}  
# ============================================================  
# Thermal PL controller (gradual + hysteresis + Global Load Limit)  
# ============================================================  
thermal_power_control() {  
  # 1. Fetch GPU indices once per cycle for efficiency  
  local -a gpu_indices  
  mapfile -t gpu_indices < <(fetch_gpu_indices)  
    
  # 2. Calculate total load (Watts) across all GPUs  
  local total_load=0  
  if local power_output=$(nvidia-smi --query-gpu=power.draw --format=csv,nounits,noheader 2>/dev/null); then  
      total_load=$(echo "$power_output" | awk '{sum += $1} END {print int(sum)}')  
  fi  
  
  # 3. Determine global power cap per GPU if limit exceeded  
  local global_cap=99999  
  local gpu_count=${#gpu_indices[@]}  
    
  # Check if total load exceeds the configured TOTAL_POWER_LIMIT  
  if (( gpu_count > 0 && ${total_load:-0} > $TOTAL_POWER_LIMIT )); then  
    # Evenly distribute the limit among GPUs  
    global_cap=$((TOTAL_POWER_LIMIT / gpu_count))  
  fi  
  
  for gpu_id in "${gpu_indices[@]}"; do  
    TEMP_OUTPUT=$(nvidia-smi -i "$gpu_id" --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null)  
    [[ -z "$TEMP_OUTPUT" || "$TEMP_OUTPUT" == "[N/A]" ]] && continue  
    TEMP=$(echo "$TEMP_OUTPUT" | awk '{print int($1)}')  
      
    # Fan control (independent from power limit)  
    fan_control "$gpu_id" "$TEMP"  
      
    if [[ -z "${CURRENT_PL[$gpu_id]}" ]]; then  
      PL_OUTPUT=$(nvidia-smi -i "$gpu_id" --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null)  
      [[ -n "$PL_OUTPUT" && "$PL_OUTPUT" != "[N/A]" ]] && \  
        CURRENT_PL[$gpu_id]=$(echo "$PL_OUTPUT" | awk '{print int($1)}')  
    fi  
    [[ -z "${CURRENT_PL[$gpu_id]}" ]] && continue  
      
    PL=${CURRENT_PL[$gpu_id]}  
      
    MAX_PL_OUTPUT=$(nvidia-smi -i "$gpu_id" --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null)  
    MIN_PL_OUTPUT=$(nvidia-smi -i "$gpu_id" --query-gpu=power.min_limit --format=csv,noheader,nounits 2>/dev/null)  
    [[ -z "$MAX_PL_OUTPUT" || "$MAX_PL_OUTPUT" == "[N/A]" ]] && continue  
    [[ -z "$MIN_PL_OUTPUT" || "$MIN_PL_OUTPUT" == "[N/A]" ]] && continue  
      
    MAX_PL=$(echo "$MAX_PL_OUTPUT" | awk '{print int($1)}')  
    MIN_PL=$(echo "$MIN_PL_OUTPUT" | awk '{print int($1)}')  
      
    # --- Thermal Logic ---  
    if (( TEMP >= TEMP_EMERGENCY )); then  
        PL=$MIN_PL  
    elif (( TEMP >= TEMP_CRITICAL )); then  
        PL=$((PL - PL_STEP_DOWN * 2))  
    elif (( TEMP > TEMP_HIGH )); then  
        PL=$((PL - PL_STEP_DOWN))  
    elif (( TEMP <= TEMP_RECOVER )); then  
        PL=$((PL + PL_STEP_UP))  
    fi  
      
    # --- Global Load Limit ---  
    # Enforce the calculated global cap regardless of thermal logic  
    (( PL > global_cap )) && PL=$global_cap  
      
    # --- Hardware Bounds ---  
    (( PL > MAX_PL )) && PL=$MAX_PL  
    (( PL < MIN_PL )) && PL=$MIN_PL  
      
    if [[ "${CURRENT_PL[$gpu_id]}" -ne "$PL" ]]; then  
        nvidia-smi -i "$gpu_id" -pl "$PL" > /dev/null 2>&1  
        CURRENT_PL[$gpu_id]=$PL  
    fi  
  done  
}  
# ============================================================  
# Cleanup / Reset functions  
# ============================================================  
reset_oc() {  
    for gpu_id in $(fetch_gpu_indices); do  
        MAX_POWER=$(nvidia-smi -i "$gpu_id" --query-gpu=power.max_limit --format=csv,noheader,nounits)  
        nvidia-smi -i "$gpu_id" -pl "$MAX_POWER" > /dev/null 2>&1  
        $FAN_CMD auto -i "$gpu_id" > /dev/null 2>&1  
        FAN_STATE[$gpu_id]="auto"  
    done  
    nvidia-smi -pm 1 > /dev/null 2>&1  
    nvidia-smi -gtt 65 > /dev/null 2>&1  
}  
cleanup() {  
    reset_oc  
    exit 0  
}  
trap cleanup SIGINT SIGTERM  
# ============================================================  
# Init  
# ============================================================  
nvidia-smi -pm 1 > /dev/null 2>&1  
# ============================================================  
# Main loop  
# ============================================================  
while true; do  
  thermal_power_control  
  sleep "$CHECK_INTERVAL"  
done
EOF

cat << 'EOF' | sudo tee /etc/systemd/system/nvidia-oc-monitor.service
[Unit]
Description=NVIDIA GPU Overclock Monitoring Service
After=multi-user.target

[Service]
Type=simple
ExecStartPre=/usr/bin/nvidia-smi
ExecStart=/usr/local/bin/nvidia-oc-monitor

[Install]
WantedBy=multi-user.target
EOF

sudo chmod +x /usr/local/bin/nvidia-oc-monitor

sudo systemctl enable nvidia-oc-monitor;
sudo systemctl restart nvidia-oc-monitor;
sudo systemctl status nvidia-oc-monitor;

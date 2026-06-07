#wget -qO- https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/nvidia-oc-monitor-init.sh | bash

cat << 'EOF' | sudo tee /usr/local/bin/nvidia-oc-monitor
#!/bin/bash

# ============================================================  
# Thermal power control settings  
# ============================================================  
TEMP_HIGH=71  
TEMP_CRITICAL=83  
TEMP_EMERGENCY=85  
TEMP_RECOVER=50
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
# GPU discovery (robust) - Cache GPU indices once at startup  
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

GPUS=()  
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
    local gpu_count=${#GPUS[@]}  
    [[ $gpu_count -eq 0 ]] && return 0  

    # 1. Batch query: total power draw (1 call for all GPUs)  
    local total_load=0  
    if power_output=$(nvidia-smi --query-gpu=power.draw --format=csv,nounits,noheader 2>/dev/null); then  
        total_load=$(echo "$power_output" | awk '{sum += $1} END {print int(sum)}')  
    fi  

    # 2. Determine global power cap per GPU if limit exceeded  
    local global_cap=99999  
    if (( total_load > TOTAL_POWER_LIMIT )); then  
        global_cap=$((TOTAL_POWER_LIMIT / gpu_count))  
    fi  

    # 3. Batch query: temperature + power limits (1 call for all GPUs)  
    local batch_output  
    batch_output=$(nvidia-smi --query-gpu=temperature.gpu,power.limit,power.max_limit,power.min_limit \
        --format=csv,noheader 2>/dev/null) || return 0  

    # 4. Parse batch output and process each GPU  
    local idx=0  
    while IFS=',' read -r temp_raw pl_raw max_pl_raw min_pl_raw; do  
        local gpu_id=${GPUS[$idx]}  
        idx=$((idx + 1))

        # Parse values with integer conversion  
        local temp=$(echo "$temp_raw" | awk '{print int($1)}')  
        local max_pl=$(echo "$max_pl_raw" | awk '{print int($1)}')  
        local min_pl=$(echo "$min_pl_raw" | awk '{print int($1)}')  

        # Skip if N/A  
        [[ "$temp_raw" == *"[N/A]"* || "$max_pl_raw" == *"[N/A]"* || "$min_pl_raw" == *"[N/A]"* ]] && continue  

        # Fan control (independent from power limit)  
        fan_control "$gpu_id" "$temp"  

        # Initialize current PL from hardware if not cached  
        if [[ -z "${CURRENT_PL[$gpu_id]}" ]]; then  
            local pl_current=$(echo "$pl_raw" | awk '{print int($1)}')  
            [[ "$pl_raw" == *"[N/A]"* ]] && continue  
            CURRENT_PL[$gpu_id]=$pl_current  
        fi  

        local pl=${CURRENT_PL[$gpu_id]}  

        # --- Thermal Logic ---  
        if (( temp >= TEMP_EMERGENCY )); then  
            pl=$min_pl  
        elif (( temp >= TEMP_CRITICAL )); then  
            pl=$((pl - PL_STEP_DOWN * 2))  
        elif (( temp > TEMP_HIGH )); then  
            pl=$((pl - PL_STEP_DOWN))  
        elif (( temp <= TEMP_RECOVER )); then  
            pl=$((pl + PL_STEP_UP))  
        fi  

        # --- Global Load Limit ---  
        (( pl > global_cap )) && pl=$global_cap  

        # --- Hardware Bounds ---  
        (( pl > max_pl )) && pl=$max_pl  
        (( pl < min_pl )) && pl=$min_pl  

        # Apply if changed  
        if [[ "${CURRENT_PL[$gpu_id]}" -ne "$pl" ]]; then  
            nvidia-smi -i "$gpu_id" -pl "$pl" > /dev/null 2>&1  
            CURRENT_PL[$gpu_id]=$pl  
        fi  
    done <<< "$batch_output"  
}  
# ============================================================  
# Cleanup / Reset functions  
# ============================================================  
reset_oc() {  
    local gpu_count=${#GPUS[@]}  
    [[ $gpu_count -eq 0 ]] && return 0  

    # Batch query max power limits  
    local batch_output  
    batch_output=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader 2>/dev/null) || return 0  

    local idx=0  
    while IFS= read -r max_power_raw; do  
        local gpu_id=${GPUS[$idx]}  
        idx=$((idx + 1))  

        local max_power=$(echo "$max_power_raw" | awk '{print int($1)}')  
        [[ "$max_power_raw" == *"[N/A]"* ]] && continue  

        nvidia-smi -i "$gpu_id" -pl "$max_power" > /dev/null 2>&1  
        $FAN_CMD auto -i "$gpu_id" > /dev/null 2>&1  
        FAN_STATE[$gpu_id]="auto"  
    done <<< "$batch_output"  

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
# Discover GPUs once at startup (robust, cached)  
# ============================================================  
mapfile -t GPUS < <(fetch_gpu_indices)  
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

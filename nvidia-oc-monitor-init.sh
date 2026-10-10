#wget -qO- https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/nvidia-oc-monitor-init.sh | bash
#
# PATCHED VARIANT — adds a configurable per-GPU power cap (default 400 W).
# Every change from the upstream script is marked with  # --- PATCH ---
#
# Configure without editing this file:
#   sudo systemctl edit nvidia-oc-monitor     ->  [Service] Environment="GPU_POWER_CAP=350"
# or edit /etc/nvidia-oc-monitor.conf         (created below, wins over systemd env)

cat << 'EOF' | sudo tee /usr/local/bin/nvidia-oc-monitor
#!/bin/bash

# ============================================================
# Configuration source of truth  # --- PATCH ---
# Precedence: /etc/nvidia-oc-monitor.conf  >  systemd Environment=  >  defaults below
# ============================================================
CONFIG_FILE="${OC_MONITOR_CONFIG:-/etc/nvidia-oc-monitor.conf}"
[[ -r "$CONFIG_FILE" ]] && . "$CONFIG_FILE"

# ============================================================  
# Thermal power control settings  
# ============================================================  
TEMP_HIGH=71  
TEMP_CRITICAL=83  
TEMP_EMERGENCY=85  
TEMP_RECOVER=50
PL_STEP_DOWN=10  
PL_STEP_UP=15  

CHECK_INTERVAL=${CHECK_INTERVAL:-5}

# Global power limit in Watts (3500 W = 3.5 kW)  
TOTAL_POWER_LIMIT=${TOTAL_POWER_LIMIT:-3500}
declare -A CURRENT_PL  

# ============================================================
# Per-GPU power cap  # --- PATCH ---
# Hard ceiling applied to every GPU, always (not only when the rig is over budget).
# 0 disables the cap and falls back to the hardware max_limit.
# ============================================================
GPU_POWER_CAP=${GPU_POWER_CAP:-400}

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
# Effective ceiling for one GPU  # --- PATCH ---
# min(hardware max_limit, GPU_POWER_CAP) — keeps us inside what the card accepts.
# ============================================================
effective_cap() {
    local hw_max=$1
    local cap=$hw_max
    (( GPU_POWER_CAP > 0 && GPU_POWER_CAP < hw_max )) && cap=$GPU_POWER_CAP
    echo "$cap"
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

        # --- Per-GPU Power Cap  # --- PATCH ---
        # Applied BEFORE the hardware bounds so the recovery ramp (pl + PL_STEP_UP)
        # can never climb back above the cap, and so the cap is enforced on the very
        # first pass even when temps sit in the dead band.
        local cap
        cap=$(effective_cap "$max_pl")
        (( pl > cap )) && pl=$cap

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

    # Batch query power limits
    # --- PATCH: min_limit is queried too, so a cap below the card's floor is
    # clamped instead of handed to nvidia-smi, which would reject it. ---
    local batch_output  
    batch_output=$(nvidia-smi --query-gpu=power.max_limit,power.min_limit --format=csv,noheader 2>/dev/null) || return 0  

    local idx=0  
    while IFS=',' read -r max_power_raw min_power_raw; do  
        local gpu_id=${GPUS[$idx]}  
        idx=$((idx + 1))  

        local max_power=$(echo "$max_power_raw" | awk '{print int($1)}')  
        local min_power=$(echo "$min_power_raw" | awk '{print int($1)}')  
        [[ "$max_power_raw" == *"[N/A]"* ]] && continue  

        # --- PATCH: reset to the cap (clamped into [min_limit, max_limit]), not to the hardware max ---
        local target
        target=$(effective_cap "$max_power")
        (( min_power > 0 && target < min_power )) && target=$min_power
        nvidia-smi -i "$gpu_id" -pl "$target" > /dev/null 2>&1  
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
# Startup report + cap sanity check  # --- PATCH ---
# The cap is clamped to [min_limit, max_limit] per GPU, so an out-of-range value
# is silently rounded to the nearest bound. Warn instead of hiding it.
# ============================================================
echo "nvidia-oc-monitor: GPUs=${#GPUS[@]} GPU_POWER_CAP=${GPU_POWER_CAP}W TOTAL_POWER_LIMIT=${TOTAL_POWER_LIMIT}W"
if (( GPU_POWER_CAP > 0 )); then
    nvidia-smi --query-gpu=index,power.min_limit,power.max_limit --format=csv,noheader 2>/dev/null |
    while IFS=',' read -r g min max; do
        g=$(echo "$g" | tr -d ' '); min=$(echo "$min" | awk '{print int($1)}'); max=$(echo "$max" | awk '{print int($1)}')
        [[ "$min" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] || continue
        (( min > 0 && max > 0 )) || continue
        if (( GPU_POWER_CAP < min )); then
            echo "WARNING: GPU $g cap ${GPU_POWER_CAP}W is below its min_limit ${min}W -> will use ${min}W"
        elif (( GPU_POWER_CAP > max )); then
            echo "WARNING: GPU $g cap ${GPU_POWER_CAP}W is above its max_limit ${max}W -> will use ${max}W"
        fi
    done
fi
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
# --- PATCH: per-GPU power cap, change here or in /etc/nvidia-oc-monitor.conf ---
Environment="GPU_POWER_CAP=400"
EnvironmentFile=-/etc/nvidia-oc-monitor.conf
ExecStartPre=/usr/bin/nvidia-smi
ExecStart=/usr/local/bin/nvidia-oc-monitor

[Install]
WantedBy=multi-user.target
EOF

# --- PATCH: create the config file once, never clobber an existing one ---
if [[ ! -f /etc/nvidia-oc-monitor.conf ]]; then
cat << 'EOF' | sudo tee /etc/nvidia-oc-monitor.conf
# Read by /usr/local/bin/nvidia-oc-monitor at startup.
# Hard per-GPU power ceiling in Watts. 0 = disabled (use hardware max).
GPU_POWER_CAP=400

# Rig-wide budget in Watts; only kicks in when total draw exceeds it.
TOTAL_POWER_LIMIT=3500
EOF
fi

sudo chmod +x /usr/local/bin/nvidia-oc-monitor

sudo systemctl daemon-reload;          # --- PATCH: needed after editing the unit ---
sudo systemctl enable nvidia-oc-monitor;
sudo systemctl restart nvidia-oc-monitor;
sudo systemctl status nvidia-oc-monitor;

#wget -qO- https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/nvidia-oc-monitor-init.sh | bash

cat << 'EOF' | sudo tee /usr/local/bin/nvidia-oc-monitor
#!/bin/bash

# ============================================================
# Operating mode: process | thermal
# ============================================================
MODE="thermal"

# ============================================================
# Configuration
# ============================================================
configFileUrl="https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/nvidia-oc-monitor.conf"

declare -A processSettings

time_interval=60
oc_change_delay=1
reboot_on_failure=false

# ============================================================
# Thermal power control settings
# ============================================================
TEMP_HIGH=80
TEMP_CRITICAL=85
TEMP_RECOVER=75
TEMP_EMERGENCY=88

PL_STEP_DOWN=10
PL_STEP_UP=15
CHECK_INTERVAL=5

declare -A CURRENT_PL

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
            if $reboot_on_failure; then
                reboot --force
            else
                exit 1
            fi
        fi
    done
}

# ============================================================
# Thermal PL controller (gradual + hysteresis)
# ============================================================
thermal_power_control() {
  for gpu_id in $(fetch_gpu_indices); do
    # Get temperature with error handling
    TEMP_OUTPUT=$(nvidia-smi -i "$gpu_id" --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
    if [[ -z "$TEMP_OUTPUT" || "$TEMP_OUTPUT" == "[N/A]" ]]; then
      continue
    fi
    TEMP=$(echo "$TEMP_OUTPUT" | awk '{print int($1)}')

    # Get current power limit with error handling
    if [[ -z "${CURRENT_PL[$gpu_id]}" ]]; then
      PL_OUTPUT=$(nvidia-smi -i "$gpu_id" --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null)
      if [[ -n "$PL_OUTPUT" && "$PL_OUTPUT" != "[N/A]" ]]; then
        CURRENT_PL[$gpu_id]=$(echo "$PL_OUTPUT" | awk '{print int($1)}')
      fi
    fi

    # Ensure we have a valid PL value
    if [[ -z "${CURRENT_PL[$gpu_id]}" ]]; then
      continue
    fi
    
    # Use the already converted PL value
    PL=${CURRENT_PL[$gpu_id]}

    # Get power limits with error handling
    MAX_PL_OUTPUT=$(nvidia-smi -i "$gpu_id" --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null)
    MIN_PL_OUTPUT=$(nvidia-smi -i "$gpu_id" --query-gpu=power.min_limit --format=csv,noheader,nounits 2>/dev/null)
    
    if [[ -z "$MAX_PL_OUTPUT" || "$MAX_PL_OUTPUT" == "[N/A]" ]]; then
      continue
    fi
    if [[ -z "$MIN_PL_OUTPUT" || "$MIN_PL_OUTPUT" == "[N/A]" ]]; then
      continue
    fi
    
    MAX_PL=$(echo "$MAX_PL_OUTPUT" | awk '{print int($1)}')
    MIN_PL=$(echo "$MIN_PL_OUTPUT" | awk '{print int($1)}')

    # Apply thermal control logic
    if (( TEMP >= TEMP_EMERGENCY )); then
        PL=$MIN_PL
    elif (( TEMP >= TEMP_CRITICAL )); then
        PL=$((PL - PL_STEP_DOWN * 2))
    elif (( TEMP > TEMP_HIGH )); then
        PL=$((PL - PL_STEP_DOWN))
    elif (( TEMP <= TEMP_RECOVER )); then
        PL=$((PL + PL_STEP_UP))
    fi

    # Clamp power limit within bounds
    if (( PL > MAX_PL )); then
        PL=$MAX_PL
    fi
    if (( PL < MIN_PL )); then
        PL=$MIN_PL
    fi
    
    if (( TEMP >= TEMP_EMERGENCY )); then
        PL=$MIN_PL
    elif (( TEMP >= TEMP_CRITICAL )); then
        PL=$((PL - PL_STEP_DOWN * 2))
    elif (( TEMP > TEMP_HIGH )); then
        PL=$((PL - PL_STEP_DOWN))
    elif (( TEMP <= TEMP_RECOVER )); then
        PL=$((PL + PL_STEP_UP))
    fi

    (( PL > MAX_PL )) && PL=$MAX_PL
    (( PL < MIN_PL )) && PL=$MIN_PL

    if [[ "${CURRENT_PL[$gpu_id]}" -ne "$PL" ]]; then
        nvidia-smi -i "$gpu_id" -pl "$PL" > /dev/null 2>&1
        CURRENT_PL[$gpu_id]=$PL
    fi
  done
}

# ============================================================
# Load config
# ============================================================
load_config_from_url() {
    uniqueUrl="${configFileUrl}?$(date +%s)"

    if curl -fs "$uniqueUrl" -o /tmp/processSettings.conf; then
        while IFS='=' read -r key value; do
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            [[ -z "$key" || "$key" == \#* ]] && continue
            processSettings["$key"]=$value
        done < /tmp/processSettings.conf
    fi
}

# ============================================================
# OC functions (unchanged logic)
# ============================================================
set_oc() {
    local gpu_id=$1
    local settings=$4

    local mem_clock core_clock power_limit

    IFS=',' read -ra kvpairs <<< "$settings"
    for kv in "${kvpairs[@]}"; do
        IFS='=' read -r key value <<< "$kv"
        case "$key" in
            mem_clock) mem_clock=$value ;;
            core_clock) core_clock=$value ;;
            power_limit) power_limit=$value ;;
        esac
    done

    [[ -n "$mem_clock" ]] && nvidia-smi -i "$gpu_id" -lmc 0,"$mem_clock" > /dev/null 2>&1
    [[ -n "$core_clock" ]] && nvidia-smi -i "$gpu_id" -lgc 0,"$core_clock" > /dev/null 2>&1
    [[ -n "$power_limit" ]] && nvidia-smi -i "$gpu_id" -pl "$power_limit" > /dev/null 2>&1
}

reset_oc() {
    nvidia-smi -rgc > /dev/null 2>&1
    nvidia-smi -rmc > /dev/null 2>&1

    for gpu_id in $(fetch_gpu_indices); do
        MAX_POWER=$(nvidia-smi -i "$gpu_id" --query-gpu=power.max_limit --format=csv,noheader,nounits)
        nvidia-smi -i "$gpu_id" -pl "$MAX_POWER" > /dev/null 2>&1
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
load_config_from_url
nvidia-smi -pm 1 > /dev/null 2>&1

# ============================================================
# Main loop
# ============================================================
while true; do
  case "$MODE" in
    thermal)
      thermal_power_control
      sleep "$CHECK_INTERVAL"
      ;;
    process)
      reset_oc
      for gpu_id in $(fetch_gpu_indices); do
        for pid in $(nvidia-smi -i "$gpu_id" --query-compute-apps=pid --format=csv,noheader); do
          process_cmd=$(ps -p "$pid" -o args=)
          for entry in "${!processSettings[@]}"; do
            IFS=',' read -r process process_arg <<< "$entry"
            if [[ "$process_cmd" =~ $process ]]; then
              [[ -z "$process_arg" || "$process_cmd" == *"$process_arg"* ]] && \
              sleep "$oc_change_delay" && \
              set_oc "$gpu_id" "$process" "$process_arg" "${processSettings[$entry]}"
            fi
          done
        done
      done
      sleep "$time_interval"
      ;;
  esac
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

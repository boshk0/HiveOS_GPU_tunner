#!/bin/bash

#sudo bash -c 'wget -qO- https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/nvidia-oc-monitor-init-patched.sh | bash'
#
# PATCHED VARIANT v2 — configurable per-GPU power cap + every tunable env-driven
#                      + auto-installs set_fan_speed from the same repo.
# Every change from the upstream script is marked with  # --- PATCH ---
#
# Run as ROOT. Either:
#   sudo bash -c 'wget -qO- https://raw.githubusercontent.com/<you>/.../nvidia-oc-monitor-init-patched.sh | bash'
#   curl -fsSL <url> -o installer.sh && sudo bash installer.sh
# Plain `wget -qO- <url> | bash` as a normal user FAILS: sudo cannot prompt
# for a password through the pipe. That is why this script requires root
# instead of sprinkling sudo, and checks it up front.
#
# Configure without editing this file — ALL of these now work:
#   sudo systemctl edit nvidia-oc-monitor     ->  [Service] Environment="TEMP_HIGH=68"
#   or edit /etc/nvidia-oc-monitor.conf       (created below, wins over systemd env)
#
# v1 -> v2 changes:
#   * Every constant is now ${VAR:-default}: sourced config / systemd env actually
#     takes effect (in v1 the thermal + fan block was assigned AFTER the source and
#     silently clobbered whatever you put in the config file).
#   * set_fan_speed (ELF x86-64 binary, lives in the repo root) is downloaded to
#     /usr/local/bin/set_fan_speed and chmod +x during setup. FAN_CMD defaults there.
#   * GPU target temperature (-gtt) is now GPU_TARGET_TEMP instead of a bare 65.
#   * Startup warns if set_fan_speed is missing / not executable.
#   * systemd unit no longer duplicates GPU_POWER_CAP=400 — the conf file is the
#     single source of truth.

set -u

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root:  sudo bash $0"
    echo "       piped form:        sudo bash -c 'wget -qO- <url> | bash'"
    exit 1
fi

# ============================================================
# Installer knobs  # --- PATCH ---
# Override on the fly:  sudo REPO_BRANCH=main FAN_CMD=/opt/bin/set_fan_speed bash installer.sh
# ============================================================
REPO="${REPO:-boshk0/HiveOS_GPU_tunner}"
REPO_BRANCH="${REPO_BRANCH:-main}"   # pin a commit SHA for reproducible installs
MONITOR_BIN="${MONITOR_BIN:-/usr/local/bin/nvidia-oc-monitor}"
FAN_CMD="${FAN_CMD:-/usr/local/bin/set_fan_speed}"   # --- PATCH: was /home/miner/set_fan_speed ---
CONFIG_FILE="${CONFIG_FILE:-/etc/nvidia-oc-monitor.conf}"
UNIT_FILE="${UNIT_FILE:-/etc/systemd/system/nvidia-oc-monitor.service}"

fetch_raw() {   # fetch_raw <relative-path> <dest>
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL "https://raw.githubusercontent.com/$REPO/$REPO_BRANCH/$1" -o "$2"
    else
        wget -qO "$2" "https://raw.githubusercontent.com/$REPO/$REPO_BRANCH/$1"
    fi
}

# ============================================================
# Install set_fan_speed  # --- PATCH ---
# Compiled NVML helper (x86-64 ELF) from the same repo:
#   usage: set_fan_speed [-i gpu_index] <0-100>|auto
# Needs libnvidia-ml.so.1 (i.e. the NVIDIA driver) at runtime.
# ============================================================
# Always (re-)download so every setup run pulls the current repo build,
# then make it executable. Overwriting is safe: the monitor invokes it by path.
echo "Installing set_fan_speed -> $FAN_CMD"
fetch_raw set_fan_speed "$FAN_CMD" || { echo "ERROR: failed to download set_fan_speed"; exit 1; }
chmod +x "$FAN_CMD"
# Sanity check: must be an ELF binary (first 4 bytes \x7fELF). `file` is not
# guaranteed on minimal hosts, so check the magic directly.
if [[ "$(head -c 4 "$FAN_CMD" 2>/dev/null | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]]; then
    echo "ERROR: $FAN_CMD is not an ELF binary — wrong architecture download or corrupt file."
    echo "       This build is x86-64 only; ARM rigs need set_fan_speed recompiled."
    exit 1
fi
# Optional smoke test: 'auto' on GPU 0 is a no-op that proves NVML loads.
if command -v nvidia-smi > /dev/null 2>&1; then
    if ! "$FAN_CMD" auto -i 0 > /dev/null 2>&1; then
        echo "WARNING: '$FAN_CMD auto -i 0' failed — check that the NVIDIA driver provides libnvidia-ml.so.1"
    fi
fi

cat << 'EOF' | tee "$MONITOR_BIN"
#!/bin/bash

# ============================================================
# Configuration source of truth  # --- PATCH ---
# Precedence: /etc/nvidia-oc-monitor.conf  >  systemd Environment=  >  defaults below
# The source MUST happen before every default assignment, and every default
# must be written as ${VAR:-default}, otherwise it clobbers the config.
# ============================================================
CONFIG_FILE="${OC_MONITOR_CONFIG:-/etc/nvidia-oc-monitor.conf}"
[[ -r "$CONFIG_FILE" ]] && . "$CONFIG_FILE"

# ============================================================
# Thermal power control settings  # --- PATCH: all env/config-driven now
# ============================================================
TEMP_HIGH=${TEMP_HIGH:-71}
TEMP_CRITICAL=${TEMP_CRITICAL:-83}
TEMP_EMERGENCY=${TEMP_EMERGENCY:-85}
TEMP_RECOVER=${TEMP_RECOVER:-50}
PL_STEP_DOWN=${PL_STEP_DOWN:-10}
PL_STEP_UP=${PL_STEP_UP:-15}
PL_CRITICAL_FACTOR=${PL_CRITICAL_FACTOR:-2}   # step-down multiplier at TEMP_CRITICAL

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
# Fan control settings  # --- PATCH: all env/config-driven now
# ============================================================
TEMP_FAN_ON=${TEMP_FAN_ON:-65}
TEMP_FAN_OFF=${TEMP_FAN_OFF:-$TEMP_RECOVER}
FAN_ON_SPEED=${FAN_ON_SPEED:-80}

FAN_CMD=${FAN_CMD:-/usr/local/bin/set_fan_speed}   # --- PATCH: was hardcoded /home/miner/set_fan_speed ---
GPU_TARGET_TEMP=${GPU_TARGET_TEMP:-65}             # --- PATCH: was a bare literal in 'nvidia-smi -gtt 65' ---
PERSISTENCE_MODE=${PERSISTENCE_MODE:-1}           # --- PATCH: 1 = force persistence mode on ---
declare -A FAN_STATE   # auto | manual

# ============================================================
# GPU discovery (robust) - Cache GPU indices once at startup
# ============================================================
fetch_gpu_indices() {
    local retries=0
    local max_retries=${GPU_DISCOVERY_RETRIES:-5}   # --- PATCH: was hardcoded 5 ---
    local per_try_timeout=${GPU_DISCOVERY_TIMEOUT:-5}   # --- PATCH: was hardcoded 5 ---
    while true; do
        if output=$(timeout "$per_try_timeout" nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null); then
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
        "$FAN_CMD" "$FAN_ON_SPEED" -i "$gpu_id" > /dev/null 2>&1   # --- PATCH: quoted $FAN_CMD ---
        FAN_STATE[$gpu_id]="manual"
    elif (( temp <= TEMP_FAN_OFF )) && [[ "${FAN_STATE[$gpu_id]}" != "auto" ]]; then
        "$FAN_CMD" auto -i "$gpu_id" > /dev/null 2>&1
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
            pl=$((pl - PL_STEP_DOWN * PL_CRITICAL_FACTOR))   # --- PATCH: factor was a bare * 2 ---
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
        "$FAN_CMD" auto -i "$gpu_id" > /dev/null 2>&1
        FAN_STATE[$gpu_id]="auto"
    done <<< "$batch_output"

    (( PERSISTENCE_MODE )) && nvidia-smi -pm 1 > /dev/null 2>&1
    nvidia-smi -gtt "$GPU_TARGET_TEMP" > /dev/null 2>&1   # --- PATCH: was hardcoded 65 ---
}
cleanup() {
    reset_oc
    exit 0
}
trap cleanup SIGINT SIGTERM
# ============================================================
# Init
# ============================================================
(( PERSISTENCE_MODE )) && nvidia-smi -pm 1 > /dev/null 2>&1
# ============================================================
# Discover GPUs once at startup (robust, cached)
# ============================================================
mapfile -t GPUS < <(fetch_gpu_indices)
# ============================================================
# Startup report + sanity checks  # --- PATCH ---
# The cap is clamped to [min_limit, max_limit] per GPU, so an out-of-range value
# is silently rounded to the nearest bound. Warn instead of hiding it.
# ============================================================
echo "nvidia-oc-monitor: GPUs=${#GPUS[@]} GPU_POWER_CAP=${GPU_POWER_CAP}W TOTAL_POWER_LIMIT=${TOTAL_POWER_LIMIT}W FAN_CMD=${FAN_CMD}"
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
# --- PATCH: fail loudly instead of silently no-op'ing fan control all day ---
if [[ ! -x "$FAN_CMD" ]]; then
    echo "WARNING: FAN_CMD '$FAN_CMD' is missing or not executable — fan control is DISABLED"
fi
# ============================================================
# Main loop
# ============================================================
while true; do
    thermal_power_control
    sleep "$CHECK_INTERVAL"
done
EOF

cat << 'EOF' | tee "$UNIT_FILE"
[Unit]
Description=NVIDIA GPU Overclock Monitoring Service
After=multi-user.target

[Service]
Type=simple
# --- PATCH: no Environment= line here. /etc/nvidia-oc-monitor.conf is the single
# source of truth; use `systemctl edit` only for one-off overrides. ---
EnvironmentFile=-/etc/nvidia-oc-monitor.conf
ExecStartPre=/usr/bin/nvidia-smi
ExecStart=/usr/local/bin/nvidia-oc-monitor

[Install]
WantedBy=multi-user.target
EOF

# --- PATCH: create the config file once, never clobber an existing one ---
if [[ ! -f "$CONFIG_FILE" ]]; then
cat << EOF | tee "$CONFIG_FILE"
# Read by /usr/local/bin/nvidia-oc-monitor at startup.
# Every tunable below can be set here; uncomment and change what you need.

# Hard per-GPU power ceiling in Watts. 0 = disabled (use hardware max).
GPU_POWER_CAP=400

# Rig-wide budget in Watts; only kicks in when total draw exceeds it.
TOTAL_POWER_LIMIT=3500

# --- Thermal power control ---
# TEMP_HIGH=71          # above this: start stepping power limit down
# TEMP_CRITICAL=83      # above this: step down PL_STEP_DOWN x PL_CRITICAL_FACTOR (10x2)
# TEMP_EMERGENCY=85     # at this: drop straight to the hardware min_limit
# TEMP_RECOVER=50       # at/below this: ramp power limit back up
# PL_STEP_DOWN=10
# PL_STEP_UP=15
# PL_CRITICAL_FACTOR=2

# --- Fan control (via set_fan_speed) ---
# TEMP_FAN_ON=65        # above this: take the fan over manually
# TEMP_FAN_OFF=50       # at/below this: hand it back to the driver (defaults to TEMP_RECOVER)
# FAN_ON_SPEED=80
# FAN_CMD=/usr/local/bin/set_fan_speed

# --- Misc ---
# CHECK_INTERVAL=5
# GPU_TARGET_TEMP=65            # nvidia-smi -gtt target temperature
# PERSISTENCE_MODE=1            # 0 = don't force persistence mode
# GPU_DISCOVERY_RETRIES=5
# GPU_DISCOVERY_TIMEOUT=5
EOF
fi

chmod +x "$MONITOR_BIN"

systemctl daemon-reload;          # --- PATCH: needed after editing the unit ---
systemctl enable nvidia-oc-monitor;
systemctl restart nvidia-oc-monitor;
systemctl status nvidia-oc-monitor;

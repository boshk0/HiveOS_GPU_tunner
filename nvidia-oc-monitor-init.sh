#wget -qO- https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/nvidia-oc-monitor-init.sh | bash

cat << 'EOF' | sudo tee /usr/local/bin/nvidia-oc-monitor
#!/bin/bash

# Configuration file URL
configFileUrl="https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/nvidia-oc-monitor.conf"

# Define an associative array for process settings with arguments, memory, core clocks, and power limit
declare -A processSettings
#processSettings["pow-miner-cuda,"]="mem_clock=810" # Miner for GRAM algo
#processSettings["qli-runner,"]="mem_clock=5001,power_limit=200" # Miner for QUBIC algo
#processSettings["xelis-taxminer,"]="mem_clock=5001" # Miner for XEL algo
#processSettings["hashcat,"]="mem_clock=5001" # Hashcat password cracker
#processSettings["lolMiner,--algo TON "]="mem_clock=810,core_clock=2340,power_limit=225" # Miner for TON algo

time_interval=60 # Seconds between each loop
oc_change_delay=1 # Delay between resetting and setting OC
reboot_on_failure=false # Default is false. Set to true to enable automated reboots if `nvidia-smi` fails.

# Function to fetch GPU indices using `nvidia-smi`
fetch_gpu_indices() {
    local retries=0
    local max_retries=5
    local retry_delay=1

    while true; do
        if output=$(timeout 5 nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null); then
            echo "$output"
            return 0
        else
            retries=$((retries + 1))
            echo "$(date): Warning: Unable to fetch GPU information (attempt $retries/$max_retries). Retrying in $retry_delay second(s)..."
            sleep "$retry_delay"
        fi

        if [[ $retries -ge $max_retries ]]; then
            echo "$(date): Error: `nvidia-smi` is unresponsive after $max_retries attempts."
            if $reboot_on_failure; then
                echo "$(date): Rebooting system..."
                sudo reboot --force
            else
                echo "$(date): Reboot is disabled. Exiting."
                exit 1
            fi
        fi
    done
}

# Function to fetch and load settings from the configuration URL
load_config_from_url() {
    # Generate a unique URL to prevent caching (use current timestamp)
    uniqueUrl="${configFileUrl}?$(date +%s)"

    if curl -f -s -H "Cache-Control: no-cache" -H "Pragma: no-cache" "$uniqueUrl" -o "/tmp/processSettings.conf"; then
        while IFS='=' read -r key value; do
            # Trim leading and trailing spaces
            key=$(echo $key | xargs)
            value=$(echo $value | xargs)

            # Skip lines that are empty or start with '#' after trimming
            [[ -z "$key" || $key == \#* ]] && continue

            processSettings["$key"]=$value
        done < "/tmp/processSettings.conf"
        echo "$(date): Successfully loaded configuration: $uniqueUrl"
    else
        echo "$(date): Unable to retrieve configuration. Using default configuration."
    fi
}

# Function to set overclocking
set_oc() {
    local gpu_id=$1
    local process=$2
    local process_arg=$3
    local settings=$4

    local mem_clock core_clock power_limit

    # Parse the settings
    IFS=',' read -ra kvpairs <<< "$settings"
    for kv in "${kvpairs[@]}"; do
        IFS='=' read -r key value <<< "$kv"
        case "$key" in
            mem_clock)
                mem_clock=$value
                ;;
            core_clock)
                core_clock=$value
                ;;
            power_limit)
                power_limit=$value
                ;;
        esac
    done

    if [[ -n "$mem_clock" ]]; then
        echo "$(date): Setting memory OC for GPU $gpu_id ($process $process_arg) to $mem_clock"
        {
            nvidia-smi -i $gpu_id -lmc $mem_clock
        } > /dev/null 2>&1
    fi

    if [[ -n "$core_clock" ]]; then
        echo "$(date): Setting core OC for GPU $gpu_id ($process $process_arg) to $core_clock"
        {
            nvidia-smi -i $gpu_id -lgc $core_clock
        } > /dev/null 2>&1
    fi

    if [[ -n "$power_limit" ]]; then
        echo "$(date): Setting power limit for GPU $gpu_id ($process $process_arg) to $power_limit"
        {
            nvidia-smi -i $gpu_id -pl $power_limit
        } > /dev/null 2>&1
    fi
}

# Function to reset overclocking
reset_oc() {
    # echo "$(date): Resetting OC to default"
    {
        nvidia-smi -rgc
        nvidia-smi -rmc

        nvidia-smi -pm 1           # Persistence mode
        nvidia-smi -pl 450         # Power limit
        nvidia-smi -gtt 65         # Temperature limit
    } > /dev/null 2>&1
}

# Cleanup function for graceful shutdown
cleanup() {
    echo "$(date): Script is stopping, resetting OC to default..."
    reset_oc
    exit 0
}

# Trap SIGINT and SIGTERM
trap cleanup SIGINT SIGTERM

# Fetch and load the configuration at script start
load_config_from_url

# Main loop
while true; do
    # Reset OC settings at the start of each loop
    reset_oc

    # Fetch GPU indices using the helper function
    gpu_indices=$(fetch_gpu_indices)

    for gpu_id in $gpu_indices; do
        # List processes for the specific GPU
        for pid in $(nvidia-smi -i "$gpu_id" --query-compute-apps=pid --format=csv,noheader); do
            process_cmd=$(ps -p "$pid" -o args=)
            for entry in "${!processSettings[@]}"; do
                IFS=',' read -r process process_arg <<< "$entry"
                settings=${processSettings["$entry"]}

                # Match commonly used characters like ., / and space
                if [[ "$process_cmd" =~ (^|[[:space:]/])$process($|[[:space:]]) ]]; then
                    if [[ -z "$process_arg" || "$process_cmd" == *"$process_arg"* ]]; then
                        # Give GPU time between each OC settings change (reset/set)
                        sleep $oc_change_delay

                        set_oc "$gpu_id" "$process" "$process_arg" "${settings}"
                        break 2 # Exit both loops after setting OC for the first matching process
                    fi
                fi

            done
        done
    done

    sleep $time_interval
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

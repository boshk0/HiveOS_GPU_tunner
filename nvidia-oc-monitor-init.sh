#wget -qO- https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/nvidia-oc-monitor-init.sh | bash

cat << 'EOF' | sudo tee /usr/local/bin/nvidia-oc-monitor
#!/bin/bash

# Configuration file URL
configFileUrl="https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/nvidia-oc-monitor.conf"

# Define an associative array for process settings with arguments, memory, and core clocks
declare -A processSettings
processSettings["pow-miner-cuda,"]="mem_clock=810" # Miner for GRAM algo
processSettings["qli-runner,"]="mem_clock=5001" # Miner for QUBIC algo
processSettings["xelis-taxminer,"]="mem_clock=5001" # Miner for XEL algo
processSettings["hashcat,"]="mem_clock=5001" # Hashcat password cracker
processSettings["lolMiner,--algo TON "]="mem_clock=810,code_clock=2340" # Miner for TON algo
 
time_interval=60 # Seconds between each loop
oc_change_delay=1 # Delay between resetting and setting OC

# Function to fetch and load settings from the configuration URL
load_config_from_url() {
    # Generate a unique URL to prevent caching (using the current timestamp)
    uniqueUrl="${configFileUrl}?$(date +%s)"
    
    if curl -f -s -H "Cache-Control: no-cache" "$uniqueUrl" -o "/tmp/processSettings.conf"; then
        while IFS='=' read -r key value; do
            # Trim leading and trailing spaces
            key=$(echo $key | xargs)
            value=$(echo $value | xargs)

            # Skip lines that are empty or start with '#' after trimming
            [[ -z "$key" || $key == \#* ]] && continue

            processSettings["$key"]=$value
        done < "/tmp/processSettings.conf"
        echo "$(date): Successfully loaded configuration."
    else
        echo "$(date): Unable to retrieve configuration. Using default configuration."
    fi
}

# Function to set overclocking
set_oc() {
    local process=$1
    local process_arg=$2
    local settings=$3

    local mem_clock core_clock

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
        esac
    done

    if [[ -n "$mem_clock" ]]; then
        echo "$(date): Setting memory OC for $process (arg: $process_arg) to $mem_clock"
        {
            nvidia-smi -lmc $mem_clock
        } > /dev/null 2>&1
    fi

    if [[ -n "$core_clock" ]]; then
        echo "$(date): Setting core OC for $process (arg: $process_arg) to $core_clock"
        {
            nvidia-smi -lgc $core_clock
        } > /dev/null 2>&1
    fi
}

# Function to reset overclocking
reset_oc() {
    echo "$(date): Resetting OC to default"
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

    for entry in "${!processSettings[@]}"; do
        IFS=',' read -r process process_arg <<< "$entry"
        settings=${processSettings["$entry"]}
        
        if [[ -z "$process_arg" ]]; then
            # Handle processes without specific arguments
            if pgrep -f "(^|/)$process(\s|$)" > /dev/null; then
                # Give GPU time between each OC settings change (reset/set)
                sleep $oc_change_delay
        
                set_oc "$process" "" "${settings}"
                break # Exit the loop after setting OC for the first running process
            fi
        else
            # Handle processes with specific arguments
            if pgrep -if "(^|/)$process(\s|$).*$process_arg" > /dev/null; then
                # Give GPU time between each OC settings change (reset/set)
                sleep $oc_change_delay
        
                set_oc "$process" "$process_arg" "${settings}"
                break # Exit the loop after setting OC for the first running process
            fi
        fi
    done

    sleep $time_interval
done
EOF

cat << 'EOF' | sudo tee /etc/systemd/system/nvidia-oc-monitor.service
[Unit]
Description=NVIDIA GPU Overclock Monitoring Service
Requires=nvidia-persistenced.service
After=nvidia-persistenced.service

[Service]
Type=simple
ExecStart=/usr/local/bin/nvidia-oc-monitor
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo chmod +x /usr/local/bin/nvidia-oc-monitor

sudo systemctl enable nvidia-oc-monitor;
sudo systemctl restart nvidia-oc-monitor;
sudo systemctl status nvidia-oc-monitor;

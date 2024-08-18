#wget -qO- https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/temperature-exporter-init.sh | bash

cat << 'EOF' | sudo tee /usr/local/bin/temperature-exporter.py
#!/usr/bin/env python3
import time
import os
import select
import struct

# Constants
SERVER_PORT = 9036
POLL_INTERVAL = 60 # seconds
SENSOR_PATH = '/dev/hidraw1'
SENSOR_LABEL = 'tempergold01'

def read_temperature(device_path=SENSOR_PATH):
    try:
        # Credit to https://github.com/urwen/temper for this byte sequence
        QUERY = struct.pack('8B', 0x01, 0x80, 0x33, 0x01, 0x00, 0x00, 0x00, 0x00)

        # Open the device and return a file descriptor (needed for poll later)
        f = os.open(device_path, os.O_RDWR)

        # Write the "fetch temperature" query to the device
        os.write(f, QUERY)

        # Wait for the device to have data to read by polling the file descriptor
        poll = select.poll()
        poll.register(f, select.POLLIN)

        # This call blocks until data is ready
        poll.poll()
        poll.unregister(f)

        # Tempergold sends 16 bytes of data, read it and close the file
        data = os.read(f, 16)
        os.close(f)

        # Temperature is encoded as a big-endian (>) 2 byte integer (h)
        # https://docs.python.org/3/library/struct.html#format-characters
        # The encoded value represents degrees in c * 100
        return struct.unpack_from('>h', data, 2)[0] / 100

    except Exception as e:
        print(f"Error reading temperature: {e}")
        return None


if __name__ == '__main__':
    from prometheus_client import start_http_server, Gauge, CollectorRegistry

    # Create a custom registry
    registry = CollectorRegistry()

    # Create a gauge metric for temperature
    TEMPERATURE = Gauge('sensor_temperature_celsius', 'Sensor current temperature', ['sensor_id'], registry=registry)

    # Start up the server to expose the metrics.
    start_http_server(SERVER_PORT, registry=registry)

    # Update temperature every minute.
    while True:
        current_temperature = read_temperature()
        if current_temperature is not None:
            TEMPERATURE.labels(SENSOR_LABEL).set(current_temperature)
        time.sleep(POLL_INTERVAL)
EOF

cat << 'EOF' | sudo tee /etc/systemd/system/temperature-exporter.service
[Unit]
Description=USB Temperature Sensor Prometheus Exporter Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/temperature-exporter.py
RemainAfterExit=yes
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable temperature-exporter;
sudo systemctl restart temperature-exporter;
sudo systemctl status temperature-exporter;

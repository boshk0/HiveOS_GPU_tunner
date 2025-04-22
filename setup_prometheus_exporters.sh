# sudo wget -O setup_prometheus_exporters.sh https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/setup_prometheus_exporters.sh; sudo chmod +x setup_prometheus_exporters.sh; sudo ./setup_prometheus_exporters.sh

mkdir tmp;
cd tmp;

wget https://github.com/prometheus/node_exporter/releases/download/v1.9.1/node_exporter-1.9.1.linux-amd64.tar.gz;

sudo tar xvfz node_exporter-*.*-amd64.tar.gz;

sudo mv node_exporter-*.*-amd64/node_exporter /usr/local/bin/;

sudo useradd -rs /bin/false node_exporter;

cat << EOF | sudo tee /etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload;
sudo systemctl start node_exporter;
sudo systemctl enable node_exporter;
sudo systemctl status node_exporter;

cd ..
sudo rm tmp -r

#---------------------------------------------------------

mkdir tmp;
cd tmp;

wget https://github.com/utkuozdemir/nvidia_gpu_exporter/releases/download/v1.3.1/nvidia_gpu_exporter_1.3.1_linux_x86_64.tar.gz;

sudo tar xvfz nvidia_gpu_exporter*.*tar.gz;

sudo mv nvidia_gpu_exporter /usr/local/bin/;

sudo useradd -rs /bin/false nvidia_gpu_exporter;

cat << EOF | sudo tee /etc/systemd/system/nvidia_gpu_exporter.service
[Unit]
Description=Nvidia GPU Exporter
After=network-online.target

[Service]
Type=simple
User=nvidia_gpu_exporter
Group=nvidia_gpu_exporter
ExecStart=/usr/local/bin/nvidia_gpu_exporter
SyslogIdentifier=nvidia_gpu_exporter

Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload;
sudo systemctl start nvidia_gpu_exporter;
sudo systemctl enable nvidia_gpu_exporter;
sudo systemctl status nvidia_gpu_exporter;

cd ..
sudo rm tmp -r


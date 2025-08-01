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
sudo systemctl enable node_exporter;
sudo systemctl start node_exporter;
sudo systemctl status node_exporter;

cd ..
sudo rm tmp -r

#---------------------------------------------------------

sudo wget -q -O /usr/local/bin/nvidia_gpu_exporter.sh https://raw.githubusercontent.com/boshk0/gddr6_temps/master/nvidia_gpu_exporter.sh;
sudo chmod +x /usr/local/bin/nvidia_gpu_exporter.sh;
sudo wget -q -O /etc/systemd/system/nvidia_gpu_exporter.service https://raw.githubusercontent.com/boshk0/gddr6_temps/master/nvidia_gpu_exporter.service;

sudo systemctl daemon-reload;
sudo systemctl enable nvidia_gpu_exporter;
sudo systemctl start nvidia_gpu_exporter;
sudo systemctl status nvidia_gpu_exporter;


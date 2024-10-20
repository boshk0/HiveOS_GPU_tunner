MIGRATION PLAN for PROXY SERVER
======================================

Setup NEW server:
----------------
1. Install Ubuntu Server 22.04

2. APT Update/Upgrade

3. Install Docker for Ubuntu 22.04
	https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository

4. Add current user to Docker group
```bash
sudo gpasswd -a $USER docker
# close/open ssh session to take effect
```

5. Create Docker backup directory
```bash
sudo mkdir /docker_backup
```

Backup EXISTING server:
--------------------
6. Stop Docker containers
```bash
cd /etc/docker
docker compose down
```

7. Backup Docker volumes data   
```bash
sudo mkdir /docker_backup
sudo tar -czvf /docker_backup/prometheus-data.tar.gz -C /var/lib/docker/volumes/ docker_prometheus-data
sudo tar -czvf /docker_backup/grafana-data.tar.gz -C /var/lib/docker/volumes/ docker_grafana-data
sudo tar -czvf /docker_backup/openwebui-data.tar.gz -C /var/lib/docker/volumes/ docker_openwebui-data
sudo tar -czvf /docker_backup/nginx-proxy-manager-data.tar.gz -C /var/lib/docker/volumes/ docker_nginx-proxy-manager-data
sudo tar -czvf /docker_backup/letsencrypt-data.tar.gz -C /var/lib/docker/volumes/ docker_letsencrypt-data
```

8. Backup Docker compose file
```bash
sudo tar -czvf /docker_backup/docker-compose.tar.gz -C /etc/docker/ docker-compose.yml
```

9. Backup Prometheus config file
```bash
sudo tar -czvf /docker_backup/prometheus.tar.gz -C /etc/prometheus/ prometheus.yml
```

10. Copy zipped files to NEW server:
```bash
scp *.tar.gz user@new_server_ip:/docker_backup
```

Restore to NEW server:
----------------
11. Extract Docker compose file
```bash
sudo tar -xzvf /docker_backup/docker-compose.tar.gz -C /etc/docker/
```

12. Extract Prometheus config file
```bash
sudo tar -xzvf /docker_backup/prometheus.tar.gz -C /etc/prometheus/
```

13. Start/Stop Docker Services (to create volumes)
```bash
cd /etc/docker
docker-compose up -d
docker-compose down
```

14. Extract zipped files into Docker volumes folder
```bash
sudo tar -xzvf /docker_backup/prometheus-data.tar.gz -C /var/lib/docker/volumes/
sudo tar -xzvf /docker_backup/grafana-data.tar.gz -C /var/lib/docker/volumes/
sudo tar -xzvf /docker_backup/openwebui-data.tar.gz -C /var/lib/docker/volumes/
sudo tar -xzvf /docker_backup/nginx-proxy-manager-data.tar.gz -C /var/lib/docker/volumes/
sudo tar -xzvf /docker_backup/letsencrypt-data.tar.gz -C /var/lib/docker/volumes/
```

13. Match Ownership and Permissions
```bash
sudo chown -R root:root /var/lib/docker/volumes/docker_*
sudo chmod -R 755 /var/lib/docker/volumes/docker_*
```

15. Start Docker Services
```bash
cd /etc/docker
docker-compose up -d
```

16. Clean-up
```bash
sudo rm /docker_backup -r
```

17. MIGRATION COMPLETE

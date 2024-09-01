# Usage:
# curl -sSLf -o port_forwarder.py https://raw.githubusercontent.com/boshk0/HiveOS_GPU_tunner/main/port_forwarder.py
# python3 port_forwarder.py -f 0.0.0.0 -t 172.17.0.2 -p "8081:8081, 8082:8082" -d 4096

import socket
import threading
import argparse
import json

# Default values for optional arguments
default_from_host = "0.0.0.0"
default_to_host = "172.17.0.2"
default_port_mapping = {
    8081: 8081,
    8082: 8082,
    8083: 8083,
    8084: 8084,
}
default_data_length = 4096

def forward(source, destination, buffer_size):
    try:
        while True:
            data = source.recv(buffer_size)
            if not data:
                break
            destination.sendall(data)
    except Exception as e:
        print(f"Exception in forwarding: {e}")
    finally:
        try:
            source.shutdown(socket.SHUT_RD)
        except:
            pass
        source.close()

def handle_connection(client_socket, remote_host, remote_port, buffer_size):
    try:
        remote_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote_socket.connect((remote_host, remote_port))

        client_to_remote = threading.Thread(target=forward, args=(client_socket, remote_socket, buffer_size))
        remote_to_client = threading.Thread(target=forward, args=(remote_socket, client_socket, buffer_size))

        client_to_remote.start()
        remote_to_client.start()

        client_to_remote.join()
        remote_to_client.join()

    except Exception as e:
        print(f"Connection handling exception: {e}")
    finally:
        try:
            client_socket.shutdown(socket.SHUT_RDWR)
        except:
            pass
        client_socket.close()

        try:
            remote_socket.shutdown(socket.SHUT_RDWR)
        except:
            pass
        remote_socket.close()

def start_port_forwarding(local_host, port_mapping, buffer_size, remote_host):
    def listen_on_port(local_host, local_port, remote_host, remote_port, buffer_size):
        server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_socket.bind((local_host, local_port))
        server_socket.listen(5)

        print(f"Listening on {local_host}:{local_port} - Forwarding to {remote_host}:{remote_port}")

        while True:
            client_socket, addr = server_socket.accept()
            print(f"Accepted connection from {addr}")

            try:
                connection_thread = threading.Thread(
                    target=handle_connection,
                    args=(client_socket, remote_host, remote_port, buffer_size)
                )
                connection_thread.start()
            except Exception as e:
                print(f"Thread creation exception: {e}")

    threads = []
    for local_port, remote_port in port_mapping.items():
        thread = threading.Thread(target=listen_on_port,
                                  args=(local_host, local_port, remote_host, remote_port, buffer_size))
        thread.start()
        threads.append(thread)

    for thread in threads:
        thread.join()

def parse_args():
    parser = argparse.ArgumentParser(description='Port Forwarder')
    parser.add_argument('-f', '--from-host', default=default_from_host, help=f'Local host IP address (default={default_from_host})')
    parser.add_argument('-t', '--to-host', default=default_to_host, help=f'Remote host IP address (default={default_to_host})')
    parser.add_argument('-p', '--port-mapping', default=str(default_port_mapping), help=f'Port mapping dictionary (default={str(default_port_mapping)}) or comma-separated port mappings (e.g. "8081:8081, 8082>    parser.add_argument('-d', '--data-length', type=int, default=default_data_length, help=f'Default data length (default={default_data_length})')

    return parser.parse_args()

def load_port_mapping(port_mapping_str):
    try:
        if ":" in port_mapping_str:
            port_mappings = [mapping.split(":") for mapping in port_mapping_str.split(",")]
            port_mapping = {}
            for local, remote in port_mappings:
                local = int(local)
                remote = int(remote)
                port_mapping[local] = remote
        else:
            port_mapping = json.loads(port_mapping_str)
            if not isinstance(port_mapping, dict):
                raise ValueError("Invalid port mapping")
            for key in port_mapping:
                if not isinstance(key, int) or not isinstance(port_mapping[key], int):
                    raise ValueError("Invalid port mapping")
            return port_mapping
        return port_mapping
    except json.JSONDecodeError as e:
        print(f"Error parsing port mapping: {e}")
        exit(1)
    except ValueError as e:
        print(f"Error validating port mapping: {e}")
        exit(1)

def main():
    args = parse_args()
    port_mapping = load_port_mapping(args.port_mapping)
    start_port_forwarding(args.from_host, port_mapping, args.data_length, args.to_host)

if __name__ == "__main__":
    main()

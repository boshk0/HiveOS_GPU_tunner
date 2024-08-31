import socket
import threading

from_host = "0.0.0.0"
to_host = "172.17.0.2"
port_mapping = {
    8081: 8081,
    8082: 8082,  # Add more port mappings as needed
}
default_data_length = 1024  # Default buffer size

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

def start_port_forwarding(local_host, port_mapping, buffer_size):
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
                                  args=(local_host, local_port, to_host, remote_port, buffer_size))
        thread.start()
        threads.append(thread)
    
    for thread in threads:
        thread.join()

if __name__ == "__main__":
    data_length = default_data_length  # You can adjust this as needed
    start_port_forwarding(from_host, port_mapping, data_length)

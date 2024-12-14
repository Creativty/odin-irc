package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"

socket_connect :: proc(address: string) -> net.TCP_Socket {
	socket, err_dial := net.dial_tcp_from_hostname_and_port_string(address)
	if err_dial != nil {
		fmt.eprintln("error: could not dial", address, "with error", err_dial)
		os.exit(1)
	}
	return socket
}

socket_send :: proc(socket: net.TCP_Socket, bytes: []u8) -> int {
	bytes_sent, err_write := net.send_tcp(socket, bytes)
	if err_write != nil {
		fmt.eprintln("error: failed during send:", err_write)
		os.exit(1)
	}
	return bytes_sent
}

socket_recv :: proc(socket: net.TCP_Socket, buff: []byte) -> int {
	bytes_recv, err_recv := net.recv_tcp(socket, buff)
	if err_recv != nil {
		fmt.eprintln("error: failed during recv:", err_recv)
		os.exit(1)
	}
	return bytes_recv
}

get_address :: proc() -> string {
	args := os.args
	if len(args) != 2 {
		fmt.println("Usage: ", args[0], "<address>")
		os.exit(1)
	}
	return args[1]
}

main :: proc() {
	buff: [32 * mem.Kilobyte]byte
	address := get_address()

	context.logger = log.create_console_logger()
	socket := socket_connect(address)
	defer net.close(socket)

	data := "GET / HTTP/1.1\r\n\r\n"
	bytes_sent := socket_send(socket, transmute([]u8)data)
	log.debugf("sent %d bytes\n", bytes_sent)

	bytes_recv := socket_recv(socket, buff[:])
	msg := buff[:bytes_recv]
	fmt.println(cast(string)msg)
}

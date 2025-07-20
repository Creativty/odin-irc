package main

import "core:c"
import "openssl"
import "core:log"
import "core:fmt"
import "core:mem"
import "core:net"
import "base:runtime"
import "core:strings"
import "core:sys/posix"
import "core:sync/chan"

IRC_Connection_Step :: enum {
	Offline,
	Insecure,
	Secure,
	Online,
}

IRC_Connection :: struct {
	address:	net.Address,
	port:		int,

	/* Connection state */
	socket:		net.TCP_Socket,
	ssl_ctx:	openssl.SSL_CTX,
	ssl_inst:	openssl.SSL,
	step:		IRC_Connection_Step,
}

IRC_Error :: union #shared_nil {
	net.Network_Error,
	net.Set_Blocking_Error,
	posix.Errno,
	openssl.SSL_Error,
}

IRC_Command_Kind :: enum {
	PONG,
	PASS,
	NICK,
	USER,
	QUIT,
}

IRC_Retry_Mode :: enum {
	Read,
	Write,
}

irc_await :: proc(conn: ^IRC_Connection, mode := IRC_Retry_Mode.Read) -> (err: IRC_Error) {
	fds: posix.fd_set
	retval: c.int
	posix.FD_SET(cast(posix.FD)conn.socket, &fds)

	nfds := cast(c.int)conn.socket + 1
	timeout := posix.timeval{
		tv_sec = 0,
		tv_usec = 1_000 * 100,
	}
	switch mode {
	case .Write:
		retval = posix.select(nfds, nil, &fds, nil, &timeout)
	case .Read:
		retval = posix.select(nfds, &fds, nil, nil, &timeout)
	case:
		unreachable()
	}
	if retval == -1 do err = posix.get_errno()
	return
}

irc_retry :: proc(conn: ^IRC_Connection, ret: c.int) -> (err: IRC_Error) {
	_err := openssl.SSL_get_error(conn.ssl_inst, ret)
	#partial switch _err {
	case .Want_Read:
		return irc_await(conn, .Read)
	case .Want_Write:
		return irc_await(conn, .Write)
	case:
		return _err
	}
}

irc_dial :: proc(address: net.Address, port: int) -> (conn: IRC_Connection, err: IRC_Error) {
	conn.address, conn.port = address, port
	conn.socket = net.dial_tcp(conn.address, conn.port) or_return
	net.set_blocking(conn.socket, false) or_return
	conn.step = .Insecure

	method := openssl.TLS_client_method()
	conn.ssl_ctx = openssl.SSL_CTX_new(method); if conn.ssl_ctx == nil do return conn, posix.get_errno()
	conn.ssl_inst = openssl.SSL_new(conn.ssl_ctx); if conn.ssl_inst == nil do return conn, posix.get_errno()

	openssl.SSL_set_shutdown(conn.ssl_inst, openssl.SSL_Shutdown_Default)
	openssl.SSL_set_fd(conn.ssl_inst, cast(c.int)conn.socket)

	for {
		ret := openssl.SSL_connect(conn.ssl_inst)
		if ret == 1 do break
		irc_retry(&conn, ret) or_return
	}
	conn.step = .Secure
	return
}

irc_connect :: proc(conn: ^IRC_Connection, username: string, password := "") -> (err: IRC_Error) {
	assert(conn.step != .Online, "Tried to connect while already connected")
	assert(conn.step == .Secure, "Tried to connect while not on in a secure context")

	if len(password) > 0 do irc_command(conn, .PASS, password) or_return
	irc_command(conn, .NICK, username) or_return
	irc_command(conn, .USER, username, 0, username) or_return
	conn.step = .Online
	return
}

irc_disconnect :: proc(conn: ^IRC_Connection) -> (err: IRC_Error) {
	assert(conn.step == .Online, "Tried to disconnect while already disconnected")

	irc_command(conn, .QUIT) or_return
	conn.step = .Secure
	return
}

irc_cleanup :: proc(conn: ^IRC_Connection) {
	switch conn.step {
	case .Online:
		irc_disconnect(conn)
		fallthrough
	case .Secure:
		if conn.ssl_inst != nil {
			for {
				ret := openssl.SSL_shutdown(conn.ssl_inst)
				if ret >= 0 do break
				err := irc_retry(conn, ret)
				if err != nil do panic("Could not terminate secure connection in a clean manner")
			}
			openssl.SSL_free(conn.ssl_inst)
		}
		if conn.ssl_ctx != nil do openssl.SSL_CTX_free(conn.ssl_ctx)
		fallthrough
	case .Insecure:
		net.close(conn.socket)
		fallthrough
	case .Offline:
	}
	conn^ = IRC_Connection{}
}

irc_send :: proc(conn: ^IRC_Connection, msg: string) -> (err: IRC_Error) {
	assert(conn.step == .Secure || conn.step == .Online, "Tried to send message while not connected")

	for {
		written: c.size_t
		ret := openssl.SSL_write_ex(conn.ssl_inst, raw_data(msg), cast(c.size_t)len(msg), &written)
		if ret > 0 do break
		irc_retry(conn, ret) or_return
	}
	return
}

irc_recv :: proc(conn: ^IRC_Connection, sb: ^strings.Builder) -> (read_n: uint, err: IRC_Error) {
	n: c.size_t
	buff: [mem.Kilobyte]u8
	for {
		ret := openssl.SSL_read_ex(conn.ssl_inst, raw_data(buff[:]), mem.Kilobyte, &n)
		if ret == 1 {
			read_n += n
			strings.write_bytes(sb, buff[:n])
			continue
		}
		err := irc_retry(conn, 0)
		if err == nil || err == .Want_X509_Lookup do break
		else do return n, err
	}
	return n, nil
}

irc_command :: proc(conn: ^IRC_Connection, cmd: IRC_Command_Kind, args: ..any) -> (err: IRC_Error) {
	irc_fmt: string
	#partial switch cmd {
	case .PONG:
		assert(len(args) == 1, "PONG takes one argument")
		server  := args[0].(string)
		irc_fmt  = fmt.tprintf("PONG %s\r\n", server)
		irc_send(conn, irc_fmt) or_return
	case .PASS:
		assert(len(args) == 1, "PASS takes one argument")
		password := args[0].(string)
		irc_fmt   = fmt.tprintf("PASS %s\r\n", password)
		irc_send(conn, irc_fmt) or_return
	case .NICK:
		assert(len(args) == 1, "NICK takes one argument")
		nick    := args[0].(string)
		irc_fmt  = fmt.tprintf("NICK %s\r\n", nick)
		irc_send(conn, irc_fmt) or_return
	case .USER: /* TODO(XENOBAS): Allow for multiple arguments */
		assert(len(args) == 3, "USER takes three arguments")
		username := args[0].(string)
		mode	 := args[1].(int)
		realname := args[2].(string)
		irc_fmt   = fmt.tprintf("USER %s palermo.hackint.org * :%s\r\n", username/*, mode*/, realname)
		irc_send(conn, irc_fmt) or_return
	case .QUIT:
		assert(len(args) == 0, "QUIT takes no arguments")
		irc_fmt = fmt.tprintf("QUIT\r\n")
		irc_send(conn, irc_fmt) or_return
	case:
		unreachable()
	}
	return
}

Response :: union {
	Response_Text,
	Response_Debug,
}

Response_Debug :: struct {
	level: log.Level,
	message: string,
}
Response_Text :: distinct string

irc_routine :: proc(chan_req: chan.Chan(string, .Recv), chan_res: chan.Chan(Response, .Send)) {
	when TRACK_ALLOC {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer {
			for _, leak in track.allocation_map do fmt.printfln("%v leaked %m", leak.location, leak.size)
			mem.tracking_allocator_destroy(&track)
		}
		context.allocator = mem.tracking_allocator(&track)
	}
	defer runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)

	// TODO(XENOBAS): Accept destination of connection
	chan.send(chan_res, Response_Debug{ .Debug, fmt.tprintf("Begin initialisation") })

	// ircs://irc.hackint.org:6697/odin
	// ircs IRC Secure, 65.108.220.207 ip, 6697 port, odin channel
	conn, err := irc_dial(net.IP4_Address{ 65, 108, 220, 207 }, 6697)
	if err != nil {
		// NOTE(XENOBAS):
		// This is definitely a footgun of pointers
		// I don't know if this string works across thread memory boundaries or not.
		chan.send(chan_res, Response_Debug{
			level = .Fatal,
			message = fmt.tprintf("Failed during dial because of: %v", err),
		})
		return
	}
	defer irc_cleanup(&conn)
	chan.send(chan_res, Response_Debug{ .Debug, fmt.tprintf("Dialed remote host successfully") })

	err = irc_connect(&conn, "XENOBAS")
	if err != nil {
		chan.send(chan_res, Response_Debug{ .Fatal, fmt.tprintf("Failed during user connection: %v", err) })
		return
	}
	chan.send(chan_res, Response_Debug{ .Info, fmt.tprintf("Connected successfully") })

	read_rem: string
	loop: for {
		if chan.is_closed(chan_req) do break
		if conn.step == .Online {
			// Read data waiting in socket
			sb := strings.builder_make()
			defer strings.builder_destroy(&sb)

			if len(read_rem) > 0 {
				strings.write_string(&sb, read_rem)
				read_rem = ""
			}
			if n, err := irc_recv(&conn, &sb); err != nil {
				chan.send(chan_res, Response_Debug{ .Error, fmt.tprintf("Could not receive bytes from remote host because of %v", err) })
				break loop
			} else if n == 0 do continue

			response := strings.to_string(sb)
			for line in strings.split_after_iterator(&response, "\r\n") {
				cmd, ok := parse(line)
				if ok do switch cmd.name {
				case "PING":
					resp: Response_Debug
					if cmd.params_count != 1 {
						resp.level = .Fatal
						resp.message = fmt.tprintf("Unimplemented params passed to PING %v", cmd.params[:cmd.params_count])

						chan.send(chan_res, resp)
						break loop
					}

					if err := irc_command(&conn, .PONG, cmd.params[0]); err != nil {
						resp.level = .Error
						resp.message = fmt.tprintf("PONG to %s has failed: %v", cmd.params[0], err)

						chan.send(chan_res, resp)
					}
				case "NOTICE", "PRIVMSG":
					if cmd.params_count != 2 {
						resp: Response_Debug
						resp.level = .Error
						resp.message = fmt.tprintf("Unexpected number of arguments passed to %s %v", cmd.name, cmd.params[:cmd.params_count])

						chan.send(chan_res, resp)
					}

					resp := cast(Response_Text)strings.clone(cmd.params[1], context.temp_allocator)
					chan.send(chan_res, resp)
				case:
					log.warnf("Unimplemented response %q", line)
				} else {
					log.errorf("Could not parse server message %q", line)
					chan.send(chan_res, Response_Debug{ .Error, fmt.tprintf("Checkout logs for parsing error") })
				}
				// if cmd.name == "NOTICE" || cmd.name == "372" || cmd.name == "376" || cmd.name == "353" { // MOTD, END OF MOTD, NAMRPLY ?
				// 	if cmd.params_count != 2 do chan.send(chan_res, Response_Debug{ .Error, fmt.tprintf("%s with invalid params: %v", cmd.name, cmd.params[:cmd.params_count]) })
				// 	else do chan.send(chan_res, cast(Response_Text)fmt.tprintf(cmd.params[1]))
				// } else {
				// 	chan.send(chan_res, Response_Debug{ .Warning, fmt.tprintf("Unrecognized: %q", line) })
				// }
			}
			if len(response) > 0 do read_rem = strings.clone(response, context.temp_allocator)

			// Write data into socket
			for msg in chan.try_recv(chan_req) {
				err := irc_send(&conn, msg)
				if err == nil do continue
				chan.send(chan_res, Response_Debug{ .Error, fmt.tprintf("Socket write of %q failed because of %v", msg, err) })
				if err == .Zero_Return do break loop
			}
		}
	}
	chan.send(chan_res, Response_Debug{ .Debug, fmt.tprintf("End of thread") })
}

package ssl

import "core:c"
foreign import openssl {
	"system:ssl",
	"system:libssl.so.3"
}

SSL :: distinct rawptr
SSL_CTX :: distinct rawptr
SSL_METHOD :: distinct rawptr

SSL_Shutdown_Mode :: enum c.int {
	SENT_SHUTDOWN = 1,
	RECEIVED_SHUTDOWN = 2,
}

SSL_Shutdown_Default :: bit_set[SSL_Shutdown_Mode]{ .SENT_SHUTDOWN, .RECEIVED_SHUTDOWN }

SSL_Error :: enum c.int {
	None,
	Zero_Return,
	Want_Read,
	Want_Write,
	Want_Connect,
	Want_Accept,
	Want_X509_Lookup,
	Want_Async,
	Want_Async_Job,
	Want_Client_Hello_CB,
	Syscall,
	Ssl,
}

foreign openssl {
	TLS_client_method	:: proc() -> SSL_METHOD ---

	SSL_CTX_new			:: proc(method: SSL_METHOD) -> SSL_CTX ---
	SSL_CTX_free		:: proc(ctx: SSL_CTX) ---

	SSL_new				:: proc(ctx: SSL_CTX) -> SSL ---
	SSL_free			:: proc(ssl: SSL) ---
	SSL_read			:: proc(ssl: SSL, buf: rawptr, num: c.int) -> c.int ---
	SSL_read_ex			:: proc(ssl: SSL, buf: rawptr, num: c.size_t, readbytes: ^c.size_t) -> c.int ---
	SSL_write			:: proc(ssl: SSL, buf: rawptr, num: c.int) -> c.int ---
	SSL_write_ex		:: proc(ssl: SSL, buf: rawptr, num: c.size_t, written: ^c.size_t) -> c.int ---
	SSL_set_fd			:: proc(ssl: SSL, socket: c.int) -> c.int ---
	SSL_connect			:: proc(ssl: SSL) -> c.int ---
	SSL_shutdown		:: proc(ssl: SSL) -> c.int ---
	SSL_set_shutdown	:: proc(ssl: SSL, mode: bit_set[SSL_Shutdown_Mode]) ---

	SSL_get_error		:: proc(ssl: SSL, ret: c.int) -> SSL_Error ---
}

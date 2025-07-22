package ui

import "core:c"
import "core:os"
import "core:fmt"
import "core:mem"
import "core:time"
import "../termcl"
import "core:strings"
import "core:sys/posix"
import "core:terminal/ansi"

Terminal_Encoding :: enum {
	Legacy = 0,
	XTerm,
	Kitty,
}

Terminal :: struct {
	builder: strings.Builder,
	dimensions: [2]int,
	state: Terminal_State,
	timeout: int,

	encoding: Terminal_Encoding,
	decoders: [Terminal_Encoding]Terminal_Decoder,

	last_n: int,
	last_char: rune,

	debug_len: int,
	debug_buff: [512]u8,
}

Terminal_Decoder :: #type proc(terminal: ^Terminal, buff: []u8)

Terminal_State :: posix.termios

Terminal_Clear_Command :: enum {
	All,
	Rest_Line,
}

_terminal_query_state :: proc() -> (state: Terminal_State, ok: bool) {
	ok = posix.tcgetattr(posix.STDIN_FILENO, &state) == .OK
	return state, ok
}

_terminal_enter :: proc(terminal: ^Terminal) {
	// TODO(XENOBAS): Support more modes.
	KITTY_QUERY     :: "?u"
	XTERM_QUERY     :: "c"
	ALTERNATE_ENTER :: "?1049h"

	state, ok := _terminal_query_state()
	assert(ok, "could not query terminal state for setting its mode")
	terminal.state = state

	state.c_lflag -= { .ECHO, .ICANON } // C_Break mode
	retval := posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &state)
	assert(retval == .OK, "could not set terminal state")
	os.flush(os.stdin)

	os.write(os.stdout, transmute([]u8)string(ansi.CSI + ALTERNATE_ENTER + ansi.CSI + KITTY_QUERY + ansi.CSI + XTERM_QUERY))
	os.flush(os.stdout)
}

_terminal_leave :: proc(terminal: ^Terminal) {
	state := terminal.state

	retval := posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &state)
	assert(retval == .OK, "could not restore terminal state")
	os.flush(os.stdin)

	KITTY_LEAVE     :: "<u"
	XTERM_LEAVE     :: ">4;0m"
	ALTERNATE_LEAVE :: "?1049l"
	switch terminal.encoding {
	case .Kitty:
		os.write(os.stdout, transmute([]u8)string(ansi.CSI + KITTY_LEAVE))
	case .XTerm:
		os.write(os.stdout, transmute([]u8)string(ansi.CSI + XTERM_LEAVE))
	case .Legacy:
	}
	os.write(os.stdout, transmute([]u8)string(ansi.CSI + ALTERNATE_LEAVE))
	os.flush(os.stdout)
}

@(private)
Reader :: struct {
	buff: []u8,
	index: int,
}

@(private)
read_letter :: proc(r: ^Reader, t: ^Terminal) -> (c: u8, ok: bool) {
	if r.index >= len(r.buff) do return 0, false
	c = r.buff[r.index]
	t.debug_buff[t.debug_len] = c
	t.debug_len += 1
	r.index += 1
	return c, true
}

_terminal_decode_legacy :: proc(terminal: ^Terminal, buff: []u8) {
	reader := Reader{ buff, 0 }
	for {
		c := read_letter(&reader, terminal) or_break
		if c == '\e' {
			c = read_letter(&reader, terminal) or_break
			if c != '[' do continue
			c = read_letter(&reader, terminal) or_break
			if c != '?' do continue
			c = read_letter(&reader, terminal) or_break
			if c < '0' || c > '9' do continue
			c = read_letter(&reader, terminal) or_break
			if c == 'u' && terminal.encoding == .Legacy {
				terminal.encoding = .Kitty

				KITTY_ENTER     : string : ">3u"
				os.write(os.stdout, transmute([]u8)(ansi.CSI + KITTY_ENTER))
				os.flush(os.stdout)
				break
			}
			if c != ';' do continue
			c = read_letter(&reader, terminal) or_break
			if c < '0' || c > '9' do continue
			c = read_letter(&reader, terminal) or_break
			if c == 'c' && terminal.encoding == .Legacy {
				terminal.encoding = .XTerm

				XTERM_ENTER     : string : ">4;2m"
				os.write(os.stdout, transmute([]u8)(ansi.CSI + XTERM_ENTER))
				os.flush(os.stdout)
				break
			}
		}
	}
}

_terminal_decode_kitty :: proc(terminal: ^Terminal, buff: []u8) {
	reader := Reader{ buff, 0 }
	for {
		read_letter(&reader, terminal) or_break
	}
}

_terminal_decode_xterm :: proc(terminal: ^Terminal, buff: []u8) {
	reader := Reader{ buff, 0 }
	for {
		read_letter(&reader, terminal) or_break
	}
}

terminal_make :: proc() -> (terminal: ^Terminal) {
	terminal = new(Terminal)
	terminal.builder = strings.builder_make()
	terminal.timeout = 10
	terminal.decoders[.Kitty] = _terminal_decode_kitty
	terminal.decoders[.XTerm] = _terminal_decode_xterm
	terminal.decoders[.Legacy] = _terminal_decode_legacy
	_terminal_enter(terminal)
	return
}

terminal_destroy :: proc(terminal: ^Terminal) {
	_terminal_leave(terminal)
	strings.builder_destroy(&terminal.builder)
	free(terminal)
}

terminal_clear :: proc(terminal: ^Terminal, mode: Terminal_Clear_Command) {
	assert(terminal != nil)

	switch mode {
	case .All:
		terminal_write(terminal, ansi.CSI + "H" + ansi.CSI + "2J")
	case .Rest_Line:
		terminal_write(terminal, ansi.CSI + ansi.EL)
	}
}

terminal_blit :: proc(terminal: ^Terminal) {
	text := strings.to_string(terminal.builder)
	os.write(os.stdout, transmute([]u8)text)
	os.flush(os.stdout)
	strings.builder_reset(&terminal.builder)
}

terminal_tick :: proc(terminal: ^Terminal) {
	size, ok := termcl.get_term_size_via_syscall()
	if ok do terminal.dimensions = { cast(int)size.w, cast(int)size.h }

	fd := posix.pollfd { fd = posix.STDIN_FILENO, events = { .IN } }
	if posix.poll(&fd, 1, cast(c.int)terminal.timeout) > 0 {
		buff: [mem.Kilobyte]byte
		n, err := os.read(os.stdin, buff[:])
		assert(err == nil, "read syscall has failed while querying input")

		terminal.last_n = cast(int)n
		terminal.decoders[terminal.encoding](terminal, buff[:n])
	}
}

terminal_write_string :: #force_inline proc(terminal: ^Terminal, s: string) {
	strings.write_string(&terminal.builder, s)
}

terminal_write_rune :: #force_inline proc(terminal: ^Terminal, r: rune) {
	strings.write_rune(&terminal.builder, r)
}

terminal_write :: proc {
	terminal_write_string,
	terminal_write_rune,
}

terminal_reset_style :: proc(terminal: ^Terminal) {
	terminal_write(terminal, ansi.CSI + ansi.RESET + ansi.SGR)
}

terminal_set_color_rgb :: proc(terminal: ^Terminal, r: u8, g: u8, b: u8, is_background := false) {
	code := fmt.tprintf(ansi.CSI + "%s;2;%d;%d;%dm", "48" if is_background else "38", r, g, b)
	terminal_write(terminal, code)
}

terminal_set_cursor_pos :: proc(terminal: ^Terminal, newpos: [2]int) {
	assert(newpos.x > 0, "invalid x coordinate")
	assert(newpos.y > 0, "invalid y coordinate")

	code := fmt.tprintf(ansi.CSI + "%d;%dH", newpos.y, newpos.x)
	terminal_write(terminal, code)
}

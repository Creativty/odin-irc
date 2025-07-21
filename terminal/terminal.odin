package ui

import "core:os"
import "core:fmt"
import "core:mem"
import "core:time"
import "../termcl"
import "core:strings"
import "core:sys/posix"
import "core:terminal/ansi"

Terminal :: struct {
	builder: strings.Builder,
	dimensions: [2]int,
	state: Terminal_State,
	timeout: int,
}

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
	ALTERNATE_ENTER :: "?1049h"

	state, ok := _terminal_query_state()
	assert(ok, "could not query terminal state for setting its mode")
	terminal.state = state

	state.c_lflag -= { .ECHO, .ICANON } // C_Break mode
	retval := posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &state)
	assert(retval == .OK, "could not set terminal state")
	os.flush(os.stdin)

	os.write(os.stdout, transmute([]u8)string(ansi.CSI + ALTERNATE_ENTER))
	os.flush(os.stdout)
}

_terminal_leave :: proc(terminal: ^Terminal) {
	ALTERNATE_LEAVE :: "?1049l"

	state := terminal.state

	retval := posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &state)
	assert(retval == .OK, "could not restore terminal state")
	os.flush(os.stdin)

	os.write(os.stdout, transmute([]u8)string(ansi.CSI + ALTERNATE_LEAVE))
	os.flush(os.stdout)
}

terminal_make :: proc() -> (terminal: ^Terminal) {
	terminal = new(Terminal)
	terminal.builder = strings.builder_make()
	terminal.timeout = 10
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
	if posix.poll(&fd, 1, 8) > 0 {
		buff: [mem.Kilobyte]byte
		n, err := os.read_ptr(os.stdin, raw_data(buff[:]), mem.Kilobyte)
		assert(err == nil, "read syscall has failed while querying input")
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

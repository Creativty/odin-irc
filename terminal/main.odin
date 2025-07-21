package ui

import "core:os"
import "core:fmt"
import "core:mem"
import "core:time"
import "../termcl"
import "core:strings"
import "core:sys/posix"
import "core:terminal/ansi"

draw_tabs :: proc(terminal: ^Terminal, tabs: []string) {
	fg, bg: termcl.RGB_Color
	cursor: int
	show_more: bool

	terminal_set_cursor_pos(terminal, { 1, 1 })
	for tab, index in tabs {
		if cursor + len(tab) + 1 + 2 > terminal.dimensions.x {
			show_more = true
			break
		}

		fg, bg = { 0xc1, 0xc1, 0xc1 }, { 0x24, 0x24, 0x24 }
		if index == 3 {
			fg = { 0xfc, 0xdb, 0x33 }
			bg = { 0x12, 0x12, 0x12 }
		}

		terminal_set_color_rgb(terminal, bg.r, bg.g, bg.b, is_background = true)
		terminal_set_color_rgb(terminal, fg.r, fg.g, fg.b, is_background = false)
		terminal_write(terminal, tab)
		terminal_write(terminal, ' ')

		cursor += len(tab) + 1
	}
	terminal_set_color_rgb(terminal, 0x24, 0x24, 0x24)
	terminal_clear(terminal, .Rest_Line)

	if show_more {
		terminal_set_cursor_pos(terminal, { terminal.dimensions.x, 1 })
		terminal_set_color_rgb(terminal, 0xc1, 0xc1, 0xc1, is_background = false)
		terminal_set_color_rgb(terminal, 0x24, 0x24, 0x24, is_background = true)
		terminal_write(terminal, ansi.CSI + ansi.BOLD + ansi.SGR)
		terminal_write(terminal, '…')
	}
	terminal_reset_style(terminal)
}

/* TODO(XENOBAS): A propos keyboard handling
 * We'll have to do protocol negotiation at terminal instance start
 * and try to accomodate depending on the available protocol (Kitty, Legacy)
 * The major issue is... Eventually we will want to support XTerm.
 */

main :: proc() {
	terminal := terminal_make()
	defer terminal_destroy(terminal)
	terminal_reset_style(terminal)

	terminal_tick(terminal)
	terminal_clear(terminal, .All)
	draw_tabs(terminal, []string{ "#hackint", "@XENOBAS", "#odin", "#hackint", "@XENOBAS", "#odin", "#hackint", "@XENOBAS", "#odin", "#hackint", "@XENOBAS", "#odin", "#hackint", "@XENOBAS", "#odin", "#hackint", "@XENOBAS", "#odin",  "#hackint", "@XENOBAS", "#odin", "#hackint", "@XENOBAS", "#odin", "#hackint", "@XENOBAS", "#odin", "#hackint", "@XENOBAS", "#odin", "#hackint", "@XENOBAS", "#odin", "#hackint", "@XENOBAS", "#odin"})
	terminal_set_cursor_pos(terminal, { 1, 2 })

	terminal_blit(terminal)

	time.sleep(time.Second * 3)
}

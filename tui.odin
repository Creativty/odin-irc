package main

import "core:fmt"
import "core:mem"
import "core:time"
import "core:strings"
import termcl "termcl"
import "core:sync/chan"
import "core:math/rand"
import "core:unicode/utf8"
import "core:terminal/ansi"

PADDING :: 8
@(thread_local) ui_size: termcl.Screen_Size

ui_measure_text :: proc(text: string) -> (width: int, lines: int) {
	width = cast(int)ui_size.w - PADDING * 2
	if width <= 0 do return 0, 0

	length := len(text)
	width = min(length, width)
	for length > 0 {
		lines += 1
		length -= width
	}
	return width, lines
}

ui_draw_text :: proc(screen: ^termcl.Screen, text: string, wrap := false) {
	width := cast(int)ui_size.w - PADDING * 2
	if width <= 0 do return

	// TODO(XENOBAS): Support graphemes width
	text := text[:min(len(text), width)]
	termcl.write(screen, text)
}

ui_draw :: proc(screen: ^termcl.Screen, tf: ^Text_Field, responses: []Response) {
	termcl.clear(screen, .Everything)
	defer termcl.blit(screen)

	{
		offset := cast(int)ui_size.h - 4
		#reverse for response in responses {
			defer termcl.reset_styles(screen)

			text:   string
			switch v in response {
			case Response_Debug:
				text = v.message
				switch v.level {
				case .Debug:
					termcl.set_color_style_rgb(screen, termcl.RGB_Color{ 48, 48, 48 }, nil)
				case .Info:
					termcl.set_color_style_rgb(screen, termcl.RGB_Color{ 9, 136, 239 }, nil)
				case .Warning:
					termcl.set_color_style_rgb(screen, termcl.RGB_Color{ 239, 178, 9 }, nil)
				case .Error:
					termcl.set_color_style_rgb(screen, termcl.RGB_Color{ 239, 9, 28 }, nil)
				case .Fatal:
					termcl.set_color_style_rgb(screen, termcl.RGB_Color{ 239, 28, 9 }, nil)
				}
			case Response_Text:
				text = cast(string)v
			}

			width, lines := ui_measure_text(text)
			for line in 0..<lines {
				termcl.move_cursor(screen, cast(uint)offset, PADDING)
				ui_draw_text(screen, text[(lines - line - 1) * width:])
				offset -= 1
				if offset <= 0 do break
			}
			// termcl.move_cursor(screen, cast(uint)offset + 1, 0)
			// termcl.write(screen, prefix)
			if offset <= 0 do break
		}
	}
	{
		status := " OFFLINE "
		termcl.move_cursor(screen, ui_size.h - 3, 0)
		termcl.write(screen, status)
		for i in 0..<(ui_size.w - len(status) - 1) do termcl.write(screen, '─')

		termcl.move_cursor(screen, ui_size.h - 2, len(status) + 1)
		termcl.write(screen, "> ")

		text := text_field_to_string(tf)
		if len(text) > 0 {
			termcl.write(screen, text)
			cursor := termcl.get_cursor_position(screen)
			termcl.move_cursor(screen, cursor.y, max(cursor.x, 1) - 1)
		}
	}
}

ui_routine :: proc(chan_req: chan.Chan(string, .Send), chan_res: chan.Chan(Response, .Recv)) {
	when false {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer {
			for _, leak in track.allocation_map do fmt.printfln("%v leaked %m", leak.location, leak.size)
			mem.tracking_allocator_destroy(&track)
		}
		context.allocator = mem.tracking_allocator(&track)
	}

	screen := termcl.init_screen()
	defer termcl.destroy_screen(&screen)
	termcl.set_term_mode(&screen, .Cbreak)

	termcl.hide_cursor(false)
	fmt.print(ansi.CSI + "6 q")
	defer fmt.print(ansi.CSI + "1 q")

	tf, texts := text_field_make(), make([dynamic]string)
	responses := make([dynamic]Response)
	defer {
		for text in texts do delete(text)
		delete(texts)
		delete(responses)
		text_field_delete(&tf)
	}

	scroll: int
	ui_size = termcl.get_term_size(&screen)
	ui_draw(&screen, &tf, responses[:])
	loop: for {
		redraw := false
		ui_size_query := termcl.get_term_size(&screen)
		if ui_size != ui_size_query {
			ui_size = ui_size_query
			redraw = true
		}

		if response, ok := chan.try_recv(chan_res); ok {
			append(&responses, response)
			switch v in response {
			case Response_Debug:
				append(&texts, fmt.aprintf("[IRC:%v]: %s", v.level, v.message))
			case Response_Text:
				append(&texts, strings.clone(cast(string)v))
			}
			redraw = true
		}

		input, has_input := termcl.read(&screen)
		if has_input do redraw = true
		kb_input, has_kb_input := termcl.parse_keyboard_input(input)
		if has_kb_input {
			#partial switch kb_input.key {
			case .Enter:
				text := text_field_to_string(&tf)
				if strings.trim_space(text) == "" do continue
				if strings.starts_with(text, "/") {
					switch text[1:] {
					case "markov":
						sentences := [?]string{ "I love eating toasted cheese and tuna sandwiches.", "He had a hidden stash underneath the floorboards in the back room of the house.", "Gary didn't understand why Doug went upstairs to get one dollar bills when he invited him to go cow tipping.", "There's no reason a hula hoop can't also be a circus ring.", "Of course, she loves her pink bunny slippers.", "The clock within this blog and the clock on my laptop are 1 hour different from each other.", "They throw cabbage that turns your brain into emotional baggage.", "She found it strange that people use their cellphones to actually talk to one another.", "As time wore on, simple dog commands turned into full paragraphs explaining why the dog couldn’t do something.", "Weather is not trivial - it's especially important when you're standing in it.", "He hated that he loved what she hated about hate.", "The light in his life was actually a fire burning all around him.", "Various sea birds are elegant, but nothing is as elegant as a gliding pelican.", "She insisted that cleaning out your closet was the key to good driving.", "Their argument could be heard across the parking lot.", "While all her friends were positive that Mary had a sixth sense, she knew she actually had a seventh sense."}
						rand.shuffle(sentences[:])
						length := rand.int_max(5) + 1
						append(&texts, strings.join(sentences[:length], " "))
					case "exit":
						chan.close(chan_req)
						break loop
					case:
						chan.send(chan_req, strings.concatenate({ text[1:], "\r\n" }))
					}
				} else do append(&texts, strings.clone(text))
				text_field_clear(&tf)
			case .Arrow_Up:
				if scroll < len(responses) do scroll += 1
			case .Arrow_Down:
				if scroll > 0 do scroll -= 1
			case .Escape: /* TODO(XENOBAS): This is slow on Escape quit for some reason */
				break loop
			case .Backspace:
				text_field_remove(&tf)
			case .Space:
				text_field_write_rune(&tf, ' ')
			case .Dollar:
				text_field_write_rune(&tf, '$')
			case .Hash:
				text_field_write_rune(&tf, '#')
			case .Underscore:
				text_field_write_rune(&tf, '_')
			case .Tilde:
				text_field_write_rune(&tf, '~')
			case .Caret:
				text_field_write_rune(&tf, '^')
			case .Greater_Than:
				text_field_write_rune(&tf, '>')
			case .Less_Than:
				text_field_write_rune(&tf, '<')
			case .Question_Mark:
				text_field_write_rune(&tf, '?')
			case .Ampersand:
				text_field_write_rune(&tf, '&')
			case .Percent:
				text_field_write_rune(&tf, '%')
			case .Comma:
				text_field_write_rune(&tf, ',')
			case .Exclamation:
				text_field_write_rune(&tf, '!')
			case .Pipe:
				text_field_write_rune(&tf, '|')
			case .At:
				text_field_write_rune(&tf, '@')
			case .Asterisk:
				text_field_write_rune(&tf, '*')
			case .Single_Quote:
				text_field_write_rune(&tf, '\'')
			case .Double_Quote:
				text_field_write_rune(&tf, '"')
			case .Backtick:
				text_field_write_rune(&tf, '`')
			case .Semicolon:
				text_field_write_rune(&tf, ';')
			case .Colon:
				text_field_write_rune(&tf, ':')
			case .Slash:
				text_field_write_rune(&tf, '/')
			case .Backslash:
				text_field_write_rune(&tf, '\\')
			case .Minus:
				text_field_write_rune(&tf, '-')
			case .Plus:
				text_field_write_rune(&tf, '+')
			case .Equal:
				text_field_write_rune(&tf, '=')
			case .Open_Paren:
				text_field_write_rune(&tf, '(')
			case .Close_Paren:
				text_field_write_rune(&tf, ')')
			case .Open_Curly_Bracket:
				text_field_write_rune(&tf, '{')
			case .Close_Curly_Bracket:
				text_field_write_rune(&tf, '}')
			case .Open_Square_Bracket:
				text_field_write_rune(&tf, '[')
			case .Close_Square_Bracket:
				text_field_write_rune(&tf, ']')
			case .Period:
				text_field_write_rune(&tf, '.')
			case .Num_0:
				text_field_write_rune(&tf, '0')
			case .Num_1:
				text_field_write_rune(&tf, '1')
			case .Num_2:
				text_field_write_rune(&tf, '2')
			case .Num_3:
				text_field_write_rune(&tf, '3')
			case .Num_4:
				text_field_write_rune(&tf, '4')
			case .Num_5:
				text_field_write_rune(&tf, '5')
			case .Num_6:
				text_field_write_rune(&tf, '6')
			case .Num_7:
				text_field_write_rune(&tf, '7')
			case .Num_8:
				text_field_write_rune(&tf, '8')
			case .Num_9:
				text_field_write_rune(&tf, '9')
			case .A:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'A')
				else do text_field_write_rune(&tf, 'a')
			case .B:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'B')
				else do text_field_write_rune(&tf, 'b')
			case .C:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'C')
				else do text_field_write_rune(&tf, 'c')
			case .D:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'D')
				else do text_field_write_rune(&tf, 'd')
			case .E:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'E')
				else do text_field_write_rune(&tf, 'e')
			case .F:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'F')
				else do text_field_write_rune(&tf, 'f')
			case .G:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'G')
				else do text_field_write_rune(&tf, 'g')
			case .H:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'H')
				else do text_field_write_rune(&tf, 'h')
			case .I:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'I')
				else do text_field_write_rune(&tf, 'i')
			case .J:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'J')
				else do text_field_write_rune(&tf, 'j')
			case .K:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'K')
				else do text_field_write_rune(&tf, 'k')
			case .L:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'L')
				else do text_field_write_rune(&tf, 'l')
			case .M:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'M')
				else do text_field_write_rune(&tf, 'm')
			case .N:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'N')
				else do text_field_write_rune(&tf, 'n')
			case .O:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'O')
				else do text_field_write_rune(&tf, 'o')
			case .P:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'P')
				else do text_field_write_rune(&tf, 'p')
			case .Q:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'Q')
				else do text_field_write_rune(&tf, 'q')
			case .R:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'R')
				else do text_field_write_rune(&tf, 'r')
			case .S:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'S')
				else do text_field_write_rune(&tf, 's')
			case .T:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'T')
				else do text_field_write_rune(&tf, 't')
			case .U:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'U')
				else do text_field_write_rune(&tf, 'u')
			case .V:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'V')
				else do text_field_write_rune(&tf, 'v')
			case .W:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'W')
				else do text_field_write_rune(&tf, 'w')
			case .X:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'X')
				else do text_field_write_rune(&tf, 'x')
			case .Y:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'Y')
				else do text_field_write_rune(&tf, 'y')
			case .Z:
				if kb_input.mod == .Shift do text_field_write_rune(&tf, 'Z')
				else do text_field_write_rune(&tf, 'z')
			}
		}

		if redraw do ui_draw(&screen, &tf, responses[:len(responses)-scroll])
	}
}

/* Text Field */
Text_Field :: struct {
	builder: strings.Builder,
	offset: int,
}

text_field_make :: proc() -> (tf: Text_Field) {
	strings.builder_init(&tf.builder)
	return
}

text_field_write_byte :: proc(tf: ^Text_Field, char: u8) {
	if ok, _ := inject_at(&tf.builder.buf, tf.offset, char); ok {
		tf.offset += 1
	}
}

text_field_write_string :: proc(tf: ^Text_Field, str: string) {
	for i in 0..<len(str) {
		_ = inject_at(&tf.builder.buf, tf.offset, str[i]) or_break
		tf.offset += 1
	}
}

text_field_write_rune :: proc(tf: ^Text_Field, r: rune) {
	bytes, len := utf8.encode_rune(r)
	text_field_write_string(tf, transmute(string)bytes[:len])
}

text_field_to_string :: proc(tf: ^Text_Field) -> (text: string) {
	return (strings.to_string(tf.builder))
}

text_field_remove :: proc(tf: ^Text_Field) {
	if tf.offset <= 0 do return
	remove_range(&tf.builder.buf, tf.offset - 1, tf.offset)
	tf.offset -= 1
}

text_field_clear :: proc(tf: ^Text_Field) {
	tf.offset = 0
	strings.builder_reset(&tf.builder)
}

text_field_delete :: proc(tf: ^Text_Field) {
	strings.builder_destroy(&tf.builder)
	tf.offset = 0
	tf^ = { }
}

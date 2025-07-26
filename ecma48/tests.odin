package ecma48

import "core:testing"

@(test)
invalid :: proc(t: ^testing.T) {
	{
		seq, ok := scan("")
		testing.expect_value(t, ok, false)
	}
	{
		seq, ok := scan("\e")
		testing.expect_value(t, ok, false)
	}
	{
		seq, ok := scan("\e[")
		testing.expect_value(t, ok, false)
	}
	{
		seq, ok := scan("\e[1;31+m")
		testing.expect_value(t, ok, false)
	}
}

@(test)
basic :: proc(t: ^testing.T) {
	{
		seq, ok := scan("\e[j")
		testing.expect_value(t, ok, true)
		testing.expect_value(t, seq.params_n, 0)
		testing.expect_value(t, seq.text, "\e[j")
		testing.expect_value(t, seq.id, 'j')
	}
	{
		seq, ok := scan("\e[1;31m")
		testing.expect_value(t, ok, true)

		id := cast(rune)seq.id
		testing.expect_value(t, id, 'm')
		testing.expect_value(t, seq.params_n, 2)
		testing.expect_value(t, seq.params[0], "1")
		testing.expect_value(t, seq.params[1], "31")
		testing.expect_value(t, seq.text, "\e[1;31m")
	}
	{
		seq, ok := scan("\e[1;31+128;;m")
		testing.expect_value(t, ok, true)
		testing.expect_value(t, seq.params_n, 4)
		testing.expect_value(t, seq.params[0], "1")
		testing.expect_value(t, seq.params[1], "31")
		testing.expect_value(t, seq.params[2], "128")
		testing.expect_value(t, seq.params[3], "")
	}
	{
		seq, ok := scan("\e[?u")
		testing.expect_value(t, ok, true)
		id := cast(rune)seq.id
		initial := cast(rune)seq.initial
		testing.expect_value(t, initial, '?')
		testing.expect_value(t, id, 'u')
	}
	{
		seq, ok := scan("\e[?uHello world")
		testing.expect_value(t, ok, true)
		testing.expect_value(t, seq.text, "\e[?u")
	}
}

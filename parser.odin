package main

import "core:log"
import "core:testing"
import "core:strings"

import "core:fmt"
import "core:strconv"

Reader :: struct {
	index: int,
	source: string,
	capture: string,
}

read_letter :: proc(r: ^Reader, letter: byte) -> bool {
	if len(r.source[r.index:]) > 0 && r.source[r.index] == letter {
		r.index += 1
		return true
	}
	return false
}

read_number :: proc(r: ^Reader) -> bool {
	count: int
	capture: for count < len(r.source[r.index:]) {
		switch r.source[r.index:][count] {
		case '0'..='9':
		case:
			break capture
		}
		count += 1
	}
	if count > 0 {
		r.capture  = r.source[r.index:][:count]
		r.index   += count
	}
	return count > 0
}

read_shortname :: proc(r: ^Reader) -> bool {
	count := 0
	capture: for count < len(r.source[r.index:]) {
		switch r.source[r.index + count] {
		case 'a'..='z', 'A'..='Z', '0'..='9':
			count += 1
		case:
			break capture
		}
	}
	if count > 0 {
		r.capture  = r.source[r.index:][:count]
		r.index   += count
	}
	return count > 0
}

read_hostname :: proc(r: ^Reader) -> bool {
	count: int
	index := r.index

	read_shortname(r) or_return
	count += len(r.capture)
	for read_letter(r, '.') {
		if !read_shortname(r) {
			r.index = index
			return false
		}
		count += len(r.capture) + 1
	}
	r.capture = r.source[index:][:count]
	return true
}

read_ipv6 :: proc(r: ^Reader) -> bool {
	return false
}

read_ipv4 :: proc(r: ^Reader) -> bool {
	index := r.index
	count, octet: int
	capture: for octet < 4 {
		read_number(r) or_break
		n_count := len(r.capture)

		if octet < 3 do read_letter(r, '.') or_break
		count += n_count + (octet < 3 ? 1 : 0)
		octet += 1
	}
	if octet == 4 {
		r.capture = r.source[index:][:count]
	} else do r.index = index
	return octet == 4
}

read_hostaddr :: proc(r: ^Reader) -> bool {
	if read_ipv6(r) do return true
	if read_ipv4(r) do return true
	return false
}

read_nickname :: proc(r: ^Reader) -> bool {
	count := 0
	capture: for count < len(r.source[r.index:]) && count <= 9 {
		switch r.source[r.index + count] {
		case 'a'..='z', 'A'..='Z', '[', ']', '\\', '`', '_', '^', '{', '|', '}':
		case '0'..='9', '-':
			if count == 0 do break capture
		case:
			break capture
		}
		count += 1
	}
	if count > 0 {
		r.capture  = r.source[r.index:][:count]
		r.index   += count
	}
	return count > 0
}

read_user :: proc(r: ^Reader) -> bool {
	count := 0
	capture: for count < len(r.source[r.index:]) {
		switch r.source[r.index + count] {
		case 0, '\r', '\n', ' ', '@':
			break capture
		case:
		}
		count += 1
	}
	if count > 0 {
		r.capture  = r.source[r.index:][:count]
		r.index   += count
	}
	return count > 0
}

read_command :: proc(r: ^Reader) -> bool {
	index := r.index

	read_number(r)
	if len(r.capture) == 3 do return true
	else do r.index = index

	count := 0
	capture: for count < len(r.source[r.index:]) {
		switch r.source[r.index:][count] {
		case 'a'..='z', 'A'..='Z':
			count += 1
		case:
			break capture
		}
	}
	if count > 0 {
		r.capture = r.source[r.index:][:count]
		r.index  += count
	}
	return count > 0
}

IRC_Command :: struct {
	name: string,
	params: [15]string `fmt:"v,params_count"`,
	params_count: int  `fmt:"-"`,

	host: string,
	user: string,
	nickname: string,
	servername: string,
}

read_nospcrlfcl :: proc(r: ^Reader) -> bool {
	if len(r.source[r.index:]) < 1 do return false
	switch r.source[r.index] {
	case 0, '\r', '\n', ' ', ':':
		return false
	case:
		r.capture = r.source[r.index:][:1]
		r.index += 1
		return true
	}
}

read_middle :: proc(r: ^Reader) -> bool {
	index   := r.index
	read_nospcrlfcl(r) or_return
	for {
		if read_letter(r, ':') do continue
		read_nospcrlfcl(r) or_break
	}
	count := r.index - index
	r.capture = r.source[index:][:count]
	return count > 0
}

read_trailing :: proc(r: ^Reader) -> bool {
	index := r.index
	for len(r.source[r.index:]) > 0 {
		if read_letter(r, ':') do continue
		if read_letter(r, ' ') do continue
		read_nospcrlfcl(r) or_break
	}
	count := r.index - index
	if count > 0 do r.capture = r.source[index:][:count]
	return count > 0
}

parse_prefix :: proc(r: ^Reader, cmd: ^IRC_Command) -> bool {
	if !read_letter(r, ':') do return true

	index := r.index
	if read_hostname(r) {
		capture := r.capture
		if read_letter(r, ' ') {
			cmd.servername = capture
			return true
		}
		r.index = index
	}

	read_nickname(r) or_return
	cmd.nickname = r.capture

	host_expected: bool
	if read_letter(r, '!') {
		read_user(r) or_return
		cmd.user = r.capture
		host_expected = true
	}
	if read_letter(r, '@') {
		if read_hostname(r) {
			cmd.host = r.capture
			host_expected = false
		} else if read_hostaddr(r) {
			cmd.host = r.capture
			host_expected = false
		}
	}
	if host_expected do return false
	return read_letter(r, ' ')
}

parse :: proc(msg: string) -> (cmd: IRC_Command, ok: bool) {
	if !strings.has_suffix(msg, "\r\n") do return cmd, false

	msg := strings.trim_space(msg)
	if msg == "" do return cmd, false

	reader: Reader
	reader.source = msg
	parse_prefix(&reader, &cmd) or_return
	// if read_letter(&reader, ':') {
	// 	if read_nickname(&reader) {
	// 		cmd.nickname  = reader.capture

	// 		require_host := false
	// 		if read_letter(&reader, '!') {
	// 			read_user(&reader) or_return
	// 			cmd.user = reader.capture
	// 			require_host = true
	// 		}
	// 		if read_letter(&reader, '@') {
	// 			if read_hostname(&reader) {
	// 				cmd.host = reader.capture
	// 			} else if read_hostaddr(&reader) {
	// 				cmd.host = reader.capture
	// 			} else do return cmd, false
	// 		} else if require_host do return cmd, false
	// 	} else if read_hostname(&reader) {
	// 		cmd.servername = reader.capture
	// 	} else do return cmd, false
	// 	read_letter(&reader, ' ') or_return
	// }

	read_command(&reader) or_return
	cmd.name = reader.capture

	for &param in cmd.params[:14] {
		read_letter(&reader, ' ') or_break
		if !read_middle(&reader) {
			reader.index -= 1
			break
		}
		param = reader.capture
		cmd.params_count += 1
	}

	if read_letter(&reader, ' ') {
		if cmd.params_count == 14 do read_letter(&reader, ':')
		else do read_letter(&reader, ':') or_return
		read_trailing(&reader) or_return
		cmd.params[cmd.params_count] = reader.capture
		cmd.params_count += 1
	}
	return cmd, len(reader.source[reader.index:]) == 0
}

@(test)
test_parse :: proc(t: ^testing.T) {
	Case :: struct {
		ok: bool,
		msg: string,
		cmd: []struct{
			key: string,
			val: union{ string, int },
		},
	}
	cases := []Case{
		{ true, ":NickServ!NickServ@services.hackint.org NOTICE XENOBAS1 :\r\n", { } },
		// { true, ":UserTest03!~usertest0@105.157.179.151 PRIVMSG XENOBAS1 :Does this work ?\r\n", { { "nickname", "UserTest03" } } },
		// { true, ":UserTest03!~usertest0@105.157.179.151 PRIVMSG XENOBAS1 :Now it should appear\r\n", { { "nickname", "UserTest03" }, { "user", "~usertest0" }, { "host", "105.157.179.151" }, { "name", "PRIVMSG" }, { "params[0]", "XENOBAS1" }, { "params[1]", "Now it should appear" } } },
		// { true, ":palermo.hackint.org NOTICE * :*** Checking Ident\r\n", { { "servername", "palermo.hackint.org" }, { "name", "NOTICE" }, { "params[0]", "*" }, { "params[1]", "*** Checking Ident" } } },
		// { true, ":palermo.hackint.org NOTICE * :*** Looking up your hostname...\r\n", { { "servername", "palermo.hackint.org" }, { "name", "NOTICE" }, { "params[0]", "*" }, { "params[1]", "*** Looking up your hostname..." } } },
		// { true, ":palermo.hackint.org NOTICE * :*** Couldn't look up your hostname\r\n", { { "servername", "palermo.hackint.org" }, { "name", "NOTICE" }, { "params[0]", "*" }, { "params[1]", "*** Couldn't look up your hostname" } } },
		// { true, ":palermo.hackint.org NOTICE * :*** No Ident response\r\n", { { "servername", "palermo.hackint.org" }, { "name", "NOTICE" }, { "params[0]", "*" }, { "params[1]", "*** No Ident response" } } },
		// { true, "PING :833A4B49\r\n", { { "name", "PING" }, { "params[0]", "833A4B49" } } },

		// { false, "\r\n", { } },
		// { true, "QUIT\r\n", { { "name", "QUIT" } } },
		// { true, ":www.google.com QUIT\r\n", { { "name", "QUIT" }, { "servername", "www.google.com" } } },
		// { true, "QUIT Bye\r\n", { { "name", "QUIT" }, { "params_count", 1 }, { "params[0]", "Bye" } } },
		// { true, "QUIT 1 2 3 :4 5: 6\r\n", { { "name", "QUIT" }, { "params_count", 4 }, { "params[0]", "1" }, { "params[1]", "2" }, { "params[2]", "3" }, { "params[3]", "4 5: 6" } } },
	}

	for _case in cases {
		info: bool
		cmd, ok := parse(_case.msg)

		info = info
		if !testing.expect_value(t, ok, _case.ok) do info = true
		for part in _case.cmd {
			val: union{ string, int }

			is_param: bool
			if strings.starts_with(part.key, "params[") && strings.ends_with(part.key, "]") {
				substr := part.key[7:]
				substr  = substr[:len(substr) - 1]

				n: int
				idx, ok := strconv.parse_int(substr, 10, &n)
				if ok && idx >= 0 && idx <= 14 {
					val = cmd.params[idx]
					is_param = true
				} else do unimplemented(fmt.tprintf("%s => ok = %v, idx = %v", part.key, ok, idx))
			}

			switch part.key {
			case "host":
				val = cmd.host
			case "user":
				val = cmd.user
			case "nickname":
				val = cmd.nickname
			case "params_count":
				val = cmd.params_count
			case "servername":
				val = cmd.servername
			case "name":
				val = cmd.name
			case:
				if !is_param {
					message := fmt.tprintf("key %s", part.key)
					unimplemented(message)
				}
			}
			if !testing.expect_value(t, val, part.val) do info = true
		}
		if info {
			log.infof("Case %v", _case)
			log.infof("Cmd  %v", cmd)
		}
	}
	// testing.expect_value(t, parse(":"), "")
	// testing.expect_value(t, parse(":www.hazben.hotel"), "www.hazben.hotel")
	// testing.expect_value(t, parse(":www.hazben.hotel."), "")
	// testing.expect_value(t, parse(":www.hazben.hotel.xyz"), "www.hazben.hotel.xyz")
}

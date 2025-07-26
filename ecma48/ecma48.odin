/* ECMA48 7-bit codes form parser 
 * https://ecma-international.org/wp-content/uploads/ECMA-48_5th_edition_june_1991.pdf
 */
package ecma48

/* Defines the parameters capacity per Control Sequence */
CSI_CAPACITY :: #config(ECMA48_CSI_CAPACITY, 16)

Control_Sequence :: struct {
	id:			byte					`fmt:"c"`,
	initial:	byte					`fmt:"c"`,
	params_n:	int						`fmt:"-"`,
	params:		[CSI_CAPACITY]string	`fmt:"v,params_n"`,
	text:		string,
}

Reader :: struct {
	source: string,

	begin: int,
	current: int,
}

peek :: proc(r: ^Reader, offset := 0) -> byte {
	if r.current + offset >= len(r.source) do return 0
	return r.source[r.current + offset]
}

next :: proc(r: ^Reader) -> byte {
	ch := peek(r)
	if ch != 0 {
		r.current += 1
	}
	return ch
}

commit :: proc(r: ^Reader) {
	r.begin = r.current
}

restore :: proc(r: ^Reader) {
	r.current = r.begin
}

take :: proc(r: ^Reader) -> string {
	len := r.current - r.begin
	txt := r.source[r.begin:][:len]

	commit(r)
	return txt
}

accept_byte :: proc(r: ^Reader, pattern: byte) -> (ch: byte, ok: bool) {
	if peek(r) == pattern do return next(r), true
	return 0, false
}

accept_proc :: proc(r: ^Reader, pattern: #type proc(b: byte) -> bool) -> (ch: byte, ok: bool) {
	if pattern(peek(r)) do return next(r), true
	return 0, false
}

accept :: proc {
	accept_byte,
	accept_proc,
}

scan :: proc(s: string) -> (seq: Control_Sequence, ok: bool) {
	r: Reader
	r.source = s

	accept(&r, '\e') or_return
	accept(&r, '[') or_return
	if initial, ok := accept(&r, is_param_private_byte); ok do seq.initial = initial
	commit(&r)

	wait_param: bool
	for seq.params_n <= CSI_CAPACITY {
		commit(&r)
		for _ in accept(&r, is_param_substr_byte) { }
		param := take(&r)

		commit_param := len(param) > 0
		if _, ok := accept(&r, ';'); ok do commit_param = true
		if !commit_param {
			if wait_param do return seq, false
			break
		}
		assert(seq.params_n < CSI_CAPACITY, "Tried to scan a control sequence that has more parameters than the capacity")
		seq.params[seq.params_n] = param
		seq.params_n += 1

		_, wait_param = accept(&r, is_interim_byte)
	}
	seq.id   = accept(&r, is_final_byte) or_return
	seq.text = r.source[:r.current]

	return seq, true
}

is_interim_byte :: proc(b: byte) -> bool {
	return b >= 0x20 && b <= 0x2f
}

is_param_byte :: proc(b: byte) -> bool {
	return b >= 0x30 && b <= 0x3f
}

is_param_private_byte :: proc(b: byte) -> bool {
	return b >= 0x3c && b <= 0x3f
}

is_param_substr_byte :: proc(b: byte) -> bool {
	return b >= 0x30 && b <= 0x3a
}

is_final_byte :: proc(b: byte) -> bool {
	return b >= 0x40 && b <= 0x7d
}

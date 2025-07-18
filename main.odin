package main

import "core:os"
import "core:fmt"
import "core:log"
import "core:time"
import "core:thread"
import "core:sync/chan"

/* TODO(XENOBAS):
 * 1. BUGS
      - When the non blocking reading happens to split before a "\r\n", it fails parsing (BUG)
        appears to be the last structural bug we will be seeing.
	  - Scrolling must stop at last line to the top.
 * ----------------------------------------------------
 * 2. Connection should be established via command (/connect ...), not on startup
 * 3. Tabs per conversation (channel, server, user)
 * 4. Text field should be scrollable and only one line.
 * 5. Client should have persistent data (NICK...)
 * 6. TermCL is slow so replace it, or is being used improperly so fix it
 * 7. IRC without OpenSSL secure layer
 */

TRACK_ALLOC :: #config(TRACK_ALLOC, false)

main :: proc() {
	if err := os.make_directory("logs"); err != nil && err != os.EEXIST do fmt.panicf("Could not create `logs` directory because of %v", err)

	log_buff: [time.MIN_YY_DATE_LEN]u8
	log_timestamp     := time.now()
	log_path          := fmt.tprintf("logs/%s.txt", time.to_string_yy_mm_dd(log_timestamp, log_buff[:]))
	log_file, log_err := os.open(log_path, os.O_CREATE | os.O_RDWR | os.O_APPEND, 0o666)
	if log_err != nil do fmt.panicf("Couldn't create logger: %v", log_err)
	defer os.close(log_file)

	context.logger = log.create_file_logger(log_file)
	defer log.destroy_file_logger(context.logger)

	chan_req, err_req := chan.create(chan.Chan(string), 8, context.allocator)
	assert(err_req == .None, "Could not create inter-thread communication channel for requests")
	defer chan.destroy(chan_req)

	chan_res, err_res := chan.create(chan.Chan(Response), 8, context.allocator)
	assert(err_res == .None, "Could not create inter-thread communication channel for requests")
	defer chan.destroy(chan_res)

	ui_thread := thread.create_and_start_with_poly_data2(chan.as_send(chan_req), chan.as_recv(chan_res), ui_routine, init_context = context)
	defer thread.destroy(ui_thread)

	irc_thread := thread.create_and_start_with_poly_data2(chan.as_recv(chan_req), chan.as_send(chan_res), irc_routine, init_context = context)
	defer thread.destroy(irc_thread)

	thread.join_multiple(ui_thread, irc_thread)
}

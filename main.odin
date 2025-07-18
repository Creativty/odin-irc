package main

import "core:thread"
import "core:sync/chan"

/* TODO(XENOBAS):
 * 2. TermCL is slow so replace it, or is being used improperly so fix it
 * 3. Connection should be established via command (/connect ...), not on startup
 * 4. Client should have persistent data (NICK...)
 * 5. IRC without secure layer
 *    --Allocations are not being properly freed when transferring data over channels--
 */

TRACK_ALLOC :: #config(TRACK_ALLOC, false)

main :: proc() {
	chan_req, err_req := chan.create(chan.Chan(string), 8, context.allocator)
	assert(err_req == .None, "Could not create inter-thread communication channel for requests")
	defer chan.destroy(chan_req)

	chan_res, err_res := chan.create(chan.Chan(Response), 8, context.allocator)
	assert(err_res == .None, "Could not create inter-thread communication channel for requests")
	defer chan.destroy(chan_res)

	ui_thread := thread.create_and_start_with_poly_data2(chan.as_send(chan_req), chan.as_recv(chan_res), ui_routine)
	defer thread.destroy(ui_thread)

	irc_thread := thread.create_and_start_with_poly_data2(chan.as_recv(chan_req), chan.as_send(chan_res), irc_routine)
	defer thread.destroy(irc_thread)

	thread.join_multiple(ui_thread, irc_thread)
}

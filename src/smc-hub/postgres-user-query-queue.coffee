"""
User query queue.

The point of this is to make it so:
 (1) there is a limit on the number of simultaneous queries that a single connected client
     can make to the database, and
 (2) when the client disconnects, any outstanding (not started) queries are cancelled, and
 (3) queries that don't even start until a certain amount of time after they were made are
     automatically considered to have failed (so the client retries).
"""

{defaults} = misc = require('smc-util/misc')
required = defaults.required

# We do at most this many user queries **at once** to the database on behalf of each connected client.
USER_QUERY_LIMIT      = 1

# If we don't even start query by this long after we receive query, then we consider it failed
USER_QUERY_TIMEOUT_MS = 15000

# How many recent query times to save for each client.
# This is currently not used for anything except logging.
TIME_HISTORY_LENGTH = 100

class exports.UserQueryQueue
    constructor: (opts) ->
        opts = defaults opts,
            do_query   : required
            dbg        : required
            limit      : USER_QUERY_LIMIT
            timeout_ms : USER_QUERY_TIMEOUT_MS
        @_do_query   = opts.do_query
        @_limit      = opts.limit
        @_dbg        = opts.dbg
        @_timeout_ms = opts.timeout_ms
        @_state      = {}

    destroy: =>
        delete @_do_query
        delete @_limit
        delete @_dbg
        delete @_state

    cancel_user_queries: (opts) =>
        opts = defaults opts,
            client_id : required
        state = @_state[opts.client_id]
        @_dbg("cancel_user_queries(client_id='#{opts.client_id}') -- discarding #{state?.queue?.length}")
        if state?
            delete state.queue  # so we will stop trying to do queries for this client
            delete @_state[opts.client_id]  # and won't waste memory on them

    user_query: (opts) =>
        opts = defaults opts,
            client_id  : required
            priority   : undefined  # (NOT IMPLEMENTED) priority for this query
                                    # (an integer [-10,...,19] like in UNIX)
            account_id : undefined
            project_id : undefined
            query      : required
            options    : []
            changes    : undefined
            cb         : undefined
        client_id = opts.client_id
        @_dbg("user_query(client_id='#{opts.client_id}')")
        delete opts.client_id
        state = @_state[client_id]
        if not state?
            state = @_state[client_id] =
                client_id : client_id
                queue     : []    # queries in the queue
                count     : 0     # number of queries currently outstanding (waiting for these to finish)
                sent      : 0     # total number of queries sent to database
                time_ms   : []    # how long recent queries took in ms times_ms[times_ms.length-1] is most recent
        opts.time = new Date()
        state.queue.push(opts)
        state.sent += 1
        @_update(state)

    _do_one_query: (opts, cb) =>
        if new Date() - opts.time >= @_timeout_ms
            @_dbg("_do_one_query -- timed out")
            # It took too long before we even **started** the query.  There is no
            # point in even trying; the client likely already gave up.
            opts.cb?("timeout")
            cb()
            return

        @_dbg("_do_one_query(client_id='#{opts.client_id}') -- doing the query")
        # Actually do the query
        orig_cb = opts.cb
        # Remove the two properties from opts that @_do_query doesn't take
        # as inputs, and of course we do not need anymore.
        delete opts.time  # no longer matters
        delete opts.client_id
        delete opts.priority

        # Set a cb that calls our cb exactly once, but sends anything
        # it receives to the orig_cb, if there is one.
        opts.cb = (err, result) =>
            if cb?
                cb()
                cb = undefined
            if result?.action == 'close' or err
                # I think this is necessary for this closure to ever
                # get garbage collected.  **Not tested, and this could be bad.**
                delete opts.cb
            orig_cb?(err, result)

        # Finally, do the query.
        @_do_query(opts)

    _update: (state) =>
        while state.queue? and state.queue.length > 0 and state.count < @_limit
            @_process_next_call(state)

    _process_next_call: (state) =>
        if not state.queue?
            return
        if state.queue.length == 0
            return
        state.count += 1
        opts = state.queue.shift()
        @_info(state)
        tm = new Date()
        @_do_one_query opts, =>
            state.count -= 1
            state.time_ms.push(new Date() - tm)
            if state.time_ms.length > TIME_HISTORY_LENGTH
                state.time_ms.shift()
            @_info(state)
            @_update(state)

    _avg: (state) =>
        # recent average time
        v = state.time_ms.slice(state.time_ms.length - 10)
        s = 0
        for a in v
            s += a
        return s / v.length

    _info: (state) =>
        @_dbg("client_id='#{state.client_id}': avg=#{@_avg(state)}ms, count=#{state.count}, queued.length=#{state.queue?.length}, sent=#{state.sent}")
source: context7//signalwire/freeswitch-docs — ESL bgapi/uuid_* commands

# FreeSWITCH ESL — bgapi and uuid_* commands (official docs)

Retrieved via context7 MCP `query-docs` from the official FreeSWITCH docs
(/signalwire/freeswitch-docs, mirroring docs at
github.com/signalwire/freeswitch-docs/docs/integration/event-socket.mdx and
docs/programming/esl-inbound.mdx).

## Event Socket inbound connection, auth, and command execution

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/integration/event-socket.mdx

Clients connect to the configured `listen-ip` and `listen-port`. After
connection, the client must authenticate before issuing commands:

1. FreeSWITCH sends `Content-Type: auth/request`.
2. Client sends `auth <password>` followed by a blank line.
3. FreeSWITCH replies `Content-Type: command/reply` with
   `Reply-Text: +OK accepted` (or `-ERR invalid`).

Command execution:

- **Foreground API**: send `api <command>` + blank line. Response is
  `Content-Type: api/response`.
- **Background API**: send `bgapi <command>` + blank line. Response is
  `Content-Type: command/reply` with a `Job-UUID`.
- **Events**: send `event <format> <event_type>` to subscribe to events.
- **Disconnection**: send `exit`; FreeSWITCH responds
  `Content-Type: text/disconnect-notice` before closing the socket.

## Execute background API command with bgapi

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/integration/event-socket.mdx

`bgapi` executes an API command in a background thread, returning a
`Job-UUID` immediately:

```text
bgapi originate sofia/gateway/gw/15551234567 &echo
```

## Inbound ESL connection and event handling (Lua example)

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/programming/esl-inbound.mdx

```lua
-- connect AND authenticate
local con = ESL.ESLconnection("127.0.0.1", "8021", "ClueCon")
if con:connected() == 0 then return end

-- blocking api call: result is the ESLevent body
local info = con:api("status")
print(info:getBody())

-- kick off a call in the background; we get a Job-UUID back immediately
con:bgapi("originate", "user/1000 &echo")

-- subscribe to all events in plain format
con:events("plain", "ALL")

while con:connected() == 1 do
    local e = con:recvEvent()          -- recvEventTimed(ms) is the timed variant
    if e then
        local name = e:getHeader("Event-Name")
        if name == "CHANNEL_CREATE" or name == "CHANNEL_ANSWER"
            or name == "CHANNEL_HANGUP" then
            print(string.format("%s  uuid=%s  number=%s", name,
                e:getHeader("Unique-ID"),
                e:getHeader("Caller-Destination-Number")))
        elseif name == "BACKGROUND_JOB" then
            -- deferred result of our bgapi originate
            print("job " .. tostring(e:getHeader("Job-UUID"))
                .. " -> " .. tostring(e:getBody()))
        end
    end
end
```

## Control a live channel (uuid_* commands)

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/programming/esl-inbound.mdx

Use `con:api` to execute commands like `uuid_kill` or `uuid_transfer` on a
specific channel using its `Unique-ID`:

```lua
con:api("uuid_kill", uuid)
con:api("uuid_transfer", uuid .. " 9999")
```

## Common uses — placing and controlling calls

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/programming/esl-inbound.mdx

- `con:bgapi("originate", "user/1000 &park")` starts a call without blocking.
- `con:api("uuid_kill", uuid)` / `con:api("uuid_transfer", uuid .. " 9999")`
  act on a live channel by its `Unique-ID`.

Because `bgapi` returns a `Job-UUID` and the real answer arrives later as a
`BACKGROUND_JOB` event, a robust dialer keeps an events loop running, records
the `Job-UUID` it got back, and matches it against the `Job-UUID` header on
each `BACKGROUND_JOB` to learn the outcome of each `originate`.

# MCP server

`heliograph mcp` turns the CLI into a set of tools any MCP-capable agent can
call. Claude Code, Codex CLI, Claude Desktop, Cursor, Windsurf, Cline, Zed -
anything that speaks the Model Context Protocol.

It is the same binary. There is nothing extra to install.

If you were looking for an MCP server that runs commands over SSH, this is the
one for when there is no SSH. A tool call publishes a request; a station on the
far side, started by somebody with legitimate access, decides whether to run it.

## How do I add heliograph as an MCP server?

Claude Code, one command:

```bash
claude mcp add heliograph -- heliograph mcp
```

Codex CLI, the same shape:

```bash
codex mcp add heliograph -- heliograph mcp
```

Anything that takes a JSON config:

```json
{
  "mcpServers": {
    "heliograph": {
      "command": "heliograph",
      "args": ["mcp"]
    }
  }
}
```

The server reads your existing estates. If `heliograph estates` lists it, the
tools can reach it.

## The tools

| tool | what it does |
|---|---|
| `heliograph_estates` | what is configured here, and which transport each uses |
| `heliograph_send` | publish a step, and return. It does **not** wait |
| `heliograph_status` | what the station is doing now |
| `heliograph_cancel` | kill the running step, on git or a file share |
| `heliograph_stop` | end the station's loop after the current run |
| `heliograph_logs` | the captured logs, newest first |
| `heliograph_read_log` | one log, whole |
| `heliograph_gaps` | where a run stalled, longest interval first |
| `heliograph_doctor` | will this work from here, changing nothing |

`heliograph_send` builds its request with the same code as `heliograph send`.
It names the station it was written for, expires after 24 hours unless you pass
`expires` (`"0"` for never), and takes the optional `mode` the step must
declare. A request an agent sends is bound exactly as one typed at the CLI.

## Why tools and not just the skill

The [skill](claude-code.md) teaches an agent to run the CLI, and that works.
Every answer arrives as text it has to parse back out of a terminal.

A tool returns a result the agent did not have to scrape, with an argument list
it cannot get subtly wrong. `heliograph_gaps` hands back the intervals already
measured and attributed. The agent does not have to notice a stall in a column
of timestamps; it is told.

## What it does not change

**Nothing about the gates.** A tool call publishes a request. The station still
decides whether to run it, still refuses a step that declares neither read-only
nor action, and still refuses an action unless it was started with
`--allow-actions` and the request carries `CONFIRM=yes`.

An MCP client asks. It does not get to answer.

```diagram gates
Three gates, all on the far side. The control side can ask for anything; the station decides.
```


**Nothing about the far side.** There is still no connection, no tunnel and
nothing held open. Somebody with legitimate access started the loop, and they
can stop it.

## Reading a result

`heliograph_send` returns as soon as the request is published, which is before
the run has started. An agent that treats the reply as the result will read the
*previous* run's log and report it as this one's. The tool description says so,
and the shape of the loop is:

1. `heliograph_send`
2. `heliograph_status` with the `id` it returned, until the state is `idle`,
   `cancelled`, `refused`, `stopped` or `undelivered`. With the id, a status
   about an earlier request comes back as `not picked up yet` instead of as
   this one's result
3. `heliograph_gaps` to find where the time went
4. `heliograph_read_log` for the whole thing

`refused` is not a failure. It means the station would not run that step, and
the reason says which flag would have permitted it. An agent that reads a
refusal as a crash will retry the same step forever.

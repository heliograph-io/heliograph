// `heliograph mcp` exposes this CLI to any MCP-capable agent as typed tools.
//
// # WHY A SUBCOMMAND AND NOT A SECOND BINARY
//
// One download, and the client configuration is the binary somebody already
// has. More than that, the tools call the SAME open() the commands call, so
// "a tool and a command cannot disagree about which machine they are talking
// to" is a fact about the code rather than an intention. A separate binary
// would have needed its own copy of that resolution, and a copy is a thing
// that drifts.
//
// # WHY TOOLS AND NOT JUST THE SKILL
//
// A skill teaches an agent to run this CLI, and every answer arrives as text
// it has to parse back out of a terminal. A tool returns a result it did not
// have to scrape, with an argument list it cannot get subtly wrong.
//
// The gates are unchanged and unreachable from here. A tool call publishes a
// request; the station still decides whether to run it, still refuses a step
// that declares no mode, and still refuses an action unless it was started
// with --allow-actions. An MCP client asks. It does not get to answer.
package main

import (
	"bytes"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/heliograph-io/heliograph/internal/estate"
	"github.com/heliograph-io/heliograph/internal/logfile"
	"github.com/heliograph-io/heliograph/internal/mcp"
	"github.com/heliograph-io/heliograph/internal/wire"
)

// cmdMCP serves the tools over stdio until the client closes it.
//
// Nothing is written to stdout except protocol frames: stdout IS the
// transport, and a stray Println would be read as a malformed message and end
// the session. Anything worth saying goes to stderr.
func cmdMCP(args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("mcp takes no arguments: it speaks JSON-RPC on stdin and stdout")
	}
	s := mcp.NewServer("heliograph", buildVersion(), tools())
	return s.Serve(os.Stdin, os.Stdout)
}

func obj(props map[string]any, required ...string) map[string]any {
	m := map[string]any{"type": "object", "properties": props}
	if len(required) > 0 {
		m["required"] = required
	}
	return m
}
func str(desc string) map[string]any { return map[string]any{"type": "string", "description": desc} }

func tools() []mcp.Tool {
	estateArg := str("Which estate. Optional when only one is configured.")

	return []mcp.Tool{{
		Name: "heliograph_estates",
		Description: "List the configured estates and the transport each uses. " +
			"Call this first when you do not know which estate to act on.",
		Schema: obj(map[string]any{}),
		Call: func(map[string]any) (string, error) {
			names, err := estate.List()
			if err != nil {
				return "", err
			}
			if len(names) == 0 {
				return "No estates are configured. Run `heliograph init <name> --dir <path>` first.", nil
			}
			var b strings.Builder
			for _, n := range names {
				e, err := estate.Load(n)
				if err != nil {
					fmt.Fprintf(&b, "%s (unreadable: %v)\n", n, err)
					continue
				}
				fmt.Fprintf(&b, "%s\ttransport=%s\tdir=%s\n", e.Name, e.Transport, e.Dir)
			}
			return b.String(), nil
		},
	}, {
		Name: "heliograph_send",
		Description: "Publish a step for the station to run, and return immediately. " +
			"This does NOT wait for the result: poll heliograph_status with the id this returns " +
			"until it reports a terminal state, then read the log. The station decides whether to run it at " +
			"all: a step that declares no mode is refused, and one that changes state needs " +
			"CONFIRM=yes and a station started with --allow-actions.",
		Schema: obj(map[string]any{
			"step":   str("A step registered in the station's run.sh, or a path such as steps/net-probe.sh"),
			"env":    map[string]any{"type": "object", "description": "Environment for the run, for example {\"HOSTS\":\"sql01 sql02\"}", "additionalProperties": map[string]any{"type": "string"}},
			"note":   str("Free text for the next human. The station ignores it."),
			"estate": estateArg,
		}, "step"),
		Call: func(a map[string]any) (string, error) {
			step := mcp.Str(a, "step")
			if step == "" {
				return "", fmt.Errorf("step is required")
			}
			o, err := open(mcp.Str(a, "estate"))
			if err != nil {
				return "", err
			}
			// Sorted, so the same call twice produces the same request rather
			// than one that differs only in map order.
			env := mcp.StrMap(a, "env")
			keys := make([]string, 0, len(env))
			for k := range env {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			var parts []string
			for _, k := range keys {
				parts = append(parts, wire.QuoteEnv(k+"="+env[k]))
			}
			req := wire.Request{
				Version: wire.Version,
				ID:      wire.NewID(step, time.Now()),
				Step:    step,
				Env:     strings.Join(parts, " "),
				Note:    mcp.Str(a, "note"),
			}
			if err := o.PutRequest(req); err != nil {
				return "", err
			}
			// The same record `heliograph send` keeps, so `heliograph watch`
			// waits for a request an agent sent too.
			_ = estate.RecordSent(o.Estate.Name, req.ID)
			return fmt.Sprintf("sent %s\nstep: %s\nenv: %s\n\nThe station picks this up within its poll interval. "+
				"Poll heliograph_status with id %s until state is idle, cancelled, refused, stopped or undelivered. "+
				"Without the id, the status straight after a send still describes the previous run.",
				req.ID, step, req.Env, req.ID), nil
		},
	}, {
		Name: "heliograph_status",
		Description: "What the station is doing now. State is one of starting, running, idle, " +
			"cancelled, refused, stopped or undelivered. Five of those are terminal: idle, " +
			"cancelled, refused, stopped and undelivered. `starting` and `running` mean the run " +
			"is still going. An empty state means the station has published nothing yet, which " +
			"usually means it has not been started. A state you do not recognise is neither " +
			"finished nor alive: a newer station may publish one, so keep polling rather than " +
			"giving up. `refused` is not a failure: it means the station would not run the step, " +
			"and the reason names the flag that would permit it. `undelivered` means the run " +
			"finished and the log is complete but the transport would not take it, so waiting " +
			"for more is exactly wrong.",
		// The `actions` line this returns is deliberately NOT described here.
		// Glama scores the tool DEFINITIONS and publishes that score against a
		// release version, so any wording change here needs a human to make a
		// Glama release before the listing stops being true - see
		// TestGlamaSnapshotMatchesTheTools. The returned line explains itself
		// in full, which is where a model reads it anyway, so the description
		// buys nothing worth a manual release.
		Schema: obj(map[string]any{
			"id": str("The id heliograph_send returned. With it, a status about any other request " +
				"is reported as not picked up yet instead of as this request's result."),
			"estate": estateArg,
		}),
		Call: func(a map[string]any) (string, error) {
			o, err := open(mcp.Str(a, "estate"))
			if err != nil {
				return "", err
			}
			s, err := o.FetchStatus()
			if err != nil {
				return "", err
			}
			if s.State == "" {
				return "The station has published no status. It may not have been started: the operator runs ./start.sh once.", nil
			}
			// NOT THIS REQUEST'S RESULT, and said instead of the result. Straight
			// after a send the status still describes the previous run, and a
			// model shown that run's `refused` reads it as a refusal of the step
			// it just sent - then asks for a station restart nobody needs.
			if msg, moved := notPickedUp(s, mcp.Str(a, "id")); msg != "" {
				msg = strings.ToUpper(msg[:1]) + msg[1:] + "."
				if moved {
					return msg + " Polling again will not change this: find that request's log with heliograph_logs.", nil
				}
				return msg + " That status is about an earlier request, not this one. Poll again.", nil
			}
			var b strings.Builder
			fmt.Fprintf(&b, "state: %s\n", s.State)
			// ALWAYS, including when the station published nothing for it. A
			// field omitted when it is unknown is the one a model fills in from
			// the log history sitting in front of it, and that inference is
			// wrong in both directions.
			// The CLI pads its labels into a column; this side is key/value for
			// a model, so the padding comes back out and the sentence stays.
			fmt.Fprintf(&b, "%s\n", strings.Replace(actionModeLine(s), "actions:  ", "actions: ", 1))
			for _, kv := range [][2]string{{"id", s.ID}, {"step", s.Step}, {"host", s.Host},
				{"started", s.Started}, {"progress", s.Progress}, {"last", s.Last},
				{"finished", s.Finished}, {"exit", s.Exit}, {"log", s.Log}, {"reason", s.Reason}} {
				if kv[1] != "" {
					fmt.Fprintf(&b, "%s: %s\n", kv[0], kv[1])
				}
			}
			if s.Refused() {
				b.WriteString("\nThe station refused this. An action step needs the station started " +
					"with --allow-actions and the request to carry CONFIRM=yes.\n")
			}
			return b.String(), nil
		},
	}, {
		Name: "heliograph_logs",
		Description: "List the captured logs, newest first. Each name carries the request id " +
			"that produced it, so the log for a run you sent is the one whose name matches " +
			"the id heliograph_send returned. Use this to find a log; use heliograph_read_log " +
			"to read one.",
		Schema: obj(map[string]any{"estate": estateArg}),
		Call: func(a map[string]any) (string, error) {
			o, err := open(mcp.Str(a, "estate"))
			if err != nil {
				return "", err
			}
			names, err := o.ListLogs()
			if err != nil {
				return "", err
			}
			if len(names) == 0 {
				return "No logs yet.", nil
			}
			return strings.Join(names, "\n"), nil
		},
	}, {
		Name: "heliograph_read_log",
		Description: "Read a captured log whole. Every line carries a UTC timestamp. " +
			"Read all of it, including the parts that worked: a passing probe beside a failing " +
			"one is the control that says what the failure means. A green exit means the probes " +
			"that ran passed, not that the work happened.",
		Schema: obj(map[string]any{
			"name":   str("Log filename. Omit for the most recent."),
			"estate": estateArg,
		}),
		Call: func(a map[string]any) (string, error) {
			o, err := open(mcp.Str(a, "estate"))
			if err != nil {
				return "", err
			}
			name := mcp.Str(a, "name")
			if name == "" {
				names, err := o.ListLogs()
				if err != nil {
					return "", err
				}
				if len(names) == 0 {
					return "", fmt.Errorf("no logs yet")
				}
				name = names[0]
			}
			b, err := o.ReadLog(name)
			if err != nil {
				return "", err
			}
			// Never truncated. The line somebody cuts is the line they needed,
			// and that rule does not soften because the reader is a model.
			return string(b), nil
		},
	}, {
		Name: "heliograph_gaps",
		Description: "Where a run stalled. Returns the intervals in the log's timestamp column, " +
			"longest first, each attributed to the line BEFORE it, which is what was running. " +
			"Do this before reading a long log: a hang and slow progress are indistinguishable " +
			"without it. If every line carries the same timestamp the capture was buffered and " +
			"the log cannot answer the question at all, which this reports as an error.",
		Schema: obj(map[string]any{
			"name":        str("Log filename. Omit for the most recent."),
			"min_seconds": map[string]any{"type": "number", "description": "Shortest interval worth reporting. Default 10."},
			"estate":      estateArg,
		}),
		Call: func(a map[string]any) (string, error) {
			o, err := open(mcp.Str(a, "estate"))
			if err != nil {
				return "", err
			}
			name := mcp.Str(a, "name")
			if name == "" {
				names, err := o.ListLogs()
				if err != nil {
					return "", err
				}
				if len(names) == 0 {
					return "", fmt.Errorf("no logs yet")
				}
				name = names[0]
			}
			body, err := o.ReadLog(name)
			if err != nil {
				return "", err
			}
			min := 10 * time.Second
			if v, ok := a["min_seconds"].(float64); ok && v > 0 {
				min = time.Duration(v) * time.Second
			}
			gaps, err := logfile.Gaps(bytes.NewReader(body), min)
			if err != nil {
				return "", err
			}
			n, _ := logfile.CountStamped(bytes.NewReader(body))
			var b strings.Builder
			fmt.Fprintf(&b, "%s\n%d captured lines\n\n", name, n)
			if len(gaps) == 0 {
				fmt.Fprintf(&b, "No interval of %s or more: nothing stalled.\n", min)
				return b.String(), nil
			}
			fmt.Fprintf(&b, "%d interval(s) of %s or more, longest first.\n", len(gaps), min)
			b.WriteString("Each is attributed to the line BEFORE it, which is what was running.\n\n")
			for _, g := range gaps {
				b.WriteString(g.Format() + "\n")
			}
			return b.String(), nil
		},
	}, {
		Name: "heliograph_doctor",
		Description: "Check whether the transport works from here, and change nothing. " +
			"Run this before a long step: read access is not write access, and finding out " +
			"afterwards costs a whole round trip through somebody who cannot debug the machine.",
		Schema: obj(map[string]any{"estate": estateArg}),
		Call: func(a map[string]any) (string, error) {
			o, err := open(mcp.Str(a, "estate"))
			if err != nil {
				return "", err
			}
			var b strings.Builder
			fmt.Fprintf(&b, "estate: %s\ntransport: %s\n", o.Name, o.Describe())
			if err := o.Check(); err != nil {
				fmt.Fprintf(&b, "FAIL: %v\n", err)
				return b.String(), nil
			}
			b.WriteString("ok: the transport is reachable\n")
			s, err := o.FetchStatus()
			switch {
			case err != nil:
				fmt.Fprintf(&b, "FAIL: cannot read the station's status: %v\n", err)
			case s.State == "":
				b.WriteString("note: the station has published no status yet\n")
			default:
				fmt.Fprintf(&b, "ok: the station last published %q\n", s.State)
			}
			return b.String(), nil
		},
	}}
}

// The env quoting lives in wire.QuoteEnv, with the document it belongs to.
// Sharing it with the CLI is deliberate: a second copy of the code that stands
// between setting a variable and running a command would eventually drift, and
// the drift would only show up on a machine nobody here can reach.

package main

// `cancel` and `stop`, the two requests that must never start a run.
//
// Both were a hand edit: SKILL.md told an agent to set `cancel: yes` or
// `stop: yes` in station/request, commit and push. That broke the skill's own
// rule against editing files instead of using the CLI, and "commit and push"
// means nothing on a file share, a bundle, an object store or a relay. The
// fields were always in the wire format; nothing wrote them.
//
// THEY SET ONE FIELD ON THE REQUEST ALREADY IN THE SLOT, where the transport
// can read it back, and keep its id. A new id is a trigger: after the station
// cancelled a step it would run whatever that new request named, and a blank
// step is the station's DEFAULT step. And the slot may hold a request queued
// behind the running one, which a new document would silently replace.

import (
	"flag"
	"fmt"
	"strings"
	"time"

	"github.com/heliograph-io/heliograph/internal/transport"
	"github.com/heliograph-io/heliograph/internal/wire"
)

// cancelHeard is the transports whose station reads the request WHILE a step
// runs, which is the only time a cancel means anything. It is the station's
// `live` capability: tp_capabilities in station/bash/transports/ and
// Get-TpCapabilities in station/powershell/transports/. A test reads both and
// fails when this list and theirs disagree.
//
// Everywhere else the station reads a request between runs, so a cancel would
// arrive after the step it was meant to stop had finished. `cancel` refuses
// there rather than publish something that cannot work.
var cancelHeard = map[string]bool{"git": true, "share": true}

// cancelRun publishes a cancel for the step the station is running, and says
// what will happen. want is the id to cancel; "" means whatever is running.
func cancelRun(op opened, want string) (string, error) {
	if !cancelHeard[op.Estate.Transport] {
		return "", fmt.Errorf("not sent: a %s station reads a request only between runs, so a cancel "+
			"would reach it after the step had finished. Only git and a file share can cancel a running step. "+
			"`heliograph stop` ends the loop once this run is over", op.Estate.Transport)
	}
	rr, ok := op.Transport.(transport.RequestReader)
	if !ok {
		return "", fmt.Errorf("not sent: estate %q cannot read back its request, so a cancel would replace it", op.Estate.Name)
	}
	s, err := op.FetchStatus()
	if err != nil {
		return "", err
	}
	if msg := stationElsewhere(op, s); msg != "" {
		return "", fmt.Errorf("not sent: %s.\n%s", msg, stationElsewhereRemedy(op, s))
	}
	// A CANCEL STOPS A RUN, and only a run. The station takes `cancel:` into
	// account only while a step is running. Sent at any other time it is stale
	// by the time a step starts, and the station ignores it on purpose - so a
	// request it has not picked up yet still runs.
	if !s.Running() {
		if want != "" && want != s.ID {
			return "", fmt.Errorf("nothing to cancel: %s is not running. %s. "+
				"A cancel stops a running step; a request the station has not read yet still runs", want, stateLine(s))
		}
		return "", fmt.Errorf("nothing to cancel: %s", stateLine(s))
	}
	if want != "" && want != s.ID {
		return "", fmt.Errorf("not sent: %s is not the running step. The station is running %s (%s). "+
			"A cancel names the run it stops, so one for another id would be ignored", want, s.ID, orDash(s.Step))
	}
	id := s.ID

	req, err := rr.FetchRequest()
	if err != nil {
		return "", err
	}
	if req.ID == "" {
		// Nothing in the slot, which a station running a step should not see.
		// The running id is the safe one to carry: the station has already
		// acted on it, so it can never trigger a run.
		req = wire.Request{Version: wire.Version, ID: id, Step: s.Step, Target: op.Scope}
	}
	if req.Cancel == id {
		return fmt.Sprintf("a cancel for %s is already published. The station acts on it at its next poll.", id), nil
	}
	req.Cancel = id
	if err := op.PutRequest(req); err != nil {
		return "", err
	}
	var b strings.Builder
	fmt.Fprintf(&b, "cancel sent for %s (step %s)\n", id, orDash(s.Step))
	b.WriteString("  the station signals the step at its next poll and publishes `cancelled`, with the log as far as it got.\n")
	if req.ID != id {
		fmt.Fprintf(&b, "  request %s is still queued and runs next: a cancel stops only the running step.\n", req.ID)
	}
	fmt.Fprintf(&b, "  `heliograph watch %s --timeout 2m` to see it land.\n", id)
	return b.String(), nil
}

// stopStation publishes a stop, which ends the station's loop once the step it
// is running has finished. Every transport carries it: the station checks
// `stop:` before anything else in a request, between runs.
func stopStation(op opened) (string, error) {
	s, err := op.FetchStatus()
	if err != nil {
		return "", err
	}
	if msg := stationElsewhere(op, s); msg != "" {
		return "", fmt.Errorf("not sent: %s.\n%s", msg, stationElsewhereRemedy(op, s))
	}
	var req wire.Request
	if rr, ok := op.Transport.(transport.RequestReader); ok {
		if req, err = rr.FetchRequest(); err != nil {
			return "", err
		}
	}
	if req.Stop == "yes" {
		return "a stop is already published. The station stops before it reads another request.", nil
	}
	if req.ID == "" {
		// NO REQUEST TO CARRY IT: a relay, a bundle or an object store, whose
		// request cannot be read back, or a slot that has never held one. The id
		// is the last one the station read, so even a station that ignored
		// `stop:` would find nothing new to run. A fresh one only when the
		// station has published nothing at all.
		id := s.ID
		if id == "" {
			id = wire.NewID("stop", time.Now())
		}
		req = wire.Request{Version: wire.Version, ID: id, Target: op.Scope}
	}
	unrun := unrunRequest(op.Estate.Name, s)
	req.Stop = "yes"
	if err := op.PutRequest(req); err != nil {
		return "", err
	}
	var b strings.Builder
	fmt.Fprintf(&b, "stop sent to %s\n", op.Estate.Name)
	b.WriteString("  the station finishes the step it is running, publishes `stopped`, and exits.\n")
	if unrun != "" {
		fmt.Fprintf(&b, "  request %s has not run, and now will not: the station stops before it reads another.\n", unrun)
	}
	b.WriteString("  Only the operator can start it again. A station that reads this request stops again,\n" +
		"  so send the next step before they restart it: a new send replaces the stop.\n")
	return b.String(), nil
}

// stateLine says what the station last published, for a refusal to quote.
func stateLine(s wire.Status) string {
	if s.State == "" {
		return "the station has published no status, so it has run nothing here"
	}
	if s.ID == "" {
		return fmt.Sprintf("the station last published %q", s.State)
	}
	return fmt.Sprintf("the station last published %q for %s", s.State, s.ID)
}

func cmdCancel(args []string) error {
	fs := flag.NewFlagSet("cancel", flag.ExitOnError)
	name := estateFlag(fs)
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	if len(pos) > 1 {
		return fmt.Errorf("usage: heliograph cancel [id]")
	}
	op, err := open(*name)
	if err != nil {
		return err
	}
	want := ""
	if len(pos) == 1 {
		want = pos[0]
	}
	out, err := cancelRun(op, want)
	if err != nil {
		return err
	}
	fmt.Print(out)
	return nil
}

func cmdStop(args []string) error {
	fs := flag.NewFlagSet("stop", flag.ExitOnError)
	name := estateFlag(fs)
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 0 {
		return fmt.Errorf("usage: heliograph stop")
	}
	op, err := open(*name)
	if err != nil {
		return err
	}
	out, err := stopStation(op)
	if err != nil {
		return err
	}
	fmt.Print(out)
	return nil
}

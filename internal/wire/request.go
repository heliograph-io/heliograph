// Package wire is the request and status documents that cross the gap, and
// nothing else. It has no knowledge of how they travel.
//
// The format is `key: value`, one per line, because a transport repo is read
// by an operator on a machine nobody here can reach. When a loop is not doing
// what somebody expected, the first useful act is `cat station/request`, and
// that has to be legible without tooling, a schema, or us.
//
// JSON would be tidier to parse and worse at the only job that matters.
package wire

import (
	"bufio"
	"bytes"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Version is the protocol this build speaks. It is written into every request
// so that a station can refuse a document it does not understand rather than
// guess at it. Stations live in the field and the CLI will update faster than
// they do.
const Version = 1

// Request is what the control side publishes and the station acts on.
//
// The trigger is ID and only ID. Documentation, step edits and payload changes
// land on a task branch constantly; if any change fired a run, the station
// would run on all of them.
type Request struct {
	Version int
	ID      string // the trigger. A change here, and only here, starts a run
	Step    string // a registered name, or a path. Blank means the default
	Env     string // extra environment for the run, verbatim shell text
	Cancel  string // "yes" kills whatever is running; an id kills only that run
	Stop    string // "yes" ends the loop cleanly after the current run
	Note    string // free text for the next human. The station ignores it

	// THE SIGNED SCOPE, and every one of these exists because a signature over
	// "run this" turned out not to be enough.
	//
	//	Mode     the request says what it expects the step to be. A step file
	//	         edited from read-only to action between authoring and running
	//	         would otherwise carry the earlier decision's authority
	//	Target   the station this was written for, so a request captured from
	//	         one estate cannot be replayed at another. The relay binds this
	//	         in its envelope too; every other transport had nothing
	//	Expires  a captured request stops being valid. Without it, one taken
	//	         from a transport repo is good for ever
	//
	// All three are inside the document, so on the relay they are inside the
	// signature already: sign-then-encrypt covers the plaintext. Enforcing them
	// is what turns that into scope.
	Mode    string // read-only | action, as the author expects to find it
	Target  string // the station's scope: branch, station name, lane
	Expires string // RFC3339 UTC, after which the station refuses it

	// Trust carries a trusted-set change, verbatim.
	//
	// IT RIDES IN THE REQUEST because every transport already carries one, and a
	// second fetch verb would have to be implemented on all six. On the relay it
	// would be worse than awkward: collection deletes, so asking twice eats the
	// queue.
	//
	// wire does not parse it. The lines are `trust-*` keys, they are passed
	// through untouched, and internal/trust is the only thing that reads them -
	// so the document format and the trust schema can move independently, and
	// wire has no reason to import a package about authority.
	Trust []byte
}

// order fixes the sequence keys are written in. Stable output means a diff
// between two requests shows what changed rather than everything moving.
var order = []string{"version", "id", "step", "mode", "target", "expires", "env", "cancel", "stop", "note"}

func (r Request) field(k string) string {
	switch k {
	case "version":
		if r.Version == 0 {
			return ""
		}
		return strconv.Itoa(r.Version)
	case "id":
		return r.ID
	case "step":
		return r.Step
	case "mode":
		return r.Mode
	case "target":
		return r.Target
	case "expires":
		return r.Expires
	case "env":
		return r.Env
	case "cancel":
		return r.Cancel
	case "stop":
		return r.Stop
	case "note":
		return r.Note
	}
	return ""
}

// Validate refuses anything that would forge a second key.
//
// A newline inside a value ends the line the station is reading and starts one
// it was never sent. `id: x\nstop: yes` would stop a loop on a machine nobody
// can reach, and it would look like the loop had simply died. Refused here,
// where there is somebody to tell.
func (r Request) Validate() error {
	for _, k := range order {
		v := r.field(k)
		if strings.ContainsAny(v, "\n\r") {
			return fmt.Errorf("wire: %s contains a newline, which would forge a second key: %q", k, v)
		}
	}
	if r.ID == "" {
		return fmt.Errorf("wire: a request needs an id, which is the only thing that triggers a run")
	}
	switch r.Mode {
	case "", "read-only", "action":
	default:
		return fmt.Errorf("wire: mode %q is neither read-only nor action, and a station would refuse it on a machine nobody can reach", r.Mode)
	}
	if r.Expires != "" {
		if _, err := time.Parse(time.RFC3339, r.Expires); err != nil {
			return fmt.Errorf("wire: expires %q is not an RFC3339 UTC time, and a station that cannot parse it refuses the request", r.Expires)
		}
	}
	// A CHANGE IS ONE SIGNED ACT AND IT TRAVELS ALONE.
	//
	// The station reads `trust-op` with `sed -n` and takes the FIRST match, so a
	// document carrying two changes would silently apply one. And a request that
	// both alters authority and runs a step is one whose audit line cannot say
	// which of the two the author meant to be the point.
	if len(r.Trust) > 0 && r.Step != "" {
		return fmt.Errorf("wire: a request carries a trusted-set change or a step, not both: the change is the act, and a step alongside it has no audit line of its own")
	}
	for _, line := range bytes.Split(r.Trust, []byte("\n")) {
		k, _, ok := splitField(string(line))
		if !ok || len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		if !strings.HasPrefix(k, "trust-") {
			return fmt.Errorf("wire: %q is in the trust block and is not a trust- key: it would forge a request field", k)
		}
	}
	return nil
}

// Marshal renders the document.
//
// Every key is written even when its value is empty. sed does not need them,
// but the operator reading the file does: an absent `cancel:` gives no hint
// that cancelling is a thing they could do.
func (r Request) Marshal() []byte {
	var b bytes.Buffer
	for _, k := range order {
		if v := r.field(k); v != "" {
			fmt.Fprintf(&b, "%s: %s\n", k, v)
		} else {
			fmt.Fprintf(&b, "%s:\n", k)
		}
	}
	// Verbatim, and LAST. The station's `field` helper takes the first match of
	// a key, so appending cannot shadow one of the keys above.
	if len(r.Trust) > 0 {
		b.Write(r.Trust)
		if r.Trust[len(r.Trust)-1] != '\n' {
			b.WriteByte('\n')
		}
	}
	return b.Bytes()
}

// ParseRequest reads the document back.
//
// Unknown keys are ignored and missing keys are zero. Neither is an error: a
// station newer than this CLI will write keys we have never heard of, and
// refusing to read it would make the newer side unreadable by the older one,
// on exactly the machine nobody can reach to upgrade.
func ParseRequest(b []byte) (Request, error) {
	var r Request
	var trust []byte
	s := bufio.NewScanner(bytes.NewReader(b))
	s.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for s.Scan() {
		k, v, ok := splitField(s.Text())
		if !ok {
			continue
		}
		switch k {
		case "version":
			r.Version, _ = strconv.Atoi(v)
		case "id":
			r.ID = v
		case "step":
			r.Step = v
		case "env":
			r.Env = v
		case "cancel":
			r.Cancel = v
		case "stop":
			r.Stop = v
		case "note":
			r.Note = v
		case "mode":
			r.Mode = v
		case "target":
			r.Target = v
		case "expires":
			r.Expires = v
		default:
			// Collected rather than parsed. See Request.Trust.
			if strings.HasPrefix(k, "trust-") {
				trust = append(trust, s.Text()...)
				trust = append(trust, '\n')
			}
		}
	}
	r.Trust = trust
	return r, s.Err()
}

// splitField splits on the FIRST colon only.
//
// Values carry colons routinely - a URL, a time, a PATH - and splitting on
// every one truncates them silently. The station splits on the first, so this
// does too. Disagreeing about that would be a bug nobody could see from either
// side of the gap.
func splitField(line string) (key, value string, ok bool) {
	i := strings.IndexByte(line, ':')
	if i < 0 {
		return "", "", false
	}
	return strings.TrimSpace(line[:i]), strings.TrimSpace(line[i+1:]), true
}

// NewID builds a trigger that sorts by time and says what it asked for.
//
// A bare timestamp would be enough to trigger a run and useless in a status
// line three days later. The step name is what makes `git log` readable.
func NewID(step string, t time.Time) string {
	stamp := t.UTC().Format("20060102T150405Z")
	name := strings.TrimSuffix(step, ".sh")
	name = strings.TrimSuffix(name, ".ps1")
	// A step given by path is ordinary, but a slash in an id reads as a path
	// and invites somebody to treat it as one.
	if i := strings.LastIndexByte(name, '/'); i >= 0 {
		name = name[i+1:]
	}
	if name == "" {
		return stamp
	}
	return stamp + "-" + name
}

// IDTime reads the send time back out of an id NewID built. ok is false for an
// id that did not come from NewID, which a station may well hold: an operator
// can write any id into a request by hand.
//
// It is what lets the control side tell a station that has not reached a
// request yet from one that has moved PAST it. The first is worth waiting for.
// The second never produces the request's own status, so waiting on it is
// waiting for ever.
func IDTime(id string) (time.Time, bool) {
	const layout = "20060102T150405Z"
	if len(id) < len(layout) {
		return time.Time{}, false
	}
	t, err := time.Parse(layout, id[:len(layout)])
	if err != nil {
		return time.Time{}, false
	}
	if len(id) > len(layout) && id[len(layout)] != '-' {
		return time.Time{}, false
	}
	return t, true
}

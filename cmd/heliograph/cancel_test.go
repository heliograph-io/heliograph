package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/heliograph-io/heliograph/internal/estate"
	"github.com/heliograph-io/heliograph/internal/wire"
)

// These stand in for the far side by writing its status by hand, over a share
// estate, and read back the request the tools wrote. The station's own half is
// in cancel_e2e_test.go.

func readRequest(t *testing.T, d string) wire.Request {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(d, "request"))
	if err != nil {
		t.Fatalf("no request in the slot: %v", err)
	}
	r, err := wire.ParseRequest(b)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// A cancel keeps the request in the slot, including one queued behind the
// running step. Writing a new request instead would replace the queued one,
// and a new id would start a run once the cancel had landed.
func TestCancelKeepsTheQueuedRequest(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "status"),
		"state:    running\nid:       20260901T100000Z-slow\nstep:     slow\nbranch:   probe\n")
	write(t, filepath.Join(d, "request"),
		"version: 1\nid: 20260901T100500Z-env\nstep: env\ncancel:\nstop:\nnote: queued\n")

	out, err := call(t, "heliograph_cancel", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	r := readRequest(t, d)
	if r.ID != "20260901T100500Z-env" || r.Step != "env" || r.Note != "queued" {
		t.Errorf("the queued request did not survive the cancel: %+v", r)
	}
	if r.Cancel != "20260901T100000Z-slow" {
		t.Errorf("the cancel does not name the running id: %q", r.Cancel)
	}
	if !strings.Contains(out, "still queued") {
		t.Errorf("the reply does not say the queued request still runs:\n%s", out)
	}

	// Again, and nothing is rewritten.
	again, err := call(t, "heliograph_cancel", map[string]any{})
	if err != nil || !strings.Contains(again, "already published") {
		t.Errorf("a second cancel did not say one is already published (err %v):\n%s", err, again)
	}
}

// A cancel only stops a run. The station ignores a `cancel:` that was already
// in the slot when a step started, so one sent for a request it has not read
// would not stop that request: it would run anyway.
func TestCancelRefusesWhatIsNotRunning(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "status"), "state:    idle\nid:       20260901T100000Z-env\nbranch:   probe\n")

	if out, err := call(t, "heliograph_cancel", map[string]any{}); err == nil || !strings.Contains(err.Error(), "nothing to cancel") {
		t.Errorf("a cancel with nothing running was sent (err %v):\n%s", err, out)
	}
	if _, err := os.Stat(filepath.Join(d, "request")); err == nil {
		t.Error("a refused cancel wrote a request anyway")
	}

	write(t, filepath.Join(d, "status"), "state:    running\nid:       20260901T100000Z-env\nbranch:   probe\n")
	_, err := call(t, "heliograph_cancel", map[string]any{"id": "20260901T090000Z-old"})
	if err == nil || !strings.Contains(err.Error(), "not the running step") {
		t.Errorf("a cancel for an id that is not running was sent: %v", err)
	}
}

// Everywhere but git and a share the station reads a request between runs, so
// a cancel would arrive after the step had finished. Refused, not published.
func TestCancelRefusesATransportThatCannotHearIt(t *testing.T) {
	root := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(root, "config"))
	out := filepath.Join(root, "outbox")
	e := estate.Estate{Name: "airgap", Transport: "bundle", Dir: out}
	if err := e.Save(); err != nil {
		t.Fatal(err)
	}
	_, err := call(t, "heliograph_cancel", map[string]any{})
	if err == nil || !strings.Contains(err.Error(), "between runs") {
		t.Errorf("a cancel over a bundle was not refused: %v", err)
	}

	// Stop still works there: it is read between runs, which is when it acts.
	if _, err := call(t, "heliograph_stop", map[string]any{}); err != nil {
		t.Errorf("a stop over a bundle was refused: %v", err)
	}
	ents, _ := os.ReadDir(out)
	if len(ents) != 1 {
		t.Fatalf("the stop wrote %d bundles, want 1", len(ents))
	}
	b, _ := os.ReadFile(filepath.Join(out, ents[0].Name()))
	if r, _ := wire.ParseRequest(b); r.Stop != "yes" || r.Step != "" {
		t.Errorf("the stop bundle is not a stop that names no step:\n%s", b)
	}
}

// A stop keeps the id in the slot, which the station has already read, so it
// can never start a run.
func TestStopKeepsTheIDTheStationRead(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "status"), "state:    idle\nid:       20260901T100000Z-env\nbranch:   probe\n")
	write(t, filepath.Join(d, "request"), "version: 1\nid: 20260901T100000Z-env\nstep: env\ncancel:\nstop:\nnote:\n")

	out, err := call(t, "heliograph_stop", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	r := readRequest(t, d)
	if r.Stop != "yes" || r.ID != "20260901T100000Z-env" {
		t.Errorf("the stop did not keep the id the station read: %+v", r)
	}
	if !strings.Contains(out, "stop sent") || !strings.Contains(out, "send the next step before") {
		t.Errorf("the reply does not say what a restart will do:\n%s", out)
	}
	again, err := call(t, "heliograph_stop", map[string]any{})
	if err != nil || !strings.Contains(again, "already published") {
		t.Errorf("a second stop did not say one is already published (err %v):\n%s", err, again)
	}
}

// cancelHeard is the station's `live` capability, copied. Read from both
// stations' transports, so a transport that gains or loses a mid-run read fails
// here until `cancel` agrees.
func TestCancelHeardMatchesTheStation(t *testing.T) {
	dir := stationDir(t)
	bashCaps := regexp.MustCompile(`tp_capabilities\(\)\s*\{\s*printf '([^']*)`)
	psCaps := regexp.MustCompile(`function Get-TpCapabilities\s*\{\s*return '([^']*)'`)
	checked := 0
	for _, name := range initTransports {
		for _, f := range []struct {
			path string
			re   *regexp.Regexp
		}{
			{filepath.Join(dir, "station", "bash", "transports", name+".sh"), bashCaps},
			{filepath.Join(dir, "station", "powershell", "transports", name+".psm1"), psCaps},
		} {
			b, err := os.ReadFile(f.path)
			if os.IsNotExist(err) {
				continue
			}
			if err != nil {
				t.Fatal(err)
			}
			m := f.re.FindStringSubmatch(string(b))
			if m == nil {
				t.Errorf("%s declares no capabilities this test can read", f.path)
				continue
			}
			checked++
			live := strings.Contains(" "+strings.TrimSpace(strings.TrimSuffix(m[1], `\n`))+" ", " live ")
			if live != cancelHeard[name] {
				t.Errorf("%s: the station's live read is %v and cancelHeard[%q] is %v", f.path, live, name, cancelHeard[name])
			}
		}
	}
	if checked < len(initTransports) {
		t.Fatalf("read %d capability lists for %d transports, so some went unchecked", checked, len(initTransports))
	}
}

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// heliograph_wait against a share estate whose status this test writes by
// hand, standing in for the far side. There was no watch tool, so an agent
// polled heliograph_status once per tool call.

// waitCall runs heliograph_wait and records the progress it reports.
func waitCall(t *testing.T, args map[string]any) (string, []string, error) {
	t.Helper()
	saved := waitPoll
	waitPoll = 50 * time.Millisecond
	t.Cleanup(func() { waitPoll = saved })
	var lines []string
	last := -1.0
	for _, tl := range tools() {
		if tl.Name != "heliograph_wait" {
			continue
		}
		out, err := tl.CallWithProgress(args, func(done, total float64, msg string) {
			if done <= last {
				t.Errorf("progress went from %v to %v: it has to grow", last, done)
			}
			last = done
			lines = append(lines, msg)
		})
		return out, lines, err
	}
	t.Fatal("no heliograph_wait tool")
	return "", nil, nil
}

func TestWaitReturnsWhenTheRunEnds(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	id := "20260901T100000Z-slow"
	write(t, filepath.Join(d, "status"), "state:    running\nid:       "+id+"\nprogress: 12 lines\nbranch:   probe\n")
	// The station finishing, a moment later. os.WriteFile rather than write():
	// a helper that can t.Fatal must not run outside the test's goroutine.
	go func() {
		time.Sleep(300 * time.Millisecond)
		_ = os.WriteFile(filepath.Join(d, "status"),
			[]byte("state:    idle\nid:       "+id+"\nexit:     0\nlog:      ops-logs/slow-20260901T100000Z.txt\nbranch:   probe\n"), 0o644)
	}()

	out, lines, err := waitCall(t, map[string]any{"id": id, "max_seconds": float64(20)})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "state: idle") || !strings.Contains(out, "heliograph_read_log") {
		t.Errorf("wait did not return the finished status and where to read it:\n%s", out)
	}
	if len(lines) == 0 || !strings.Contains(lines[0], "running, 12 lines") {
		t.Errorf("wait reported no progress while the step ran: %q", lines)
	}
}

// At its limit it returns what it knows and says the run carries on, rather
// than failing: the request is still good.
func TestWaitSaysNotPickedUpAtItsLimit(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "status"), "state:    idle\nid:       20260901T090000Z-env\nbranch:   probe\n")

	start := time.Now()
	out, _, err := waitCall(t, map[string]any{"id": "20260901T100000Z-slow", "max_seconds": 0.3})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "Not finished after 0.3s: not picked up yet: 20260901T100000Z-slow") ||
		!strings.Contains(out, "Call heliograph_wait again") {
		t.Errorf("the limit did not say where the request is and how to carry on:\n%s", out)
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Errorf("a 0.3s wait took %s", d)
	}
}

// A station that has moved past the request never reports it again, so the
// wait stops at once rather than at its limit.
func TestWaitStopsWhenTheStationHasMovedPast(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "status"), "state:    idle\nid:       20260901T110000Z-env\nbranch:   probe\n")

	start := time.Now()
	out, _, err := waitCall(t, map[string]any{"id": "20260901T100000Z-slow", "max_seconds": float64(30)})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "moved on to 20260901T110000Z-env") {
		t.Errorf("wait did not say the station moved past the request:\n%s", out)
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Errorf("wait held on for %s for a request that will never report", d)
	}
}

func TestWaitRefusesAnUnboundedOrMissingArgument(t *testing.T) {
	share := estateOnDisk(t)
	scopeDir(t, share)
	for _, args := range []map[string]any{
		{},
		{"id": "x", "max_seconds": float64(0)},
		{"id": "x", "max_seconds": float64(waitMax + 1)},
		{"id": "x", "max_seconds": "60"},
	} {
		if _, _, err := waitCall(t, args); err == nil {
			t.Errorf("wait accepted %v", args)
		}
	}
}

// A client lets a model call a read-only tool without asking. These are the
// tools that change nothing anywhere, and exactly these.
func TestReadOnlyToolsAreMarkedAndNoOthers(t *testing.T) {
	want := map[string]bool{
		"heliograph_estates": true, "heliograph_status": true, "heliograph_wait": true,
		"heliograph_logs": true, "heliograph_read_log": true, "heliograph_gaps": true,
		"heliograph_doctor": true,
	}
	for _, tl := range tools() {
		if tl.ReadOnly != want[tl.Name] {
			t.Errorf("%s: ReadOnly is %v, want %v", tl.Name, tl.ReadOnly, want[tl.Name])
		}
	}
}

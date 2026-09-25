package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The test that matters.
//
// Everything in internal/ can pass while the CLI and the station quietly
// disagree about the document they share, because both halves are checked
// against our own idea of the format. This one drives a real, unmodified
// station with the real binary and asserts that a log came back with the
// step's output in it.
//
// The station lives in this repository now, so the default is the checkout
// this test is running in and nothing skips. HELIOGRAPH_STATION_DIR overrides
// it, for running against an external station checkout, and the resolved
// directory FAILS rather than skips when it is wrong: a silently skipped
// end-to-end test is the same shape of problem as a green suite that checked
// nothing.

func stationDir(t *testing.T) string {
	t.Helper()
	dir := os.Getenv("HELIOGRAPH_STATION_DIR")
	if dir == "" {
		// This file lives in cmd/heliograph, two levels below the repo root.
		abs, err := filepath.Abs(filepath.Join("..", ".."))
		if err != nil {
			t.Fatal(err)
		}
		dir = abs
	}
	bootstrap := filepath.Join(dir, "station", "bootstrap.sh")
	if _, err := os.Stat(bootstrap); err != nil {
		t.Fatalf("%s does not carry a station (no station/bootstrap.sh): %v", dir, err)
	}
	return dir
}

// NO BACKGROUND GIT, and this is a flake fix rather than a tidiness one.
//
// `git commit` and `git push` run `git gc --auto`, which DETACHES. It is still
// writing into .git when the test returns, and t.TempDir's cleanup then fails:
//
//	TempDir RemoveAll cleanup: unlinkat .../work/.git: directory not empty
//
// That fails the test AFTER every assertion in it has passed, which is the
// worst shape a flake can have - the failure names a directory rather than
// anything the test was checking. Seen on CI in TestGapsFindsARealStall; it can
// hit any test in this package, because they all commit into a temporary repo.
//
// Set in the ENVIRONMENT rather than as repo config, so it reaches the repos
// bootstrap.sh and station.sh create for themselves - which are the ones doing
// the pushing - and every git the CLI runs as a child.
var noBackgroundGit = []string{
	"GIT_CONFIG_COUNT=2",
	"GIT_CONFIG_KEY_0=gc.auto", "GIT_CONFIG_VALUE_0=0",
	"GIT_CONFIG_KEY_1=maintenance.auto", "GIT_CONFIG_VALUE_1=false",
}

// quietOrigin stops the bare "remote" doing maintenance of its own after a push.
//
// noBackgroundGit does not reach it. For a push to a path, git starts
// receive-pack on the far repository with GIT_CONFIG_COUNT and friends REMOVED
// from its environment, so the origin runs its own auto maintenance, detached,
// and it can still be writing into origin.git/objects when the test returns:
//
//	TempDir RemoveAll cleanup: unlinkat .../origin.git/objects: directory not empty
//
// Seen on CI (git 2.55) in TestWatchWaitsForTheRequestJustSent, which pushes
// more often than most. The stripping was checked rather than assumed: a
// post-receive hook in the origin, pushed to with GIT_CONFIG_COUNT set, sees it
// unset and gc.auto at its default, and sees gc.auto=0 once it is in the
// origin's own config. So the setting goes there, for every bare origin in this
// package, since any test that pushes can hit it.
func quietOrigin(t *testing.T, origin string) {
	t.Helper()
	for _, kv := range [][2]string{{"receive.autogc", "false"}, {"gc.auto", "0"}, {"maintenance.auto", "false"}} {
		sh(t, origin, "git", "config", kv[0], kv[1])
	}
}

func sh(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=ci", "GIT_AUTHOR_EMAIL=ci@example.invalid",
		"GIT_COMMITTER_NAME=ci", "GIT_COMMITTER_EMAIL=ci@example.invalid",
	)
	cmd.Env = append(cmd.Env, noBackgroundGit...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %v\n%s", args, err, out)
	}
	return string(out)
}

func TestCLIDrivesAStockStation(t *testing.T) {
	station := stationDir(t)
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}

	base := t.TempDir()
	origin := filepath.Join(base, "origin.git")
	work := filepath.Join(base, "work")
	cfg := filepath.Join(base, "config")

	// A transport repo built by the station's own bootstrap.sh. Not a fixture we
	// wrote: if the station changes what it lays down, this notices.
	sh(t, base, filepath.Join(station, "station", "bootstrap.sh"), work)
	sh(t, base, "git", "init", "-q", "-b", "main", "--bare", origin)
	quietOrigin(t, origin)
	sh(t, work, "git", "init", "-q", "-b", "main")
	sh(t, work, "git", "remote", "add", "origin", origin)

	step := "#!/usr/bin/env bash\n# heliograph-mode: read-only\necho THE-MEASUREMENT-CAME-BACK\n"
	if err := os.WriteFile(filepath.Join(work, "steps", "probe.sh"), []byte(step), 0o755); err != nil {
		t.Fatal(err)
	}
	sh(t, work, "git", "add", "-A")
	sh(t, work, "git", "commit", "-qm", "init")
	sh(t, work, "git", "push", "-q", "-u", "origin", "main")

	// Build and run the real binary, not the functions behind it. Argument
	// parsing and printing are where a CLI usually goes wrong.
	bin := filepath.Join(base, "heliograph")
	sh(t, ".", "go", "build", "-o", bin, "github.com/heliograph-io/heliograph/cmd/heliograph")

	hg := func(args ...string) string {
		t.Helper()
		cmd := exec.Command(bin, args...)
		cmd.Dir = base
		cmd.Env = append(append(os.Environ(), "XDG_CONFIG_HOME="+cfg), noBackgroundGit...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("heliograph %v: %v\n%s", args, err, out)
		}
		return string(out)
	}

	// init
	if out := hg("init", "e2e", "--dir", work); !strings.Contains(out, "main") {
		t.Errorf("init did not report the branch:\n%s", out)
	}

	// send
	out := hg("send", "steps/probe.sh")
	if !strings.Contains(out, "sent ") {
		t.Errorf("send did not report an id:\n%s", out)
	}

	// The station, run once, exactly as an operator would. Nothing about it is
	// modified for this test, and PUSH is left at its default: a log that is
	// captured but never pushed is the failure this whole loop exists to
	// prevent, so the test must not quietly arrange for it.
	sh(t, work, "bash", "./station.sh", "--once", "--interval", "1")

	// status, read back through the CLI
	if s := hg("status"); !strings.Contains(s, "idle") {
		t.Errorf("status after a completed run:\n%s", s)
	}

	// and the log itself
	logs := hg("logs")
	if !strings.Contains(logs, "probe-") {
		t.Fatalf("no log came back:\n%s", logs)
	}
	body := hg("logs", "--last")
	if !strings.Contains(body, "THE-MEASUREMENT-CAME-BACK") {
		t.Errorf("the log does not contain the step's output:\n%s", body)
	}
	// The property the whole toolkit exists for. If the CLI ever reformats a
	// log on the way out, this is what notices.
	if !strings.Contains(body, " | THE-MEASUREMENT-CAME-BACK") {
		t.Errorf("the captured line lost its timestamp column:\n%s", body)
	}
	if !strings.Contains(body, "RESULT       : OK") {
		t.Errorf("the log has no footer:\n%s", body)
	}
}

// --gaps is the reason the binary is worth installing, so it is proved against
// a real captured log rather than a fixture we wrote. The step sleeps, and the
// gap has to appear attributed to the line before it.
func TestGapsFindsARealStall(t *testing.T) {
	station := stationDir(t)
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}

	base := t.TempDir()
	origin := filepath.Join(base, "origin.git")
	work := filepath.Join(base, "work")
	cfg := filepath.Join(base, "config")

	sh(t, base, filepath.Join(station, "station", "bootstrap.sh"), work)
	sh(t, base, "git", "init", "-q", "-b", "main", "--bare", origin)
	quietOrigin(t, origin)
	sh(t, work, "git", "init", "-q", "-b", "main")
	sh(t, work, "git", "remote", "add", "origin", origin)

	step := "#!/usr/bin/env bash\n# heliograph-mode: read-only\n" +
		"echo STARTING-THE-SLOW-THING\nsleep 4\necho DONE\n"
	if err := os.WriteFile(filepath.Join(work, "steps", "slow.sh"), []byte(step), 0o755); err != nil {
		t.Fatal(err)
	}
	sh(t, work, "git", "add", "-A")
	sh(t, work, "git", "commit", "-qm", "init")
	sh(t, work, "git", "push", "-q", "-u", "origin", "main")

	bin := filepath.Join(base, "heliograph")
	sh(t, ".", "go", "build", "-o", bin, "github.com/heliograph-io/heliograph/cmd/heliograph")
	hg := func(args ...string) string {
		t.Helper()
		cmd := exec.Command(bin, args...)
		cmd.Dir = base
		cmd.Env = append(append(os.Environ(), "XDG_CONFIG_HOME="+cfg), noBackgroundGit...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("heliograph %v: %v\n%s", args, err, out)
		}
		return string(out)
	}

	hg("init", "gaps", "--dir", work)
	hg("send", "steps/slow.sh")
	sh(t, work, "bash", "./station.sh", "--once", "--interval", "1")

	out := hg("logs", "--last", "--gaps", "--min", "3s")
	if !strings.Contains(out, "STARTING-THE-SLOW-THING") {
		t.Errorf("the gap was not attributed to the line that was running:\n%s", out)
	}
	// And the ordinary intervals must not be reported, or the signal is buried.
	if strings.Contains(out, "| DONE") {
		t.Errorf("a line that did not stall was reported as a gap:\n%s", out)
	}
}

// The same test, over the share transport.
//
// WHY A SECOND ONE RATHER THAN A TABLE. This is the only assertion in the
// repository that both halves of the share transport agree about where the
// documents live, and it is worth being able to fail on its own. The control
// side has existed since A3; the station side did not, so `heliograph init
// --transport share` wrote requests into a directory nothing could read and
// nothing said so. Two implementations of a layout, on opposite sides of a gap
// nobody can reach, is exactly the shape that needs measuring rather than
// reviewing.
//
// THE STEP IS PLANTED, NOT SENT, and that is a real difference rather than a
// convenience here. On git the step file travels in the repository, so `send`
// makes it available. A share carries the request, the status and the logs and
// nothing else, so the steps have to be on the station already - which is what
// `heliograph plant` means by having nothing to clone.
func TestCLIDrivesAShareStation(t *testing.T) {
	station := stationDir(t)
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}

	base := t.TempDir()
	mount := filepath.Join(base, "mnt") // the share, as both sides see it
	work := filepath.Join(base, "work") // the station's payload
	cfg := filepath.Join(base, "config")
	if err := os.MkdirAll(mount, 0o755); err != nil {
		t.Fatal(err)
	}

	// The station's own bootstrap, not a fixture: if it stops shipping
	// transports/share.sh this notices.
	sh(t, base, filepath.Join(station, "station", "bootstrap.sh"), work)

	step := "#!/usr/bin/env bash\n# heliograph-mode: read-only\necho THE-SHARE-CARRIED-IT\n"
	if err := os.WriteFile(filepath.Join(work, "steps", "probe.sh"), []byte(step), 0o755); err != nil {
		t.Fatal(err)
	}

	bin := filepath.Join(base, "heliograph")
	sh(t, ".", "go", "build", "-o", bin, "github.com/heliograph-io/heliograph/cmd/heliograph")
	hg := func(args ...string) string {
		t.Helper()
		cmd := exec.Command(bin, args...)
		cmd.Dir = base
		cmd.Env = append(append(os.Environ(), "XDG_CONFIG_HOME="+cfg), noBackgroundGit...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("heliograph %v: %v\n%s", args, err, out)
		}
		return string(out)
	}

	hg("init", "shared", "--transport", "share", "--dir", mount, "--scope", "dns-timeouts")
	if out := hg("send", "steps/probe.sh"); !strings.Contains(out, "sent ") {
		t.Fatalf("send did not report an id:\n%s", out)
	}

	// The station, run once, exactly as an operator would - through start.sh,
	// which is the command they are actually told to type, rather than
	// station.sh directly. PUSH is left at its default: a log captured and
	// never delivered is the failure this loop exists to prevent, so the test
	// must not quietly arrange for it.
	cmd := exec.Command("bash", "./start.sh", "--", "--once", "--interval", "1")
	cmd.Dir = work
	cmd.Env = append(os.Environ(),
		"TRANSPORT=share", "SHARE_DIR="+mount, "SHARE_SCOPE=dns-timeouts")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("the share station did not run: %v\n%s", err, out)
	}

	if s := hg("status"); !strings.Contains(s, "idle") {
		t.Errorf("status after a completed run:\n%s", s)
	}
	logs := hg("logs")
	if !strings.Contains(logs, "probe-") {
		t.Fatalf("no log came back over the share:\n%s", logs)
	}
	body := hg("logs", "--last")
	if !strings.Contains(body, "THE-SHARE-CARRIED-IT") {
		t.Errorf("the log does not contain the step's output:\n%s", body)
	}
	if !strings.Contains(body, " | THE-SHARE-CARRIED-IT") {
		t.Errorf("the captured line lost its timestamp column:\n%s", body)
	}
	if !strings.Contains(body, "RESULT       : OK") {
		t.Errorf("the log has no footer, so the far side cannot tell a finished run from a hung one:\n%s", body)
	}
}

// `watch` straight after `send` waits for the request just sent.
//
// The station's status describes the last request it READ, and for a whole poll
// interval after a send that is the previous one. `watch` used to stop on the
// first finished state it saw, so it reported the previous run as the result.
// After an earlier refusal it told the reader to restart the station with
// --allow-actions, for a request the station had not read yet.
//
// Two sends against a real station: the first is refused, the second is sent
// and watched BEFORE the station runs again. The watch must not report the
// refusal, and must report the second run once it has happened.
func TestWatchWaitsForTheRequestJustSent(t *testing.T) {
	station := stationDir(t)
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}

	base := t.TempDir()
	origin := filepath.Join(base, "origin.git")
	work := filepath.Join(base, "work")
	cfg := filepath.Join(base, "config")

	sh(t, base, filepath.Join(station, "station", "bootstrap.sh"), work)
	sh(t, base, "git", "init", "-q", "-b", "main", "--bare", origin)
	quietOrigin(t, origin)
	sh(t, work, "git", "init", "-q", "-b", "main")
	sh(t, work, "git", "remote", "add", "origin", origin)

	// No mode declaration, so the station refuses it.
	undeclared := "#!/usr/bin/env bash\necho NEVER-RUNS\n"
	probe := "#!/usr/bin/env bash\n# heliograph-mode: read-only\necho THE-SECOND-REQUEST-RAN\n"
	for name, body := range map[string]string{"undeclared.sh": undeclared, "probe.sh": probe} {
		if err := os.WriteFile(filepath.Join(work, "steps", name), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	sh(t, work, "git", "add", "-A")
	sh(t, work, "git", "commit", "-qm", "init")
	sh(t, work, "git", "push", "-q", "-u", "origin", "main")

	bin := filepath.Join(base, "heliograph")
	sh(t, ".", "go", "build", "-o", bin, "github.com/heliograph-io/heliograph/cmd/heliograph")
	run := func(args ...string) (string, error) {
		t.Helper()
		cmd := exec.Command(bin, args...)
		cmd.Dir = base
		cmd.Env = append(append(os.Environ(), "XDG_CONFIG_HOME="+cfg), noBackgroundGit...)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	hg := func(args ...string) string {
		t.Helper()
		out, err := run(args...)
		if err != nil {
			t.Fatalf("heliograph %v: %v\n%s", args, err, out)
		}
		return out
	}
	sentID := func(out string) string {
		t.Helper()
		first := strings.SplitN(out, "\n", 2)[0]
		if !strings.HasPrefix(first, "sent ") {
			t.Fatalf("send did not report an id:\n%s", out)
		}
		return strings.TrimPrefix(first, "sent ")
	}

	hg("init", "e2e", "--dir", work)
	first := sentID(hg("send", "steps/undeclared.sh"))
	sh(t, work, "bash", "./station.sh", "--once", "--interval", "1")
	if s := hg("status"); !strings.Contains(s, "refused") || !strings.Contains(s, first) {
		t.Fatalf("the first request was not refused, so this test proves nothing:\n%s", s)
	}

	// An id carries the time to the second, and "sent after" can only be told
	// apart across a second boundary. On a fast runner both sends land in the
	// same second, and the superseded check at the end then cannot fire.
	time.Sleep(1100 * time.Millisecond)
	second := sentID(hg("send", "steps/probe.sh"))

	// The station has not run since, so the only finished state on the far
	// side is the first request's refusal.
	out, err := run("watch", "--interval", "1s", "--timeout", "3s")
	if err == nil {
		t.Fatalf("watch returned a result for a request the station has not read:\n%s", out)
	}
	if strings.Contains(out, "--allow-actions") || strings.Contains(out, "refused:") {
		t.Errorf("watch reported the earlier refusal as this request's result:\n%s", out)
	}
	if !strings.Contains(out, "not picked up") || !strings.Contains(out, second) {
		t.Errorf("watch did not say the request it is waiting for has not been picked up:\n%s", out)
	}
	if s := hg("status"); !strings.Contains(s, "not picked up yet: "+second) {
		t.Errorf("status did not say the request just sent has not been picked up:\n%s", s)
	}

	sh(t, work, "bash", "./station.sh", "--once", "--interval", "1")

	done := hg("watch", "--interval", "1s", "--timeout", "10s")
	if !strings.Contains(done, "log:") || !strings.Contains(done, "probe") {
		t.Errorf("watch did not report the second run once it had happened:\n%s", done)
	}
	if body := hg("logs", "--last"); !strings.Contains(body, "THE-SECOND-REQUEST-RAN") {
		t.Errorf("the last log is not the second request's:\n%s", body)
	}

	// A named id the station has moved past is never reported again, so
	// watching it must stop rather than wait for ever.
	if out, err := run("watch", first, "--interval", "1s", "--timeout", "5s"); err == nil ||
		!strings.Contains(out, "moved on to "+second) {
		t.Errorf("watching a superseded request did not stop and say why (err %v):\n%s", err, out)
	}
}

// The example every page leads with runs on a stock station, and a step that
// does not exist is refused with a reason the reader can see.
//
// `heliograph send net-probe` was refused on every freshly bootstrapped
// station: run.sh registered the step as `net`. The station then published
// "declares no mode ()", because it threw away the exit code that says "no such
// step". And `status` and `watch` never printed the station's `reason:` at all,
// only generic advice about --allow-actions, so the reader could not have seen
// even the wrong reason.
func TestTheDocumentedStepRunsAndAnUnknownOneSaysWhy(t *testing.T) {
	station := stationDir(t)
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}

	base := t.TempDir()
	origin := filepath.Join(base, "origin.git")
	work := filepath.Join(base, "work")
	cfg := filepath.Join(base, "config")

	sh(t, base, filepath.Join(station, "station", "bootstrap.sh"), work)
	sh(t, base, "git", "init", "-q", "-b", "main", "--bare", origin)
	quietOrigin(t, origin)
	sh(t, work, "git", "init", "-q", "-b", "main")
	sh(t, work, "git", "remote", "add", "origin", origin)
	sh(t, work, "git", "add", "-A")
	sh(t, work, "git", "commit", "-qm", "init")
	sh(t, work, "git", "push", "-q", "-u", "origin", "main")

	bin := filepath.Join(base, "heliograph")
	sh(t, ".", "go", "build", "-o", bin, "github.com/heliograph-io/heliograph/cmd/heliograph")
	hg := func(args ...string) string {
		t.Helper()
		cmd := exec.Command(bin, args...)
		cmd.Dir = base
		cmd.Env = append(append(os.Environ(), "XDG_CONFIG_HOME="+cfg), noBackgroundGit...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("heliograph %v: %v\n%s", args, err, out)
		}
		return string(out)
	}

	hg("init", "e2e", "--dir", work)

	// The flagship example, exactly as the README types it. With no HOSTS the
	// step exits 2 and says why, which is still a run with a log.
	hg("send", "net-probe")
	sh(t, work, "bash", "./station.sh", "--once", "--interval", "1")
	if s := hg("status"); !strings.Contains(s, "state:    idle") {
		t.Fatalf("net-probe did not run on a stock station:\n%s", s)
	}
	if logs := hg("logs"); !strings.Contains(logs, "net-probe-") {
		t.Errorf("net-probe left no log:\n%s", logs)
	}

	hg("send", "no-such-step")
	sh(t, work, "bash", "./station.sh", "--once", "--interval", "1")
	s := hg("status")
	if !strings.Contains(s, "reason:   unknown step 'no-such-step'") {
		t.Errorf("status did not print the station's reason, or the reason is not \"unknown step\":\n%s", s)
	}
	// The `actions:` line names --allow-actions as a property of the station,
	// so the check is for the generic ADVICE, which is about the request.
	if strings.Contains(s, "declares no mode") || strings.Contains(s, "an action step needs") {
		t.Errorf("an unknown step was explained as a missing mode or a missing flag:\n%s", s)
	}
	w := hg("watch", "--interval", "1s", "--timeout", "10s")
	if !strings.Contains(w, "reason: unknown step 'no-such-step'") {
		t.Errorf("watch did not print the station's reason:\n%s", w)
	}
}

// A send from a branch no station reads is refused, naming both branches.
//
// SKILL.md told an agent to cut `task/<slug>`, commit and send. The branch
// inherits main's station/status, and a station still on main never reads it,
// so the request waited for nothing while `watch` and `doctor` reported main's
// last run as the answer. The status names the branch it was published from,
// which is all the CLI needs to notice.
//
// And the other half: `station add` cuts a branch too, and the send it prints
// must still go through before the new station has ever run.
func TestSendRefusesABranchNoStationReads(t *testing.T) {
	station := stationDir(t)
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}

	base := t.TempDir()
	origin := filepath.Join(base, "origin.git")
	work := filepath.Join(base, "work")
	cfg := filepath.Join(base, "config")

	sh(t, base, filepath.Join(station, "station", "bootstrap.sh"), work)
	sh(t, base, "git", "init", "-q", "-b", "main", "--bare", origin)
	quietOrigin(t, origin)
	sh(t, work, "git", "init", "-q", "-b", "main")
	sh(t, work, "git", "remote", "add", "origin", origin)
	// A step of our own rather than `env`, which probes the network and the
	// cloud CLIs and takes as long as this machine makes it take.
	probe := "#!/usr/bin/env bash\n# heliograph-mode: read-only\necho PROBED\n"
	if err := os.WriteFile(filepath.Join(work, "steps", "probe.sh"), []byte(probe), 0o755); err != nil {
		t.Fatal(err)
	}
	sh(t, work, "git", "add", "-A")
	sh(t, work, "git", "commit", "-qm", "init")
	sh(t, work, "git", "push", "-q", "-u", "origin", "main")

	bin := filepath.Join(base, "heliograph")
	sh(t, ".", "go", "build", "-o", bin, "github.com/heliograph-io/heliograph/cmd/heliograph")
	run := func(args ...string) (string, error) {
		t.Helper()
		cmd := exec.Command(bin, args...)
		cmd.Dir = base
		cmd.Env = append(append(os.Environ(), "XDG_CONFIG_HOME="+cfg,
			"GIT_AUTHOR_NAME=ci", "GIT_AUTHOR_EMAIL=ci@example.invalid",
			"GIT_COMMITTER_NAME=ci", "GIT_COMMITTER_EMAIL=ci@example.invalid"), noBackgroundGit...)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	hg := func(args ...string) string {
		t.Helper()
		out, err := run(args...)
		if err != nil {
			t.Fatalf("heliograph %v: %v\n%s", args, err, out)
		}
		return out
	}

	// A station that has run on main, so main carries a status naming main.
	hg("init", "e2e", "--dir", work)
	hg("send", "steps/probe.sh")
	sh(t, work, "bash", "./station.sh", "--once", "--interval", "1")
	sh(t, work, "git", "pull", "-q", "--rebase", "origin", "main")

	// The workflow SKILL.md used to give: cut a task branch, push it, send.
	sh(t, work, "git", "checkout", "-q", "-b", "task/x")
	sh(t, work, "git", "push", "-q", "-u", "origin", "task/x")

	before := sh(t, work, "git", "ls-remote", "origin", "refs/heads/task/x")
	out, err := run("send", "steps/probe.sh")
	if err == nil {
		t.Fatalf("send published to a branch no station reads:\n%s", out)
	}
	if !strings.Contains(out, `"main"`) || !strings.Contains(out, `"task/x"`) {
		t.Errorf("the refusal does not name both branches:\n%s", out)
	}
	if after := sh(t, work, "git", "ls-remote", "origin", "refs/heads/task/x"); after != before {
		t.Error("the refused request reached the remote anyway")
	}

	w, _ := run("watch", "--interval", "1s", "--timeout", "2s")
	if !strings.Contains(w, "warning:") || !strings.Contains(w, `"main"`) || !strings.Contains(w, `"task/x"`) {
		t.Errorf("watch did not warn that the status is another branch's:\n%s", w)
	}
	d, err := run("doctor")
	if err == nil || !strings.Contains(d, "FAIL") || !strings.Contains(d, `"main"`) || !strings.Contains(d, `"task/x"`) {
		t.Errorf("doctor did not fail on a status another branch published (err %v):\n%s", err, d)
	}

	// Once a station has published from the task branch, the send goes through:
	// the refusal is about the branch, not the estate. A clone of its own, as an
	// operator's would be. It refuses main's inherited request, which names
	// main as its target, and that refusal is published from task/x.
	far := filepath.Join(base, "far")
	sh(t, base, "git", "clone", "-q", "-b", "task/x", origin, far)
	sh(t, far, "bash", "./station.sh", "--once", "--interval", "1")
	hg("send", "steps/probe.sh")
	sh(t, far, "bash", "./station.sh", "--once", "--interval", "1")
	if body := hg("logs", "--last"); !strings.Contains(body, "PROBED") {
		t.Errorf("the request sent once the station was on task/x did not run there:\n%s", body)
	}

	// `station add` cuts station/db-a from a checkout whose status names
	// task/x. The send it prints goes through before that station has run.
	add := hg("station", "add", "db-a")
	if !strings.Contains(add, "heliograph send <step> -e db-a") {
		t.Fatalf("station add did not print the send it expects to work:\n%s", add)
	}
	hg("send", "steps/probe.sh", "-e", "db-a")
	if d := hg("doctor", "-e", "db-a"); !strings.Contains(d, "published no status yet") {
		t.Errorf("a new station's doctor reports another station's status as its own:\n%s", d)
	}
}

// A send over a request the station has not read says it is replacing it.
//
// The station holds one request, and the newest wins. Two sends before it
// polls, and the first never runs - while SKILL.md said a new send "queues",
// so an agent that sent two steps in a row believed both had run.
func TestSendNamesTheUnrunRequestItReplaces(t *testing.T) {
	station := stationDir(t)
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}

	base := t.TempDir()
	origin := filepath.Join(base, "origin.git")
	work := filepath.Join(base, "work")
	cfg := filepath.Join(base, "config")

	sh(t, base, filepath.Join(station, "station", "bootstrap.sh"), work)
	sh(t, base, "git", "init", "-q", "-b", "main", "--bare", origin)
	quietOrigin(t, origin)
	sh(t, work, "git", "init", "-q", "-b", "main")
	sh(t, work, "git", "remote", "add", "origin", origin)
	for name, word := range map[string]string{"first.sh": "FIRST-RAN", "second.sh": "SECOND-RAN"} {
		body := "#!/usr/bin/env bash\n# heliograph-mode: read-only\necho " + word + "\n"
		if err := os.WriteFile(filepath.Join(work, "steps", name), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	sh(t, work, "git", "add", "-A")
	sh(t, work, "git", "commit", "-qm", "init")
	sh(t, work, "git", "push", "-q", "-u", "origin", "main")

	bin := filepath.Join(base, "heliograph")
	sh(t, ".", "go", "build", "-o", bin, "github.com/heliograph-io/heliograph/cmd/heliograph")
	hg := func(args ...string) string {
		t.Helper()
		cmd := exec.Command(bin, args...)
		cmd.Dir = base
		cmd.Env = append(append(os.Environ(), "XDG_CONFIG_HOME="+cfg), noBackgroundGit...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("heliograph %v: %v\n%s", args, err, out)
		}
		return string(out)
	}

	hg("init", "e2e", "--dir", work)
	firstOut := hg("send", "steps/first.sh")
	if strings.Contains(firstOut, "replaced") {
		t.Errorf("the first send claimed to replace something:\n%s", firstOut)
	}
	first := strings.TrimPrefix(strings.SplitN(firstOut, "\n", 2)[0], "sent ")

	// Ids carry the time to the second, and two in the same second would be
	// the same request.
	time.Sleep(1100 * time.Millisecond)
	out := hg("send", "steps/second.sh")
	if !strings.Contains(out, "replaced unrun request "+first) {
		t.Errorf("the second send did not name the unrun request it replaced (%s):\n%s", first, out)
	}

	// And it is true: the station runs the second and never the first.
	sh(t, work, "bash", "./station.sh", "--once", "--interval", "1")
	if logs := hg("logs"); strings.Contains(logs, "first-") || !strings.Contains(logs, "second-") {
		t.Errorf("the station did not run exactly the second request:\n%s", logs)
	}

	// Once the station has read the last request, the next send replaces nothing.
	time.Sleep(1100 * time.Millisecond)
	if again := hg("send", "steps/first.sh"); strings.Contains(again, "replaced") {
		t.Errorf("a send after the station had read the last request claimed to replace it:\n%s", again)
	}
}

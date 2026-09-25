package main

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// `cancel` and `stop` against a real station, running its loop in the
// background, on the two transports whose station reads a request mid-run.
//
// There was no verb for either. SKILL.md told an agent to hand-edit
// station/request, commit and push, which means nothing on a share. So each
// test cancels a step that would otherwise run for two minutes, checks the
// station is still polling, then stops the loop and checks it exited.

// slowStep prints a line, then sleeps far longer than the test waits.
const slowStep = "#!/usr/bin/env bash\n# heliograph-mode: read-only\n" +
	"echo SLOW-STEP-STARTED\nsleep 120\necho SLOW-STEP-FINISHED\n"

// backgroundStation starts a station loop and returns a channel that receives
// its exit. On a failed test it is sent SIGTERM, which the station traps to
// signal the step's process group, so no `sleep 120` outlives the test.
func backgroundStation(t *testing.T, cmd *exec.Cmd) (<-chan error, *bytes.Buffer) {
	t.Helper()
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	t.Cleanup(func() {
		if cmd.ProcessState == nil {
			_ = cmd.Process.Signal(syscall.SIGTERM)
			select {
			case <-done:
			case <-time.After(15 * time.Second):
				_ = cmd.Process.Kill()
			}
		}
	})
	return done, &out
}

// waitFor polls `status` until it contains want, or fails.
func waitFor(t *testing.T, status func() string, want string, station *bytes.Buffer) string {
	t.Helper()
	deadline := time.Now().Add(60 * time.Second)
	var s string
	for time.Now().Before(deadline) {
		s = status()
		if strings.Contains(s, want) {
			return s
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("status never showed %q. Last status:\n%s\nThe station said:\n%s", want, s, station.String())
	return ""
}

// cancelThenStop is the shared body: the same verbs and the same assertions
// over either transport.
func cancelThenStop(t *testing.T, run func(args ...string) (string, error), done <-chan error, station *bytes.Buffer) {
	t.Helper()
	hg := func(args ...string) string {
		t.Helper()
		out, err := run(args...)
		if err != nil {
			t.Fatalf("heliograph %v: %v\n%s", args, err, out)
		}
		return out
	}
	status := func() string { return hg("status") }

	sent := hg("send", "steps/slow.sh")
	id := strings.TrimPrefix(strings.SplitN(sent, "\n", 2)[0], "sent ")
	waitFor(t, status, "state:    running", station)

	out := hg("cancel")
	if !strings.Contains(out, "cancel sent for "+id) {
		t.Fatalf("cancel did not name the running request %s:\n%s", id, out)
	}
	s := waitFor(t, status, "state:    cancelled", station)
	if !strings.Contains(s, id) {
		t.Errorf("the cancelled status is not about %s:\n%s", id, s)
	}
	body := hg("logs", "--last")
	if !strings.Contains(body, "SLOW-STEP-STARTED") || strings.Contains(body, "SLOW-STEP-FINISHED") {
		t.Errorf("the partial log is not the cancelled run's:\n%s", body)
	}

	// The loop is still polling: a cancel stops the step, not the station.
	select {
	case err := <-done:
		t.Fatalf("the station exited after a cancel (%v):\n%s", err, station.String())
	case <-time.After(3 * time.Second):
	}
	// And the cancel started nothing: the request kept the id already run.
	if logs := hg("logs"); strings.Count(logs, "slow") != 1 {
		t.Errorf("the cancel triggered another run:\n%s", logs)
	}
	if out, err := run("cancel"); err == nil || !strings.Contains(out, "nothing to cancel") {
		t.Errorf("a cancel with nothing running did not say so (err %v):\n%s", err, out)
	}

	if out := hg("stop"); !strings.Contains(out, "stop sent") {
		t.Fatalf("stop did not say it was sent:\n%s", out)
	}
	select {
	case <-done:
	case <-time.After(60 * time.Second):
		t.Fatalf("the station did not exit after a stop:\n%s", station.String())
	}
	if s := status(); !strings.Contains(s, "state:    stopped") {
		t.Errorf("the station exited without publishing stopped:\n%s", s)
	}
	if out := hg("stop"); !strings.Contains(out, "already published") {
		t.Errorf("a second stop did not say one is already published:\n%s", out)
	}
}

func TestCancelAndStopAGitStation(t *testing.T) {
	station := stationDir(t)
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}

	base := t.TempDir()
	origin := filepath.Join(base, "origin.git")
	work := filepath.Join(base, "work")
	far := filepath.Join(base, "far")
	cfg := filepath.Join(base, "config")

	sh(t, base, filepath.Join(station, "station", "bootstrap.sh"), work)
	sh(t, base, "git", "init", "-q", "-b", "main", "--bare", origin)
	quietOrigin(t, origin)
	sh(t, work, "git", "init", "-q", "-b", "main")
	sh(t, work, "git", "remote", "add", "origin", origin)
	if err := os.WriteFile(filepath.Join(work, "steps", "slow.sh"), []byte(slowStep), 0o755); err != nil {
		t.Fatal(err)
	}
	sh(t, work, "git", "add", "-A")
	sh(t, work, "git", "commit", "-qm", "init")
	sh(t, work, "git", "push", "-q", "-u", "origin", "main")
	// The operator's clone. The station commits in its own tree while the CLI
	// commits in this one, as on two machines.
	sh(t, base, "git", "clone", "-q", "-b", "main", origin, far)

	bin := filepath.Join(base, "heliograph")
	sh(t, ".", "go", "build", "-o", bin, "github.com/heliograph-io/heliograph/cmd/heliograph")
	run := func(args ...string) (string, error) {
		cmd := exec.Command(bin, args...)
		cmd.Dir = base
		cmd.Env = append(append(os.Environ(), "XDG_CONFIG_HOME="+cfg,
			"GIT_AUTHOR_NAME=ci", "GIT_AUTHOR_EMAIL=ci@example.invalid",
			"GIT_COMMITTER_NAME=ci", "GIT_COMMITTER_EMAIL=ci@example.invalid"), noBackgroundGit...)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	if out, err := run("init", "e2e", "--dir", work); err != nil {
		t.Fatalf("init: %v\n%s", err, out)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", "./station.sh", "--interval", "1")
	cmd.Dir = far
	// PROGRESS_EVERY=0: no snapshot commits racing the CLI's push. The push
	// retries once, and this test is about the cancel, not the retry.
	cmd.Env = append(append(os.Environ(), "PROGRESS_EVERY=0",
		"GIT_AUTHOR_NAME=ci", "GIT_AUTHOR_EMAIL=ci@example.invalid",
		"GIT_COMMITTER_NAME=ci", "GIT_COMMITTER_EMAIL=ci@example.invalid"), noBackgroundGit...)
	done, out := backgroundStation(t, cmd)

	cancelThenStop(t, run, done, out)
}

func TestCancelAndStopAShareStation(t *testing.T) {
	station := stationDir(t)
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}

	base := t.TempDir()
	mount := filepath.Join(base, "mnt")
	work := filepath.Join(base, "work")
	cfg := filepath.Join(base, "config")
	if err := os.MkdirAll(mount, 0o755); err != nil {
		t.Fatal(err)
	}
	sh(t, base, filepath.Join(station, "station", "bootstrap.sh"), work)
	// Planted, not sent: a share carries documents, not step files.
	if err := os.WriteFile(filepath.Join(work, "steps", "slow.sh"), []byte(slowStep), 0o755); err != nil {
		t.Fatal(err)
	}

	bin := filepath.Join(base, "heliograph")
	sh(t, ".", "go", "build", "-o", bin, "github.com/heliograph-io/heliograph/cmd/heliograph")
	run := func(args ...string) (string, error) {
		cmd := exec.Command(bin, args...)
		cmd.Dir = base
		cmd.Env = append(append(os.Environ(), "XDG_CONFIG_HOME="+cfg), noBackgroundGit...)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	if out, err := run("init", "shared", "--transport", "share", "--dir", mount, "--scope", "slow"); err != nil {
		t.Fatalf("init: %v\n%s", err, out)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	// Through start.sh, the command an operator is told to type.
	cmd := exec.CommandContext(ctx, "bash", "./start.sh", "--", "--interval", "1")
	cmd.Dir = work
	cmd.Env = append(append(os.Environ(), "PROGRESS_EVERY=0",
		"TRANSPORT=share", "SHARE_DIR="+mount, "SHARE_SCOPE=slow"), noBackgroundGit...)
	done, out := backgroundStation(t, cmd)

	cancelThenStop(t, run, done, out)
}

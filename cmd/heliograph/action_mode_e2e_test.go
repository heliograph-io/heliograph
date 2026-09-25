package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/heliograph-io/heliograph/internal/wire"
)

// The parser tests prove this side can read the field. They cannot prove any
// station writes it, and a field agreed on one side of the gap is not a field.
//
// So a real station is bootstrapped and run twice from the same checkout: once
// as an operator would start it, and once with --allow-actions. The two runs
// must publish different modes, and the CLI must report each one. Nothing here
// is a fixture: the status document is whatever station.sh actually wrote.
func TestARealStationPublishesItsActionMode(t *testing.T) {
	station := stationDir(t)
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}

	// Both halves of the gate, in one table, because the value that would be
	// wrong is the one nobody set. A station started plainly is read-only, and
	// that is the case a reader is most likely to meet.
	for _, tc := range []struct {
		name string
		flag []string
		want string
	}{
		{"a station started as the operator is told to start one", nil, "refused"},
		{"a station started with the flag", []string{"--allow-actions"}, "allowed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			base := t.TempDir()
			origin := filepath.Join(base, "origin.git")
			work := filepath.Join(base, "work")
			cfg := filepath.Join(base, "config")

			sh(t, base, filepath.Join(station, "station", "bootstrap.sh"), work)
			sh(t, base, "git", "init", "-q", "-b", "main", "--bare", origin)
			quietOrigin(t, origin)
			sh(t, work, "git", "init", "-q", "-b", "main")
			sh(t, work, "git", "remote", "add", "origin", origin)

			step := "#!/usr/bin/env bash\n# heliograph-mode: read-only\necho THE-MEASUREMENT\n"
			if err := os.WriteFile(filepath.Join(work, "steps", "probe.sh"), []byte(step), 0o755); err != nil {
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

			hg("init", "e2e", "--dir", work)
			hg("send", "steps/probe.sh")
			sh(t, work, append([]string{"bash", "./station.sh", "--once", "--interval", "1"}, tc.flag...)...)

			// The document the station wrote, parsed by the code the CLI uses.
			raw, err := os.ReadFile(filepath.Join(work, "station", "status"))
			if err != nil {
				t.Fatalf("the station published no status at all: %v", err)
			}
			s, err := wire.ParseStatus(raw)
			if err != nil {
				t.Fatal(err)
			}
			if s.Actions != tc.want {
				t.Errorf("the station published actions %q, want %q\n%s", s.Actions, tc.want, raw)
			}
			if !s.ActionsReported() {
				t.Errorf("the station's mode did not survive the round trip:\n%s", raw)
			}

			// And through the binary, because a field parsed and never shown is
			// a field the person asking the question still cannot see.
			if out := hg("status"); !strings.Contains(out, "actions:  "+tc.want) {
				t.Errorf("`heliograph status` does not report the mode:\n%s", out)
			}
		})
	}
}

// EVERY writer of a status document, in every shipped station, and not only
// the transition one the round trip above exercises.
//
// Three loops ship and there are five places between them that write a status:
// station.sh writes one on a transition and another while a step runs,
// pigeonhole.sh reuses its transition writer for both, and station.ps1 has the
// same pair as station.sh. A field added to one writer and not its neighbour
// disappears exactly when a long step is running, which is when somebody is
// most likely to be looking at a fleet view. `payload:` was published on
// transitions and not in progress for the same reason.
//
// SOURCE, AND IT IS THE CHEAP HALF OF A PAIR. Three of the five writers are
// round-tripped for real: station.sh's transition writer by the test above,
// station.sh's progress writer by tests/test-station-progress.sh, and both
// station.ps1 writers by tests/test-station-loop-ps1.sh on Windows.
// pigeonhole.sh's needs an Azure account, and station.ps1 needs Windows, so on
// a Linux checkout this is what covers them.
//
// It also catches the case none of those do: a SIXTH writer added later, in any
// of the three loops, that nobody thinks to round-trip. That is how the field
// would go missing, and the count below is what makes the omission loud.
//
// Every status document begins with `state:` padded to the same column, so
// finding that line finds every writer without naming a function.
func TestEveryStatusWriterInEveryStationPublishesTheActionMode(t *testing.T) {
	dir := stationDir(t)
	writer := regexp.MustCompile(`state: {4}`)

	writers := 0
	for _, f := range []string{
		filepath.Join("station", "bash", "station.sh"),
		filepath.Join("station", "bash", "pigeonhole.sh"),
		filepath.Join("station", "powershell", "station.ps1"),
	} {
		lines := strings.Split(read(t, filepath.Join(dir, f)), "\n")
		for i, line := range lines {
			if !writer.MatchString(line) {
				continue
			}
			writers++
			// The rest of the document, bounded. A writer is a short block; a
			// match twenty lines away is in the next function.
			end := i + 16
			if end > len(lines) {
				end = len(lines)
			}
			if !strings.Contains(strings.Join(lines[i:end], "\n"), "actions:") {
				t.Errorf("%s:%d writes a status that carries no action mode, so a "+
					"reader of that document has to infer it", f, i+1)
			}
		}
	}
	// Two per station bar pigeonhole, which has one. Asserted, because a regex
	// that stops matching turns this whole check into a silent pass.
	if writers != 5 {
		t.Fatalf("found %d status writers, expected 5 - the check no longer finds them", writers)
	}
}

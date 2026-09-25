package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The documentation and the binary drift the moment nothing checks them. A page
// that names a tool which does not exist teaches an agent to call it, and the
// call fails on the far side of a client that cannot see why.
//
// Reading the shipped page rather than a fixture is the point: this fails when
// somebody adds a tool and forgets the docs, which is the direction the mistake
// actually goes.

var tableRow = regexp.MustCompile("(?m)^\\| `(heliograph_[a-z_]+)` \\|")

func TestDocsListEveryToolAndNoOthers(t *testing.T) {
	b, err := os.ReadFile("../../site/content/mcp.md")
	if err != nil {
		t.Skipf("the site content is not here: %v", err)
	}
	documented := map[string]bool{}
	for _, m := range tableRow.FindAllStringSubmatch(string(b), -1) {
		documented[m[1]] = true
	}
	if len(documented) == 0 {
		t.Fatal("the page has no tool table, so this check would pass on an empty page")
	}

	shipped := map[string]bool{}
	for _, tl := range tools() {
		shipped[tl.Name] = true
		if !documented[tl.Name] {
			t.Errorf("%s ships but is in no table on the mcp page", tl.Name)
		}
	}
	for name := range documented {
		if !shipped[name] {
			t.Errorf("the mcp page names %s, which does not exist", name)
		}
	}
}

// The install line on the page has to be the command that actually works. This
// is the first thing anybody types and the last thing anybody re-reads.
func TestDocsInstallLineMatchesTheSubcommand(t *testing.T) {
	b, err := os.ReadFile("../../site/content/mcp.md")
	if err != nil {
		t.Skipf("the site content is not here: %v", err)
	}
	if !strings.Contains(string(b), "heliograph mcp") {
		t.Error("the page never names the subcommand that starts the server")
	}
	// And the subcommand has to be reachable. A page documenting a command the
	// binary does not have is worse than no page.
	if !strings.Contains(usage, "heliograph mcp") {
		t.Error("`heliograph help` does not mention mcp")
	}
}

// A documented `heliograph send <step>` must name a step a stock station has.
//
// `net-probe` is the example every page led with, and run.sh registered the
// step as `net`. So the flagship command was refused on every freshly
// bootstrapped station, and the refusal said the step "declares no mode",
// which sent the reader to a file that did not exist.
//
// ASKED OF run.sh ITSELF, through `--mode`, rather than read out of its case
// table: run.sh is what the station asks, and exit 2 is its answer for "no such
// step". A path (steps/probe.sh) is the reader's own file and a <placeholder>
// is not a step, so both are skipped.
var documentedSend = regexp.MustCompile("heliograph send ((?:-[a-z-]+ [^\\s`]+ )*)([^\\s`\"'|)]+)")

func TestEveryDocumentedSendNamesARealStep(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	runner, err := filepath.Abs("../../station/bash/run.sh")
	if err != nil {
		t.Fatal(err)
	}
	files := []string{"../../README.md", "../../skills/heliograph/SKILL.md"}
	pages, _ := filepath.Glob("../../site/content/*.md")
	files = append(files, pages...)

	checked := map[string]bool{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("cannot read %s: %v", f, err)
		}
		for _, m := range documentedSend.FindAllStringSubmatch(string(b), -1) {
			step := m[2]
			if strings.ContainsAny(step, "/<$") || checked[step] {
				continue
			}
			checked[step] = true
			cmd := exec.Command("bash", runner, "--mode", step)
			out, err := cmd.CombinedOutput()
			if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 2 {
				t.Errorf("%s sends %q, and a stock station has no such step:\n%s", f, step, out)
			}
		}
	}
	if len(checked) == 0 {
		t.Fatal("no `heliograph send <step>` found in the docs, so this checked nothing")
	}
}

package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The site documented the near side only, for a long time, and nothing said so.
//
// Everything about the far side - the thing the product actually is - lived in
// skills/heliograph/references/, which is tuned for an agent's context budget
// and is published nowhere. A reader deciding whether to permit this in their
// estate could read about the CLI and find nothing about what would run on
// their machine.
//
// That is not a gap anybody notices by looking, because every page that exists
// is fine. It is only visible by asking what is NOT there, which is what these
// tests do.

// siteText is every published page, concatenated. The question here is always
// "is this documented anywhere", never "is it on the right page" - page
// boundaries are an editorial decision and should stay one.
func siteText(t *testing.T) string {
	t.Helper()
	pages, err := filepath.Glob("../../site/content/*.md")
	if err != nil || len(pages) == 0 {
		t.Skipf("the site content is not here: %v", err)
	}
	var b strings.Builder
	for _, p := range pages {
		body, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("%s: %v", p, err)
		}
		b.Write(body)
		b.WriteString("\n")
	}
	return b.String()
}

// Every script an operator could be asked to run must be named on the site.
//
// These are the files a person types the name of. Being told to run
// `./service.sh install` by a colleague, and finding the documentation silent
// on it, is the moment somebody decides the docs are not worth reading.
func TestEveryOperatorFacingScriptIsDocumented(t *testing.T) {
	site := siteText(t)

	dir := "../../station/bash"
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Skipf("the station payload is not here: %v", err)
	}

	// Sourced libraries and internal helpers are deliberately exempt: nobody
	// runs caplib.sh, and documenting it as a command would be wrong. It is
	// covered as a library on the runner page instead.
	exempt := map[string]bool{
		"caplib.sh": true,
	}

	checked := 0
	for _, e := range ents {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sh") || exempt[e.Name()] {
			continue
		}
		checked++
		if !strings.Contains(site, e.Name()) {
			t.Errorf("station/bash/%s is a script an operator can run, and no site page names it", e.Name())
		}
	}
	if checked == 0 {
		t.Fatal("no station scripts were found, so this check asserted nothing")
	}
}

// The same question, asked of the PowerShell payload.
//
// It is a SEPARATE test rather than another directory in the loop above,
// because the exemptions are different and collapsing them would mean one list
// of exempt names covering two payloads - where a name exempted for a good
// reason in one silently exempts a different file in the other.
//
// This payload is the whole reason the question is worth asking twice. It
// exists for an estate that will not install anything, so the operator reading
// the documentation is the one with the fewest other ways to find out.
func TestEveryOperatorFacingPowerShellScriptIsDocumented(t *testing.T) {
	site := siteText(t)

	// Sourced modules are exempt for the same reason caplib.sh is: nobody runs
	// them, and documenting one as a command would be wrong. They are covered
	// as libraries on the runner page.
	exempt := map[string]bool{
		"caplib.psm1": true,
	}

	checked := 0
	for _, dir := range []string{"../../station/powershell", "../../station"} {
		ents, err := os.ReadDir(dir)
		if err != nil {
			t.Skipf("the PowerShell payload is not here: %v", err)
		}
		for _, e := range ents {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".ps1") || exempt[e.Name()] {
				continue
			}
			checked++
			if !strings.Contains(site, e.Name()) {
				t.Errorf("%s/%s is a script an operator can run, and no site page names it",
					strings.TrimPrefix(dir, "../../"), e.Name())
			}
		}
	}
	if checked == 0 {
		t.Fatal("no PowerShell scripts were found, so this check asserted nothing")
	}
}

// The PowerShell station's components, named explicitly for the same reason the
// bash ones are: the point is coverage of CAPABILITIES, and a capability is not
// a filename.
//
// EVERY ENTRY HERE IS SOMETHING A READER HAS TO DECIDE ON. Whether the station
// can poll, which transports it has, what it refuses, what it cannot do. The
// page said "it does not receive" for as long as that was true, and the danger
// now is the opposite one: a page that quietly stops naming a limit reads as
// though the limit went away.
func TestThePowerShellStationIsDocumented(t *testing.T) {
	site := siteText(t)

	for _, want := range []struct{ what, phrase string }{
		{"the loop", "station.ps1"},
		{"the runner", "run.ps1"},
		{"the preflight", "start.ps1"},
		{"the bash-free planter", "bootstrap.ps1"},
		{"choosing a payload", "--flavour"},
		{"its transports", "share.psm1"},
		{"the git transport", "git.psm1"},
		{"the relay transport", "relay.psm1"},
		// THE PROPERTY THAT SELLS IT, and the one most likely to be lost in a
		// rewrite: the relay works on this payload with NOTHING INSTALLED. The
		// bash station needs `heliograph-seal` beside it, and a reader who
		// assumes the same of this one concludes the payload is useless on the
		// estate it was built for.
		{"that its seal ships as source rather than as a binary", "lib/seal/"},
		{"the library the curve arithmetic comes from", "Chaos.NaCl"},
		{"Constrained Language Mode, which stops the capture dead", "Constrained Language Mode"},
		{"the execution policy a GPO can set", "execution policy"},
		{"the Job Object the cancel rests on", "Job Object"},
		{"the version this targets as its floor", "5.1"},
		// THE LIMITS. A reader deciding whether to put this on a production
		// machine needs these more than they need the feature list.
		//
		// "no relay transport" used to be one of them and is now false, so it
		// is gone rather than reworded. What replaced it is the limit that
		// actually applies: the seal is compiled by Add-Type, and Constrained
		// Language Mode refuses that. A reader planning a locked-down estate
		// has to be told which lock stops this.
		{"that its own self-update needs a restart", "self-update"},
		{"the pin file that is not the bash station's", ".station-approved-ps"},
	} {
		if !strings.Contains(site, want.phrase) {
			t.Errorf("the site never mentions %s (looked for %q)", want.what, want.phrase)
		}
	}
}

// The components that make heliograph what it is, each of which had no page at
// all before 2026-09-08. Named explicitly rather than derived, because the
// point is coverage of CAPABILITIES, and a capability is not a filename.
func TestTheFarSideIsDocumented(t *testing.T) {
	site := siteText(t)

	for _, want := range []struct{ what, phrase string }{
		{"the mode declaration gate", "heliograph-mode"},
		{"the read-only default", "ALLOW_ACTIONS"},
		{"the root refusal", "ALLOW_ROOT"},
		{"step pinning", "REQUIRE_PIN"},
		{"progress pushes", "PROGRESS_EVERY"},
		{"the undelivered state", "undelivered"},
		{"the finished-log verb", "tp_put_log"},
		{"the conformance suite", "conformance"},
		{"the Docker image", "heliograph-toolkit"},
		{"Kubernetes", "kubectl"},
		{"systemd", "systemd"},
		{"the Windows scheduled task", "scheduled task"},
		{"PowerShell steps", "ps_step"},
		{"redaction", "cap_redact"},
		{"sending a secret to the far side", "secret.sh"},
		{"the pipeline loop guard", "NO_CI"},
		{"the seal binary", "heliograph-seal"},
		// The bundle's station side, which three pages said did not exist. It
		// is the only transport that makes air-gapped literally true, so the
		// page written for that search term has to say it works.
		{"the bundle's station side", "BUNDLE_DIR"},
	} {
		if !strings.Contains(site, want.phrase) {
			t.Errorf("the site never mentions %s (looked for %q)", want.what, want.phrase)
		}
	}
}

// All five Azure templates ship, and all five must be findable. Four were
// deployed for real; the fifth never has been, and saying which is which is
// the part that is worth anything.
func TestEveryAzureTemplateIsDocumented(t *testing.T) {
	site := siteText(t)

	ents, err := os.ReadDir("../../station/bash/azure")
	if err != nil {
		t.Skipf("the Azure templates are not here: %v", err)
	}

	// How a page would name each directory in prose, since a reader searches
	// for the product name rather than the folder.
	naming := map[string]string{
		"aci":              "ACI",
		"webapp":           "Web App for Containers",
		"containerappsjob": "Container Apps Job",
		"vm":               "VM",
		"function":         "Function App",
	}

	checked := 0
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		checked++
		phrase, ok := naming[e.Name()]
		if !ok {
			t.Errorf("station/bash/azure/%s ships and this test has no name for it: "+
				"add one, and make sure a page documents it", e.Name())
			continue
		}
		if !strings.Contains(site, phrase) {
			t.Errorf("the Azure template %q ships and no site page mentions %q", e.Name(), phrase)
		}
	}
	if checked != 5 {
		t.Errorf("expected 5 Azure templates, found %d - the docs claim five", checked)
	}
}

// Every agent this repository ships an installer for must be documented.
//
// install-codex.sh has existed for as long as install.sh, and the site
// mentioned Codex in exactly one line of one page while Claude Code had a page
// of its own. An installer nobody can find is an installer nobody runs, and
// "which agents does this support" is the first question a reader asks.
func TestEveryShippedInstallerIsDocumented(t *testing.T) {
	site := siteText(t)

	// installer file -> the word a reader would search for.
	agents := map[string]string{
		"install.sh":       "Claude Code",
		"install-codex.sh": "Codex",
	}

	ents, err := os.ReadDir("../..")
	if err != nil {
		t.Skipf("the repository root is not here: %v", err)
	}
	found := 0
	for _, e := range ents {
		name := e.Name()
		if !strings.HasPrefix(name, "install") || !strings.HasSuffix(name, ".sh") {
			continue
		}
		found++
		agent, ok := agents[name]
		if !ok {
			t.Errorf("%s ships and this test has no agent name for it: add one, "+
				"and make sure a page documents that agent", name)
			continue
		}
		if !strings.Contains(site, agent) {
			t.Errorf("%s ships and no site page mentions %q", name, agent)
		}
		// And the installer itself has to be findable, or a reader is told the
		// agent is supported without being told how.
		if !strings.Contains(site, name) {
			t.Errorf("the site names %q as supported but never names %s, so there is "+
				"nothing to run", agent, name)
		}
	}
	if found == 0 {
		t.Fatal("no installers were found, so this check asserted nothing")
	}
}

// Every credential mechanism the station honours must be documented.
//
// The git transport's whole credential chain lived in caplib.sh and in a skill
// reference that was never published. The transports page - the page about the
// git transport - did not mention a token at all, and the mechanisms appeared
// only as asides on five other pages: containers, service, pipelines, azure and
// hosts. Somebody setting up their first station read the page named after
// their transport and was told nothing about the thing most likely to stop it
// working.
func TestEveryGitCredentialMechanismIsDocumented(t *testing.T) {
	site := siteText(t)

	dir := stationDir(t)
	caplib := read(t, filepath.Join(dir, "station", "bash", "caplib.sh"))

	// Read the names out of the implementation rather than listing them here,
	// so a mechanism added to the chain and not written up fails this test.
	// LONGEST ALTERNATIVE FIRST, and a word boundary. Written the obvious way
	// round, GIT_TOKEN matches first and GIT_TOKEN_FILE is only ever seen as
	// GIT_TOKEN followed by _FILE - so the check found two mechanisms out of
	// four and would have passed a page documenting half of them.
	mechanisms := regexp.MustCompile(`GIT_(?:AUTH_HEADER|TOKEN_FILE|TOKEN_USER|TOKEN)\b`).
		FindAllString(caplib, -1)
	seen := map[string]bool{}
	for _, m := range mechanisms {
		seen[m] = true
	}
	if len(seen) < 4 {
		t.Fatalf("expected four credential mechanisms in caplib.sh, found %d - "+
			"this check would assert almost nothing", len(seen))
	}
	for m := range seen {
		if !strings.Contains(site, m) {
			t.Errorf("the station honours %s and no site page names it", m)
		}
	}

	// The transports page is where somebody setting up git actually looks.
	tp, err := os.ReadFile("../../site/content/transports.md")
	if err != nil {
		t.Skipf("the transports page is not here: %v", err)
	}
	for _, want := range []string{"GIT_TOKEN", "ssh", "start.sh --check"} {
		if !strings.Contains(string(tp), want) {
			t.Errorf("the transports page never mentions %q, so the git section "+
				"does not tell a reader how the station authenticates", want)
		}
	}
}

// topLevel finds the commands main() actually dispatches on.
//
// Read from the switch rather than from `usage`, because usage is itself a
// piece of documentation and checking documentation against documentation
// proves only that two copies agree.
var topLevel = regexp.MustCompile(`(?m)^\tcase "([a-z]+)"(?:, "([a-z-]+)")?:`)

// Every command the binary dispatches must be on the CLI reference page.
//
// `station` was not. It shipped with its own subcommand, a worktree, an estate
// and printed operator instructions, and the page listing every command did not
// name it - so the only way to discover it was to read main.go or run the
// binary with no arguments.
func TestEveryCommandIsOnTheCLIPage(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Skipf("main.go is not here: %v", err)
	}
	// Only the dispatch switch in main(), which ends at its default arm.
	body := string(src)
	start := strings.Index(body, "switch os.Args[1] {")
	if start < 0 {
		t.Fatal("main() has no dispatch switch, so this check found nothing to assert")
	}
	end := strings.Index(body[start:], "\tdefault:")
	if end < 0 {
		t.Fatal("the dispatch switch has no default arm")
	}
	body = body[start : start+end]

	page, err := os.ReadFile("../../site/content/cli.md")
	if err != nil {
		t.Skipf("the CLI page is not here: %v", err)
	}
	doc := string(page)

	// Not commands: version reporting and the help flags, which no reference
	// page needs to teach.
	exempt := map[string]bool{"version": true, "help": true}

	found := 0
	for _, m := range topLevel.FindAllStringSubmatch(body, -1) {
		if exempt[m[1]] {
			continue
		}
		found++
		// An arm may carry an alias - `case "check", "doctor":`. Documenting
		// one canonical spelling is legitimate, so either satisfies this;
		// documenting NEITHER does not.
		names := []string{m[1]}
		if m[2] != "" {
			names = append(names, m[2])
		}
		ok := false
		for _, n := range names {
			if strings.Contains(doc, "heliograph "+n) {
				ok = true
			}
		}
		if !ok {
			t.Errorf("`heliograph %s` is a command and the CLI page names none of %v, "+
				"so the only way to find it is to read main.go", m[1], names)
		}
	}
	if found == 0 {
		t.Fatal("no commands were found in the dispatch switch, so this check asserted nothing")
	}
}

// Every field the station publishes in its status must be documented, because
// the CLI prints them and a reader meeting one it cannot interpret is the
// moment somebody guesses.
func TestEveryStatusFieldIsDocumented(t *testing.T) {
	site := siteText(t)
	dir := stationDir(t)
	station := read(t, filepath.Join(dir, "station", "bash", "station.sh"))

	// NOT anchored to the start of the line. Anchored, this matched only the
	// fields inside the plain `{ echo ...; }` blocks and silently missed every
	// conditional one - `[ -n "$PAYLOAD" ] && echo "payload:  ..."` among them,
	// which is the field this check was written for. It passed vacuously.
	fields := regexp.MustCompile(`echo "([a-z]+): *\$?`).FindAllStringSubmatch(station, -1)
	seen := map[string]bool{}
	for _, f := range fields {
		seen[f[1]] = true
	}
	if len(seen) < 5 {
		t.Fatalf("found only %d status fields in station.sh, so this asserts almost nothing", len(seen))
	}
	for f := range seen {
		if !strings.Contains(site, f) {
			t.Errorf("the station publishes a %q field and no site page mentions it", f)
		}
	}
}

// ROADMAP.md is the plan: what heliograph is for, where it stands, and the
// epics for now, next and later. It replaced PLAN.md on 2026-09-30, when the
// register had become a log of what landed; the log moved whole to
// docs/history/2026-09-plan.md and PLAN.md became a one-line pointer.
//
// The check is deliberately narrow. Whether "next" is still the right order is
// a judgement no test can make. Whether the plan still agrees with the
// filesystem about which transports exist is not a judgement at all, and
// whether every open epic is listed is checked outside this repository, by a
// tool that can ask GitHub.
func TestThePlanIsPresentAndAgreesWithTheCode(t *testing.T) {
	plan, err := os.ReadFile("../../ROADMAP.md")
	if err != nil {
		t.Fatalf("ROADMAP.md is the plan and it is not here: %v", err)
	}
	p := string(plan)

	// Old links to PLAN.md must still land somewhere that says where to go.
	pointer, err := os.ReadFile("../../PLAN.md")
	if err != nil {
		t.Fatalf("PLAN.md is the pointer every old link resolves to, and it is gone: %v", err)
	}
	if !strings.Contains(string(pointer), "ROADMAP.md") {
		t.Error("PLAN.md no longer points at ROADMAP.md, so an old link lands nowhere")
	}

	// An unreferenced plan is one nobody opens.
	for _, f := range []string{"../../AGENTS.md", "../../README.md"} {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		if !strings.Contains(string(b), "ROADMAP.md") {
			t.Errorf("%s does not point at ROADMAP.md, so nobody arriving would find it", filepath.Base(f))
		}
	}

	// It says which transports have no station side. The moment one gains a
	// transport file that claim is false, and this is the register a reader
	// trusts about what works.
	//
	// PER LINE, NOT PER FILE. The first version asked whether "no station side"
	// appeared anywhere in the register, which was true of all three transports while
	// it was true of any of them - so writing share.sh made the register wrong
	// about share AND made it impossible to record that bundle still has none.
	// It caught the real drift on the day share.sh landed and then could not be
	// satisfied without deleting a true sentence. A claim is made about a
	// transport on the line that names it.
	//
	// The spelling is how the register writes it, not how the file is named:
	// this is prose for a reader.
	planSpelling := map[string]string{
		"share":    "file share",
		"bundle":   "bundle",
		"objstore": "object store",
	}
	//
	// BOTH DIRECTIONS. Only checking "the file exists and the register says it
	// does not" is half a guard: delete a transport and the register goes on
	// promising it works, which is the more dangerous of the two errors. So a
	// transport with no station file must be SAID to have none.
	for name, spelt := range planSpelling {
		_, statErr := os.Stat(filepath.Join("../../station/bash/transports", name+".sh"))
		exists := statErr == nil
		claimed := false
		for _, line := range strings.Split(p, "\n") {
			if !strings.Contains(strings.ToLower(line), spelt) {
				continue
			}
			if strings.Contains(line, "no station side") {
				claimed = true
				if exists {
					t.Errorf("station/bash/transports/%s.sh exists, and ROADMAP.md still says "+
						"%q has no station side:\n  %s", name, spelt, strings.TrimSpace(line))
				}
			}
		}
		if !exists && !claimed {
			t.Errorf("there is no station/bash/transports/%s.sh, and no line of ROADMAP.md "+
				"mentioning %q says so. The plan would be promising a transport "+
				"that has only one half", name, spelt)
		}
	}

	// The sections that make it a plan rather than a note.
	for _, want := range []string{"## What heliograph is for", "## Where we are",
		"## Now, Next, Later", "### Now", "### Next", "### Later",
		"## What we will not do", "## Open and commercial",
		"## Claims and their status", "## Contributing"} {
		if !strings.Contains(p, want) {
			t.Errorf("ROADMAP.md has no %q section, so it has stopped being the plan", want)
		}
	}

	// The lessons left PLAN.md for AGENTS.md, and the history for docs/history.
	// Losing either would lose the part of the old register that still teaches.
	agents, err := os.ReadFile("../../AGENTS.md")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(agents), "## Lessons this repository has already paid for") {
		t.Error("AGENTS.md has lost the lessons this repository has already paid for")
	}
	if _, err := os.Stat("../../docs/history/2026-09-plan.md"); err != nil {
		t.Errorf("the history PLAN.md points at is gone: %v", err)
	}
}

// A CLAIM THAT HAS STOPPED BEING TRUE IS WORSE THAN A MISSING ONE, and the
// tests above cannot see it. They ask whether something is documented; they say
// nothing about a page that documents the opposite.
//
// This is not hypothetical. When the PowerShell loop landed, three places went
// on saying it did not exist:
//
//   - conformance.md said gate 3 "lives in the loop, which is a later PR"
//   - station.md said a native PowerShell station was "designed and not built"
//   - start.ps1 - THE ONE COMMAND THE OPERATOR TYPES - printed "the loop is not
//     implemented for PowerShell yet", refused to hand over, and exited 0. Every
//     check in its table passed, so it read as a successful preflight rather
//     than as a station that never started.
//
// An assertion in test-station-ps1.sh was holding the last one in place: it
// REQUIRED the words "does not yet RECEIVE". A test can pin a stale sentence as
// firmly as a correct one.
//
// So each entry here is a phrase that was true once and is not now. The code is
// searched as well as the prose, because the worst instance was in the code.
func TestNothingStillClaimsTheStationCannotPoll(t *testing.T) {
	roots := []string{"../../site/content", "../../skills", "../../station/powershell"}
	stale := []struct{ phrase, why string }{
		{"does not yet RECEIVE", "the PowerShell station polls"},
		{"loop is not implemented for PowerShell", "station.ps1 is the loop"},
		{"there is no loop, so a request", "there is a loop"},
		{"designed and not built", "it is built"},
		{"which is a later PR", "the later PR landed"},
		{"cannot RECEIVE", "it receives"},
		// THE RELAY'S REASON, which outlived being disproved in five files at
		// once. The claim was that the seal needs a native binary; all four
		// primitives are ~200 KB of managed C#, verified against RFC 7748,
		// 8032, 8439 and 5869. The station still has no relay - it is not
		// built - but "not built" and "not possible" are different sentences
		// and only one of them is true.
		//
		// MATCHED ON THE ASSERTION'S OWN SHAPE, not on "native binary". The
		// first version banned that, and failed on the pages CORRECTING the
		// claim - which have to say the words in order to withdraw them. A
		// guard that cannot tell an assertion from its retraction makes the
		// retraction unwritable.
		{"is a different bootstrap question", "the seal needs no native binary, so that is not the reason"},
		{"which is a Go binary, and a station", "the seal needs no native binary, so that is not the reason"},
		// AND NOW THE CLAIM ITSELF, because the transport is built. The reason
		// was corrected first and the capability followed, which left five
		// pages saying "not built" that were each true when written.
		//
		// Matched on the assertions' own shapes for the reason above: the pages
		// that WITHDRAW the claim have to be able to say "no relay" in a
		// sentence about no longer having no relay.
		{"no relay transport for", "transports/relay.psm1 exists and passes conformance"},
		{"It has no relay yet", "transports/relay.psm1 exists and passes conformance"},
		{"has no relay either", "transports/relay.psm1 exists and passes conformance"},
		{"Transports are git and share only", "it ships git, share and relay"},
		{"ships **git and share** and nothing else", "it ships git, share and relay"},
		{"relay transport is not written yet", "it is written"},
	}

	checked := 0
	for _, root := range roots {
		err := filepath.Walk(root, func(p string, fi os.FileInfo, err error) error {
			if err != nil || fi.IsDir() {
				return nil
			}
			switch filepath.Ext(p) {
			case ".md", ".ps1", ".psm1", ".sh":
			default:
				return nil
			}
			b, err := os.ReadFile(p)
			if err != nil {
				return nil
			}
			checked++
			// THIS FILE IS EXEMPT FROM ITSELF. It has to quote the phrases in
			// order to search for them, and a guard that fails on its own
			// evidence is a guard nobody can write.
			body := string(b)
			for _, s := range stale {
				if strings.Contains(body, s.phrase) {
					t.Errorf("%s still says %q, and %s", p, s.phrase, s.why)
				}
			}
			return nil
		})
		if err != nil {
			t.Skipf("%s is not here: %v", root, err)
		}
	}
	if checked == 0 {
		t.Fatal("no files were searched, so this check asserted nothing")
	}
}

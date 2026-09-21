package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// A transport needs BOTH halves. The control side publishes a request and reads
// a log; the station side picks the request up and sends the log back. One half
// on its own moves nothing.
//
// The documentation drifted in exactly that gap. `site/content/transports.md`
// carried
//
//	heliograph init payments --transport relay --url ... --estate ...
//
// naming a transport `init` has never accepted and two flags that have never
// existed, while the status tables in the README and on the page called relay,
// file share, bundle and object store "works". internal/transport implements
// four of those; `station/bash/transports/` holds git, blob and relay, so no
// combination of the two was true of more than git.
//
// The cost of that drift is not a wrong sentence. Somebody plants a station
// against a transport that cannot carry a log, on a machine they cannot log
// into, and finds out by waiting.
//
// These tests read the shipped page and the shipped payload, because the
// mistake goes in that direction: a transport gets written, the page gets
// enthusiastic, and nothing disagrees.

var transportFlag = regexp.MustCompile(`--transport[ =]+([a-z]+)`)

// Nothing in the documentation may show `--transport X` unless `init` accepts X.
// This is the assertion that would have caught the relay example on the day it
// was written.
func TestDocsNeverShowATransportInitCannotSelect(t *testing.T) {
	known := map[string]bool{}
	for _, k := range initTransports {
		known[k] = true
	}
	if len(known) == 0 {
		t.Fatal("initTransports is empty, so this check could not fail")
	}

	pages, err := filepath.Glob("../../site/content/*.md")
	if err != nil || len(pages) == 0 {
		t.Skipf("the site content is not here: %v", err)
	}

	// A placeholder is not a claim. `--transport git|share|...` in a usage
	// block is describing the flag, not invoking it.
	checked := 0
	for _, p := range pages {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("%s: %v", p, err)
		}
		for _, m := range transportFlag.FindAllStringSubmatch(string(b), -1) {
			checked++
			if !known[m[1]] {
				t.Errorf("%s shows `--transport %s`, which `heliograph init` does not accept. "+
					"It knows %s", filepath.Base(p), m[1], strings.Join(initTransports, ", "))
			}
		}
	}
	if checked == 0 {
		t.Error("no --transport example was found on any page, so this check asserted nothing")
	}
}

// Every transport the station payload ships must be named on the transports
// page, and the page must not invent one the payload does not have. The station
// side is the half a reader cannot inspect from here, so it is the half most
// worth pinning.
func TestEveryStationTransportIsOnThePage(t *testing.T) {
	b, err := os.ReadFile("../../site/content/transports.md")
	if err != nil {
		t.Skipf("the site content is not here: %v", err)
	}
	page := string(b)

	shipped, err := filepath.Glob("../../station/bash/transports/*.sh")
	if err != nil || len(shipped) == 0 {
		t.Skipf("the station payload is not here: %v", err)
	}

	// The page is prose, so it names transports the way a reader would: "Azure
	// Blob" rather than "blob". Match on the word a human would write.
	spelling := map[string]string{
		"git":      "git",
		"blob":     "Azure Blob",
		"relay":    "relay",
		"share":    "file share",
		"bundle":   "bundle",
		"objstore": "object store",
	}
	for _, f := range shipped {
		name := strings.TrimSuffix(filepath.Base(f), ".sh")
		want, ok := spelling[name]
		if !ok {
			t.Errorf("the station ships transports/%s.sh and this test has no spelling for it: "+
				"add one, and make sure the page documents it", name)
			continue
		}
		if !strings.Contains(page, want) {
			t.Errorf("the station ships transports/%s.sh and the transports page never mentions %q",
				name, want)
		}
	}
}

// Every verb the reference transport implements must appear on the page that
// claims to list the contract.
//
// The page said "ten functions" and listed them, and that list is how somebody
// writing the next transport - or the PowerShell station - learns what they owe.
// A verb added to git and not to the page is a verb the second implementation
// does not write, which is exactly how `tp_put_log` came to exist on git alone
// while relay and blob shipped nothing at all.
//
// git is the one measured because it is the only transport that implements the
// whole contract including the optional halves. A verb it does not have is not
// yet a contract.
func TestEveryVerbGitImplementsIsOnThePage(t *testing.T) {
	b, err := os.ReadFile("../../site/content/transports.md")
	if err != nil {
		t.Skipf("the site content is not here: %v", err)
	}
	page := string(b)

	src, err := os.ReadFile("../../station/bash/transports/git.sh")
	if err != nil {
		t.Skipf("the station payload is not here: %v", err)
	}

	// A definition, not a mention: `^tp_name()` at the left margin. The header
	// comment in that file lists the contract too, and matching it would make
	// this test agree with a comment rather than with the code.
	def := regexp.MustCompile(`(?m)^(tp_[a-z_]+)\(\)`)
	found := map[string]bool{}
	for _, m := range def.FindAllStringSubmatch(string(src), -1) {
		found[m[1]] = true
	}
	if len(found) < 10 {
		t.Fatalf("only %d tp_* definitions found in git.sh, so this check is not "+
			"reading the file it thinks it is", len(found))
	}
	for name := range found {
		if !strings.Contains(page, name) {
			t.Errorf("transports/git.sh defines %s() and the transports page never names it. "+
				"That list is what the next transport - and the PowerShell station - "+
				"is written from", name)
		}
	}
}

// The status table has to name both sides. A single "works" column is what let
// a control-side-only transport read as finished.
func TestTheTransportsPageStatesBothSides(t *testing.T) {
	b, err := os.ReadFile("../../site/content/transports.md")
	if err != nil {
		t.Skipf("the site content is not here: %v", err)
	}
	page := string(b)
	for _, want := range []string{"control side", "station side"} {
		if !strings.Contains(page, want) {
			t.Errorf("the transports page never says %q, so a reader cannot tell "+
				"which half of a transport exists", want)
		}
	}
}

// The README's capability table drifted for some time, and nothing noticed,
// because the tests above bind the DOCUMENTATION SITE to the code and nothing
// bound the README.
//
// Until 21 Sep 2026 it said relay was "half a transport" that "no CLI command
// can select", that the station had no transport for share, bundle or object
// store, and that the PowerShell station was "planned". All four were false
// against this repository: --transport relay is in initTransports,
// station/bash/transports/ carries six transports, and station/powershell/ is
// ~2,600 lines that CI runs on a Windows runner.
//
// It cost more than tidiness. skills.dbhq.uk/heliograph deliberately published
// the MORE CONSERVATIVE claim because this README contradicted the docs site,
// and said in a source comment that it would stay understated "until
// heliograph settles which is true". A README nobody tested was understating
// the product on a third-party page.
//
// So this asserts the specific false claims cannot come back, rather than
// trying to parse the table: the negative form is what rots, and it is cheap
// to pin.
func TestReadmeTransportClaimsMatchTheCode(t *testing.T) {
	b, err := os.ReadFile("../../README.md")
	if err != nil {
		t.Skipf("no README here: %v", err)
	}
	readme := string(b)

	// Each of these was published and each was false.
	for _, claim := range []string{
		"No CLI command can select it",
		"the station has no transport for any of them",
		"PowerShell station | planned",
	} {
		if strings.Contains(readme, claim) {
			t.Errorf("README repeats a claim the code contradicts: %q", claim)
		}
	}

	// And the positive side, so the table cannot simply go silent instead.
	if !strings.Contains(readme, "--transport relay") {
		t.Error("README no longer shows that init can select the relay transport")
	}

	// Every station transport that exists on disk should be reachable from
	// `init`, which is the invariant the table is describing.
	entries, err := filepath.Glob("../../station/bash/transports/*.sh")
	if err != nil || len(entries) == 0 {
		t.Skipf("the bash station payload is not here: %v", err)
	}
	known := map[string]bool{}
	for _, k := range initTransports {
		known[k] = true
	}
	for _, e := range entries {
		name := strings.TrimSuffix(filepath.Base(e), ".sh")
		// blob is reached through drop.sh in the payload rather than by init,
		// which the table says explicitly.
		if name == "blob" {
			continue
		}
		if !known[name] {
			t.Errorf("station/bash/transports/%s.sh exists but init cannot select %q", name, name)
		}
	}
}

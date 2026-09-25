package packaging

// Version drift between four files is the failure this prevents, and it is a
// quiet one: npm serves a wrapper that downloads a release tag which does not
// exist, and the error a user sees is a 404 from GitHub with no hint that two
// numbers disagree.
//
// The tag is the source of truth. Everything else has to match it.

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

func read(t *testing.T, path string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("cannot read %s: %v", path, err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("%s is not valid JSON: %v", path, err)
	}
	return m
}

// latestTag is what the release actually published. On a shallow CI checkout
// there may be no tags, and that is a skip rather than a failure: the check
// needs a tag to compare against and cannot invent one.
func latestTag(t *testing.T) string {
	t.Helper()
	out, err := exec.Command("git", "describe", "--tags", "--abbrev=0").Output()
	if err != nil {
		t.Skip("no tags in this checkout, so there is nothing to compare against")
	}
	return strings.TrimPrefix(strings.TrimSpace(string(out)), "v")
}

// The packaged version must be the latest tag or newer.
//
// NOT exactly equal, and the difference matters. A release begins with a commit
// that bumps these files, and that commit necessarily lands BEFORE the tag
// exists - so an equality check fails on every release-preparation branch and
// makes the gate impossible to satisfy. I wrote it that way first and it
// blocked the very next release.
//
// Ahead of the tag is a release in preparation, which is normal. Behind it is
// the bug: npm would serve a wrapper that downloads an older release than the
// one it claims to be, or a release that has been superseded.
//
// Exactness still matters at the moment of publishing, and the release workflow
// asserts it there - where a mismatch would ship a package that 404s on install.
func TestPackagedVersionsAreNotBehindTheLatestTag(t *testing.T) {
	tag := latestTag(t)
	for _, c := range []struct{ path, key string }{
		{"npm/package.json", "version"},
		{"mcpb/manifest.json", "version"},
		{"../server.json", "version"},
	} {
		got, _ := read(t, c.path)[c.key].(string)
		cmp, err := compareSemver(got, tag)
		if err != nil {
			t.Errorf("%s has version %q, which is not a version: %v", c.path, got, err)
			continue
		}
		if cmp < 0 {
			t.Errorf("%s says version %q, which is BEHIND the latest tag v%s.\n"+
				"The published wrapper would download an older release than it claims to be.",
				c.path, got, tag)
		}
	}
}

// The three files must agree with each other, whatever they say. Two of them
// bumped and one forgotten is the shape this catches, and it is the likely one:
// they are bumped by hand, in three different files, in one commit.
func TestPackagedVersionsAgreeWithEachOther(t *testing.T) {
	seen := map[string][]string{}
	for _, c := range []struct{ path, key string }{
		{"npm/package.json", "version"},
		{"mcpb/manifest.json", "version"},
		{"../server.json", "version"},
	} {
		v, _ := read(t, c.path)[c.key].(string)
		seen[v] = append(seen[v], c.path)
	}
	if len(seen) > 1 {
		t.Errorf("the packaged versions disagree: %v", seen)
	}
}

// server.json carries the version twice: once for the server and once for the
// npm package it installs. A client reads the second one.
func TestServerJSONPackageVersionMatchesItsOwn(t *testing.T) {
	srv := read(t, "../server.json")
	own, _ := srv["version"].(string)
	pkgs, _ := srv["packages"].([]any)
	if len(pkgs) == 0 {
		t.Fatal("server.json lists no packages")
	}
	p, _ := pkgs[0].(map[string]any)
	if got, _ := p["version"].(string); got != own {
		t.Errorf("server.json is version %q but installs package version %q; a client "+
			"following the registry gets the second one", own, got)
	}
}

// compareSemver returns -1, 0 or 1. Only the numeric parts, because that is all
// these versions ever carry and a full semver parser here would be a dependency
// or a hundred lines to compare three integers.
func compareSemver(a, b string) (int, error) {
	pa, err := parts(a)
	if err != nil {
		return 0, err
	}
	pb, err := parts(b)
	if err != nil {
		return 0, err
	}
	for i := 0; i < 3; i++ {
		switch {
		case pa[i] < pb[i]:
			return -1, nil
		case pa[i] > pb[i]:
			return 1, nil
		}
	}
	return 0, nil
}

func parts(v string) ([3]int, error) {
	var out [3]int
	f := strings.SplitN(strings.TrimPrefix(v, "v"), ".", 4)
	if len(f) < 3 {
		return out, fmt.Errorf("%q is not major.minor.patch", v)
	}
	for i := 0; i < 3; i++ {
		n, err := strconv.Atoi(strings.SplitN(f[i], "-", 2)[0])
		if err != nil {
			return out, fmt.Errorf("%q: %w", v, err)
		}
		out[i] = n
	}
	return out, nil
}

// The registry proves ownership of an npm package by matching a marker in the
// published README against the name in server.json. If they drift, publishing
// is rejected with a message about ownership rather than about a typo.
func TestRegistryOwnershipMarkerMatches(t *testing.T) {
	name, _ := read(t, "../server.json")["name"].(string)
	if name == "" {
		t.Fatal("server.json has no name")
	}
	b, err := os.ReadFile("npm/README.md")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "mcp-name: "+name) {
		t.Errorf("npm/README.md does not carry `mcp-name: %s`, so the registry cannot "+
			"verify ownership of the package", name)
	}
	pkgName, _ := read(t, "npm/package.json")["mcpName"].(string)
	if pkgName != name {
		t.Errorf("package.json mcpName is %q, server.json name is %q", pkgName, name)
	}
}

// The npm package must point at the identifier server.json advertises, or a
// client following the registry installs something else entirely.
func TestServerJSONPointsAtThePublishedPackage(t *testing.T) {
	srv := read(t, "../server.json")
	pkgs, _ := srv["packages"].([]any)
	if len(pkgs) == 0 {
		t.Fatal("server.json lists no packages, so no client can install it")
	}
	p, _ := pkgs[0].(map[string]any)
	want, _ := read(t, "npm/package.json")["name"].(string)
	if got, _ := p["identifier"].(string); got != want {
		t.Errorf("server.json installs %q but the package is called %q", got, want)
	}
	tr, _ := p["transport"].(map[string]any)
	if got, _ := tr["type"].(string); got != "stdio" {
		t.Errorf("transport type is %q; heliograph mcp speaks stdio", got)
	}
}

// Every tool the bundle advertises has to exist. A manifest listing a tool the
// binary does not have is a promise a client makes on our behalf.
func TestManifestToolsMatchTheServer(t *testing.T) {
	m := read(t, "mcpb/manifest.json")
	tools, _ := m["tools"].([]any)
	if len(tools) == 0 {
		t.Fatal("the manifest advertises no tools")
	}
	seen := map[string]bool{}
	for _, x := range tools {
		tm, _ := x.(map[string]any)
		n, _ := tm["name"].(string)
		if !strings.HasPrefix(n, "heliograph_") {
			t.Errorf("tool %q is not one of ours", n)
		}
		if d, _ := tm["description"].(string); len(d) < 15 {
			t.Errorf("tool %q has no usable description", n)
		}
		seen[n] = true
	}
	// The tools the MCP server actually registers, read from the source that
	// registers them. This was a list of seven typed here, and it stayed
	// seven when the server gained heliograph_cancel and heliograph_stop, so
	// the bundle hid two tools and the test still passed. This package cannot
	// import package main, so the names are read the way test-doc-coherence.sh
	// reads them.
	src, err := os.ReadFile("../cmd/heliograph/mcptools.go")
	if err != nil {
		t.Fatal(err)
	}
	server := map[string]bool{}
	for _, m := range registered.FindAllStringSubmatch(string(src), -1) {
		server[m[1]] = true
	}
	if len(server) == 0 {
		t.Fatal("no tool names found in mcptools.go, so this checked nothing")
	}
	for n := range server {
		if !seen[n] {
			t.Errorf("the manifest does not advertise %s, which the server provides", n)
		}
	}
	for n := range seen {
		if !server[n] {
			t.Errorf("the manifest advertises %s, which the server does not provide", n)
		}
	}
}

var registered = regexp.MustCompile(`Name:\s*"(heliograph_[a-z_]+)"`)

// The registry rejects a description over 100 characters, and it rejects it at
// publish time: the file validates locally, the schema says nothing, and the
// first sign is a 422 from a command somebody runs once a release. The
// description that shipped here was 106 characters and had never been sent.
func TestServerJSONDescriptionFitsTheRegistry(t *testing.T) {
	d, _ := read(t, "../server.json")["description"].(string)
	if d == "" {
		t.Fatal("server.json has no description")
	}
	if n := len([]rune(d)); n > 100 {
		t.Errorf("the description is %d characters and the registry allows 100: %q", n, d)
	}
	// And it must still say what the thing does. "heliograph" alone is the
	// 19th-century signalling mirror to everything that reads this listing.
	if !strings.Contains(strings.ToLower(d), "run commands") {
		t.Errorf("the description does not say what it runs: %q", d)
	}
}

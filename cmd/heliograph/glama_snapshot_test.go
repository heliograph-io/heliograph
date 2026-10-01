package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"

	"github.com/heliograph-io/heliograph/internal/mcp"
)

// Glama scores the TOOL DEFINITIONS - their names, descriptions and schemas -
// and publishes that score against a release version. Ours said v0.1.0 while
// the project was at v0.3.2, which tells anybody reading the listing that this
// is a 0.1 project.
//
// Two ways that goes wrong, and this catches the one that matters:
//
//   THE VERSION DRIFTS. Cosmetic but misleading, and only a human can fix it,
//   because creating a Glama release needs a session and their admin page. No
//   API, checked: the admin route redirects to /sign-up even with a valid key.
//
//   THE TOOLS CHANGE AND NOBODY RE-RELEASES. This is the expensive one. The
//   published score then describes tools that no longer exist, and a directory
//   is telling people something false about what this server does.
//
// So the snapshot records what was last published and at which version. Change
// a tool description and this fails, telling you to refresh the listing - which
// is the only moment a Glama release is actually worth making. Bumping the
// project version alone does not warrant one, and this does not ask for one.

type glamaSnapshot struct {
	Comment string `json:"_comment"`
	Version string `json:"releasedVersion"`
	Digest  string `json:"toolsDigest"`
	Tools   []struct {
		Name        string `json:"name"`
		Description string `json:"description"`
	} `json:"tools"`
}

const snapshotPath = "../../packaging/glama-release.json"

// toolsDigest is over the names, descriptions, schemas and annotations, because
// all four are what Glama reads. A schema change with the same description
// still changes what the tool is, and so does a tool that stops being marked
// read-only.
func toolsDigest(t *testing.T) (string, []string) {
	t.Helper()
	type entry struct {
		Name, Description string
		Schema            map[string]any
		Annotations       map[string]any
	}
	var es []entry
	var names []string
	for _, tl := range tools() {
		es = append(es, entry{tl.Name, tl.Description, tl.Schema, mcp.Annotations(tl)})
		names = append(names, tl.Name)
	}
	sort.Slice(es, func(a, b int) bool { return es[a].Name < es[b].Name })
	sort.Strings(names)
	b, err := json.Marshal(es)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), names
}

func TestGlamaSnapshotMatchesTheTools(t *testing.T) {
	raw, err := os.ReadFile(snapshotPath)
	if err != nil {
		t.Fatalf("no Glama snapshot at %s: %v", snapshotPath, err)
	}
	var snap glamaSnapshot
	if err := json.Unmarshal(raw, &snap); err != nil {
		t.Fatalf("%s is not readable: %v", snapshotPath, err)
	}

	digest, names := toolsDigest(t)
	if snap.Digest == digest {
		return
	}

	// Say what changed, not just that something did. A digest mismatch with no
	// detail sends somebody diffing seven tool descriptions by eye.
	was := map[string]string{}
	for _, x := range snap.Tools {
		was[x.Name] = x.Description
	}
	var lines []string
	now := map[string]bool{}
	for _, tl := range tools() {
		now[tl.Name] = true
		old, existed := was[tl.Name]
		switch {
		case !existed:
			lines = append(lines, "  added:       "+tl.Name)
		case old != tl.Description:
			lines = append(lines, "  reworded:    "+tl.Name)
		}
	}
	for _, x := range snap.Tools {
		if !now[x.Name] {
			lines = append(lines, "  removed:     "+x.Name)
		}
	}
	if len(lines) == 0 {
		lines = append(lines, "  a schema changed, with every name and description the same")
	}

	t.Errorf(`the MCP tool definitions have changed since the Glama listing was released.

%s

Glama scores these and publishes the score against a release version. The
listing now describes tools that are not these, which is a directory telling
people something false about this server.

To fix, in this order:
  1. https://glama.ai/mcp/servers/heliograph-io/heliograph/admin/dockerfile
     Build and Release, with the version this project is actually at.
  2. Update %s:
       "releasedVersion": "<that version>"
       "toolsDigest":     "%s"
       and the tools list below it (%d tools: %s)

There is no API for step 1: the admin route redirects to /sign-up even with a
valid key, so it needs a person and a session.`,
		strings.Join(lines, "\n"), snapshotPath, digest, len(names), strings.Join(names, ", "))
}

// A snapshot claiming a version the project has never reached is worse than no
// snapshot: it reads as confirmation that the listing is current.
func TestGlamaSnapshotVersionIsReal(t *testing.T) {
	raw, err := os.ReadFile(snapshotPath)
	if err != nil {
		t.Skip("no snapshot here")
	}
	var snap glamaSnapshot
	if err := json.Unmarshal(raw, &snap); err != nil {
		t.Fatal(err)
	}
	if snap.Version == "" {
		t.Error("the snapshot records no released version, so nothing can be compared to it")
	}
	if strings.HasPrefix(snap.Version, "v") {
		t.Errorf("releasedVersion is %q; write it without the v, as the packaging files do", snap.Version)
	}
	if n := len(snap.Tools); n != len(tools()) {
		t.Errorf("the snapshot lists %d tools and the server has %d", n, len(tools()))
	}
	fmt.Fprintf(os.Stderr, "glama listing released at %s\n", snap.Version)
}

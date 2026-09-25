package packaging

import (
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The station image is published by publish-image.yml as
// ghcr.io/<owner>/heliograph-toolkit, and the owner has been heliograph-io since
// the 2026-09-16 transfer. SKILL.md, three pages of the site, six Azure
// templates and the Kubernetes manifest still named ghcr.io/dbhq-uk/..., an
// image built from the deleted skill repository, while the Dockerfile comment
// said the station was built there. A user following them ran a stale image.

const (
	stationImage = "ghcr.io/heliograph-io/heliograph-toolkit"
	oldImage     = "dbhq-uk/heliograph-toolkit"
)

// history is where naming the old image is a record rather than an
// instruction: the register and the design documents.
func history(p string) bool {
	return p == "../PLAN.md" || strings.HasPrefix(p, "../docs/")
}

var pinned = regexp.MustCompile(`ghcr\.io/[A-Za-z0-9_.-]+/heliograph-toolkit:([A-Za-z0-9_.-]+)`)

func TestEveryStationImageIsThePublishedPackage(t *testing.T) {
	tags, err := exec.Command("git", "tag", "--list", "v*").Output()
	if err != nil || len(strings.TrimSpace(string(tags))) == 0 {
		t.Skip("no tags in this checkout, so a pinned image cannot be checked against a release")
	}
	released := map[string]bool{}
	for _, tag := range strings.Fields(string(tags)) {
		released[strings.TrimPrefix(tag, "v")] = true
	}

	found := 0
	err = filepath.WalkDir("..", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			switch d.Name() {
			case ".git", "node_modules":
				return filepath.SkipDir
			}
			return nil
		}
		if history(p) || strings.HasSuffix(p, "_test.go") {
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		body := string(b)
		if strings.Contains(body, oldImage) {
			t.Errorf("%s names %s, the image built from the deleted skill repository: use %s", p, oldImage, stationImage)
		}
		for _, m := range pinned.FindAllStringSubmatch(body, -1) {
			// `ghcr.io/org/...:v9.9.9` is the placeholder heliograph.sh and its
			// test use for "any registry-qualified name", not an image to run.
			if strings.HasPrefix(m[0], "ghcr.io/org/") {
				continue
			}
			found++
			if !strings.HasPrefix(m[0], stationImage+":") {
				t.Errorf("%s pins %s, which is not %s", p, m[0], stationImage)
				continue
			}
			// No `v`: the publish workflow strips it, and the site says so.
			if !released[m[1]] {
				t.Errorf("%s pins %s, and there is no release v%s for publish-image.yml to have built it from", p, m[0], m[1])
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if found == 0 {
		t.Fatal("no pinned station image found anywhere, so this checked nothing")
	}
}

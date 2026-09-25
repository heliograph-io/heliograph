package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The helper tables must name functions the helper files define.
//
// The site's table said `lib/terraform.sh` does plan and apply, and that
// `lib/tfguard.sh` refuses an apply whose plan does not match what was
// reviewed. The first has no apply, deliberately, and the second defines
// `tf_lock_guard` and `tg` and nothing about plans. A reader who trusted the
// table would write a step around a function that does not exist, and find out
// on the far side. Each row now names its functions, and each has to be there.

var helperRow = regexp.MustCompile("(?m)^\\| `lib/([a-z]+)\\.sh` \\| (.*) \\|$")
var backticked = regexp.MustCompile("`([a-z][a-z_]*)`")
var defined = regexp.MustCompile(`(?m)^([a-z_][a-z0-9_]*)\(\)`)

func TestHelperTablesNameFunctionsTheHelpersDefine(t *testing.T) {
	lib := filepath.Join(stationDir(t), "station", "bash", "lib")
	files, err := filepath.Glob(filepath.Join(lib, "*.sh"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no helpers in %s", lib)
	}
	// Which file defines each function, so a name from one row that belongs to
	// another file is caught as well as one that belongs to none.
	home := map[string]string{}
	funcs := map[string]map[string]bool{}
	for _, f := range files {
		name := strings.TrimSuffix(filepath.Base(f), ".sh")
		funcs[name] = map[string]bool{}
		for _, m := range defined.FindAllStringSubmatch(read(t, f), -1) {
			funcs[name][m[1]] = true
			home[m[1]] = name
		}
	}

	for _, doc := range []string{
		"../../site/content/steps.md",
		"../../skills/heliograph/references/steps.md",
	} {
		b, err := os.ReadFile(doc)
		if err != nil {
			t.Fatalf("cannot read %s: %v", doc, err)
		}
		rows := helperRow.FindAllStringSubmatch(string(b), -1)
		if len(rows) == 0 {
			t.Errorf("%s has no helper table this test can read", doc)
		}
		for _, row := range rows {
			file, text := row[1], row[2]
			if funcs[file] == nil {
				t.Errorf("%s describes lib/%s.sh, which does not exist", doc, file)
				continue
			}
			named := 0
			for _, m := range backticked.FindAllStringSubmatch(text, -1) {
				w := m[1]
				// A word with no underscore that no helper defines is prose in
				// backticks, such as `nc`, not a claim about a function.
				if !strings.Contains(w, "_") && home[w] == "" {
					continue
				}
				named++
				if !funcs[file][w] {
					where := "no helper file"
					if home[w] != "" {
						where = "lib/" + home[w] + ".sh"
					}
					t.Errorf("%s says lib/%s.sh has `%s`, and it is defined in %s", doc, file, w, where)
				}
			}
			if named == 0 {
				t.Errorf("%s describes lib/%s.sh without naming one function it defines: %q", doc, file, text)
			}
		}
	}
}

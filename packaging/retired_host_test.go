package packaging

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The documentation's old name. Its apex has 301'd to heliograph.io, the
// commercial site, since 2026-09-16, so a link to it lands a reader on a
// product page instead of the toolkit's docs.
const retiredHost = "heliograph.dbhq.uk"

// Nothing that ships may send a reader to the retired host.
//
// The four manifests are what the plugin, the MCP registry, npm and the .mcpb
// bundle show as the homepage, and all four still named it after #145 had
// fixed the npm README beside one of them. Nothing checked the fields, so
// nothing noticed. SKILL.md is what an agent follows, and it is shipped too.
func TestNoManifestSendsAReaderToTheRetiredHost(t *testing.T) {
	for _, f := range []string{
		"../.claude-plugin/plugin.json",
		"../server.json",
		"npm/package.json",
		"mcpb/manifest.json",
		"../skills/heliograph/SKILL.md",
	} {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("cannot read %s: %v", f, err)
		}
		if strings.Contains(string(b), retiredHost) {
			t.Errorf("%s names %s, which now redirects to the commercial site: use https://docs.heliograph.io", f, retiredHost)
		}
	}
}

// And no string the binaries can print links it.
//
// STRING LITERALS, NOT THE WHOLE FILE. Comments mention the old name on
// purpose, as history, and one Go string carries it as a CSS comment saying
// the site moved. A LINK is the defect, so the needle is "://" plus the host,
// and only in what the compiler would put in the binary.
func TestNoShippedStringLinksTheRetiredHost(t *testing.T) {
	fset := token.NewFileSet()
	checked := 0
	for _, root := range []string{"../cmd", "../internal"} {
		err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
				return nil
			}
			f, err := parser.ParseFile(fset, p, nil, 0)
			if err != nil {
				return err
			}
			checked++
			ast.Inspect(f, func(n ast.Node) bool {
				if lit, ok := n.(*ast.BasicLit); ok && lit.Kind == token.STRING &&
					strings.Contains(lit.Value, "://"+retiredHost) {
					t.Errorf("%s: a string links %s, which now redirects to the commercial site", fset.Position(lit.Pos()), retiredHost)
				}
				return true
			})
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	if checked == 0 {
		t.Fatal("no Go source found under cmd/ or internal/, so this checked nothing")
	}
}

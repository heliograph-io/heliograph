package transport

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/heliograph-io/heliograph/internal/wire"
)

func TestShareRoundTripsARequest(t *testing.T) {
	dir := t.TempDir()
	s, err := NewShare(dir, "payments")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.PutRequest(wire.Request{Version: wire.Version, ID: "run-1", Step: "env"}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "payments", "request"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "id: run-1") {
		t.Errorf("got:\n%s", b)
	}
}

// The station polls this directory and can read at any instant. A partially
// written request is one with no id yet, or worse a truncated env, and the
// station would act on it. Write-then-rename is what makes that impossible.
func TestShareLeavesNoPartialRequestBehind(t *testing.T) {
	dir := t.TempDir()
	s, err := NewShare(dir, "p")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.PutRequest(wire.Request{Version: wire.Version, ID: "run-1"}); err != nil {
		t.Fatal(err)
	}
	ents, err := os.ReadDir(filepath.Join(dir, "p"))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Errorf("a temporary file was left behind: %s", e.Name())
		}
	}
}

// Two investigations on one share must not overwrite each other, and a scope
// that is a path would let one write into another.
func TestShareRefusesAScopeThatIsAPath(t *testing.T) {
	dir := t.TempDir()
	for _, bad := range []string{"", "../escape", "a/b", ".", ".."} {
		if _, err := NewShare(dir, bad); err == nil {
			t.Errorf("accepted scope %q", bad)
		}
	}
}

func TestShareScopesAreIndependent(t *testing.T) {
	dir := t.TempDir()
	a, _ := NewShare(dir, "alpha")
	b, _ := NewShare(dir, "beta")
	if err := a.PutRequest(wire.Request{Version: 1, ID: "for-alpha"}); err != nil {
		t.Fatal(err)
	}
	if err := b.PutRequest(wire.Request{Version: 1, ID: "for-beta"}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(dir, "alpha", "request"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(got), "for-alpha") {
		t.Errorf("beta overwrote alpha:\n%s", got)
	}
}

// A share mounted read-only, or one whose server has gone away leaving a stale
// handle, stats perfectly and fails on the first write. That write would be the
// log, an hour later, with nobody left to tell.
func TestShareCheckWritesRatherThanStats(t *testing.T) {
	dir := t.TempDir()
	s, err := NewShare(dir, "p")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Check(); err != nil {
		t.Fatalf("Check failed on a writable share: %v", err)
	}
	// And it must leave nothing behind.
	ents, _ := os.ReadDir(filepath.Join(dir, "p"))
	for _, e := range ents {
		if strings.Contains(e.Name(), "write-check") {
			t.Errorf("Check left %s behind", e.Name())
		}
	}

	if os.Geteuid() == 0 {
		t.Log("running as root, so the read-only half cannot be exercised")
		return
	}
	ro := t.TempDir()
	if _, err := NewShare(ro, "p"); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(ro, "p"), 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(filepath.Join(ro, "p"), 0o755) })
	s2 := &Share{dir: ro, scope: "p"}
	if err := s2.Check(); err == nil {
		t.Error("Check passed against a read-only share")
	}
}

func TestShareListsLogsNewestFirst(t *testing.T) {
	dir := t.TempDir()
	s, err := NewShare(dir, "p")
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{
		"env-20260906T090000Z.txt",
		"net-20260906T104500Z.txt",
		"env-20260906T101500Z.txt",
		"notes.md",
	} {
		if err := os.WriteFile(filepath.Join(dir, "p", "ops-logs", n), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got, err := s.ListLogs()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Fatalf("got %v", got)
	}
	if !strings.Contains(got[0], "104500Z") {
		t.Errorf("not newest first: %v", got)
	}
}

func TestShareRefusesALogPathOutsideItsDirectory(t *testing.T) {
	dir := t.TempDir()
	s, _ := NewShare(dir, "p")
	for _, bad := range []string{"../../etc/passwd", "/etc/passwd", "ops-logs/../../x"} {
		if _, err := s.ReadLog(bad); err == nil {
			t.Errorf("read %q", bad)
		}
	}
}

// --- bundle -------------------------------------------------------------------

func TestBundleWritesACarryableFile(t *testing.T) {
	dir := t.TempDir()
	b, err := NewBundle(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := b.PutRequest(wire.Request{Version: wire.Version, ID: "20260906T101500Z-net", Step: "net"}); err != nil {
		t.Fatal(err)
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var found string
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".hgb") {
			found = e.Name()
		}
	}
	if found == "" {
		t.Fatal("no bundle was written")
	}
	// The name carries the id, so a stack of them on a stick is self-describing
	// and sorts into the order they were made.
	if !strings.Contains(found, "20260906T101500Z-net") {
		t.Errorf("the bundle name does not carry the id: %s", found)
	}
}

// `heliograph mcp` publishes through this, and there stdout is the protocol.
// The carry instructions went to stdout, so a heliograph_send or heliograph_stop
// over a bundle estate put four lines of prose into the JSON-RPC stream.
func TestBundleWritesNothingToStdout(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	saved := os.Stdout
	os.Stdout = w
	b, _ := NewBundle(t.TempDir())
	putErr := b.PutRequest(wire.Request{Version: wire.Version, ID: "20260906T101500Z-net", Step: "net"})
	os.Stdout = saved
	_ = w.Close()
	out, _ := io.ReadAll(r)
	if putErr != nil {
		t.Fatal(putErr)
	}
	if len(out) != 0 {
		t.Errorf("PutRequest wrote to stdout, which is the MCP protocol stream:\n%s", out)
	}
}

// An id reaches a filename and is partly caller-supplied. A separator in it
// would write somewhere nobody asked for.
func TestBundleNeutralisesASeparatorInTheID(t *testing.T) {
	dir := t.TempDir()
	b, _ := NewBundle(dir)
	if err := b.PutRequest(wire.Request{Version: 1, ID: "../../escape"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(dir), "escape")); err == nil {
		t.Error("a bundle was written outside its directory")
	}
	ents, _ := os.ReadDir(dir)
	if len(ents) != 1 {
		t.Errorf("expected one bundle in the directory, got %d", len(ents))
	}
}

func TestSafeFileComponent(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"20260906T101500Z-net", "20260906T101500Z-net"},
		{"a/b", "a-b"},
		{"../x", "x"},
		{"a b;c", "a-b-c"},
	} {
		if got := safeFileComponent(tc.in); got != tc.want {
			t.Errorf("%q: got %q want %q", tc.in, got, tc.want)
		}
	}
	// An id that reduces to nothing must still produce a usable name rather
	// than an empty one.
	if got := safeFileComponent("///"); got == "" || strings.Contains(got, "/") {
		t.Errorf("got %q", got)
	}
}

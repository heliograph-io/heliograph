package transport

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/heliograph-io/heliograph/internal/wire"
)

// Share carries the documents through a directory both sides can see: an SMB
// mount, an NFS export, a shared volume, a folder on a jump host.
//
// It is the cheapest transport there is and it covers a real population. An
// estate that will not open an egress path, will not provision a storage
// account and will not permit a git host will quite often already have a share
// that both machines mount, because that is how everything else in the estate
// moves files.
//
// It needs no credential of its own: the mount is the credential, which is
// also its whole security model and worth being plain about. Anyone who can
// write to the share can queue a request, so the share must be as tightly
// scoped as the account the station runs as.
type Share struct {
	dir   string // the shared directory, as this side sees it
	scope string // subdirectory: one investigation per scope
}

// NewShare attaches to a shared directory.
//
// It requires the directory to exist and to be writable, checked by writing,
// because a share that is mounted read-only looks identical to one that is
// mounted properly until the first log fails to arrive.
func NewShare(dir, scope string) (*Share, error) {
	if scope == "" {
		return nil, errors.New("a share needs a scope: one directory per investigation, so two do not overwrite each other")
	}
	// A WHITELIST, and the reason is not path traversal alone.
	//
	// Refusing separators covers the obvious case. It does not cover the one
	// that bites: the scope is published as the status document's `branch:`
	// value, and that document is line-oriented `key: value`. A scope holding a
	// NEWLINE injects a second key, and the parser keeps the last - so a scope
	// of "x\nstate: running" makes an idle station report itself busy for ever.
	//
	// transports/share.sh refuses exactly this set on the far side. Two copies
	// of one rule, because neither side may assume the other configured it.
	if !validScope(scope) {
		return nil, fmt.Errorf("%q is not a usable scope: it becomes a directory name AND the status document's branch field, so it may hold only letters, digits, dot, hyphen and underscore, and may not begin with a hyphen", scope)
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	fi, err := os.Stat(abs)
	if err != nil {
		return nil, fmt.Errorf("cannot see %s: %w", abs, err)
	}
	if !fi.IsDir() {
		return nil, fmt.Errorf("%s is not a directory", abs)
	}
	s := &Share{dir: abs, scope: scope}
	if err := os.MkdirAll(s.path("ops-logs"), 0o755); err != nil {
		return nil, fmt.Errorf("cannot write to %s: %w", abs, err)
	}
	return s, nil
}

// validScope is the rule both sides apply to a scope.
//
// Letters, digits, dot, hyphen and underscore, not empty, not `.` or `..`, and
// not beginning with a hyphen - which would become an option to whichever
// command the far side hands it to. transports/share.sh spells the same set.
func validScope(s string) bool {
	if s == "" || s == "." || s == ".." || strings.HasPrefix(s, "-") {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9',
			r == '.', r == '-', r == '_':
		default:
			return false
		}
	}
	return true
}

func (s *Share) path(parts ...string) string {
	return filepath.Join(append([]string{s.dir, s.scope}, parts...)...)
}

func (s *Share) Dir() string    { return s.dir }
func (s *Share) Branch() string { return s.scope }

func (s *Share) Describe() string {
	return fmt.Sprintf("file share %s, scope %s, credential: the mount itself", s.dir, s.scope)
}

func (s *Share) Check() error {
	// Written rather than stat'ed. A share mounted read-only, or one whose
	// server has gone away leaving a stale handle, stats perfectly and fails
	// on the first write - which would be the log, an hour later, with nobody
	// left to tell.
	probe := s.path(".heliograph-write-check")
	if err := os.WriteFile(probe, []byte("heliograph write check\n"), 0o644); err != nil {
		return fmt.Errorf("cannot write to the share at %s: %w", s.path(), err)
	}
	return os.Remove(probe)
}

func (s *Share) FetchStatus() (wire.Status, error) {
	b, err := os.ReadFile(s.path("status"))
	if err != nil {
		// A station that has never run has published nothing. Not a fault.
		return wire.Status{}, nil
	}
	return wire.ParseStatus(b)
}

// FetchRequest reads the request in the scope's slot. The station reads it and
// never writes it.
func (s *Share) FetchRequest() (wire.Request, error) {
	b, err := os.ReadFile(s.path("request"))
	if err != nil {
		if os.IsNotExist(err) {
			return wire.Request{}, nil
		}
		return wire.Request{}, err
	}
	return wire.ParseRequest(b)
}

// PutRequest writes the request atomically.
//
// Write-then-rename, because a station polling this directory can read it at
// any instant. A partially written request is a request with no `id:` yet, or
// worse a truncated `env:`, and the station would act on it. Rename within a
// directory is atomic on every filesystem worth running this on.
func (s *Share) PutRequest(r wire.Request) error {
	if err := r.Validate(); err != nil {
		return err
	}
	final := s.path("request")
	tmp := final + ".tmp"
	if err := os.MkdirAll(filepath.Dir(final), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(tmp, r.Marshal(), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, final); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func (s *Share) ListLogs() ([]string, error) {
	ents, err := os.ReadDir(s.path("ops-logs"))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var names []string
	for _, e := range ents {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".txt") {
			names = append(names, e.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names)))
	return names, nil
}

func (s *Share) ReadLog(name string) ([]byte, error) {
	clean, err := safeLogName(name)
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(s.path("ops-logs", clean))
	if err != nil {
		return nil, fmt.Errorf("no log named %q on the share", clean)
	}
	return b, nil
}

var _ Transport = (*Share)(nil)

// --- bundle ------------------------------------------------------------------

// Bundle is the transport for a gap nothing crosses: a request is exported to a
// file, carried by hand, and the reply is imported the same way.
//
// This is the only thing that makes "air-gapped" literally true rather than
// nearly true. Everything else here still needs some path between the two
// machines, even if it is a storage account nobody can route to directly.
//
// It is not a loop and does not pretend to be. A run takes as long as it takes
// somebody to walk, and the value is that the format, the gates and the log are
// identical to every other transport - the method survives the walk.
type Bundle struct {
	dir string // where bundles are written and read
}

func NewBundle(dir string) (*Bundle, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		return nil, err
	}
	return &Bundle{dir: abs}, nil
}

func (b *Bundle) Dir() string    { return b.dir }
func (b *Bundle) Branch() string { return "bundle" }

func (b *Bundle) Describe() string {
	return fmt.Sprintf("bundle in %s, carried by hand", b.dir)
}

// Check reports what a bundle can and cannot do, rather than pretending to
// reach something. There is nothing to reach: that is the point.
func (b *Bundle) Check() error {
	probe := filepath.Join(b.dir, ".heliograph-write-check")
	if err := os.WriteFile(probe, []byte("x"), 0o644); err != nil {
		return fmt.Errorf("cannot write bundles to %s: %w", b.dir, err)
	}
	return os.Remove(probe)
}

// PutRequest writes a request bundle for somebody to carry.
//
// The name carries the id, so a stack of them on a USB stick is self-describing
// and sorts into the order they were made.
func (b *Bundle) PutRequest(r wire.Request) error {
	if err := r.Validate(); err != nil {
		return err
	}
	name := fmt.Sprintf("request-%s.hgb", safeFileComponent(r.ID))
	path := filepath.Join(b.dir, name)
	if err := os.WriteFile(path, r.Marshal(), 0o644); err != nil {
		return err
	}
	// ON STDERR, because `heliograph mcp` calls this too, and there stdout is
	// the protocol: these lines would be read as a malformed message.
	fmt.Fprintf(os.Stderr, "bundle written: %s\n", path)
	// WHAT TO DO NEXT, and it has been wrong twice. It first named
	// `./station.sh --bundle`, a flag that has never existed; it was then
	// corrected to say the bundle had no station side at all, which was true
	// until transports/bundle.sh landed. Both cost somebody an afternoon
	// before they concluded the tool was broken, so this says the thing that
	// is true now and names the variables rather than a flag.
	fmt.Fprintln(os.Stderr, "  carry it across, then on the far side:")
	fmt.Fprintln(os.Stderr, "    TRANSPORT=bundle BUNDLE_DIR=<where you mounted it> ./start.sh -- --once")
	fmt.Fprintln(os.Stderr, "  and carry the medium back. https://docs.heliograph.io/air-gapped")
	return nil
}

// FetchStatus reads a reply bundle that has been carried back.
func (b *Bundle) FetchStatus() (wire.Status, error) {
	c, err := os.ReadFile(filepath.Join(b.dir, "status"))
	if err != nil {
		return wire.Status{}, nil
	}
	return wire.ParseStatus(c)
}

func (b *Bundle) ListLogs() ([]string, error) {
	ents, err := os.ReadDir(b.dir)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range ents {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".txt") {
			names = append(names, e.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names)))
	return names, nil
}

func (b *Bundle) ReadLog(name string) ([]byte, error) {
	clean, err := safeLogName(name)
	if err != nil {
		return nil, err
	}
	return os.ReadFile(filepath.Join(b.dir, clean))
}

var _ Transport = (*Bundle)(nil)

// safeFileComponent makes a string usable as one path element.
//
// An id reaches a filename, and an id is partly caller-supplied. A separator in
// it would write somewhere nobody asked for.
func safeFileComponent(s string) string {
	if s == "" {
		return time.Now().UTC().Format("20060102T150405Z")
	}
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9',
			r == '-', r == '_', r == '.':
			b.WriteRune(r)
		default:
			b.WriteRune('-')
		}
	}
	out := strings.Trim(b.String(), ".-")
	if out == "" {
		return time.Now().UTC().Format("20060102T150405Z")
	}
	return out
}

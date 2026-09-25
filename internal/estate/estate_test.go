package estate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRoundTripsThroughDisk(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	e := Estate{Name: "payments", Transport: "git", Dir: "/w/payments", Branch: "task/dns"}
	if err := e.Save(); err != nil {
		t.Fatal(err)
	}
	got, err := Load("payments")
	if err != nil {
		t.Fatal(err)
	}
	if got != e {
		t.Errorf("got %+v want %+v", got, e)
	}
}

// The error has to name what was not found. "estate not found" sends the
// reader to check a spelling they cannot see.
func TestLoadNamesTheEstateItCouldNotFind(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	_, err := Load("nope")
	if err == nil {
		t.Fatal("loading a missing estate succeeded")
	}
	if !strings.Contains(err.Error(), "nope") {
		t.Errorf("the error does not name the estate: %v", err)
	}
}

// The name becomes a filename. `../../.ssh/authorized_keys` must not.
func TestSaveRefusesANameThatEscapesTheConfigDirectory(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	for _, bad := range []string{"../escape", "a/b", "/abs", "..", ".", ""} {
		if err := (Estate{Name: bad, Transport: "git"}).Save(); err == nil {
			t.Errorf("saved an estate named %q", bad)
		}
	}
	// And nothing was written outside where it belongs.
	if _, err := os.Stat(filepath.Join(dir, "escape.json")); err == nil {
		t.Error("a file was written outside the estates directory")
	}
}

func TestLoadRefusesTheSameNames(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	for _, bad := range []string{"../escape", "a/b", "/abs"} {
		if _, err := Load(bad); err == nil {
			t.Errorf("loaded an estate named %q", bad)
		}
	}
}

func TestListIsSortedAndSkipsRubbish(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	for _, n := range []string{"zeta", "alpha", "mid"} {
		if err := (Estate{Name: n, Transport: "git", Dir: "/w/" + n}).Save(); err != nil {
			t.Fatal(err)
		}
	}
	// Something that is not ours, in the same directory.
	if err := os.WriteFile(filepath.Join(dir, "heliograph", "estates", "notes.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := List()
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"alpha", "mid", "zeta"}
	if len(got) != len(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v want %v", got, want)
		}
	}
}

// An estate with no transport, or no directory, cannot be acted on. Catching
// it at save time is far cheaper than at send time, when the reader is already
// waiting on a machine they cannot reach.
func TestSaveRefusesAnUnusableEstate(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	if err := (Estate{Name: "x"}).Save(); err == nil {
		t.Error("saved an estate with no transport")
	}
	if err := (Estate{Name: "x", Transport: "carrier-pigeon", Dir: "/w"}).Save(); err == nil {
		t.Error("saved an estate with an unknown transport")
	}
}

// The config file may name a directory and, later, a token path. It is not a
// secret store, but it is not world-readable either.
func TestConfigIsNotWorldReadable(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := (Estate{Name: "p", Transport: "git", Dir: "/w"}).Save(); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(filepath.Join(dir, "heliograph", "estates", "p.json"))
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm()&0o077 != 0 {
		t.Errorf("mode is %o, which is readable by others", fi.Mode().Perm())
	}
}

// The last-sent id is what `watch` compares the status against. It has to
// survive between two invocations, stay per estate, and read as "nothing sent"
// rather than as an error when there is no record.
func TestLastSentIsPerEstateAndSurvives(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	if got, err := LastSent("payments"); err != nil || got != "" {
		t.Fatalf("nothing sent should read as empty, got %q, %v", got, err)
	}
	if err := RecordSent("payments", "20260925T070000Z-env"); err != nil {
		t.Fatal(err)
	}
	if err := RecordSent("cardnet", "20260925T070100Z-net"); err != nil {
		t.Fatal(err)
	}
	if got, _ := LastSent("payments"); got != "20260925T070000Z-env" {
		t.Errorf("payments read back %q", got)
	}
	if got, _ := LastSent("cardnet"); got != "20260925T070100Z-net" {
		t.Errorf("cardnet read back %q", got)
	}
	// A record is not an estate. List must not start reporting one.
	if names, _ := List(); len(names) != 0 {
		t.Errorf("a last-sent record was listed as an estate: %v", names)
	}
	if err := RecordSent("../escape", "x"); err == nil {
		t.Error("a name that escapes the state directory was accepted")
	}
}

// Package estate remembers which transport repo a name refers to, so that
// every other command can be typed without one.
//
// An investigation runs for days and the commands are typed under pressure.
// `heliograph send net-probe` has to be the whole thing; re-stating a path and
// a branch on every invocation is how the wrong repo gets a request.
package estate

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Estate is one transport repo, under a name a person chose.
type Estate struct {
	Name      string `json:"name"`
	Transport string `json:"transport"` // git | share | bundle | objstore
	Dir       string `json:"dir"`       // the working clone, or the endpoint for objstore
	Branch    string `json:"branch"`    // recorded for reporting; the checkout decides
	Scope     string `json:"scope"`     // share: one directory, objstore: one lane, per investigation

	// objstore only. Identifiers, all of them: an endpoint, a bucket and a
	// prefix say WHERE, and none of them opens anything.
	//
	// The keys are deliberately absent and there is no field for them. They
	// come from HELIOGRAPH_S3_ACCESS_KEY and HELIOGRAPH_S3_SECRET_KEY at the
	// moment of use. This file is on disk, gets copied between machines and
	// ends up in backups, and a secret in it would be a secret in all three.
	Bucket string `json:"bucket,omitempty"`
	Prefix string `json:"prefix,omitempty"`
	Region string `json:"region,omitempty"`

	// relay only. Dir carries the relay's base URL and Scope the station name,
	// the same way Dir carries an endpoint for objstore.
	//
	// RelayEstate is the estate id the RELAY routes on, which is not this
	// estate's local name. One is chosen by whoever runs the relay and appears
	// in its token configuration; the other is what you type. Conflating them
	// would mean renaming a local estate silently re-pointed it at a route that
	// does not exist, and 401 is what that looks like from here.
	RelayEstate string `json:"relay_estate,omitempty"`

	// Paths, not keys. Identity is this side's secret key file and Peer is the
	// station's public identity.
	//
	// The SECRET stays in its own file at mode 600 rather than being inlined
	// here, for the reason the objstore keys are absent entirely: this file is
	// copied between machines and ends up in backups. A path in a backup is a
	// path; a secret in a backup is a secret.
	//
	// The TOKEN has no field at all. It comes from HELIOGRAPH_RELAY_TOKEN at
	// the moment of use. It is a routing and rate-limiting credential rather
	// than the security boundary - the relay cannot read a message whatever
	// token it is shown - but it is still a bearer credential, and this file is
	// not where those live.
	Identity string `json:"identity,omitempty"`
	Peer     string `json:"peer,omitempty"`
}

// known transports. A name that is not here is refused at save time rather
// than at send time, when somebody is already waiting on a far side.
var known = map[string]bool{
	"git": true, "share": true, "bundle": true, "objstore": true, "relay": true,
}

// KeyDir is where per-estate secrets and peer identities live, and it is
// deliberately NOT the estates directory.
//
// The first version put the relay's identity at `estates/<name>.identity.json`,
// which List picks up as an estate: `heliograph send` then reported "several
// estates configured (relayed, relayed.identity)" and refused to guess. The
// same would have happened to the relay's sequence-number file. A directory
// whose every `*.json` is an estate may hold only estates.
//
// Mode 0700, because what goes in here is a secret key.
func KeyDir() (string, error) {
	base, err := heliographDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(base, "keys")
	return dir, os.MkdirAll(dir, 0o700)
}

// StateDir is where a transport keeps what it must not lose. The relay's
// sequence numbers are the case, and they are the replay defence: losing them
// would let a relay replay everything it has ever seen.
func StateDir() (string, error) {
	base, err := heliographDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(base, "state")
	return dir, os.MkdirAll(dir, 0o700)
}

// ConfigHome is the one directory everything heliograph keeps on this machine
// lives under, exported so that a second package does not have to re-implement
// the XDG rule.
//
// ONE IMPLEMENTATION, because two readers of one location is a location that
// drifts: a credential written where a later build does not look is a sign-in
// that silently stopped working. This repository has paid for that shape once
// already, with `.station-env` read by a bash validator and a PowerShell one
// that classified the same file differently.
func ConfigHome() (string, error) { return heliographDir() }

func heliographDir() (string, error) {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "heliograph"), nil
}

func configDir() (string, error) {
	base, err := heliographDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "estates"), nil
}

// validName refuses anything that is not a single path element.
//
// The name becomes a filename, so `../../.ssh/authorized_keys` has to be
// refused here rather than trusted to behave. This is a small surface and an
// unpleasant one to get wrong.
// Routing is what this estate is bound to: the git branch, the share
// directory, the object-store lane.
//
// Scope is canonical and Branch is the fallback, in that order, because
// estates written before Scope existed recorded a git branch in Branch alone.
// Reading Scope only would silently un-pin every estate in the field, which is
// the opposite of what pinning is for.
func (e Estate) Routing() string {
	if e.Scope != "" {
		return e.Scope
	}
	return e.Branch
}

// ValidName is validName, exported so a caller can refuse a bad name BEFORE it
// creates a branch and a checkout named after it. Save would catch it, by which
// point there is a pushed branch and a worktree to clean up.
func ValidName(n string) error { return validName(n) }

// isLoopback is deliberately narrow: a hostname somebody controls could resolve
// to loopback today and elsewhere tomorrow, so only the literals are accepted.
func isLoopback(u string) bool {
	for _, p := range []string{"http://127.0.0.1", "http://localhost", "http://[::1]"} {
		if strings.HasPrefix(u, p+"/") || strings.HasPrefix(u, p+":") || u == p {
			return true
		}
	}
	return false
}

// validRoutingKey is the rule for anything that becomes one segment of a relay
// URL path. transports/relay.sh spells the same set.
func validRoutingKey(v string) bool {
	if v == "" || strings.HasPrefix(v, "-") {
		return false
	}
	for _, r := range v {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9',
			r == '.', r == '-', r == '_':
		default:
			return false
		}
	}
	return true
}

func validName(n string) error {
	if n == "" {
		return fmt.Errorf("an estate needs a name")
	}
	if n == "." || n == ".." || strings.ContainsAny(n, `/\`) || strings.HasPrefix(n, ".") {
		return fmt.Errorf("%q is not a usable estate name: use letters, digits, dashes", n)
	}
	return nil
}

// Save writes the estate, refusing one that could not be acted on.
func (e Estate) Save() error {
	if err := validName(e.Name); err != nil {
		return err
	}
	if !known[e.Transport] {
		return fmt.Errorf("unknown transport %q: this build knows git, share, bundle, objstore and relay", e.Transport)
	}
	if e.Dir == "" {
		return fmt.Errorf("estate %q has no directory: it would have nothing to write to", e.Name)
	}
	if e.Transport == "objstore" && e.Bucket == "" {
		return fmt.Errorf("estate %q is an object store with no bucket", e.Name)
	}
	// Checked at SAVE, not at send. Every one of these is something the
	// operator can supply now, in front of a prompt, and none of them can be
	// guessed later - so an estate missing one is an estate that fails at the
	// moment somebody is already waiting on a far side.
	//
	// The peer is the exception and is deliberately NOT required: the station's
	// public identity does not exist until the operator has run keygen there,
	// which is after this estate has to be recorded in order to print them
	// their instructions. `relay peer` fills it in, and `send` refuses without
	// it, naming that command.
	if e.Transport == "relay" {
		// HTTPS, because the token is a bearer credential in a header. It is
		// not the security boundary - the relay cannot read a message whatever
		// token it is shown - but a credential in cleartext on the wire is a
		// credential anybody on the path can use for denial of service and
		// metadata, and there is no reason to allow it.
		//
		// Loopback is the exception, and only loopback: a test double and a
		// relay running on the same machine have no network to protect.
		if !strings.HasPrefix(e.Dir, "https://") && !isLoopback(e.Dir) {
			return fmt.Errorf("estate %q points at %q. A relay needs https://, because the token travels as a bearer header on every request", e.Name, e.Dir)
		}
		// INTERPOLATED INTO A URL PATH, both of them. A `/` reaches a different
		// route, a `?` starts a query string and a `#` truncates the path - all
		// silently, and all ending as a 404 or as somebody else's queue.
		// transports/relay.sh applies the same rule on the far side.
		for what, v := range map[string]string{"relay estate id": e.RelayEstate, "station name": e.Scope} {
			if v != "" && !validRoutingKey(v) {
				return fmt.Errorf("estate %q has %s %q, which is not a usable routing key: it becomes part of a URL path, so it may hold only letters, digits, dot, hyphen and underscore, and may not begin with a hyphen", e.Name, what, v)
			}
		}
		if e.RelayEstate == "" {
			return fmt.Errorf("estate %q is a relay with no relay estate id: that is what the relay routes on, and it is not this estate's name", e.Name)
		}
		if e.Scope == "" {
			return fmt.Errorf("estate %q is a relay with no station name: that is what a run is bound to", e.Name)
		}
		if e.Identity == "" {
			return fmt.Errorf("estate %q is a relay with no identity file: without one nothing it sends can be verified by the station", e.Name)
		}
	}
	dir, err := configDir()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(e, "", "  ")
	if err != nil {
		return err
	}
	// 0600: this names a working directory and may later name a token file.
	// Not a secret store, but not other people's business either.
	return os.WriteFile(filepath.Join(dir, e.Name+".json"), append(b, '\n'), 0o600)
}

// Load reads an estate by name.
func Load(name string) (Estate, error) {
	if err := validName(name); err != nil {
		return Estate{}, err
	}
	dir, err := configDir()
	if err != nil {
		return Estate{}, err
	}
	b, err := os.ReadFile(filepath.Join(dir, name+".json"))
	if err != nil {
		if os.IsNotExist(err) {
			// Name what was not found. "estate not found" sends the reader to
			// check a spelling they cannot see.
			return Estate{}, fmt.Errorf("no estate named %q: run `heliograph init %s --dir <path>` first", name, name)
		}
		return Estate{}, err
	}
	var e Estate
	if err := json.Unmarshal(b, &e); err != nil {
		return Estate{}, fmt.Errorf("estate %q is not readable: %w", name, err)
	}
	return e, nil
}

// List names every estate, sorted.
func List() ([]string, error) {
	dir, err := configDir()
	if err != nil {
		return nil, err
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var names []string
	for _, e := range ents {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		names = append(names, strings.TrimSuffix(e.Name(), ".json"))
	}
	sort.Strings(names)
	return names, nil
}

// RecordSent remembers the id of the last request sent to an estate from this
// machine.
//
// THE STATUS SAYS WHAT THE STATION DID LAST, NOT WHAT IT WAS ASKED LAST. Straight
// after a send the two differ for a whole poll interval, and in that window the
// status still describes the previous run. `watch` used to stop on the first
// finished state it saw, so it reported the previous run as the result - and
// after an earlier refusal it told the reader to restart the station with
// --allow-actions, for a request that had not been read yet. Remembering the id
// is what lets the reader tell "finished" from "not picked up yet".
//
// Kept in the state directory beside the relay's sequence numbers, not in the
// estate file: it changes on every send, and the estate file is configuration.
func RecordSent(name, id string) error {
	path, err := sentPath(name)
	if err != nil {
		return err
	}
	return os.WriteFile(path, []byte(id+"\n"), 0o600)
}

// LastSent returns the id RecordSent last wrote for an estate, or "" when
// nothing has been sent from this machine. Nothing recorded is not an error:
// every estate configured before this existed has no record.
func LastSent(name string) (string, error) {
	path, err := sentPath(name)
	if err != nil {
		return "", err
	}
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

func sentPath(name string) (string, error) {
	if err := validName(name); err != nil {
		return "", err
	}
	dir, err := StateDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, name+".last-sent"), nil
}

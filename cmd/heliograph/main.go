// Command heliograph drives a station across a gap you cannot cross yourself.
//
// This is the control side. It publishes a request, and reads the log that
// comes back. The far side is a stock heliograph station and nothing
// here requires a change to it.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"time"

	"github.com/heliograph-io/heliograph/internal/bootstrap"
	"github.com/heliograph-io/heliograph/internal/cloud"
	"github.com/heliograph-io/heliograph/internal/logfile"
	"github.com/heliograph-io/heliograph/internal/plant"
	"github.com/heliograph-io/heliograph/internal/seal"
	"github.com/heliograph-io/heliograph/station"

	"github.com/heliograph-io/heliograph/internal/estate"
	"github.com/heliograph-io/heliograph/internal/transport"
	"github.com/heliograph-io/heliograph/internal/wire"
)

// version is set at build time with -ldflags by `packaging/reproduce.sh`,
// which is what the release workflow runs. "dev" means somebody built this
// from source, which is worth saying rather than printing a version that is
// not one.
//
// `go install` DOES NOT RUN THAT SCRIPT, and that is the whole reason
// `buildVersion` exists below. Until 2026-09-17 this variable was the only
// source, so the published
// `go install github.com/heliograph-io/heliograph/cmd/heliograph@v0.4.3`
// produced a binary reporting `heliograph dev` while the identical binary from
// the release reported `heliograph v0.4.3`.
//
// That is worse here than in most projects. `site/content/provenance.md` asks
// a reader to check their binary against a release's SHA256SUMS and its
// Sigstore bundle, and every one of those procedures starts by knowing which
// release you have. One of three published install paths could not answer.
var version = "dev"

// buildVersion is what the binary reports, and it prefers the ldflags value.
//
// Go records the module version in the binary for a `go install module@version`
// build, so the answer is already there for the path ldflags cannot reach.
// Reading it costs nothing and covers install routes nobody has thought of yet,
// which stamping harder never would: ldflags can only ever fix the builds we
// run ourselves, and `go install` is by definition not one of them.
//
// The order matters. ldflags wins because a release build is the case where we
// know the answer exactly.
//
// WHAT THE OTHER THREE BUILDS ACTUALLY REPORT, measured rather than assumed:
//
//	go build -buildvcs=false ...  -X main.version=v0.4.4   v0.4.4
//	go install module@v0.4.3                               v0.4.3
//	go build            (a git checkout, VCS stamped)      v0.4.4-0.2026...-d3204fe+dirty
//	go build -buildvcs=false                               dev
//
// The third was the surprise. Go stamps VCS by default, so a checkout build
// gets a pseudo-version rather than "(devel)", and it is KEPT: it names the
// base version, the commit and whether the tree was dirty, which is strictly
// more useful than "dev" in the bug report it will end up in. It cannot be
// mistaken for a release either, because no release is ever shaped like that.
//
// `(devel)` is still mapped to "dev" for the fourth case, because two words
// for one state is how a support conversation goes wrong.
func buildVersion() string {
	if version != "dev" {
		return version
	}
	if info, ok := debug.ReadBuildInfo(); ok {
		return resolveVersion(version, info.Main.Version)
	}
	return version
}

// resolveVersion is the precedence, split out so a test can drive it. The
// values it takes are the only two sources there are.
func resolveVersion(ldflags, module string) string {
	if ldflags != "dev" {
		return ldflags
	}
	if module != "" && module != "(devel)" {
		return module
	}
	return ldflags
}

// initTransports is what `init --transport` accepts, in ONE place.
//
// It was three places - the flag's help text, the default arm's error, and the
// documentation - and the documentation is the one that drifted: the site
// carried an `init --transport relay --url ... --estate ...` example naming
// flags that have never existed. internal/transport implements the relay
// perfectly well; nothing here can select it.
//
// A list a test can read is what makes that checkable, which is the whole
// reason this is a variable rather than three string literals.
var initTransports = []string{"git", "share", "bundle", "objstore", "relay"}

const usage = `heliograph - run things on a machine you cannot log into

  heliograph bootstrap <dir>                plant the station payload into a transport repo
      [--flavour bash|powershell|both]      bash by default; powershell for an estate with none
  heliograph login                          sign in to a hosted service, nothing to paste
      [--service <url>] [--status] [--logout]
  heliograph push                           forward this control node's spool to the archive
      [-e <estate>] [--dry-run]
  heliograph rotate                         replace an estate's control credential
      [-e <estate>] [--yes]
  heliograph init <estate> --dir <path>     remember a transport repo by name
      [--transport git|share|bundle|objstore|relay]
      objstore: --dir <https endpoint> --bucket <name> --scope <lane> [--prefix p] [--region r]
                keys come from HELIOGRAPH_S3_ACCESS_KEY and HELIOGRAPH_S3_SECRET_KEY
      relay:    --dir <https base url> --relay-estate <id> --scope <station> [--identity file]
                the token comes from HELIOGRAPH_RELAY_TOKEN
                or --transport relay --hosted, which provisions all three
  heliograph relay peer <file|->            record the station's public identity
  heliograph estates                        what is configured here
  heliograph station add <name>             a second station on this repo, on its own branch
      [-e <estate>] [--dir <path>]
  heliograph plant                          what to send the operator
  heliograph send <step> [K=V ...]          publish a request, and return
      [--mode read-only|action] [--expires 24h|0]
  heliograph trust init                     record the anchor this estate is planted with
  heliograph trust show                     who may command this station
  heliograph trust add <name> <key>         a signed change: enrol somebody
  heliograph trust revoke <name>            a signed change: remove somebody
  heliograph status                         what the station is doing now
  heliograph watch [id]                     follow a run until it ends: the last one sent, or <id>
  heliograph logs                           list the captured logs
  heliograph logs <name>                    print one, whole
  heliograph logs --last --gaps             where the last run stalled
  heliograph doctor                         will this work from here, in full
  heliograph mcp                            serve these as tools to an agent
  heliograph version

Common flags:
  -e, --estate <name>   which estate (default: the only one, if there is one)

A step is a name registered in the station's run.sh, or a path to a step file.
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "bootstrap":
		err = cmdBootstrap(os.Args[2:])
	case "init":
		err = cmdInit(os.Args[2:])
	case "login":
		err = cmdLogin(os.Args[2:])
	case "push":
		err = cmdPush(os.Args[2:])
	case "rotate":
		err = cmdRotate(os.Args[2:])
	case "estates":
		err = cmdEstates()
	case "station":
		err = cmdStation(os.Args[2:])
	case "relay":
		err = cmdRelay(os.Args[2:])
	case "trust":
		err = cmdTrust(os.Args[2:])
	case "plant":
		err = cmdPlant(os.Args[2:])
	case "send":
		err = cmdSend(os.Args[2:])
	case "status":
		err = cmdStatus(os.Args[2:])
	case "logs":
		err = cmdLogs(os.Args[2:])
	case "watch":
		err = cmdWatch(os.Args[2:])
	case "check", "doctor":
		err = cmdDoctor(os.Args[2:])
	case "mcp":
		err = cmdMCP(os.Args[2:])
	case "version", "--version":
		fmt.Printf("heliograph %s\n", buildVersion())
		return
	case "-h", "--help", "help":
		fmt.Print(usage)
		return
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n%s", os.Args[1], usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "heliograph: "+err.Error())
		os.Exit(1)
	}
}

// resolve finds the estate to act on.
//
// With exactly one configured, naming it every time is friction for no gain.
// With several, it must be named: sending a request to the wrong estate runs a
// command on the wrong machine, and that is not recoverable by apologising.
func resolve(name string) (estate.Estate, error) {
	if name != "" {
		return estate.Load(name)
	}
	names, err := estate.List()
	if err != nil {
		return estate.Estate{}, err
	}
	switch len(names) {
	case 0:
		return estate.Estate{}, fmt.Errorf("no estates configured: run `heliograph init <name> --dir <path>`")
	case 1:
		return estate.Load(names[0])
	default:
		return estate.Estate{}, fmt.Errorf("several estates configured (%s): name one with --estate",
			strings.Join(names, ", "))
	}
}

// cmdStation manages the stations a git transport repo carries.
//
// One repository can already talk to several machines, one per branch: both
// sides read the branch from whatever is checked out. Nothing designed that and
// nothing could set it up - this package ran no checkout, switch or branch at
// all, so a second station meant doing it by hand.
//
// `station add` does the three things that have to happen together, because
// doing two of them is worse than doing none:
//
//  1. create the branch and push it WITH AN UPSTREAM
//  2. check it out into its own directory, so the control side has one
//     checkout per station and never switches between them
//  3. record it as an estate, so `-e <name>` reaches that machine and only
//     that machine
//
// It then prints what to send the operator, which is the whole point of having
// done the other three.
func cmdStation(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: heliograph station add <name> [-e <estate>] [--dir <path>]")
	}
	switch args[0] {
	case "add":
		return cmdStationAdd(args[1:])
	default:
		return fmt.Errorf("unknown station command %q: the only one is `add`", args[0])
	}
}

func cmdStationAdd(args []string) error {
	fs := flag.NewFlagSet("station add", flag.ExitOnError)
	from := estateFlag(fs)
	dir := fs.String("dir", "", "where to put the new checkout (default: beside the existing one)")
	service := fs.Bool("service", false, "the operator installs it to survive logout")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return fmt.Errorf("usage: heliograph station add <name> [-e <estate>] [--dir <path>]")
	}
	name := pos[0]
	if err := estate.ValidName(name); err != nil {
		return err
	}

	op, err := open(*from)
	if err != nil {
		return err
	}
	if op.Estate.Transport != "git" {
		return fmt.Errorf("estate %q uses the %s transport, and only git has branches to divide",
			op.Estate.Name, op.Estate.Transport)
	}
	g, ok := op.Transport.(*transport.Git)
	if !ok {
		return fmt.Errorf("estate %q is not a git checkout", op.Estate.Name)
	}
	if _, err := estate.Load(name); err == nil {
		return fmt.Errorf("an estate called %q is already configured: pick another name, or `heliograph estates` to see it", name)
	}

	// station/<name>, so a branch that routes a machine is distinguishable
	// from a task branch at a glance. Not enforced anywhere - deployments in
	// the field use task/* and cannot be reached to be upgraded - but it is
	// what this command creates.
	branch := "station/" + name
	target := *dir
	if target == "" {
		target = filepath.Join(filepath.Dir(op.Dir), filepath.Base(op.Dir)+"-"+name)
	}
	target, err = filepath.Abs(target)
	if err != nil {
		return err
	}

	if err := g.CreateBranch(branch); err != nil {
		return err
	}
	if err := g.AddWorktree(target, branch); err != nil {
		return fmt.Errorf("pushed %s but could not check it out: %w", branch, err)
	}

	e := estate.Estate{Name: name, Transport: "git", Dir: target, Branch: branch, Scope: branch}
	if err := e.Save(); err != nil {
		return fmt.Errorf("created %s and its checkout, but could not record the estate: %w", branch, err)
	}

	url, _ := g.RemoteURL()
	fmt.Printf("station %s -> %s on %s\n", name, target, branch)
	fmt.Printf("  drive it with: heliograph send <step> -e %s\n\n", name)

	t := plant.Target{RepoURL: url, Branch: branch, Service: *service}
	out, err := t.Instructions()
	if err != nil {
		return err
	}
	fmt.Print(out)
	return nil
}

// opened is what a command needs: the transport, plus the two facts every
// command prints. Returning the interface rather than *Git is what stops each
// command growing a switch of its own.
type opened struct {
	estate.Estate
	transport.Transport
	Dir    string
	Scope  string
	Origin string // what the far side would clone; empty where that has no meaning
}

func open(name string) (opened, error) {
	e, err := resolve(name)
	if err != nil {
		return opened{}, err
	}
	switch e.Transport {
	case "git":
		g, err := transport.NewGit(e.Dir)
		if err != nil {
			return opened{}, err
		}
		// A PINNED estate is checked against the checkout, and this is hazard 1.
		//
		// Both sides read the branch from whatever is checked out, and nothing
		// consulted what was recorded, so a stray `git checkout` silently
		// retargeted which MACHINE the next send reached.
		//
		// PINNED MEANS Scope, NOT Branch, and the distinction is the difference
		// between a fix and a regression. `init` records the branch it found in
		// Branch and leaves Scope empty; `station add` sets Scope deliberately.
		// So Scope means "this estate names a machine and routing matters",
		// while Branch alone means "this is a working clone, follow it".
		//
		// That second case is not hypothetical, it is the documented workflow:
		// SKILL.md tells you to `git checkout -b task/<slug>` in the transport
		// repo and then send. Pinning on Branch would have broken every
		// existing user on their next task branch, which is a far worse defect
		// than the one being fixed.
		//
		// Fails closed and names both, because the recovery differs: check the
		// branch back out, or re-create the station if it is genuinely meant to
		// live somewhere else now.
		if want := e.Scope; want != "" && want != g.Branch() {
			return opened{}, fmt.Errorf(
				"estate %q is recorded against branch %q and %s is on %q.\n"+
					"  A request sent now would reach a different machine.\n"+
					"  Check that branch back out with `git -C %s checkout %s`",
				e.Name, want, g.Dir(), g.Branch(), g.Dir(), want)
		}
		url, _ := g.RemoteURL()
		return opened{Estate: e, Transport: g, Dir: g.Dir(), Scope: g.Branch(), Origin: url}, nil
	case "share":
		s, err := transport.NewShare(e.Dir, e.Scope)
		if err != nil {
			return opened{}, err
		}
		return opened{Estate: e, Transport: s, Dir: s.Dir(), Scope: s.Branch()}, nil
	case "bundle":
		b, err := transport.NewBundle(e.Dir)
		if err != nil {
			return opened{}, err
		}
		return opened{Estate: e, Transport: b, Dir: b.Dir(), Scope: b.Branch()}, nil
	case "objstore":
		// The keys come from the environment, never from the estate file. That
		// file is on disk, gets copied between machines and ends up in
		// backups; a secret in it would be a secret in all three.
		o, err := transport.NewObjStore(transport.ObjStoreConfig{
			Endpoint:  e.Dir,
			Bucket:    e.Bucket,
			Prefix:    e.Prefix,
			Lane:      e.Scope,
			Region:    e.Region,
			AccessKey: os.Getenv("HELIOGRAPH_S3_ACCESS_KEY"),
			SecretKey: os.Getenv("HELIOGRAPH_S3_SECRET_KEY"),
		})
		if err != nil {
			return opened{}, err
		}
		return opened{Estate: e, Transport: o, Dir: o.Dir(), Scope: o.Branch()}, nil
	case "relay":
		// EVERY MISSING PIECE IS NAMED SEPARATELY, with the command that
		// supplies it. All three fail as HTTP 401 or as a verification that
		// does not happen, and 401 from a relay reads exactly like a fault at
		// the far end - which sends the reader to the wrong side of the gap,
		// to a machine they cannot log into, for a problem that is here.
		if e.Peer == "" {
			return opened{}, fmt.Errorf(
				"estate %q has no station identity yet, so nothing it sent could be verified.\n"+
					"  On the station:  heliograph-seal keygen --out ~/.heliograph-identity\n"+
					"  Then here:       heliograph relay peer -e %s <the public line they send back>",
				e.Name, e.Name)
		}
		// THE ENVIRONMENT WINS AND THE STORE IS THE FALLBACK. The variable is
		// the form a pipeline injects, and a pipeline must not be overridden by
		// whatever a person happened to sign in as on the same machine. The
		// store is what `heliograph login` and `init --hosted` fill in, and it
		// is what makes "the control token never touches the clipboard" true
		// for the whole of a hosted estate's life rather than only at signup.
		token := os.Getenv("HELIOGRAPH_RELAY_TOKEN")
		if token == "" {
			if creds, cerr := cloud.LoadCredentials(); cerr == nil {
				if stored, ok := creds.Estate(e.Name); ok {
					token = stored.Token
				}
			}
		}
		if token == "" {
			return opened{}, fmt.Errorf(
				"estate %q is a relay and it has no control credential here.\n"+
					"  It is the CONTROL token for relay estate %q, from whoever runs the relay.\n"+
					"  Set HELIOGRAPH_RELAY_TOKEN, or sign in with `heliograph login` if it is hosted.\n"+
					"  Without it every call is refused with 401, which reads like a fault at the far end",
				e.Name, e.RelayEstate)
		}
		me, err := seal.LoadIdentityFile(e.Identity)
		if err != nil {
			return opened{}, fmt.Errorf("estate %q cannot read its identity at %s: %w", e.Name, e.Identity, err)
		}
		peer, err := seal.LoadPeerFile(e.Peer)
		if err != nil {
			return opened{}, fmt.Errorf("estate %q cannot read the station identity at %s: %w", e.Name, e.Peer, err)
		}
		// The sequence numbers, beside the estate. They ARE the replay defence,
		// so losing them is not merely inconvenient: a reset would let the relay
		// replay everything it has ever seen.
		st, err := estate.StateDir()
		if err != nil {
			return opened{}, err
		}
		// A SPOOL, because a relay deletes on collection. Every other transport
		// keeps the logs where it put them; here a log arrives exactly once and
		// is then gone from the relay for ever, so if this side does not keep
		// it, nothing does.
		spool, err := estate.StateDir()
		if err != nil {
			return opened{}, err
		}
		r, err := transport.NewRelayWithSpool(e.Dir, e.RelayEstate, e.Scope, token, me, peer,
			filepath.Join(st, e.Name+".relay-state.json"),
			filepath.Join(spool, e.Name+".relay"))
		if err != nil {
			return opened{}, err
		}
		return opened{Estate: e, Transport: r, Dir: r.Dir(), Scope: r.Branch()}, nil
	default:
		return opened{}, fmt.Errorf("estate %q names transport %q, which this build does not know", e.Name, e.Transport)
	}
}

// parse handles flags and positional arguments in any order.
//
// Go's flag package stops at the first non-flag argument, so `init e2e --dir x`
// silently never sees --dir and reports a usage error about an argument that
// was right there. Nobody types flags-before-positionals by instinct, and a
// CLI that insists on it teaches that lesson one confusing error at a time.
//
// Returns the positional arguments in the order they were given.
func parse(fs *flag.FlagSet, args []string) ([]string, error) {
	var pos []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		if fs.NArg() == 0 {
			return pos, nil
		}
		pos = append(pos, fs.Arg(0))
		args = fs.Args()[1:]
	}
}

// estateFlag registers the same two spellings on every subcommand.
func estateFlag(fs *flag.FlagSet) *string {
	s := fs.String("estate", "", "which estate")
	fs.StringVar(s, "e", "", "which estate")
	return s
}

// cmdBootstrap plants the embedded station payload into a transport repo. The
// output mirrors station/bootstrap.sh line for line, because the two are the
// same operation with a different delivery: whichever one somebody ran, the
// next instruction reads the same.
func cmdBootstrap(args []string) error {
	fs := flag.NewFlagSet("bootstrap", flag.ExitOnError)
	flavour := fs.String("flavour", "bash", "which station payload: bash | powershell | both")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return fmt.Errorf("usage: heliograph bootstrap <target-dir> [--flavour bash|powershell|both]\n  the target should be a fresh, PRIVATE repo - captured logs are committed to it")
	}
	target, err := filepath.Abs(pos[0])
	if err != nil {
		return err
	}
	roots, err := bootstrap.ParseFlavours(*flavour)
	if err != nil {
		return err
	}
	// COUNTED ACROSS ALL OF THEM, so `--flavour both` reports one total rather
	// than two the reader has to add up. The per-file lines still name the
	// flavour, because with both planted "exists, left alone" on the second one
	// is the interesting line: it says which payload supplied a shared file.
	var installed, leftAlone int
	for _, root := range roots {
		payload := station.Bash
		if root == "powershell" {
			payload = station.PowerShell
		}
		r, err := bootstrap.Install(payload, root, target)
		if err != nil {
			return err
		}
		prefix := ""
		if len(roots) > 1 {
			prefix = root + ": "
		}
		for _, f := range r.Installed {
			fmt.Printf("  installed          : %s%s\n", prefix, f)
		}
		for _, f := range r.LeftAlone {
			fmt.Printf("  exists, left alone : %s%s\n", prefix, f)
		}
		installed += len(r.Installed)
		leftAlone += len(r.LeftAlone)
	}
	fmt.Printf("\nheliograph: %d file(s) installed, %d left alone, in %s\n", installed, leftAlone, target)
	if _, err := os.Stat(filepath.Join(target, ".git")); err != nil {
		fmt.Printf("\n%s is not a git repository yet, and git is the transport. Next:\n", target)
		fmt.Printf("  cd %s && git init && git add -A && git commit -m 'heliograph: transport repo'\n", target)
		fmt.Println("  then add a PRIVATE remote and push.")
	}
	fmt.Println("\nThen: heliograph init <estate> --dir " + target)
	return nil
}

func cmdInit(args []string) error {
	fs := flag.NewFlagSet("init", flag.ExitOnError)
	dir := fs.String("dir", "", "the working clone, share directory, bundle directory, or object store endpoint")
	kind := fs.String("transport", "git", strings.Join(initTransports, " | "))
	scopeFlag := fs.String("scope", "", "share: one directory per investigation. objstore: one lane")
	bucket := fs.String("bucket", "", "with --transport objstore: the bucket")
	prefix := fs.String("prefix", "", "with --transport objstore: a key prefix, for a bucket shared with something else")
	region := fs.String("region", "", "with --transport objstore: the region (default auto, which suits R2 and MinIO)")
	relayEstate := fs.String("relay-estate", "", "with --transport relay: the estate id the RELAY routes on")
	identity := fs.String("identity", "", "with --transport relay: this side's identity file (default: generated beside the estate)")
	hosted := fs.Bool("hosted", false, "with --transport relay: provision the estate on a hosted service")
	hostedSvc := fs.String("service", "", "with --hosted: the hosted service (default: HELIOGRAPH_CLOUD_URL)")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return fmt.Errorf("usage: heliograph init <estate> --dir <path>")
	}
	name := pos[0]
	// VALIDATED FIRST, before anything is written anywhere.
	//
	// Save checks it too, and by then it is too late for the relay: the identity
	// file is created before Save is reached, so `heliograph init ../estates/x
	// --transport relay` wrote a SECRET KEY into the estates directory - where
	// `heliograph estates` then listed it as an estate. The name becomes a path
	// in more than one place now, so it is settled once, here.
	if err := estate.ValidName(name); err != nil {
		return err
	}
	// --hosted ANSWERS --dir, --relay-estate AND THE TOKEN, which is the whole
	// point of it: those three are what somebody had to stand up a relay and
	// terminate TLS in order to obtain. Answered before --dir is demanded,
	// because demanding it would be demanding the thing being provisioned.
	if *hosted {
		if *kind != "relay" {
			return fmt.Errorf("--hosted provisions a relay estate, and --transport is %q", *kind)
		}
		if *dir != "" {
			return fmt.Errorf("--hosted and --dir disagree: --hosted is what supplies the relay URL")
		}
		if *relayEstate != "" {
			return fmt.Errorf("--hosted and --relay-estate disagree: --hosted is what issues the estate id")
		}
		return hostedProvision(name, *hostedSvc, *scopeFlag)
	}
	if *dir == "" {
		return fmt.Errorf("--dir is required: it is the clone this estate writes to")
	}

	// An object store's --dir is a URL, and filepath.Abs on one turns
	// https://s3.example.com into $PWD/https:/s3.example.com. Silently: the
	// estate saves, and every later command reports that it cannot reach a
	// host with a name nobody typed.
	abs := *dir
	if *kind != "objstore" && *kind != "relay" {
		abs, err = filepath.Abs(*dir)
		if err != nil {
			return err
		}
	}

	// Attach BEFORE saving. An estate that names a directory which is not a
	// usable transport is worse than no estate at all: it fails later, from a
	// command that had every reason to expect it to work.
	var tp transport.Transport
	var scope string
	switch *kind {
	case "git":
		g, err := transport.NewGit(abs)
		if err != nil {
			return err
		}
		tp, scope = g, g.Branch()
	case "share":
		if *scopeFlag == "" {
			return fmt.Errorf("--scope is required for a share: one directory per investigation, so two do not overwrite each other")
		}
		sh, err := transport.NewShare(abs, *scopeFlag)
		if err != nil {
			return err
		}
		tp, scope = sh, sh.Branch()
	case "bundle":
		b, err := transport.NewBundle(abs)
		if err != nil {
			return err
		}
		tp, scope = b, b.Branch()
	case "objstore":
		if *scopeFlag == "" {
			return fmt.Errorf("--scope is required for an object store: it is the lane, one per investigation, so two do not overwrite each other")
		}
		if *bucket == "" {
			return fmt.Errorf("--bucket is required for an object store")
		}
		o, err := transport.NewObjStore(transport.ObjStoreConfig{
			Endpoint:  abs,
			Bucket:    *bucket,
			Prefix:    *prefix,
			Lane:      *scopeFlag,
			Region:    *region,
			AccessKey: os.Getenv("HELIOGRAPH_S3_ACCESS_KEY"),
			SecretKey: os.Getenv("HELIOGRAPH_S3_SECRET_KEY"),
		})
		if err != nil {
			return err
		}
		tp, scope = o, o.Branch()
	case "relay":
		if *relayEstate == "" {
			return fmt.Errorf("--relay-estate is required: it is the id the RELAY routes on, which is chosen by whoever runs the relay and is not this estate's name")
		}
		if *scopeFlag == "" {
			return fmt.Errorf("--scope is required for a relay: it is the station name, and it is what a run is bound to")
		}
		// GENERATED HERE IF NOT SUPPLIED, and generated BEFORE anything is
		// saved. A relay estate with no identity cannot send or read anything,
		// and telling somebody to go and run a second binary to make one is a
		// step nobody needs: this side already has the same code the station's
		// heliograph-seal runs.
		//
		// It goes beside the estate file, in the same 0700 directory, at mode
		// 600. Not in the estate file: that file is copied between machines and
		// ends up in backups.
		idPath := *identity
		if idPath == "" {
			keys, err := estate.KeyDir()
			if err != nil {
				return err
			}
			idPath = filepath.Join(keys, name+".identity.json")
		}
		if _, statErr := os.Stat(idPath); statErr != nil {
			id, genErr := seal.Generate()
			if genErr != nil {
				return genErr
			}
			if err := seal.WriteIdentityFile(idPath, id); err != nil {
				return err
			}
		}
		me, err := seal.LoadIdentityFile(idPath)
		if err != nil {
			return err
		}
		// NO TRANSPORT IS OPENED HERE, and that is the one place this command
		// departs from its own rule of attaching before saving.
		//
		// NewRelay needs the station's public identity, and that does not exist
		// yet: the operator has to run keygen on the far side, which is what
		// the instructions printed below are for. Refusing to record the estate
		// until they have would mean nowhere to record their answer when they
		// send it back.
		//
		// So `send` is what refuses, naming `relay peer`, and the estate is
		// visibly half-finished until then rather than silently broken.
		e := estate.Estate{
			Name: name, Transport: "relay",
			Dir: strings.TrimRight(abs, "/"), Scope: *scopeFlag,
			RelayEstate: *relayEstate, Identity: idPath,
		}
		if err := e.Save(); err != nil {
			return err
		}
		fmt.Printf("estate %s -> relay %s, estate %s, station %s\n",
			name, e.Dir, e.RelayEstate, e.Scope)
		fmt.Printf("  identity: %s\n", idPath)
		fmt.Printf("  fingerprint: %s\n", me.Public().Fingerprint())
		fmt.Println()
		fmt.Println("  Two halves are missing and both come from the far side:")
		fmt.Println("    1. HELIOGRAPH_RELAY_TOKEN in this shell, the CONTROL token for that estate")
		fmt.Println("    2. the station's public identity, recorded with `heliograph relay peer`")
		fmt.Println()
		fmt.Println("  Run `heliograph plant -e " + name + "` for what to send the operator.")
		return nil
	default:
		return fmt.Errorf("unknown transport %q: this build knows %s",
			*kind, strings.Join(initTransports, ", "))
	}

	e := estate.Estate{Name: name, Transport: *kind, Dir: abs, Branch: scope, Scope: *scopeFlag,
		Bucket: *bucket, Prefix: *prefix, Region: *region}
	if err := e.Save(); err != nil {
		return err
	}
	fmt.Printf("estate %s -> %s on %s\n", name, abs, scope)
	fmt.Printf("  %s\n", tp.Describe())
	if err := tp.Check(); err != nil {
		// Saved anyway. Knowing the estate is configured but unreachable is
		// more useful than refusing to record it, and the reason is printed.
		fmt.Printf("  warn: %v\n", err)
	}
	return nil
}

func cmdEstates() error {
	names, err := estate.List()
	if err != nil {
		return err
	}
	if len(names) == 0 {
		fmt.Println("no estates configured")
		return nil
	}
	for _, n := range names {
		e, err := estate.Load(n)
		if err != nil {
			fmt.Printf("%-16s (unreadable: %v)\n", n, err)
			continue
		}
		// The scope is printed because it is what decides which machine the
		// name reaches, and it was previously visible only by inspecting the
		// checkout.
		if r := e.Routing(); r != "" {
			fmt.Printf("%-16s %-7s %-28s %s\n", e.Name, e.Transport, r, e.Dir)
		} else {
			fmt.Printf("%-16s %-7s %-28s %s\n", e.Name, e.Transport, "-", e.Dir)
		}
	}
	return nil
}

func cmdSend(args []string) error {
	fs := flag.NewFlagSet("send", flag.ExitOnError)
	name := estateFlag(fs)
	note := fs.String("note", "", "free text for the next human")
	mode := fs.String("mode", "", "the mode you expect the step to declare: read-only or action")
	// AN EXPIRY BY DEFAULT, and 24 hours is a decision worth stating.
	//
	// Without one, a request lifted out of a transport repo is valid for ever -
	// and `--allow-actions` and `CONFIRM=yes` were decided days before it, so a
	// replayed request is a destructive step running again with every gate
	// already satisfied. A day is long enough for a station that is down when
	// the request is sent and comes back the same working day, which is the case
	// people actually hit; anything longer stops being a bound.
	//
	// `--expires 0` turns it off, for an estate that plants a station a week
	// after writing the request. That is a real workflow, so it has a flag
	// rather than being impossible.
	expires := fs.Duration("expires", 24*time.Hour, "how long this request stays valid; 0 for no expiry")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	if len(pos) < 1 {
		return fmt.Errorf("usage: heliograph send <step> [KEY=VALUE ...]")
	}
	step := pos[0]

	// Everything after the step is environment for the run, passed verbatim.
	// The station splits it the way a shell would.
	var env []string
	for _, a := range pos[1:] {
		if !strings.Contains(a, "=") {
			return fmt.Errorf("%q is not KEY=VALUE: environment for the run goes after the step name", a)
		}
		env = append(env, wire.QuoteEnv(a))
	}

	op, err2 := open(*name)
	if err2 != nil {
		return err2
	}
	req := wire.Request{
		Version: wire.Version,
		ID:      wire.NewID(step, time.Now()),
		Step:    step,
		Env:     strings.Join(env, " "),
		Note:    *note,
		Mode:    *mode,
		// THE STATION THIS WAS WRITTEN FOR, always. A request lifted out of one
		// transport repo and put into another used to run there: the relay binds
		// estate and station inside its envelope, and no other transport bound
		// anything at all. A station refuses a target that is not its own scope,
		// and ignores the key entirely if it predates this - so setting it costs
		// nothing and closes the gap wherever the far side is current.
		Target: op.Scope,
	}
	if *expires > 0 {
		req.Expires = time.Now().UTC().Add(*expires).Format(time.RFC3339)
	}
	if err := req.Validate(); err != nil {
		return err
	}
	if err := op.PutRequest(req); err != nil {
		return err
	}
	// Recorded AFTER it arrived, never before: `watch` waits for this id, and
	// an id that never reached the far side would be waited for indefinitely.
	if err := estate.RecordSent(op.Estate.Name, req.ID); err != nil {
		fmt.Fprintf(os.Stderr, "heliograph: sent, but could not record the id for `watch`: %v\n", err)
	}
	fmt.Printf("sent %s\n", req.ID)
	fmt.Printf("  step: %s\n", step)
	if req.Env != "" {
		fmt.Printf("  env:  %s\n", req.Env)
	}
	if req.Expires != "" {
		fmt.Printf("  valid until %s. A station that reads it later refuses it.\n", req.Expires)
	}
	fmt.Println("  the station picks this up within its poll interval. `heliograph watch` to follow it.")
	return nil
}

func cmdStatus(args []string) error {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	name := estateFlag(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	op, err := open(*name)
	if err != nil {
		return err
	}
	s, err := op.FetchStatus()
	if err != nil {
		return err
	}
	if s.State == "" {
		// Distinguish "never woke up" from "working". Without this they look
		// identical until a log appears, which can be an hour.
		fmt.Println("the station has published no status: it may not have started yet")
		return nil
	}
	// THE STATUS IS ABOUT THE LAST REQUEST THE STATION READ, which straight
	// after a send is not the one just sent. Said first, because everything
	// below it - a refusal especially - reads as this request's result.
	notYet := ""
	if want, _ := estate.LastSent(op.Estate.Name); want != "" {
		notYet, _ = notPickedUp(s, want)
	}
	if notYet != "" {
		fmt.Printf("note:     %s\n", notYet)
		fmt.Println("          everything below is about an earlier request")
		fmt.Println()
	}
	fmt.Printf("state:    %s\n", s.State)
	printIf("id:      ", s.ID)
	printIf("step:    ", s.Step)
	printIf("host:    ", s.Host)
	// Which payload answered. Two stations on the same branch report different
	// hosts; two stations that have drifted report different payloads, and
	// nothing else on this page would say so.
	printIf("payload: ", s.Payload)
	// Printed for EVERY status, including the ones with no value to print.
	// This is the only line here that is a property of the station rather than
	// of the run, and a field that vanishes when it is unknown is a field
	// somebody fills in from memory.
	fmt.Println(actionModeLine(s))
	printIf("started: ", s.Started)
	printIf("progress:", s.Progress)
	printIf("last:    ", s.Last)
	printIf("finished:", s.Finished)
	printIf("exit:    ", s.Exit)
	printIf("log:     ", s.Log)
	// WHO ASKED, when the station could establish it. An archive that can only
	// say the estate asked cannot answer the first question anybody puts to it.
	printIf("by:      ", s.By)
	// WHO MAY COMMAND THIS STATION. Printed here rather than only in `doctor`
	// because this is the command people actually run, and a trusted set nobody
	// looks at is an audit nobody performs.
	if s.Trust != "" {
		fmt.Printf("trust:    %s (serial %s)\n", short12(s.Trust), orDash(s.TrustSerial))
		printIf("members: ", s.TrustMembers)
	}
	if s.Refused() && notYet == "" {
		// A refusal names a flag somebody has to pass. Saying so here saves
		// the round trip that would otherwise be spent looking for a broken
		// step that is not broken.
		fmt.Println()
		fmt.Println("refused: the station would not run this. Its reason is above.")
		fmt.Println("  an action step needs the station started with --allow-actions,")
		fmt.Println("  and the request to carry CONFIRM=yes.")
	}
	return nil
}

func printIf(label, v string) {
	if v != "" {
		fmt.Printf("%s %s\n", label, v)
	}
}

// actionModeLine says whether this station will run a step that changes state.
//
// FOUR SENTENCES AND NO DEFAULT ARM. The two published values are one thing
// each; the two silences are not the same silence and must not read as one.
//
// The absent case is the one that matters. Every station planted before the
// field publishes nothing, and rendering that as read-only would tell somebody
// an estate is safe on the strength of a station that has said nothing at all.
// The sentence therefore says what is true - the station did not answer - and
// then says out loud that this is not read-only, because that is the reading a
// hurried person supplies for themselves.
func actionModeLine(s wire.Status) string {
	switch {
	case s.ActionsAllowed():
		return "actions:  allowed - this station runs a step declaring 'action', with CONFIRM=yes on the request"
	case s.ActionsRefused():
		return "actions:  refused - this station is read-only. The operator restarts it with --allow-actions"
	case s.Actions != "":
		return fmt.Sprintf("actions:  %s - this build does not know that mode. Treat it as neither allowed nor read-only", quoteMode(s.Actions))
	default:
		return "actions:  not reported - this station is older than the field. That is not the same as read-only"
	}
}

// quoteMode shows a mode this build does not recognise without letting it
// impersonate one that is recognised. An unquoted value from the far side sits
// in the sentence looking exactly like a word this side chose.
func quoteMode(v string) string {
	if len(v) > 40 {
		v = v[:40] + "..."
	}
	return "'" + strings.ReplaceAll(v, "'", "") + "'"
}

func cmdLogs(args []string) error {
	fs := flag.NewFlagSet("logs", flag.ExitOnError)
	name := estateFlag(fs)
	last := fs.Bool("last", false, "the most recent log")
	gaps := fs.Bool("gaps", false, "where it stalled, instead of the whole log")
	min := fs.Duration("min", 10*time.Second, "with --gaps, the shortest interval worth reporting")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	op, err := open(*name)
	if err != nil {
		return err
	}

	if len(pos) == 0 && !*last {
		names, err := op.ListLogs()
		if err != nil {
			return err
		}
		if len(names) == 0 {
			fmt.Println("no logs yet")
			return nil
		}
		for _, n := range names {
			fmt.Println(n)
		}
		return nil
	}

	var target string
	if len(pos) > 0 {
		target = pos[0]
	}
	if *last {
		names, err := op.ListLogs()
		if err != nil {
			return err
		}
		if len(names) == 0 {
			return fmt.Errorf("no logs yet")
		}
		target = names[0]
	}
	b, err := op.ReadLog(target)
	if err != nil {
		return err
	}
	if *gaps {
		return printGaps(target, b, *min)
	}
	// Whole, always. The line somebody truncates is the line they needed.
	_, err = os.Stdout.Write(b)
	return err
}

// printGaps turns the timestamp column into an answer.
//
// "Scan the timestamp column for gaps before reading the content" has always
// been a discipline somebody has to remember. It is arithmetic, and a hang
// shows up here as a gap or it does not show up at all.
func printGaps(name string, body []byte, min time.Duration) error {
	n, err := logfile.CountStamped(bytes.NewReader(body))
	if err != nil {
		return err
	}
	found, err := logfile.Gaps(bytes.NewReader(body), min)
	if err != nil {
		// A capture where every line carries the same stamp is broken, and
		// reporting "no gaps" about it would look like a clean run.
		return err
	}
	fmt.Printf("%s\n%d captured lines\n\n", name, n)
	if len(found) == 0 {
		fmt.Printf("no interval of %s or more: nothing stalled\n", min)
		return nil
	}
	fmt.Printf("%d interval(s) of %s or more, longest first.\n", len(found), min)
	fmt.Printf("Each is attributed to the line BEFORE it, which is what was running.\n\n")
	for _, g := range found {
		fmt.Println(g.Format())
	}
	return nil
}

// notPickedUp says whether a status is about some request other than want,
// and if so, what to tell the reader. It returns "" when the status is the
// answer, or when there is no request to compare against.
//
// moved is true when the station has gone PAST want: its status names a request
// sent later. Then the status will never describe want, and waiting longer is
// waiting for ever. The request either ran before the later one, or was
// replaced in the request slot before the station read it.
func notPickedUp(s wire.Status, want string) (msg string, moved bool) {
	if want == "" || s.ID == want {
		return "", false
	}
	if sent, ok := wire.IDTime(want); ok {
		if now, ok := wire.IDTime(s.ID); ok && now.After(sent) {
			return fmt.Sprintf("the station has moved on to %s, which was sent after %s. "+
				"That request either ran earlier or was replaced before the station read it: "+
				"`heliograph logs` lists a log for every run", s.ID, want), true
		}
	}
	if s.State == "" {
		return fmt.Sprintf("not picked up yet: %s. The station has published no status at all", want), false
	}
	return fmt.Sprintf("not picked up yet: %s. The station last published %q for %s",
		want, s.State, orDash(s.ID)), false
}

// cmdWatch follows a run to its end.
//
// Without this the choice is polling `status` by hand or waiting blind, and
// "running for forty minutes" and "wedged" look identical from here until a
// log appears.
//
// IT WAITS FOR ONE REQUEST, not for the first finished state. Straight after a
// send the station has not read the request yet, and its status still
// describes the previous run - so a watch that stopped on any finished state
// reported that run as the result. After an earlier refusal it then told the
// reader to restart the station with --allow-actions, for a request nobody had
// read. The request is the one named, or the last one `send` recorded.
func cmdWatch(args []string) error {
	fs := flag.NewFlagSet("watch", flag.ExitOnError)
	name := estateFlag(fs)
	every := fs.Duration("interval", 10*time.Second, "how often to poll")
	timeout := fs.Duration("timeout", 0, "give up after this long (0 waits indefinitely)")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	if len(pos) > 1 {
		return fmt.Errorf("usage: heliograph watch [id] [--interval 10s] [--timeout 0]")
	}
	op, err := open(*name)
	if err != nil {
		return err
	}
	want := ""
	if len(pos) == 1 {
		want = pos[0]
	} else if want, err = estate.LastSent(op.Estate.Name); err != nil {
		return err
	}
	if want != "" {
		fmt.Printf("%s  waiting for %s\n", stamp(), want)
	} else {
		// Nothing sent from here, so there is nothing to compare against. Say
		// so, because what follows is then whatever the station does next.
		fmt.Printf("%s  no request sent from here: following whatever the station runs\n", stamp())
	}

	deadline := time.Time{}
	if *timeout > 0 {
		deadline = time.Now().Add(*timeout)
	}
	var lastLine string
	for {
		s, err := op.FetchStatus()
		if err != nil {
			// A fetch failure is a blip, not a death. The station's own loop
			// treats it that way and so does this: reporting and carrying on
			// is right for a link that flaps.
			fmt.Printf("%s  fetch failed, still watching: %v\n", stamp(), err)
		} else if msg, moved := notPickedUp(s, want); msg != "" {
			if msg != lastLine {
				fmt.Printf("%s  %s\n", stamp(), msg)
				lastLine = msg
			}
			if moved {
				return fmt.Errorf("stopped watching: the station will not report %s again", want)
			}
		} else {
			line := s.State
			if s.Progress != "" {
				line += "  " + s.Progress
			}
			if s.Last != "" {
				line += "\n           last: " + s.Last
			}
			// Print transitions, not every poll. A watch that reprints the
			// same line every ten seconds buries the change it exists to show.
			if line != lastLine {
				fmt.Printf("%s  %s\n", stamp(), line)
				lastLine = line
			}
			if s.Done() {
				fmt.Println()
				if s.Refused() {
					fmt.Println("refused: the station would not run this.")
					fmt.Println("  an action step needs the station started with --allow-actions,")
					fmt.Println("  and the request to carry CONFIRM=yes.")
					return nil
				}
				if s.Log != "" {
					fmt.Printf("log: %s\n", s.Log)
					fmt.Printf("  heliograph logs --last          to read it\n")
					fmt.Printf("  heliograph logs --last --gaps   to see where it stalled\n")
				}
				return nil
			}
		}
		if !deadline.IsZero() && time.Now().After(deadline) {
			if strings.HasPrefix(lastLine, "not picked up yet") {
				return fmt.Errorf("not picked up after %s: the request is still waiting for the station, this stopped watching", *timeout)
			}
			return fmt.Errorf("still running after %s: the run continues, this stopped watching", *timeout)
		}
		time.Sleep(*every)
	}
}

func stamp() string { return time.Now().UTC().Format("15:04:05Z") }

// cmdDoctor answers "will this work from here" and changes nothing.
//
// Every line that reports a problem also says what to do about it. A preflight
// line that names a fault without a remedy is a defect: the person reading it
// usually cannot ask anybody.
func cmdDoctor(args []string) error {
	fs := flag.NewFlagSet("doctor", flag.ExitOnError)
	name := estateFlag(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	op, err := open(*name)
	if err != nil {
		return err
	}
	fmt.Printf("estate:   %s\n", op.Estate.Name)
	fmt.Printf("dir:      %s\n", op.Dir)
	fmt.Printf("scope:    %s\n", op.Scope)
	fmt.Printf("%s\n", op.Describe())

	problems := 0
	if err := op.Check(); err != nil {
		problems++
		fmt.Printf("FAIL      %v\n", err)
		fmt.Printf("          check that %s is correct and this account may use it\n", op.Dir)
	} else {
		fmt.Println("ok        the transport is reachable")
	}

	s, err := op.FetchStatus()
	switch {
	case err != nil:
		problems++
		fmt.Printf("FAIL      cannot read the station's status: %v\n", err)
	case s.State == "":
		// Not a failure. A station that has never run is the ordinary state
		// of a repo that was set up an hour ago, and saying so plainly beats
		// a warning that reads like something is wrong.
		fmt.Println("note      the station has published no status yet")
		fmt.Println("          it may not have been started: the operator runs ./start.sh once")
	default:
		fmt.Printf("ok        the station last published %q", s.State)
		if s.UTC != "" {
			fmt.Printf(" at %s", s.UTC)
		}
		fmt.Println()
	}

	// --- the trusted set, ours against theirs --------------------------------
	//
	// THE STATION'S COPY IS THE ONE THAT DECIDES, so this reports rather than
	// reconciles. A divergence is the alarm the whole mechanism exists to raise:
	// a key in the station's set that is not in ours is a key somebody added
	// that this machine never authorised, and an estate owner can see that here
	// without asking us and without logging into the machine.
	problems += doctorTrust(op.Estate.Name, s)

	logs, err := op.ListLogs()
	if err != nil {
		problems++
		fmt.Printf("FAIL      cannot list logs: %v\n", err)
	} else {
		fmt.Printf("ok        %d log(s) on this branch\n", len(logs))
	}

	// The hosted half, when there is one. A refusal is read as a refusal here
	// rather than as a generic failure: the nine causes have different remedies
	// and one of them is not the operator's problem at all.
	problems += cloudDoctor(op.Estate)

	if problems > 0 {
		return fmt.Errorf("%d blocking problem(s) above", problems)
	}
	return nil
}

// cmdPlant prints what to send the operator.
//
// Today this is prose in a chat window: somebody types out a clone URL, a
// branch and a command, and the operator retypes them. Every retyping is a
// chance to get it wrong on a machine nobody can check afterwards.
func cmdPlant(args []string) error {
	fs := flag.NewFlagSet("plant", flag.ExitOnError)
	name := estateFlag(fs)
	service := fs.Bool("service", false, "install it to survive logout, rather than run in a shell")
	script := fs.Bool("script", false, "just the commands, with no explanation around them")
	if err := fs.Parse(args); err != nil {
		return err
	}
	// THE RELAY IS ANSWERED BEFORE open(), and that is not a shortcut.
	//
	// open() refuses a relay estate that has no station identity yet, correctly:
	// nothing it sent could be verified. But this command is what the operator
	// is given IN ORDER TO create that identity, so routing it through open()
	// would make the instructions unobtainable until after the step they
	// describe. It only needs the estate, not a live channel.
	if e, rerr := resolve(*name); rerr == nil && e.Transport == "relay" {
		return plantRelay(e, *script)
	}
	op, err := open(*name)
	if err != nil {
		return err
	}
	if op.Origin == "" {
		return fmt.Errorf("estate %q uses the %s transport, which has nothing for the far side to clone: plant it by carrying the toolkit there",
			op.Estate.Name, op.Estate.Transport)
	}
	t := plant.Target{RepoURL: op.Origin, Branch: op.Scope, Service: *service}
	var out string
	if *script {
		out, err = t.Script()
	} else {
		out, err = t.Instructions()
	}
	if err != nil {
		return err
	}
	fmt.Print(out)
	return nil
}

// The env quoting lives in wire.QuoteEnv, with the document it belongs to.

// --- the relay's key exchange ------------------------------------------------
//
// WHY THIS IS A COMMAND AND NOT A PARAGRAPH OF INSTRUCTIONS.
//
// Every other transport's enrolment is "here is a URL and a credential". The
// relay's is a key exchange, and a key exchange written as prose is one people
// get wrong quietly: the failure is a station that starts, polls happily, and
// silently drops every request because it cannot verify the signature. From the
// station's side that is indistinguishable from nobody sending anything.
//
// So the two halves that have to be recorded are recorded by a command that
// validates them, and the fingerprint that closes the enrolment risk is printed
// at both ends so the operator has something to read back.
func cmdRelay(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: heliograph relay peer [-e <estate>] <file|public-identity|->")
	}
	switch args[0] {
	case "peer":
		return cmdRelayPeer(args[1:])
	default:
		return fmt.Errorf("unknown relay command %q: this build knows `peer`", args[0])
	}
}

// cmdRelayPeer records the station's public identity, which is the second half
// of the exchange and the one that arrives last.
//
// IT ACCEPTS THE VALUE OR A PATH, because both are what actually happens. The
// operator on the far side runs `heliograph-seal keygen` and sends back one
// line, usually pasted into a ticket or a chat message. Requiring it to be
// saved to a file first is a step that exists only to suit the parser.
func cmdRelayPeer(args []string) error {
	// PARSED BY HAND, and this is the reason rather than a preference.
	//
	// A public identity is base64url, whose alphabet includes `-` and `_`. So
	// roughly one key in sixty-four BEGINS with a hyphen, and Go's flag package
	// reads that as a flag:
	//
	//   flag provided but not defined: -oi9E2tvJjMt3_3xPA20jxsnf...
	//
	// which is a usage error naming the operator's key back at them. An
	// intermittent failure that depends on the first byte of a generated key is
	// exactly the kind that gets diagnosed as "the relay is broken".
	//
	// `--` would work and nobody types it. So the estate flag is consumed
	// explicitly and everything else is the value.
	var name, value string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-e", "--estate", "-estate":
			if i+1 >= len(args) {
				return fmt.Errorf("--estate needs a name")
			}
			name = args[i+1]
			i++
		default:
			if v, ok := strings.CutPrefix(args[i], "--estate="); ok {
				name = v
				continue
			}
			if v, ok := strings.CutPrefix(args[i], "-e="); ok {
				name = v
				continue
			}
			if value != "" {
				return fmt.Errorf("usage: heliograph relay peer [-e <estate>] <file|public-identity|->")
			}
			value = args[i]
		}
	}
	if value == "" {
		return fmt.Errorf("usage: heliograph relay peer [-e <estate>] <file|public-identity|->\n" +
			"  The value is the line `heliograph-seal public --identity <file>` printed on the station.")
	}
	e, err := resolve(name)
	if err != nil {
		return err
	}
	if e.Transport != "relay" {
		return fmt.Errorf("estate %q uses the %s transport, which has no peer identity", e.Name, e.Transport)
	}

	// Resolve to a public identity, from a file, from stdin, or from the value
	// itself - and VERIFY IT PARSES before anything is recorded. A malformed
	// peer recorded now fails at `send`, which is the moment somebody is
	// already waiting on a far side.
	var raw string
	switch {
	case value == "-":
		b, rerr := io.ReadAll(os.Stdin)
		if rerr != nil {
			return rerr
		}
		raw = strings.TrimSpace(string(b))
	default:
		if _, serr := os.Stat(value); serr == nil {
			p, perr := seal.LoadPeerFile(value)
			if perr != nil {
				return fmt.Errorf("%s is not a usable public identity: %w", value, perr)
			}
			return saveRelayPeer(e, p)
		}
		raw = strings.TrimSpace(value)
	}
	pub, err := seal.DecodePublic(raw)
	if err != nil {
		return fmt.Errorf("that is not a public identity, and it is not a file that exists: %w", err)
	}
	return saveRelayPeer(e, pub)
}

func saveRelayPeer(e estate.Estate, pub seal.PublicIdentity) error {
	keys, err := estate.KeyDir()
	if err != nil {
		return err
	}
	path := filepath.Join(keys, e.Name+".peer")
	// The VALUE is written, never the file that was handed over. A peer file
	// may arrive as the station's whole identity JSON - somebody sends the file
	// rather than the line - and copying that would put the STATION'S SECRET
	// KEY into the control node's config directory. Decoding to a public
	// identity and re-encoding it makes that impossible rather than unlikely.
	if err := os.WriteFile(path, []byte(pub.Encode()+"\n"), 0o600); err != nil {
		return err
	}
	e.Peer = path
	if err := e.Save(); err != nil {
		return err
	}
	fmt.Printf("estate %s: station identity recorded\n", e.Name)
	fmt.Printf("  fingerprint: %s\n", pub.Fingerprint())
	fmt.Println()
	fmt.Println("  Check that against what the station printed, over a channel the")
	fmt.Println("  operator already trusts. It is what stops a relay substituting")
	fmt.Println("  its own key, and it is the only step here a machine cannot do.")
	return nil
}

// plantRelay prints what to send the operator of a relay station.
//
// IT IS A DIFFERENT SHAPE FROM EVERY OTHER TRANSPORT'S, because the relay is
// the only one whose enrolment is a two-way exchange. Every other plant is a
// clone URL and a credential and the operator is done. Here they have to make a
// key, send its public half back, and read a fingerprint aloud - and if any of
// that is skipped the station starts, polls happily, and silently drops every
// request because it cannot verify a signature. From their side that is
// indistinguishable from nobody sending anything, which is why the fingerprint
// step is stated as a step rather than as advice.
//
// THE CONTROL SECRET NEVER APPEARS HERE. Only the public half, which is what
// RELAY_PEER is for and all the station needs.
func plantRelay(e estate.Estate, script bool) error {
	me, err := seal.LoadIdentityFile(e.Identity)
	if err != nil {
		return fmt.Errorf("estate %q cannot read its identity at %s: %w", e.Name, e.Identity, err)
	}
	pub := me.Public()

	var b strings.Builder
	if !script {
		fmt.Fprintf(&b, "Send this to whoever can log into the station.\n\n")
		fmt.Fprintf(&b, "  relay    %s\n", e.Dir)
		fmt.Fprintf(&b, "  estate   %s\n", e.RelayEstate)
		fmt.Fprintf(&b, "  station  %s\n", e.Scope)
		fmt.Fprintf(&b, "  control fingerprint  %s\n\n", pub.Fingerprint())
		fmt.Fprintf(&b, "1. Put the station payload on the machine, and heliograph-seal beside it.\n")
		fmt.Fprintf(&b, "   The relay is the one transport that needs that binary; the page at\n")
		fmt.Fprintf(&b, "   /relay says why, and its checksum is published with the release.\n\n")
		fmt.Fprintf(&b, "2. Make the station's own key, and save the peer:\n\n")
	}
	fmt.Fprintf(&b, "cd <the station payload>\n")
	fmt.Fprintf(&b, "./heliograph-seal keygen --out ~/.heliograph-identity\n")
	fmt.Fprintf(&b, "printf '%%s\\n' '%s' > ~/.heliograph-peer\n\n", pub.Encode())
	if !script {
		fmt.Fprintf(&b, "3. Start it:\n\n")
	}
	fmt.Fprintf(&b, "export TRANSPORT=relay\n")
	fmt.Fprintf(&b, "export RELAY_URL=%s\n", e.Dir)
	fmt.Fprintf(&b, "export RELAY_ESTATE=%s\n", e.RelayEstate)
	fmt.Fprintf(&b, "export RELAY_STATION=%s\n", e.Scope)
	fmt.Fprintf(&b, "export RELAY_IDENTITY=~/.heliograph-identity\n")
	fmt.Fprintf(&b, "export RELAY_PEER=~/.heliograph-peer\n")
	fmt.Fprintf(&b, "export RELAY_TOKEN=<the STATION token for estate %s>\n", e.RelayEstate)
	fmt.Fprintf(&b, "export RELAY_SEAL_SHA256=<the checksum published with the release>\n")
	fmt.Fprintf(&b, "./start.sh --check   # will this work here? changes nothing\n")
	fmt.Fprintf(&b, "./start.sh           # run it, and walk away\n")
	if !script {
		fmt.Fprintf(&b, "\n4. Send back the fingerprint keygen printed, and the line from\n")
		fmt.Fprintf(&b, "   `./heliograph-seal public --identity ~/.heliograph-identity`.\n\n")
		fmt.Fprintf(&b, "   Then here:  heliograph relay peer -e %s <that line>\n\n", e.Name)
		fmt.Fprintf(&b, "   COMPARE THE TWO FINGERPRINTS over a channel they already trust -\n")
		fmt.Fprintf(&b, "   a phone call, not the relay. It is the only step here a machine\n")
		fmt.Fprintf(&b, "   cannot do for you, and it is what stops a relay substituting its\n")
		fmt.Fprintf(&b, "   own key for either side's.\n\n")
		fmt.Fprintf(&b, "   The STATION token is not the control token. A station token may\n")
		fmt.Fprintf(&b, "   read requests and write logs, and may not queue a request even for\n")
		fmt.Fprintf(&b, "   itself - because it sits on a machine nobody can reach.\n")
	}
	fmt.Print(b.String())
	return nil
}

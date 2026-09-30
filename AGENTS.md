# AGENTS.md

Guidance for AI agents (and people) working in this repository.

## What this is

**heliograph**: remote, captured, auditable execution on a machine nobody
present can debug. One repository, three roles, and the boundary is the gap:

| | |
|---|---|
| **control** | your machine: `cmd/heliograph` (the CLI and `heliograph mcp`), `internal/`, the skill in `skills/heliograph/`. Go, and whatever the near side can afford |
| **transport** | the channel: git, relay, file share, bundle, object store - behind one interface in `internal/transport/`, so the gates live in one place |
| **station** | the far side: `station/bash/`, planted into a private transport repo by `heliograph bootstrap` or `station/bootstrap.sh`. Bash 4+, git, GNU coreutils, nothing else |

It began as an Ansible-only capture wrapper in a private estate, was
generalised, packaged as a skill, then grew the CLI. The skill repository
(`dbhq-uk/heliograph-skill`) was merged in on 2026-09-08 - see
`docs/specs/2026-09-08-station-and-skill-merge.md`. Every rule in here was
paid for by an investigation that went wrong first.

## The boundary, and what it costs to cross it

Everything under `station/bash/` and `station/powershell/` runs on the far
side, on a locked-down box where installing anything is its own change
request. The payload is planted **as source** and read before it is run, and
that property is what gets heliograph through the door.

**Still absolute: never add Go, an interpreter or a package requirement under
`station/`.** The only Go files permitted there are `station/embed.go` and
`station/embed_test.go`, neither of which is under `bash/` or `powershell/`,
so neither ever ships. CI enforces exactly that.

**Compiled binaries on the far side are opt-in, per feature, and written
down.** Today the list has exactly one entry and the default is no binary at
all: `heliograph-seal`, which the relay transport installs on a bash station.
The beam is designed to want its own component. The list is
[`station/FAR-SIDE-BINARIES`](station/FAR-SIDE-BINARIES), CI fails any build
that references a compiled program the list does not name, and the file itself
carries the three conditions an entry has to meet.

**Reuse the listed one before proposing a second.** The policy has already
decided a case: #114 needed Ed25519 verification on the far side for a trusted
set, which Bash 4 with git and coreutils does not do - `openssl` has no
Ed25519 verify verb across the versions this runs on, and hand-rolling one
would be bespoke cryptography. It reused `heliograph-seal` rather than adding
a second binary, and recorded rejecting one as "a new thing to audit, a new
checksum, a second argument with every change control". So the number of
binaries an estate has to accept is one, not one per feature that needs
signing, and a bash station on any transport may end up carrying it. The
PowerShell station needs none even then: its seal is managed C# shipped as
source and compiled by `Add-Type` at startup.

**The price of listing one is a reproducible build**, and that phrasing is
[#93](https://github.com/heliograph-io/heliograph/issues/93)'s rather than this
file's:

> Open-sourcing it is **not sufficient**. The component needs **reproducible
> builds and published checksums**, so an operator can verify the binary
> matches the source they read. This is the price of moving off pure bash, and
> the estates that care will ask.

"Read it before you run it" stops working at a binary and is replaced by
"verify the binary matches the source you read" - which is a claim, not a
property, unless anybody can rebuild the exact bytes from the tag and check
them against a published checksum. `packaging/reproduce.sh` is that build; `/provenance` on the site is
the command. A far-side binary that is not reproducible is not permitted, and
that ordering is deliberate: the estates that mind a binary on their machine
are exactly the ones who will ask.

**Nobody loses heliograph over this.** A beacon or a flare over git, a file
share, a bundle or an object store needs no binary anywhere on the far side
and is a complete product: same requests, same gates, same logs. What an
estate that forbids compiled code gives up is the relay on a bash station, the
beam when it lands, and any later feature that needs a signature verified on
the far side - and even the relay has a way through on the PowerShell station.
Two shapes, not the tool. Say so where the beam is introduced rather than
leaving somebody to discover it during a security review.

### The rule this replaced, and what it cost

Until 2026-09-12 this section read:

> **Never add Go, a binary dependency, an interpreter or a package requirement
> under `station/bash/`.** The one Go file permitted under `station/` is
> `station/embed.go`, which never ships to the far side, and CI enforces
> exactly that.
>
> The one binary exception on the far side of the trust argument is
> `heliograph-seal`, the crypto helper for the relay transport, argued for
> explicitly in the relay spec. Every other transport stays pure bash on the
> station side.

An absolute prohibition with an exception beneath it is not a rule, and this
one had already been escaped rather than argued: `heliograph-seal` is a
compiled Go binary running on the far side, and it passes the letter of the
old rule only because it is built from `cmd/` instead of existing as Go source
under `station/`. The gate agreed. It printed "the far side never gets a
binary dependency" while one already did.

**Who paid.** The next contributor, who would have read a green check and a
true-sounding message and added a second binary by the same two-line route,
with nothing anywhere saying the policy had changed. And the reviewer in the
estate, who is told the far side is readable, finds a binary, and now has to
decide whether anything else they were told is also approximately true. The
cost of the old wording was not that it was strict; it was that it was
escapable, and being escapable is what made it silent.

The skill (`skills/heliograph/`) drives the CLI and nothing else. Do not give
it a second, hand-edited path around `send`, `watch` or the gates: one driver
is the point, and the current shape exists because the old two-path version
drifted.

## The constraints that must not be broken

Everything else here is a preference. These are not.

**1. Every captured line carries a UTC timestamp.** The stamp is applied by a
pure-bash read loop reading straight from the command, BEFORE any sed runs.
That ordering is load-bearing: it used to be applied last, which made the
whole property depend on `sed -u`, and a sed without it gave every line in a
block the same time while the log still read perfectly. Do not move the
stamping stage, do not batch output and stamp it at the end, and do not
buffer a command's output in a variable before printing it. After the fact,
in an untimed log, a hang and slow progress are indistinguishable, and a gap
in the timestamp column is the only way to tell which operation stalled.

**2. A failed run still ships, and a failed push never loses a log.** The log
is committed and pushed whether the step passed or failed, and the real exit
code survives via `PIPESTATUS`. If the push fails, `cap_push` prints the
local path rather than exiting. Each round trip through an operator is
expensive; none may be wasted by tooling that only reports success.

**3. The runner owns the log; a step just prints to stdout.** `run.sh` and
`caprun.sh` own the file, the timestamps and the push. `station.sh` decides
only *when* a runner runs. There is one implementation of the capture
pattern, in `caplib.sh`, whose executable specification is
`tests/conformance/`. Do not fork it. `station.sh`'s 60-second partial-log
pushes publish a snapshot and never write to the file; they never pull or
rebase either, because a rewrite underneath a running step leaves its appends
at a stale offset.

**4. Read-only until earned, and every gate fails closed.** A step declares
itself in its own file - `# heliograph-mode: read-only` or `action`, in the
first 30 lines - and a step that declares neither does not run at all.
`run.sh` requires `CONFIRM=yes` for an action; `station.sh` refuses an action
unless started with `--allow-actions` and publishes the refusal to
`station/status` within one poll. `ALLOW_ACTIONS` defaults to 0. Never make a
state-changing step the default. The CLI publishes requests and reads logs;
it gets no path around any of this.

**4a. The account is the blast radius.** This tooling holds no credentials,
so "what could this do" is answered by the account it runs as. Every runner
refuses to run as root unless `ALLOW_ROOT=1`. Do not add a code path that
escalates by default, and do not soften that refusal into a warning.

**5. The transport repo is private, and separate.** Captured logs are
committed to it. `cap_redact` is a safety net, not a guarantee. Never weaken
the bootstrap's insistence on reporting rather than overwriting, and never
suggest bootstrapping into a repo that holds anything else.

**6. The container clones, then gets out of the way; it never re-implements
`start.sh`.** `station/bash/docker/entrypoint.sh` resolves the repo URL,
clones or reuses a checkout, and `exec ./start.sh`. Everything past the clone
stays `start.sh`'s alone. The unprivileged user in the image is not a
security boundary. Full account:
[`site/content/containers.md`](site/content/containers.md).

**7. `station.ps1` is a launcher, never a port.** It finds the bash Git for
Windows installed and hands over to `start.sh`. A PowerShell copy of the
capture would break constraint 3 in the least visible way: a buffered port
gives every line the same timestamp, which reads like a working log. A step
*written in* PowerShell is fine - `ps_step` runs one through the ordinary
capture. The station ships `gitattributes` pinning the transport repo to LF
so that committed CRLF never breaks a Linux clone; see
[`site/content/windows.md`](site/content/windows.md).

**8. `station.sh` does not trap HUP, and that is deliberate.** `cleanup`
signals the running step's process group, so trapping HUP would kill an
in-flight step every time a connection dropped. `station/bash/service.sh`
(systemd `--user` plus lingering, or setsid + nohup) is the supported way to
survive logout; `service.ps1` does the same with a scheduled task. See
[`site/content/service.md`](site/content/service.md).

## The two rules specific to the relay

**The relay is outside the trust boundary, in both directions.** It may not
read content and it may not cause a station to run anything. A relay able to
forge a request would be code execution inside every estate at once. The
relay server stays its own repository,
[heliograph-io/heliograph-relay](https://github.com/heliograph-io/heliograph-relay),
precisely so it is publicly, obviously incapable of either.

**No bespoke cryptography.** age primitives and Ed25519, through vetted
libraries. If a design seems to need something novel, the design is wrong.

## Conventions

- Station scripts use `set -uo pipefail`, never `set -e`. A diagnostic wants
  every probe's result, not the first failure. This is the opposite of the
  usual house rule, and it is deliberate.
- Steps never prompt. No interactive sudo, no host-key questions, no `read`.
  A prompt through the capture pipeline is invisible and the run hangs.
- The station ships its ignore and attributes files as `gitignore` and
  `gitattributes`, without the dot, so they govern the transport repo rather
  than this one. Both bootstraps restore the dot on the way out. Do not "fix"
  the names.
- No host names, environments, findings or logs on `main`, in this repo or in
  a transport repo. `main` is the template.
- House style: British English, plain hyphens, **no em dashes**, no trailing
  full stops on headings. Commit messages and PR descriptions say what
  changed and *what it cost* - the measurement, the failure it prevents, the
  thing that was tried and did not work.

## Where the work stands

[`ROADMAP.md`](ROADMAP.md) is the plan: what heliograph is for, where it
stands, and one epic per line for now, next and later. Every piece of work is
an issue, and a known defect is an issue labelled `type: bug`, so write to the
issue as work lands rather than at the end - it is what survives a handover.
What landed before 2026-09-29 is in
[`docs/history/2026-09-plan.md`](docs/history/2026-09-plan.md), moved whole out
of `PLAN.md`, which is now a one-line pointer so old links still resolve.

The lessons this repository has already paid for are
[at the end of this file](#lessons-this-repository-has-already-paid-for). Read
them before starting.

One rule from them belongs here too, because it is a hard one: **a check nobody
has watched fail is a check nobody knows works.** Break every new assertion
deliberately and watch it fail before keeping it. Two coverage guards written
on 2026-09-08 were wrong in ways that read as correct and reported PASS while
asserting nothing.

## Validating a change

```bash
gofmt -l . && go vet ./... && go test ./...   # includes the e2e that drives a
                                              # real station from station/bash
bash -n install.sh install-codex.sh
find skills station tests -name '*.sh' -exec bash -n {} +
shellcheck -S warning $(find . -name '*.sh' -not -path './.git/*')
jq empty .claude-plugin/plugin.json
./tests/run-tests.sh                          # the station's own suite
```

`tests/conformance/` is the executable form of the capture contract. It
asserts properties and never internals: no file in it may name `caplib.sh`,
`run.sh` or any path inside the station payload. `drivers/mutant.sh` is
deliberately broken and the suite asserts that it **fails** - do not fix the
mutant, and do not weaken a property to make a driver pass.

CI (`validate.yml` for the Go side, `station.yml` for the station) runs all
of it, plus Windows, macOS launchd, a real Kubernetes cluster, the container
image, both installers, and the station purity gate. `./tests/run-tests.sh`
needs a working `docker` locally and skips loudly rather than failing when
there is none; CI refuses that skip.

After changing anything under `station/bash/`, verify by hand from a
bootstrapped copy:

- `PUSH=0 ./run.sh env` produces a log where **every line** carries a UTC
  stamp and the header names the branch and commit.
- A step that exits non-zero still writes the footer, still reports the real
  exit code, and still gets committed.
- `./run.sh <a step that does not exist>` exits 2 having written nothing.
- `./start.sh --check` names every blocking problem and what to do about
  each. A preflight line that reports a problem without a remedy is a defect:
  the person reading it usually cannot ask you.

Be honest about what none of it covers: nothing here exercises a capture
against a real remote machine. The behaviour that matters is what a log looks
like after a round trip through someone else's terminal, and no test asserts
that.

## Lessons this repository has already paid for

Added here when something cost real time. AGENTS.md holds the hard rules; this
holds what was learned proving them.

**A guard on a dependency graph outlives a guard on an import block.** The claim
that `push` cannot author a request is the product's central one, and it is kept
by three assertions rather than one: `go list -deps` proves the package cannot
REACH `internal/seal` or `internal/transport` transitively, an AST walk proves it
never names `wire.Request`, and the end-to-end test counts POSTs to the
station's request queue across a real push and requires the count not to move.
The first is the one that keeps working when somebody adds a helper in a year,
because an import three packages away signs exactly as well as a direct one.

**A check nobody has watched fail is a check nobody knows works.** Two coverage
guards written on 2026-09-08 were wrong in ways that read as correct:
`GIT_(?:AUTH_HEADER|TOKEN|TOKEN_FILE|TOKEN_USER)` matched `GIT_TOKEN` first and
found two mechanisms out of four; `^\s+echo "([a-z]+):` missed every
conditional field, including the one it was written for. Both reported PASS.
Break every new assertion deliberately and watch it fail before keeping it.

**Documenting a component is how the defects are found.** Writing the far-side
pages turned up three false claims, including one fatal: `station.sh` required a
local `station/request` file, which blob and relay never create, so a relay
station could never run a step at all. Nothing else had noticed.

**A test can prove a file is absent while claiming to prove a guard works.**
The transport-name whitelist was checked by passing `../../evil` and
`/etc/passwd`, and every case passed with the whitelist DELETED - because no
module exists at those paths, so the refusal came from the filesystem. The
assertion now demands the whitelist's own diagnostic, and adds a traversal that
RESOLVES TO A REAL MODULE: without the whitelist, that one loads.

**`Import-Module` inside a module function imports into THAT module's session
state.** The transport loader loaded the transport, initialised it, and returned
success - and every function the transport exported was invisible to the caller.
It read as "the transport is fine, and `Send-TpLog` does not exist". `-Global`
is the fix, and the reason it was not obvious is that the failure names the
FUNCTION rather than the import.

**A value type read through a property is a COPY.**
`$info.BasicLimitInformation.LimitFlags = 0x2000` set the flag on a copy of the
nested struct and threw it away, so the Job Object was created without
KILL_ON_JOB_CLOSE and guaranteed nothing. Every call succeeded, the mechanism
reported itself in force, the tests were green, and `taskkill` was quietly
doing all the work. Assign the nested struct back. And the reason it survived:
the only assertion looked for `strategy=`, which an empty value satisfies - so
nothing ever asked whether the job existed.

**A test that passes with the thing deleted is worse than no test.** An
assertion here claimed `Test-CapAlive` is not fooled by a zombie, and it passed
with the check removed - PowerShell reaps its own children, so the case cannot
be constructed from this suite. It was deleted rather than left looking like
coverage, and the guard it was written for is marked untested in the module.
Removing an assertion is sometimes the honest move.

**A fixed sleep encodes one implementation's startup time.** The cancel
property waited three seconds and then cancelled, which is ample for bash and
not always enough for PowerShell - two interpreter starts and a module import.
On a loaded machine the cancel landed before a single line was captured, and
the property reported *"the partial log does not survive a cancel"* about a run
that had not produced one. It waits for the run to be demonstrably under way
now. A specification may not assume how fast an implementation starts.

**A BOM makes a file look non-executable to Git-Bash.** The exec bit there is
inferred from a shebang at offset 0, and three invisible bytes move it - so
`run.sh` refused a BOM'd step with *"step file is not executable"* and told a
Windows operator to `chmod +x`, which cannot fix it. The BOM check moved ahead
of the executable test: the BOM is the cause and every other symptom points
somewhere unhelpful. Found because the twin comparison disagreed on Windows and
nowhere else, and because the assertion printed the file's first eight bytes
and its mode instead of just a number.

**"It puts it back afterwards" is not "it changes nothing".** `--check` is what
gets run where nobody is permitted to alter anything yet, and it wrote a probe
file and deleted it - with a FIXED NAME, so a file already at that path was
destroyed. The test missed it by deleting the directory first, which skipped the
whole branch that runs when it exists. Snapshot the tree, not one path.

**Git-Bash converts a path at the exec boundary and nowhere else.** An argument
like `-LogPath /tmp/x` arrives at a native program already converted, so
everything looked fine; a path EMBEDDED IN A SCRIPT gets no such treatment, and
PowerShell read `/tmp/x` as `C:\tmp\x`. The step wrote its marker to a
directory the suite never looked in, and property 5 reported *"exit 0, but the
step never ran"* about a step that had run perfectly. `cygpath -w` where the
path goes into a file rather than onto a command line.

**A loop that refuses at the wrong gate has tested nothing.** The check that
`HELIOGRAPH_ASSUME_PRIVILEGED` cannot OPEN the privileged gate ran an action
with no `CONFIRM`, so gate 2 refused every iteration before gate 4 was reached.
Every value "refused", the assertion passed, and a value that opened gate 4
would have gone unnoticed. Found by an adversarial read on 2026-09-10. When a
test asserts that gate N did something, the input has to reach gate N.

**Two implementations of one rule need a test that compares them, not two
tests.** `run.ps1` and `run.sh` were each tested and each passed, and three
things still meant different things to the two of them - `CONFIRM=YES`,
`# heliograph-mode: READ-ONLY`, and the step name `ENV` - because PowerShell
compares case-insensitively everywhere bash does not. Two of those were security
gates: a state-changing step ran on one and was refused by the other, from the
same request. The guard that holds is running the SAME declaration through both
and comparing the exit codes.

**A corpus is only testing the rules it is the ONLY thing catching.** The
redaction corpus was written case by case, each one realistic - a GitLab token
in a clone URL, a Bearer token behind an `Authorization:` header - and every one
of those is caught by a *different, broader* rule. Four rules could be deleted
outright with the corpus still reporting a clean run. Found by deleting them,
one at a time, which is now `test-redaction-corpus.sh` and runs every time. The
mutation itself was wrong twice first: deleting the last `-e` line broke the
line continuation, and `awk -v` ate a trailing backslash - and in both cases a
`cap_redact` that no longer existed leaked nothing, which reads exactly like a
rule the corpus caught. **A mutation test needs a liveness check or its passes
are silence.**

**An exit code is not evidence that anything ran.** The conformance suite's two
gate properties were asserted by exit status alone, so a runner that returned 0
without executing the step satisfied *"a declared step runs"*, and one that ran
the step and THEN refused with 5 satisfied *"nothing runs as root"* - which is
the whole defect wearing the right exit code. Both now write a marker. Three
distinct strings also satisfied *"three distinct timestamps"*; the column is now
checked for being a clock, and for being UTC, by capturing under `TZ` fourteen
hours away.

**A test double more permissive than the real thing is worse than none.** The
relay stub was written with one token; the relay's scopes are asymmetric, so a
station using the control credential would have passed here and been refused in
an estate. There are two doubles of that relay in this repository - this one and
the Go one the CLI tests use - which is two chances to drift, so the rules are
now asserted against the stub behaviourally rather than assumed from having
written it.

**A re-run that goes green is a diagnosis nobody made.** The launchd assertion
failed four times and was re-run clean four times, and the fourth failure - the
first to print `launchctl print` - said in one line that no station had ever
started on a Mac. An intermittent failure is a race between a real bug and a
poll, not an absence of one. Make a test carry its own evidence BEFORE it fails
again, because the evidence that settles it is usually the kind the next run
destroys.

**A process is not a service.** *"the loop is running as pid N"* was true
throughout a crash loop, because launchd kept making new ones. Assert on what
the thing was installed to DO - it got past preflight, it published a status -
never on the existence of a pid.

**A template nobody has validated is a template nobody knows parses.** The very
first CI run of `terraform validate` over `station/bash/azure`, added on
2026-09-09, failed on code that predated it: a SENSITIVE value cannot drive
`for_each`, because a `for_each` key becomes part of a resource address and a
secret may not go there. `var.gitToken` is sensitive, so
`for_each = var.gitToken == "" ? [] : [1]` is sensitive too, and the Container
Apps job had never parsed under the pinned terraform. It had been DEPLOYED -
just with a newer terraform than CI pins, which is why nothing noticed. Unwrap
only what is genuinely not secret: the EMPTINESS of a token, or the NAMES of a
secret map, never the values.

**Adversarial review finds what self-review does not.** Two codex passes on
2026-09-08 found ten defects, five missed entirely - a quoting bypass of the
env guard, `cap_push` returning 0 on failure, a committed test artefact that
`bootstrap` would have planted into every station.

**A test written for one defect finds another.** Writing the "a state write
that failed must be reported" case made `_relay_lock` spin for ever, because it
waited on any `mkdir` failure and an unwritable directory is one. Moving that
check inside the retry loop then broke a working lock, because a holder
releasing between the failed `mkdir` and the test looks exactly like an
unwritable filesystem - 58 numbers out of 60, two takers refused for nothing.
Ask "can I ever create this" once, up front; ask "does it exist" only in the
loop.

**A stale-lock heuristic that can fire on a live holder is not a lock.** The
relay's sequence lock broke any lock directory untouched for a minute - and a
holder's mtime does not change while it works, so the breaker deleted live
locks and two processes went in at once. Four takers wanting fifteen numbers
each got 33 distinct numbers out of 60. It fails exactly like having no lock:
intermittently, silently, under load. Ask `kill -0` whether the recorded pid is
alive, which is what station.sh has always done.

**`go:embed` reads the working tree, and .gitignore does not stop it.**
`terraform init` in the Azure templates drops 200MB of provider binaries per
template, and `bootstrap.sh` has pruned `.terraform` since it was written. The Go
planter did not - so a release built on any machine where somebody had run
terraform would have carried those binaries inside the `heliograph` binary,
permanently, in every download. CI never saw it because a CI runner starts
clean. Found by running `terraform test` locally, which is the thing the
templates needed and nothing had ever done.

**One file format, two implementations, is six disagreements.** The
`.station-env` rules were written in bash for `service.sh` and again in
PowerShell for `service.ps1`, and an adversarial read found six ways they
classified the same file differently - PowerShell regexes are case-insensitive
by default, `Get-Content` eats a UTF-8 BOM that bash does not skip when
sourcing, an empty file passed one and failed the other. A station that installs
on Windows and is refused on Linux, from one file, is worse than either answer
alone. `station-env.sh` is now the only implementation and both installers call
it.

**Ask the transport, do not keep a list of what it needs.** Scraping `cap_need`
names out of a transport looked mechanical and was a floor: Azure Blob needs a
SAS *or* a managed identity, which no `cap_need` line expresses, so a file with
the two names it does declare passed the installer and was refused by
`start.sh`. Running the transport's own `tp_init` - local by contract, no
network - gets every case right and stays right when a transport changes.

**Stripping a CR on read is not the same as stripping it on source.** The
validator read `.station-env` with the CR removed and accepted a CRLF file;
nothing strips it when a service SOURCES that file, so `SHARE_SCOPE` became
`probe` plus a carriage return and the transport refused it after installation.
The test asserting CRLF was accepted is what found it.

**A `.dockerignore` is a file nobody re-reads, and it decides what ships.**
`**/secrets/*` looked like prudence and was wrong: `station/bash/secrets/` is
part of the payload, so the image quietly planted one file fewer than every
other way of planting a station, and nothing would have noticed. The image's
payload is now compared file-for-file against `bootstrap.sh`'s.

**Sourcing an env file does not export anything.** `. file` with `KEY=value` in
it sets a SHELL variable, and the next thing the LaunchAgent and the setsid
fallback do is `exec bash start.sh` - a new process, which inherits environment
variables and not shell ones. So the file was read and every value discarded,
and a relay station started as a git one. systemd was unaffected, because
EnvironmentFile exports for you: which is exactly how a defect ends up in two
mechanisms out of three and looks like working code in the one that is tested.
`set -a` around the source.

**One file, two parsers, is a specification.** The same `.station-env` is read
by systemd's EnvironmentFile and sourced by a shell, and an ordinary Azure SAS -
`?sv=...&ss=...&sig=...` - is a value to one and three background jobs to the
other. The file is validated at install time against the intersection of the two
languages rather than hoped about.

**A round trip finds what reading cannot.** The relay had four defects that
every review had walked past, and all four surfaced within an hour of the first
end-to-end run: the preflight proved its token by reading the station's own
request queue, and a relay deletes on collection, so every `./start.sh` silently
ate the waiting request; the loop and the runner collided on sequence numbers so
`idle` was dropped as a replay; `ListLogs` returned an error, leaving the
transport whose whole purpose is retrieving a log with no way to read one; and
`log: <none>` appeared in every status for a step sent by path, on every
transport, because the glob used the path rather than the label. None of them
errored anywhere.

**A reachability check is not a delivery check.** `tp_check` on the blob
transport counted an HTTP 404 as success, on the argument that an absent request
proves the account and the credential. A misspelt container, a wrong account and
a read-only SAS all answer exactly like that, so all three cleared the preflight
and failed on the first upload - an hour later, with nobody left to tell. Every
`tp_check` now proves a WRITE, the cheapest way its store allows.

**Checking one of a pair is checking neither.** The relay verified
`RELAY_IDENTITY` was readable and never `RELAY_PEER`, so a station with no peer
key started, then failed every verification and every seal. `tp_describe` turned
the failed fingerprint into `<unreadable>` and printed it beside an `ok`.

**A command substitution is a subshell, and a transport's `tp_init` sets
variables the rest of the run needs.** `why="$(tp_init 2>&1)"` looked like the
tidy way to fold a failure into the preflight table. It reported the transport
as `ok` and then killed every git check with `BRANCH: unbound variable`, because
`BRANCH=$b` had been set in the subshell and thrown away. Capture stderr through
a file when the function has to run in this shell.

**Read the skill before changing a default.** Pinning an estate to its branch
looked right and would have broken every existing user, because SKILL.md tells
you to work on `task/<slug>` and then send. `Scope` set means routing matters;
`Branch` alone means follow the checkout.

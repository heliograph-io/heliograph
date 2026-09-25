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

[`PLAN.md`](PLAN.md) is the register: what has landed, what is next and in what
order, which defects are known and deliberately unfixed, and the lessons this
repository has already paid for. Read it before starting, and write to it as
work lands rather than at the end - it is what survives a handover.

One rule from it belongs here too, because it is a hard one: **a check nobody
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

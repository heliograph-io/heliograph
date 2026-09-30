# Contributing

Thanks for your interest - contributions are welcome.

## Ways to help

- Report a bug or request a feature via [issues](https://github.com/heliograph-io/heliograph/issues)
- Pick up an issue under one of the epics on the [roadmap](ROADMAP.md)
- Add a generic step, a `lib/` helper, or a hard-won lesson to `references/method.md`, via a pull request

## Local development

```bash
git clone https://github.com/heliograph-io/heliograph.git
cd heliograph
./install.sh          # symlinks into ~/.claude/skills (edits are live)
```

The whole skill directory is symlinked, so edits - to `SKILL.md` and
`references/` alike - are live immediately. For Codex, re-run
`./install-codex.sh` after editing `SKILL.md`, since that one file is rewritten
at install time. Full walkthrough in [`docs/dev-setup.md`](docs/dev-setup.md).

## Before opening a PR

- `bash -n` over every shell script - they parse
- `claude plugin validate .` - the plugin validates
- Bootstrap a throwaway repo and run `PUSH=0 ./run.sh env` against it. Confirm
  every line of the log carries a UTC timestamp and the header names the branch
  and commit. Nothing automated asserts this
- Confirm a failing step still writes its footer, reports its real exit code, and
  is still committed
- British English, plain hyphens, no trailing full stops on headings

## Conventions that are easy to lose

- **Specs before code**, in `docs/specs/`, reviewed on their own
- **Every PR states what it cost** - the measurement, the failure it prevents,
  the thing that was tried and did not work
- **British English, plain hyphens, no em dashes**, no trailing full stops on
  headings
- **No backtick may appear inside a Go raw string** in `internal/site/theme.go`.
  This has broken the build twice, both times from a comment
- `station/bash/.station-delivery` appears when the suite runs locally. It is
  gitignored; do not commit it

## Verifying a change

```bash
gofmt -l . && go vet ./... && go test ./...
find skills station tests -name '*.sh' -exec bash -n {} +
shellcheck -S warning $(find . -name '*.sh' -not -path './.git/*')
./tests/run-tests.sh
./tests/conformance/conformance.sh tests/conformance/drivers/bash.sh
./tests/conformance/conformance.sh tests/conformance/drivers/mutant.sh   # must FAIL
go run ./cmd/heliograph-site site/content /tmp/site                      # 26 pages
```

macOS is absent locally, so the launchd suite skips. **CI runs it and CI has
caught real defects that skip hid** - do not read a local green as complete.

**Docker may only need starting.** `sudo systemctl start docker` was all it
took, and it turns the container and Kubernetes suites from skipped into 271
assertions that run in about ten minutes - including a whole station run in a
container. They found four defects in one afternoon that CI would have taken
four pushes to surface one at a time. Try it before pushing anything that
touches `station/bash/docker/`.

## The bar for a change to `station/bash/`

The station runs on a machine you will never see, in front of someone who cannot
debug it, and each round trip is expensive. So:

**A change may not cost a round trip.** Anything that can hang without printing
first, prompt for input, or exit before writing the log is a regression however
much cleaner it reads. The five constraints in [`AGENTS.md`](AGENTS.md) are the
short version, and a PR that breaks one will be declined.

**A generic step, not your step.** `main` carries tooling that works anywhere.
A step naming hosts, environments, inventories or findings belongs on a task
branch in your own transport repo, never here. If a step of yours turned out to
be genuinely general, strip it of every local convention and send that.

**A lesson needs the failure that taught it.** `references/method.md` is a list
of rules that each cost something. A new rule should say what went wrong, in one
or two sentences, without naming an employer, a client or an estate. "A commit
step once reported success having never pushed" is the shape.

## What we will not accept

**Anything that grants access.** No tunnelling, no reverse shells, no proxying,
no holding a connection open, no credential harvesting. The whole premise is that
a person with legitimate access chooses to run each command, and the only thing
crossing the gap is a git commit. A pull request that turns this into a way
around an access control will be declined, and it is the one contribution that is
not a judgement call.

**Anything that reads a secret.** Naming a secret settles "does this exist here";
its value is never the question, and a log is permanent. Do not add a helper that
prints one, and do not weaken `cap_redact`. `secret.sh` is not an exception to
this: it carries a value you already hold *to* the far side as ciphertext, and
reads nothing off it.

**Real logs, real host names, real estates.** No `ops-logs/*.txt` from an actual
investigation, no internal DNS names, no client or employer names, and no
environment-specific defaults. Fixture-style examples are fine; a redacted real
one is not, because redaction fails quietly.

**A far-side dependency.** Bash, git and GNU coreutils. A machine in a locked-down
environment often has no package manager you can use, no network route to a
registry, and no appetite for a change request. Anything that needs installing
does not run where this is meant to run.

The one narrow exception is a compiled binary for a single transport, and it is
not a judgement call either: it has to be named in
[`station/FAR-SIDE-BINARIES`](station/FAR-SIDE-BINARIES), argued for in a spec,
built by `packaging/reproduce.sh` so anybody can rebuild the bytes and check
them against the published checksum, and verified by hash on the station before
it runs. `heliograph-seal`, for the relay, is the only one today. A third-party
binary is not in scope for that exception at all.

## Licence

By contributing you agree your work is licensed under the [Apache 2.0 licence](LICENSE),
or [CC BY 4.0](site/content/LICENSE) if it is documentation under `site/content/`.

Inbound equals outbound. There is no CLA and no copyright assignment: you keep
your copyright, and the project gets the same licence everybody else gets.

Sign your commits off with the [Developer Certificate of
Origin](https://developercertificate.org/), which is `git commit -s` and adds
one line:

```
Signed-off-by: Your Name <you@example.com>
```

That is a statement about provenance - that you wrote it, or have the right to
submit it - and it is why no CLA is needed here.

**Nothing currently enforces this.** No CI job checks for the trailer and no
existing commit carries one, because until 2026-09-17 this repository had one
contributor and a DCO between somebody and themselves is theatre. It is written
down now because the relicence is the moment it starts to matter, and a rule
recorded after the first outside pull request is a rule applied retroactively.
The check goes in with that pull request.

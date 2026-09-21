<div align="center">

<img src="site/assets/logo.svg" alt="heliograph, by DBHQ" width="120">

# heliograph

**Remote, captured, auditable execution on a machine you cannot log into**

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-docs.heliograph.io-4E7FB3)](https://docs.heliograph.io)

A free, open-source tool by [DBHQ](https://dbhq.uk)

</div>

---

Someone can reach the machine. You cannot, and you are the one who knows what
to ask it. heliograph runs that gap as a loop rather than a relay: you publish
a step, it runs on the far side, and the whole run comes back as a log with
every line timestamped in UTC, whether it passed or failed.

```
you        heliograph send net-probe ────────────────▶ transport
station    picks it up within seconds, runs it
           pushes status, then the log ──────────────▶ transport
you        heliograph logs --last --gaps ◀────────────
```

## The three ways across

heliograph carries a request to a machine you cannot log into, and brings the
log back. There are three ways across the gap, and they differ in one thing:
**what stays held, and for how long.**

**Beacon.** You cannot reach the machine and it cannot reach you - but you can
both reach one agreed place. You leave the request there and walk away. Later
the machine passes by, picks it up, runs it, and leaves the log for you to
collect. Nobody is ever connected; a *message* waits in the middle. It is the
safest of the three, because the code being run is already on the far side and
can be read before anything happens - and the slowest, because you wait for the
next visit.

**Flare.** You can reach the machine's door directly. You knock, hand over the
request, wait on the step while it runs, and take the log away in the same
visit. Nothing waits in the middle and no line stays open. Faster, because
there is no pickup to wait for. The trade: you bring the code with you, so the
machine trusts *the door* rather than vetting the code in advance.

**Beam.** You and the machine bring up a connection and hold it open. Either
side can speak at any moment and the other hears it at once, until you hang up.
A real session, not a message or a knock - and the most exposed, because while
the line is open anything can travel down it. You turn it on deliberately and
close it when you are done. It is designed, and not yet a transport you can
pick.

In one line: a beacon holds a *message*, a flare is a *single exchange*, a beam
holds the *connection itself*.

## Does this sound familiar

- You have **no SSH access to production**, and you are not going to be given any.
- The environment is **air-gapped**, or behind a bastion, a jump host or a VPN you are not on.
- It is a **client-owned or customer-managed estate**. Only their staff can log in.
- Access is blocked by **policy, not capability**: restricted, change-controlled, somebody else's sign-off.
- You are on the fourth round of **"can you run this and paste the output"**, and what came back was a screenshot of half a terminal.
- You are an **AI coding agent** driving an investigation, and you need the evidence rather than somebody's summary of it.

If you can just SSH in, you do not need this.

## Three roles, one boundary

The boundary is the gap, and the layout states it once:

| | |
|---|---|
| **control** | your machine: the `heliograph` CLI, `heliograph mcp`, and the skill that drives them. Go, and whatever the near side can afford |
| **transport** | the channel: git, relay, file share, bundle, object store - all behind one interface, so the read-only gates live in one place and cannot drift per transport |
| **station** | the far side: [`station/bash/`](station/), planted into a private transport repo. Bash 4+, git and GNU coreutils. No packages, no credentials, no tunnel |

**Nothing is ever installed on the far side.** The station is plain text you
can read before you run - bash 4+, or PowerShell 5.1 for a Windows estate that
has no bash and will not be given any - and no Go will ever appear under
`station/` beyond the one file that lets the CLI carry the payload. CI
enforces it. That constraint is the entire proposition on a locked-down
box where installing anything is its own change request.

## Install

```bash
# Linux and macOS, from a release
curl -sSL https://github.com/heliograph-io/heliograph/releases/latest/download/heliograph-linux-amd64 \
  -o /usr/local/bin/heliograph && chmod +x /usr/local/bin/heliograph

# or from source
go install github.com/heliograph-io/heliograph/cmd/heliograph@latest
```

A single static binary, no runtime. Checksums are published with each
release, and the binary carries the station payload it was built with.

The build is reproducible: `packaging/reproduce.sh v0.4.3` rebuilds every
released artefact from the tag and arrives at the published hashes, so "the
binary in the path is the source you read" is something you check rather than
something we say. Full account, including what is not yet covered, at
[docs.heliograph.io/provenance](https://docs.heliograph.io/provenance).

**The agent skill** - the same loop, driven from Claude Code, Codex, Cursor
and friends:

```
/plugin marketplace add dbhq-uk/marketplace
/plugin install heliograph@dbhq         # Claude Code
./install-codex.sh                      # Codex, from a clone
./install.sh                            # Claude Code, from a clone
npx skills add heliograph-io/heliograph       # any agent, via skills.sh
```

## Use

```bash
heliograph bootstrap ~/transport/payments             # plant the station payload
heliograph init payments --dir ~/transport/payments   # git, the default
heliograph plant                                      # what to send the operator
heliograph send net-probe HOSTS="sql01 sql02"         # publish a request
heliograph watch                                      # follow it
heliograph logs --last                                # read the whole log
heliograph logs --last --gaps                         # where it stalled
heliograph doctor                                     # will this work from here
heliograph mcp                                        # serve all of the above as tools
```

The operator's whole job is what `plant` prints: clone the transport repo,
run `./start.sh`, walk away. The loop is **read-only unless the operator said
otherwise**: every step declares itself (`# heliograph-mode: read-only` or
`action`), one that declares neither does not run, and the station refuses an
action unless it was started with `--allow-actions`. It will not run as root
either.

For an agent, `heliograph mcp` is the same CLI as typed MCP tools:

```bash
claude mcp add heliograph -- heliograph mcp
```

The gates do not move. A tool call publishes a request; the station still
decides whether to run it.

`--gaps` is the one worth knowing about. *"Scan the timestamp column for gaps
before reading the content"* is the most valuable instruction in the method,
and it is arithmetic:

```
$ heliograph logs --last --gaps
demo-20260906T183628Z.txt
5 captured lines

1 interval(s) of 10s or more, longest first.
Each is attributed to the line BEFORE it, which is what was running.

   3m12s  after  09:14:02 | Refreshing state...
```

The gap belongs to the line **before** it: the stamp on a line is when that
line was produced, so a long interval means the operation named on the
preceding line is what took the time. A log where every line carries the same
timestamp is reported as an **error**, not as "no gaps".

## Status

| | |
|---|---|
| control CLI over git | works, tested end to end against a stock station |
| `heliograph bootstrap` | works: the binary plants the station it was built with |
| `--gaps` | works |
| MCP server (`heliograph mcp`) | works |
| bash station | in use over git: the loop, the gates, the capture, Azure hosts, Kubernetes, the Windows launcher |
| relay | works end to end. `heliograph init --transport relay` selects it, both stations implement it, the [relay server](https://github.com/heliograph-io/heliograph-relay) is deployed, and `TestCLIDrivesARelayStation` drives the whole loop in CI |
| file share, bundle, object store | station transports exist for all three in the bash station (`station/bash/transports/`); `init` selects share, bundle and objstore. The PowerShell station carries share but not bundle or objstore |
| Azure Blob | works end to end, through `drop.sh` in the station payload rather than the CLI. It is what the Azure Function host uses |
| PowerShell station | ships. `station/powershell/` is ~2,600 lines carrying git, share and relay, and CI runs it on a Windows runner. Design: [A8](docs/specs/2026-09-08-powershell-station-and-full-documentation-design.md) |
| documentation site | [docs.heliograph.io](https://docs.heliograph.io): the CLI, the transports, and the far side - the station, the runner, steps, hosts, Azure, Windows, containers, services, secrets, security and the capture contract |

A transport that works on one side of the gap is not a transport, so this
table names both sides. Git and relay are driven end to end by the CLI and
proved in CI; what the others still need, and in what order, is
[the roadmap](docs/plans/2026-09-08-powershell-and-docs-roadmap.md).

> **This table was wrong for some time, and the reason is worth keeping.** Until
> 21 Sep 2026 it said relay was "half a transport" that "no CLI command can
> select", that the station had no transport for share, bundle or object store,
> and that the PowerShell station was "planned". All four were false against the
> code in this repository. The documentation site did not drift, because
> `transports_doc_test.go` binds it to `initTransports` and to the station
> transport directories - and nothing bound this file. It is bound now, by
> `TestReadmeTransportClaimsMatchTheCode`.
>
> The cost was not confined here: `skills.dbhq.uk/heliograph` deliberately
> published the *more conservative* claim because this README contradicted the
> documentation site, and recorded that it would stay understated "until
> heliograph settles which is true". This is that settlement.

## The relay

Both sides dial out over ordinary HTTPS, so an estate needs no git host, no
storage account and no VNet. Hosted, and self-hostable from the same binary.

**Not yet usable end to end.** The station side is complete and the server is
deployed; no CLI command can select it, so the near side is the missing half.

**The relay cannot read your logs, and cannot make a station run anything.**
That second half is the one that matters: a relay able to forge a request
would be code execution inside every estate at once. Content is end-to-end
encrypted with keys the relay never holds, and every message is signed.
Nothing bespoke - [age](https://age-encryption.org/v1) primitives plus
Ed25519. The full account, including what DBHQ can and cannot honestly claim,
is in
[`docs/specs/2026-09-06-relay-encryption-design.md`](docs/specs/2026-09-06-relay-encryption-design.md).
The relay server is its own repository,
[heliograph-io/heliograph-relay](https://github.com/heliograph-io/heliograph-relay),
because it holds no keys and must be publicly, obviously incapable of reading
anything it carries.

## What the beam is, and what it costs

The beam is designed and not yet built; what follows is what it will do when
it lands.

Two of the three shapes never hold a connection open. A **beacon** leaves a
message where both sides can reach it, and needs nothing to be reachable,
ever - no inbound port, no endpoint, no tunnel. A **flare** knocks, waits and
leaves; what it does not do is hold the line open once the answer is back, and
between the two of them an estate that will not have a held-open line at all
still gets the whole job done.

The **beam** does hold a line open, live and two-way, and that is a tunnel. A
blue team will read a held-open channel as one, because it is one. So it is
**off unless it is explicitly enabled on both ends**, it is sealed and signed,
and the station refuses to establish one unless it was started to allow it.
Where an estate forbids a reverse connection, the beacon and the flare are the
answer and nothing is lost but latency.

Every command still runs on the far side because someone with legitimate access
chose to let it.

## Layout

```
cmd/heliograph/         the control CLI, and `heliograph mcp`
cmd/heliograph-seal/    key generation for the relay transport
cmd/heliograph-site/    the static site generator
internal/transport/     git | relay | share | bundle | objstore
internal/bootstrap/     `heliograph bootstrap`: plants the embedded station
internal/wire/          the request and status documents that cross the gap
internal/seal/          sign-then-encrypt, for the relay
internal/logfile/       gap analysis
internal/mcp/           JSON-RPC over stdio, no dependencies
internal/estate/        which transport a name refers to
internal/plant/         what to send the operator
station/bash/           the bash station: everything that runs on the far side
station/bootstrap.sh    the no-CLI bootstrap: clone this repo, run it by hand
skills/heliograph/      the agent skill: drives the CLI, and nothing else
tests/                  the station's own suite, conformance contract included
site/content/           the documentation, one source, three renderings
infra/                  terraform: DNS, Pages, R2 state
docs/specs/             the designs, written before the code
```

The two halves used to be separate repositories, split along Go-versus-bash
rather than along the gap, and every reader had to work out which half they
were looking at. `dbhq-uk/heliograph-skill` was merged in on 2026-09-08 with
its full history; the reasoning is in
[`docs/specs/2026-09-08-station-and-skill-merge.md`](docs/specs/2026-09-08-station-and-skill-merge.md).

**That repository was deleted on 2026-09-17** and the name is not in use. It stayed public and archived after the merge, and an archived repository is read-only rather than unreachable: it still cloned, its `install.sh` still ran, and the station in it had no request-env guard at all (heliograph-cloud#274). Its history is kept privately; this repository's own history carries the merge.

## Development

[`PLAN.md`](PLAN.md) is where the work stands: what has landed, what is next,
and which defects are known and unfixed.
[`CONTRIBUTING.md`](CONTRIBUTING.md) covers working on it and
[`AGENTS.md`](AGENTS.md) is for an AI agent doing so. The skill is
[`skills/heliograph/SKILL.md`](skills/heliograph/SKILL.md);
[`docs/dev-setup.md`](docs/dev-setup.md) sets it up from source with live
edits.

## Licence

[Apache 2.0](LICENSE) (c) 2026 DBHQ Consulting Ltd, and the prose under `site/content/` is
[CC BY 4.0](site/content/LICENSE). Relicensed from MIT on 2026-09-17; every commit
up to and including `b689f9c` stays available under MIT for ever. [`NOTICE`](NOTICE)
says why Apache rather than MIT, and what the change does not take away.

The relay is a separate repository and a separate licence:
[heliograph-relay](https://github.com/heliograph-io/heliograph-relay) is
FSL-1.1-ALv2, fair source, converting to Apache 2.0 two years after each
release. **No shape is ever gated**: beacon, flare and beam all work on a relay
you host yourself.

Full statement, including the professional-services grant and its honest limit:
**<https://docs.heliograph.io/licence>**

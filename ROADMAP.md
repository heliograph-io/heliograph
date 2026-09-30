# Roadmap

What heliograph is for, where it stands, and what comes next. Every piece of work is a [GitHub issue](https://github.com/heliograph-io/heliograph/issues), and the epics below are the plan. What landed before 2026-09-29 is in [`docs/history/2026-09-plan.md`](docs/history/2026-09-plan.md).

## What heliograph is for

heliograph is for people who have to investigate or fix a machine they cannot log into, and for the people who own that machine. It is built first for software companies whose products run inside their customers' estates: the vendor's engineer, or an agent working for them, proposes each step; the customer's own operator decides what runs; and what ran, and what it printed, comes back as a record. It is not remote desktop, not a privileged-access gateway, and not a way round an estate's own controls. It does not program PLCs, and it does not replace a site visit where the job needs hands.

## Where we are

The latest release is [`v0.4.3`](https://github.com/heliograph-io/heliograph/releases/tag/v0.4.3), from 2026-09-17: the CLI, its MCP server, `heliograph-seal` and the `.mcpb` bundles, for Linux, macOS and Windows. The relay is its own repository, [heliograph-io/heliograph-relay](https://github.com/heliograph-io/heliograph-relay), tagged up to `v0.3.0`.

What works today, as the commands that show it:

```bash
heliograph bootstrap ~/transport/payments   # plant a bash or PowerShell station
heliograph init payments --dir ~/transport/payments --transport git   # or share, bundle, objstore, relay
heliograph doctor                           # read access, write access, the credential in force
heliograph send env                         # propose a step; the far side decides whether it runs
heliograph watch --timeout 10m              # follow it
heliograph logs --last --gaps               # every line time-stamped, and where the output went quiet
curl https://relay.heliograph.io/health     # the relay we run, the commit it reports and its hash
```

Both stations, bash and PowerShell, poll, run, deliver and publish, with every gate. The CLI drives a real station end to end in CI over git, a file share and the relay. The [quick start](https://docs.heliograph.io/quickstart) goes from nothing to a captured log in five steps.

Known defects are issues labelled [`type: bug`](https://github.com/heliograph-io/heliograph/issues?q=is%3Aissue+is%3Aopen+label%3A%22type%3A+bug%22). The worst open one is [#203](https://github.com/heliograph-io/heliograph/issues/203): both stations push a log to the branch's configured upstream rather than to `origin`.

## Now, Next, Later

One line per epic. Each epic's `Done when` list is the definition of finished, and its sub-issues are the work. The [board](https://github.com/orgs/heliograph-io/projects/1) shows the same issues by status.

### Now

- [A captured log comes back whole, or the station and the tools say exactly what is missing](https://github.com/heliograph-io/heliograph/issues/209) - what ran and what it printed reaches the control side, and where it did not, every surface reports what was observed rather than a guess.

### Next

- [A change-controlled estate can install and verify heliograph through a channel it already uses](https://github.com/heliograph-io/heliograph/issues/210) - an estate that will not approve a `curl` command installs heliograph from a package manager it already trusts, and can verify it on a sealed network.
- [Beacon, flare and beam each cross the gap with the guarantees the site claims for them](https://github.com/heliograph-io/heliograph/issues/85) - beacon and flare are finished and the beam, a held-open live channel, is built.

### Later

- [heliograph runs on the hosts, pipelines and control nodes people already have](https://github.com/heliograph-io/heliograph/issues/211) - each new host, transport and control node is proved end to end, or refused in writing with the reason.

## What we will not do

**Gate a shape.** Beacon, flare and beam all work on a relay you run yourself and on the one we run. No capability that crosses the gap moves behind a paywall. That rule was set in [heliograph#93](https://github.com/heliograph-io/heliograph/issues/93): extension points exist for multi-user, multi-estate and governance concerns, and never to take a transport shape, the cryptography, key handling, the gates or audit generation out of the build you can run yourself.

**Hold your signing key in a service.** Where a request is signed, as it is on the relay transport, it is signed on the control node that sends it. A service holding every estate's signing key could run commands inside every estate at once, which is what the relay is built not to be, so [the site's roadmap](https://docs.heliograph.io/roadmap) lists a hosted web control plane as "never". The relay verifies signatures and holds no private key, and its CI checks the built binary cannot sign ([relay README](https://github.com/heliograph-io/heliograph-relay#verified-never-signed)). The CLI's code that forwards a spool to a service cannot reach the code that signs a request (`internal/cloud/authorship_test.go:69`).

## Open and commercial

Applied on 2026-09-17, and described in full on [licensing](https://docs.heliograph.io/licence):

| | |
|---|---|
| **heliograph**: CLI, station payloads, wire format, transports | [Apache 2.0](LICENSE) |
| **The documentation** under `site/content/` | [CC BY 4.0](site/content/LICENSE) |
| **heliograph-relay** | [FSL-1.1-ALv2](https://github.com/heliograph-io/heliograph-relay/blob/main/LICENSE), fair source, converting to Apache 2.0 two years after each release. Always self-hostable |
| **Heliograph Cloud** | proprietary. Its documentation is public and CC BY 4.0 |

Every commit published under MIT stays available under MIT: `b689f9c` and earlier here, `f664ea0` and earlier in the relay, including its `v0.1.0` and `v0.1.1` tags. Each repository's `NOTICE` says so.

## Claims and their status

| claim | status | evidence |
|---|---|---|
| CLI releases are signed | **True from `v0.4.2`.** Every release before it carries no signature | `SHA256SUMS.sigstore.json` is published on `v0.4.2` and `v0.4.3`. The `cosign verify-blob` command on [provenance](https://docs.heliograph.io/provenance) answered `Verified OK` against `v0.4.2` from a clean download |
| CLI release binaries rebuild byte for byte | **True** | `packaging/reproduce.sh` is the build the release uses, and the `reproducible` job in `.github/workflows/validate.yml` builds twice from two directories and fails on a difference |
| The relay is signed | **Not true.** It has tags up to `v0.3.0` and no GitHub release, so nothing carries a signature | [relay README](https://github.com/heliograph-io/heliograph-relay#provenance): "Nothing here is signed yet" |
| The relay rebuilds byte for byte | **True**, for the Go binary and the Worker | The relay's CI builds each twice on every pull request. `edge/reproduce.sh` rebuilds the Worker bundle from a tag |
| The relay we run is the published source | **Not established.** One deployed hash has been compared to a build, by hand | On 2026-09-29 `relay.heliograph.io/health` reported commit `adc17a8` (`v0.3.0`) and hash `0b2d5e01ab8202978af0a0bcde40aca53a1b6d326e68bc68bf98a83dea1f65a6`, and a fresh rebuild of `v0.3.0` with `edge/reproduce.sh` gave the same hash. A Worker cannot read its own code, so that hash is the number the deploy workflow computed and reported. It matches a build; it does not prove what is serving |

## Contributing

The [public board](https://github.com/orgs/heliograph-io/projects/1) holds every open issue under its epic. [`CONTRIBUTING.md`](CONTRIBUTING.md) says how to work on heliograph and what will not be accepted, and [`AGENTS.md`](AGENTS.md) holds the constraints and the lessons this repository has already paid for. Report a vulnerability as [`SECURITY.md`](SECURITY.md) says, not in an issue.

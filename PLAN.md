# PLAN

The living register. Written so the state survives a context compaction, a
handover, or a week away. Update it as work lands rather than at the end.

**Detail lives elsewhere and is not repeated here:**
[`docs/specs/`](docs/specs/) for designs,
[`docs/plans/2026-09-08-powershell-and-docs-roadmap.md`](docs/plans/2026-09-08-powershell-and-docs-roadmap.md)
for the 19-PR breakdown. This file says where we are and what is next.

---

## Where we are

Every transport now has both halves. Git, the file share, the relay and the
bundle are proved by a round trip in CI; the object store's signer is proved
against the Go implementation's own vectors, because there is no account to
round-trip against. The site documents the far side. **The PowerShell station is
complete**: it polls, runs, delivers and publishes, and it is planted by all
three bootstraps.

| | |
|---|---|
| control CLI over git | works, driven end to end in CI against a real station |
| relay | **works end to end**, driven against the deployed relay at `heliograph-relay.dbhq.uk` on 2026-09-09 |
| Azure Blob | works end to end via `drop.sh` and `pigeonhole.sh`, not via the CLI |
| every host but a pipeline | carries a transport. Azure Blob works outright everywhere; the relay and the file share need a volume the templates do not mount |
| file share | **works end to end**, proved by a CLI round trip in CI |
| bundle | **works end to end**, proved by a CLI round trip across a directory that stands in for the medium. No `live` and no `self`, because a stick does not change while you watch it |
| object store | **works end to end**. The station signs SigV4 in bash over openssl and curl - no AWS CLI, no binary - and the signer is held to golden vectors from the Go side, every stage pinned |
| bash station | in use; the loop, the gates, the capture |
| PowerShell station | **complete and proven**. Polls, runs, delivers and publishes over git, share **and relay**, with all four gates. Every conformance property, on 5.1 and on 7, over all three. **The relay needs no binary**: the seal is managed C# shipped as source, held to the Go side's golden vectors byte for byte |
| site | 29 pages, near and far side, plus `/matrix` (every transport, station and controller, from one source in Go) and `/roadmap`. **Measured and indexed from 2026-09-09**: GA4 on the dbhq.uk stream behind consent, sitemap with `lastmod` submitted to Search Console |

## Landed 2026-09-08

| PR | |
|---|---|
| #20 | A8 spec: the PowerShell station, and `tp_put_log` |
| #21 | status claims match the code, plus a drift guard |
| #24 | **`tp_put_log`** - the finished log now ships on relay and blob |
| #25 | the far side published: 14 new site pages, plus coverage guards |
| #26 | the home header was the whole sitemap, three rows deep |
| #27 | mobile drawer, and the host/transport tables |
| #28 | the sidebar stays put when you use it |
| #29 | Codex first-class on the site |
| #30 | the git transport's credential, documented |
| #31 | spec: one repository, many stations |
| #32 | **`heliograph station add`** |
| #33 | the multi-station hardening |
| #34 | documented what shipped, and two more guards |
| #35 | this file |
| #36 | **the preflight stops assuming git** - `tp_preflight`, `tp_sync`, and a token that was being printed |
| #37 | **`transports/share.sh`** - the file share gets its far side |
| #38 | **the relay, reachable and usable** - and four defects only a round trip could find |
| #39 | proved over the deployed relay, and CI keeps asking |
| #40 | **containers and services can select a transport** - and twelve defects a review found in it |
| #41 | **`heliograph-seal` in the image** - a relay station runs in a container |
| #42 | the launchd flake carries its own diagnosis |

## Landed 2026-09-09

| PR | |
|---|---|
| #43 | **analytics and search on the site** - GA4 behind consent, `lastmod`, descriptions, JSON-LD, `og.png`, a 404 page, and the two font preloads that 404ed on every page view. Spec: [`docs/specs/2026-09-09-analytics-and-seo-design.md`](docs/specs/2026-09-09-analytics-and-seo-design.md). The keyword research behind it moved to the private `dbhq-uk/dbhq-seo` on 2026-09-12, beside the raw data it cites: it is go-to-market work and this repository is public |
| #44 | **Windows and the pipelines** - the scheduled task carries a transport |
| - | **the breadcrumb says the nav label, not the H1** - `/compared` read "heliograph / heliograph compared with AWS SSM Run Command and Azure Run Command", found by driving the deployed page rather than by a test |
| - | **the rail rebinds after a client-side navigation** - it had stopped marking the current section after one soft nav, on every docs page. Found by driving the deployed site; `swap()` now announces `hg:swap` |
| - | **the DBHQ menu, a `/dbhq` page, and the footer block removed** - #45's "Also from DBHQ" said the same three links on 27 pages, at the point a reader has stopped reading. Also fixed: `\| \| \|`, the headerless-table idiom on ten pages, was skipped as a separator and the first row of data became a `<thead>` |
| - | **the docs affordances, measured against paseo.sh** - a copy button on every code block, Copy/View as markdown above the title, a visible breadcrumb, a rail that marks where you are, `favicon.ico` and `apple-touch-icon.png`, and the GitHub mark on the site's own links to the repository. Spec: [`docs/specs/2026-09-09-site-affordances-design.md`](docs/specs/2026-09-09-site-affordances-design.md) |
| - | **the content the research asked for** - `/air-gapped`, `/compared` (AWS SSM and Azure Run Command), and a permissions section on `/security`. Also: `heliograph send` on a bundle told people to run `./station.sh --bundle`, which has never existed; it now says the honest thing |
| #49 | **the Azure templates carry a transport**, and CI validates them at all - which found that a sensitive value cannot drive `for_each`, so the Container Apps job had never parsed under the pinned terraform. Also: **no station had ever run under launchd**, because a LaunchAgent's PATH holds only macOS's bash 3.2 |
| #50 | **conformance over every transport**, with a stub relay so it needs no Cloudflare account - and a teeth check per transport, because running the suite three times only proves three passes |
| #51 | **the conformance harness stops being Unix** (Track B/PR 8) - p6's privileged account and p8's cancel move into the driver, p8 proves the cancel by watching the log stop growing, and the redaction corpus lands with a test that every rule is load-bearing |
| #52 | **`caplib.psm1`** (Track B/PR 9) - the capture in PowerShell, passing properties 1-4, 7 and 8, skipping the gates and delivery by name. The step fixtures moved into the driver too, which was the last Unix left in the suite |
| #66 | **the PowerShell transports** (Track B/PR 12) - git and share deliver, and property 9 stops skipping. Teeth for both, because a second implementation of delivery is a second thing that can silently stop delivering. Found: `Import-Module` inside a module function imports into THAT module's session and nowhere else, so the transport loaded, initialised, reported success, and every one of its functions was invisible |
| #54 | **the cancel and the preflight** (Track B/PR 11, part) - a Win32 Job Object with `taskkill /T /F` where `Add-Type` is blocked, which is the estate this station is for. Property 8 stops skipping on Windows. `start.ps1` answers the two questions that decide whether a station can run at all: Constrained Language Mode, and a GPO-set execution policy |
| #53 | **`run.ps1`** (Track B/PR 10) - the runner and its three gates, a `probe.psm1` and a shipped `env` step. Found three case-sensitivity divergences from `run.sh`, two of them in a security gate, and added a twin comparison that would have caught all three |

## Landed 2026-09-11

| PR | |
|---|---|
| #71 | **HTTPS enforced, and `llms.txt` announced** (#70) - a `<link rel=alternate>` in every head and a visible footer anchor. It had been reachable only by an agent that already knew the path |
| #72 | **the rest of #70's code half** - `author` splits from `publisher`, so a named person writes the pages and DBHQ publishes them, with a footer byline saying so; `datePublished` from the first commit beside `dateModified`; and Googlebot and Bingbot are kept off the `.md` mirrors, under their own groups so no other agent is. Also corrected: the "roughly 31 times more bytes" claim, quoted in four files and never measured. It is three to sixteen times, about eight on the median page, and a test now measures it on every build |
| - | **the PowerShell station, finished** (Track B, PRs 13-14 merged into one). `station.ps1` - the loop, gate 3, the receive half of both transports, the bootstrap that plants it, and the documentation. Split no further on purpose: every earlier PR was split so that each piece could be *proved*, and once the loop exists the remaining pieces are provable end to end together. See below for what it found |
| - | **`/dbhq` loses the browser-tools table, and the compliance-label word leaves the repository** - the two hosted tools are no longer listed, and the company line now says senior engineering delivery across multiple industries. The claim that this class of tool was permitted on account of its customers' compliance status was an overclaim - nobody in that sector has certified it - and the word appeared in the README, `/index`, `/security`, `/relay`, `/claude-code` and the design spec. Each one is rewritten to make the same argument without asserting somebody else's approval: the TCP paragraph now ends "nothing here is worth having if a blue team has to call it one", and the relay threat model argues from the estate that would not give you SSH rather than from naming its customers' compliance status. The audience list drops the word for "somebody else's sign-off" |
| - | **verve run over every markdown file in the repository, and the prose passed** - 27 site pages, the README, AGENTS.md, CONTRIBUTING.md, SECURITY.md, PLAN.md, and every file under `docs/`. No em dashes, no curly quotes, no AI vocabulary, no throat-clearing openers, no filler phrases, no meta-commentary. The forty-eight adverb hits are all doing semantic work ("literally true rather than nearly true", "what they really break", "publicly, obviously incapable"), and the "not X, it is Y" constructions each correct a misreading, which is the case the rule keeps. Recorded so nobody runs it again expecting a yield. Three real edits: `in order to` in the relay spec, "a feature, not an accident" in the B1 plan (a stock construction, now says what the feature is for), and `references/` listed twice in one CONTRIBUTING sentence. Plus seven prose lines rewrapped to the 80 columns their own file keeps, in `/index`, `/conformance`, `/containers`, `/transports`, PLAN.md and `dev-setup.md`. The soft-wrapped specs and plans are left alone: that is their convention, not drift |
| - | **the mirror saving remeasured, forced by the line above** - removing the browser-tools table made `/dbhq` the shortest page on the site, which pushed its HTML-to-markdown ratio to 20.5 and failed `TestTheMirrorSavingIsTheOneTheCommentsClaim`. Remeasured again after merging main, which added `/matrix` and `/roadmap`: over 29 pages it is 2.8 to 20.5, about seven on the median page and 5.8 across the whole site. The ceiling is the shortest page rather than a mid-length one, because chrome is a fixed cost that short pages cannot dilute - `/dbhq` is an outlier, and the next page down is `/pipelines` at 14.8. The bounds keep the slack main added in #84 and move only the ceiling, 18 to 23 |
| #76 | **content gap 5, and two H2s that are questions** (#70) - `/method` answers "run a command on a remote machine" the way that SERP is written: the `ssh`, `Invoke-Command`, PsExec and cloud-agent answers first, then the case where each has been refused. One question-form H2 each on `/claude-code` and `/mcp`, and nowhere else |

**The MCP registry lists heliograph** as of 2026-09-11, at
`io.github.dbhq-uk/heliograph`, which is the name the hand publish used and is
therefore the name that entry still carries. The 2026-09-16 transfer makes the
publishable namespace `io.github.heliograph-io/heliograph`, a new entry rather
than a rename: the old one stays resolvable for anybody holding it. Published
by hand once; the release workflow
republishes it from now on, so the advertised version cannot drift from the
package. Two things had to be fixed first, and both fail only at publish time:
the description was 106 characters against a limit of 100, and the `$schema`
was a revision the registry now calls deprecated. Publishing as the
organisation needs the Actions OIDC token - a user token carries
`io.github.<user>/*` only, even with public org membership.

The rest of #70 is off-site and stays on that issue: the social previews on
both repositories, the awesome-list entries, and the Glama listing.

### What that change found

Five defects, three of them in code that had already shipped.

- **`./station.sh --allow-root` has never worked.** It set a shell variable
  that was never exported, so it satisfied the LOOP's root gate and reached
  nothing else. `run.sh` is a separate process with a gate of its own, so every
  step was refused with exit 5 while the published status said only *"the
  runner exited before it reached delivery"* - the symptom, and not one word of
  the cause. `ALLOW_ROOT=1 ./station.sh` worked the whole time, because that
  form is already in the environment. **Fixed** (one `export`), and reproduced
  end to end against the real station before and after
- **The release binary embedded 912 MB of Terraform providers.** `go:embed
  all:bash` reads the WORKING TREE, so `station/bash/azure/*/.terraform`, left
  by `terraform init` - which is what `terraform test` runs - went into the
  binary. Measured here: **239 MB, down to 11.3 MB** once cleared. The
  repository never noticed because those paths are gitignored; CI never noticed
  because a runner starts clean. `internal/bootstrap` prunes `.terraform`, and
  its comment names this exact risk, but it prunes at INSTALL time - by then
  the files are already in the binary. **Fixed** with a guard in
  `station/embed_test.go`, which is where the embed is
- **The same build carried `station/bash/.station-delivery`** - a runtime record
  naming a path under `/tmp` on the machine that built it - and `bootstrap.sh`
  planted it into every repo bootstrapped from that checkout. A station's own
  runtime state is now pruned by name in all three bootstraps and refused by the
  embed guard. `.station-env` is in that list and holds a token.

  **Where it came from**: `tests/test-intercom.sh` drove `intercom.py`, which
  finds its toolkit by walking up from its own file - which in a checkout is
  `station/bash`. So it ran the SHIPPED `run.sh` in place, and `run.sh` wrote
  its delivery record there, which is exactly right on a real station and wrong
  in a checkout. The test now runs against a bootstrapped copy via a new
  `HELIOGRAPH_TOOLKIT` override, read from the environment only - it chooses
  which `run.sh` executes, so a request must never be able to set it.
  `tests/run-tests.sh` now FAILS if any test leaves runtime state in a payload
  directory, which is a different thing from its existing leak counter: that one
  is a hint for diagnosing a flaky suite, this is a defect with a blast radius
- **`Stop-CapTree` would have killed the station.** On Unix it signalled
  `-$pid` unconditionally; a child started by `Process.Start` inherits its
  parent's process group, so the negative pid resolves to the STATION'S OWN
  GROUP. It does not fail - it succeeds at the wrong thing, so the fallback
  never fires. Nothing caught it because the only caller until now was the
  conformance driver, which starts its target under `setsid`. It now measures
  `pgid` first and says how far a cancel would reach

- **Progress never published on Windows, and nothing said so.** `Invoke-CapRun`
  holds the log open through `[System.IO.File]::AppendText`, which opens with
  `FileShare.Read`. That is only half the check: a SECOND open must also declare
  a share mode that tolerates the FIRST handle's access, and the first handle is
  a WRITER - so `File.ReadAllLines` and `Copy-Item`, which both open with
  `FileShare.Read`, throw a sharing violation against a log still being written.
  Nothing enforces any of that on Linux, so it worked perfectly there. The
  loop's read is inside a `try/catch` that returns quietly, because losing a
  race with a live writer is not a reason to stop publishing progress - so on
  Windows a long run was a black box, for every step, silently. **Found by the
  conformance run on a real Windows runner**, not by reasoning. caplib gains
  `Read-CapSharedLines` and `Copy-CapSharedFile`

Three of my own assertions proved nothing and were fixed: a metacharacter check
that passed with the guard removed (a *different* guard caught the case); a
"reason names the variable" check asserted once after a loop, so it only ever
saw the last of four spellings; and an `--allow-root` regression check that read
a status the previous sub-test had left, because `VAR=x` arriving through `"$@"`
is taken as the command name rather than as an assignment.

A fourth was timing rather than measuring: the progress check waited 400
iterations of `sleep 0.1`, which on a Windows runner outlasts the 40-second step
it is watching - so it read a DELIVERED log and called it partial. Every wait in
that file is bounded by the clock now, and the condition requires a `progress:`
key AND the step's own output, because each alone is satisfiable by something
that is not progress.

## In review, not merged 2026-09-13

**The trusted set** (`heliograph-io/heliograph-cloud#29`, `#28`). Held at the PR
deliberately: it changes authorisation semantics in a public repository, and a
wrong merge there is shipped to self-hosters.

The hole it closes is that "the service holds no signing key, so it cannot cause
a station to run anything" is true and insufficient. Signature verification only
means the station trusts whatever key it was told to trust, so anything able to
administer trust roots could add a key it controls and then sign legitimately -
nothing stolen, nothing forged, every gate passed, claim false.

A station may now hold a **trusted set**: several keys, each belonging to one
person. Four rules, each doing one job.

| | |
|---|---|
| a change is itself a signed document | verified against the set as it stands, over the transport the estate already uses. There is no unsigned path and no permissive mode |
| any trusted key may add or revoke any key **except the anchor** | offboarding one engineer across forty estates cannot mean forty visits |
| **the anchor changes only on the machine** | no request moves it, shadows its name or revokes its key - not even one signed by the anchor's own key. A compromised key can evict every other engineer and cannot evict the owner |
| the station publishes its set | digest, serial and every fingerprint, on every transition, so an owner audits who may command their estate **without asking us** |

**The mutation rule is what makes the first one a property rather than a habit.**
`trust.Set.members` is unexported and the package exports no mutator except
`Apply`, which verifies a signature before it returns a changed set. No package
outside `internal/trust` can add a member to a set, and Go's compiler enforces
that rather than a reviewer.

**The two assertions that carry the claim**, both watched failing:

- `TestTheAnchorIsUnchangeableByAnyRequest`. Dropping the anchor's KEY check and
  keeping the name check - the shape a refactor would take - lets "a member
  re-adding the anchor's key" through with a nil error, and turns "revoking the
  anchor's key under another name" into `ErrNotAMember`
- `TestNoControlPlanePathAuthorsAChange` and its three siblings, which assert
  over SOURCE rather than behaviour. "The service cannot cause a station to run
  anything" is a statement about what code exists, not about what it does when
  run: a behavioural test can only show that the paths somebody thought of do
  not author a change

**Both stations verify, and they cost different things.** The PowerShell station
needs nothing new - Ed25519 is already there in managed C#. The bash station
needs `heliograph-seal`, the one binary the relay already installs on the far
side; on any other transport it is opt-in, and a bash station told to use a set
without it refuses to start rather than accepting everything quietly. That
asymmetry is the finding for `#48`, which holds the binary policy: nothing new
crosses the boundary, and the alternative would have been a second far-side
binary.

`tests/fixtures/trust-vectors.json` holds the two implementations to the same
bytes - canonical encodings, digests, signing input and **whole refusal
sentences**. It found two divergences immediately, neither cryptographic: the
anchor refusal named a binary the PowerShell station does not have, and the
published audit line said `revoked` in one renderer and `REVOKED` in two others,
so an owner grepping their estate for REVOKED would have found it on half of it.

Also in the same branch, because a signature over "run this" was not enough:
`mode`, `target` and `expiry` join the signed scope, and the id ledger is a file
so replay protection survives a restart. `.station-state` held only the LAST id,
so a request from two days ago, put back, ran again with every gate satisfied -
the relay's sequence counter caught that and git, share, blob, bundle and object
store had nothing.

**Revocation is eventual and now says so** in `security.md`, in `cli.md`, and in
the CLI's own output at the moment somebody changes access. A station acts on a
revocation at its next poll and an already-running step is not interrupted.

## Landed 2026-09-12

| PR | |
|---|---|
| - | **the object store gets a station side** - `transports/objstore.sh`, the last transport that was control-side-only. It signs **SigV4 in bash**, over `openssl` and `curl`: no AWS CLI, no python, no binary. The layout is the control side's, including the `.partial.txt` suffix that makes `heliograph logs` hide an in-flight snapshot rather than list it beside finished runs |
| - | **a cancelled run's partial log now ships on blob and relay** - `tp_put_status`'s third argument. git, share and bundle honoured it; blob and relay had never NAMED the parameter, so nothing a reader saw in those functions said it was being dropped. It was a recorded defect rather than a caught one |
| #96 | **the PowerShell payload can survive a logout, and carry its own configuration** - `station/powershell/service.ps1`. A scheduled task rather than a service, registered against `start.ps1` so the preflight runs on every start. `--flavour powershell` had planted no way to survive a logout at all. The hard part is not the task: a task inherits nothing, so the transport's variables and the credential go into `.station-env-ps` - `KEY=value`, read and never executed, values verbatim, a newline refused rather than stripped, ACL set to this account only, deleted on uninstall. `install` refuses when a detached loop could not deliver, because nobody sees that failure until hours later |
| - | **the PowerShell relay** (#77) - `transports/relay.psm1` and `lib/seal.psm1`, so the payload built for estates that permit no binary can use the one transport that needed one. The bash relay shells out to `heliograph-seal`; this one does the whole construction in managed C# that ships as **source** inside the payload and is compiled by `Add-Type` at startup. X25519, Ed25519 and Poly1305 from a vendored Chaos.NaCl (djb's ref10, MIT, 60 files); ChaCha20, the RFC 8439 framing and HKDF-SHA256 written here. Conformance passes over the relay on both editions: **36 passed, 0 failed, 0 skipped** |
| - | **the bundle's station side** (#68) - `transports/bundle.sh`, so the one transport that makes *air-gapped* literally true now has a far side. A station started with `TRANSPORT=bundle BUNDLE_DIR=<mount>` reads the request the CLI wrote, runs it, and writes the status and the log back onto the medium for somebody to carry home. It declares `request status progress` and **not** `live` or `self`: a stick does not change while you watch it, and nothing publishes a payload to one. Conformance runs over it, and `/air-gapped`, `/transports`, `/station` and `/matrix` are corrected - all four said a station could not read a bundle |
| - | **the hosted relay gets a door** (heliograph-io/heliograph-cloud#73) - five pages pointed an operator at `heliograph-relay.dbhq.uk` and none said how to obtain a token, what it carries, or what happens if it stops. One section on `/relay` now says it, and `/cli`, `/hosts` and `/transports` link to it rather than repeating it, all in one change so no page advertises a route the others have retired. A free plan with the server's own constants as its published limits - 8 MiB a message, 256 a queue, seven days, a 25-second poll - and thirty days' notice by email if any of that changes, which is keepable only because provisioning is a hand-edited environment variable and the mailbox that issued a token is the record of who holds one. No pricing and no tier: undecided, and not this repository's to publish |

| - | **a blocked port is diagnosed as a blocked port** (#66) - the read check ended every failure on *"Check the remote URL and the credential reported above"*, so an estate that drops outbound 22 sent the operator at the two things that were fine, and `443` appeared nowhere in the repository. Both stations now classify the NETWORK before they blame the credential: a timeout, a refusal, a name that will not resolve, an untrusted CA and a proxy 407 are five different estates with five different remedies, and the message names the host's SSH endpoint on 443 where it has one. `/transports` gains the two sections that need no code at all: SSH on 443 for GitHub and GitLab, and an https remote through an inspecting proxy - `http_proxy`, `no_proxy` and `GIT_SSL_CAINFO`, and why `http.sslVerify=false` is not the answer |
| - | **the keyword research leaves the public repository** (heliograph-io/heliograph-cloud#76) - `docs/seo/2026-09-09-keyword-research.md` was go-to-market work sitting in a public repo: volumes, difficulty scores, competitor SERPs, positioning and a spend line, with a summary stating the market-size question in public. It is now `reports/heliograph/2026-09-09-keyword-research.md` in the private `dbhq-uk/dbhq-seo`, beside the 44 raw responses it cites, which were always there. The spec and the plan that link to it are annotated at the point of change rather than rewritten. The rest of the repository was swept for strategy content and there is none: `/roadmap`'s "never" table is the boundary statement the public repo is meant to carry, and `compared.md`'s pricing line is AWS's own published pricing |
| - | **all three public repositories swept, and the row above understated the result** (heliograph-io/heliograph-cloud#209) - #76's sweep covered this repository on 2026-09-12 and reported nil. Widened on 2026-09-13 to `heliograph-relay` and to `heliograph-cloud-docs`, which did not exist then, it is not nil. Two items here: `docs/specs/2026-09-06-heliograph-next-design.md` still carried three target keywords and an assessment of who holds the exact-match `.com`, which is the residue of the file #76 moved, plus a stale open intention to register a second domain - annotated at the point of change, text recorded privately first. And `site/content/relay.md:125` had acquired "who are the customers" on the end of a trust-boundary sentence in `a531f96`, which is a target-segment claim, a broken sentence and a 90-character line in a file that wraps at 78; the wording it replaced is restored. The third item is in `heliograph-cloud-docs` and is the only one with a real cost. `heliograph-relay` is clean: its tenancy, quota and billing language is the `Authoriser` interface the no-fork discipline requires to be public |
| - | **the beam's first carrier is the long poll, and `wss` is an optimisation** (heliograph-io/heliograph-cloud#36) - S4 chose `wss` by comparing it against gRPC and HTTP/2 streaming. Those were never the alternative: the alternative is the long poll the relay already uses and has already proved through these networks, and against that baseline `wss` is strictly less robust, because a long poll has no upgrade to strip. `wss` becomes carrier two, negotiated per estate with silent fallback, and the beam stops being blocked on a network question nobody has measured. The relay's own rationale is narrowed at the same time: a CONNECT proxy cannot strip an upgrade it never sees, a **TLS-intercepting** proxy can, and there is no client-side fix - which is the sharper argument, because the estates this exists for are the ones most likely to run one. Corrected in the S4 draft and on `/relay`; annotated in the two dated specs |

| - | **the build is reproducible, and the far-side binary rule is now a policy instead of an exception** - `packaging/reproduce.sh` builds every released artefact and the release workflow calls that same file, so the command a stranger is given and the command that made the artefact are one thing. Two builds of the same source, at different paths, one with no `.git`, produce identical `SHA256SUMS`. `AGENTS.md`'s absolute "never a binary on the far side" is replaced by a per-transport policy with `station/FAR-SIDE-BINARIES` as the enforced list, because `heliograph-seal` had already escaped the letter of the old rule and the CI message still said the far side never gets a binary |

### What reproducible builds found

**The relay half landed at the same time**, in
[heliograph-io/heliograph-relay#14](https://github.com/heliograph-io/heliograph-relay/pull/14):
`edge/reproduce.sh` builds the Worker bundle and prints its hash, the deploy
workflow runs that same script to compute the number it stamps in, and
`GET /health` reports the version serving and the hash of what is serving in
both implementations. The Go relay hashes its own executable at startup, so its
answer is what is running rather than what it was told - measured
`319f7aae334326a25f593392d895299903c324e30e4ccb38698c7f4278826c20` on disk and
the same string from the endpoint. A Worker cannot read its own code, so its
hash arrives from the deploy log, and the README says so rather than glossing
it.

**Nothing is signed.** The signing step exists in `release.yml` and no tag has
been through it, so no release carries a signature and nothing claims one does.
The claim "the code in the path is provably the code you can read" is therefore
still unpublished, deliberately.


**The build was not reproducible, and nothing said so.** Measured on
2026-09-12 before anything was changed: the same commit built in the git
worktree and in a tarball of that worktree gave
`475be5207e51b5406a684aabf5335fadd676f5a3473fd7b4481f477442fccebb` and
`7a1ac6922a41e4596cd835e0802863471d79d44882275dcfc133d5804ab8f8ac`. Go stamps
`vcs.revision`, `vcs.time` and `vcs.modified` into every binary by default and
omits them **silently** where there is no repository, so the one person who
would have found out is somebody verifying a download against the published
hash - who would reasonably conclude the release was not built from the
source. `-buildvcs=false` in one place fixes it; `-trimpath` alone never would
have.

**`go 1.27.1` in go.mod and `go-version: '1.27'` in four workflows is not a
pin, it is two pins that happen to agree.** With `check-latest: true` the
runner takes the newest 1.27.x that exists on the morning the job runs, and a
Go patch release changes the compiler, so the day 1.27.2 ships the released
binary stops matching anything anybody can rebuild - with every check still
green. `packaging/toolchain_test.go` now fails the build when go.mod, the
workflows and the two Dockerfiles disagree.

**A check can enforce half a rule and report PASS while the rule is broken.**
The station purity gate refused Go source under `station/` and printed "the far
side never gets a binary dependency". `heliograph-seal` is a Go binary that
runs on the far side and has done for weeks; it passes because it is built from
`cmd/` rather than living under `station/`. The gate was green, its message was
false, and the next contributor to add a far-side binary would have taken that
message as permission. The list is now the rule, and the message says what is
actually checked and what is not.

**"Beacon and flare need no binary" is very nearly true and worth not
rounding off.** The relay is a beacon and its bash station does need
`heliograph-seal`. The accurate line, and the one the docs carry: git, share,
bundle and object store need nothing compiled, the PowerShell station needs
nothing compiled even for the relay, and an estate that permits no binary loses
two shapes rather than the tool.

| #112 | **a station publishes whether it will run an action** (heliograph-io/heliograph-cloud#27) - `wire.Status` gains `actions:`, `allowed` or `refused`, written by all five status writers across the three shipped loops and read by `heliograph status` and `heliograph_status`. Before it, `read-only` versus `action` was `--allow-actions` and nothing else: a flag read once at startup, on no request and in no document, so anything wanting the answer had to infer it from log history - which is wrong in both directions, because a station restarted without the flag still has its old action logs and one started with it may never have been asked. **Three answers, not two.** A station that publishes nothing is not read-only, it is a station planted before the field, and the CLI says `not reported` rather than choosing a side. See below for what it found |
| - | **`heliograph login`, `push` and `rotate`** (heliograph-io/heliograph-cloud#15 and #11) - the CLI half of the hosted service. `login` is a device-code flow with nothing to paste; `init --transport relay --hosted` provisions an estate, so there is no container to run and no TLS for the customer to terminate; `push` forwards the spool; `rotate` replaces a control credential and says first what it does not rotate. `doctor` reads a refusal as a refusal, branching on `cause` rather than on a status code. `internal/cloud` cannot reach `internal/seal`, `internal/transport` or `internal/trust` and never names `wire.Request`, so **no code path in it can author a request**, asserted three ways rather than promised |

### What the action mode found

**The field is easy; the third answer is the whole job.** `ActionsRefused`
written the obvious way, as `!ActionsAllowed()`, passes a test over both
published values and reports every station in the field today - all of them, on
every estate - as read-only. That is not a cosmetic default. It is the column
somebody reads to decide whether an estate is safe to point at, and the answer
would be manufactured by this side rather than reported by the station. So
there are two predicates and neither fires on silence, `ActionsReported` says
which silence it is, and the CLI prints four different sentences with no shared
default arm. It is the argument `Undelivered` already makes in the same file,
about not collapsing three cases into two, and it had to be made again from
scratch.

**The trusted set reached the same conclusion independently, hours apart.**
`Trust`, `TrustSerial` and `TrustMembers` landed in this struct from #114 with
"an empty value means *not published*, never *empty set*" written above them.
Two people writing two unrelated fields both arrived at "absent is a third
state, and the safe-looking default is a lie". That is worth saying out loud,
because the next field added here will face it too.

**Rewording an MCP tool description costs a human.** Adding the field to
`heliograph_status`'s description failed `TestGlamaSnapshotMatchesTheTools`:
Glama scores the tool definitions and publishes that score against a release
version, and there is no API to make a release. So the description was reverted
and the field explains itself in the returned text, which is where a model
reads it. Worth knowing before planning any change to a tool's wording.

**It found the progress defect that #116 then fixed.** The field was added to
`publish_progress` and could not be proved from a Linux round trip, because
that writer never fired: `ops-logs/"${STEP}"-*.txt` against a step sent by
path. Filed as heliograph-io/heliograph-cloud#88, fixed separately by `step_log`
so the fix could merge on its own, and the assertion here is a real round trip
again on the rebase rather than a source read.

**Where the guards are, because there are five writers and no single test
covers them all.** `station.sh`'s transition writer is round-tripped by
`TestARealStationPublishesItsActionMode`, its progress writer by
`tests/test-station-progress.sh`, and both `station.ps1` writers by
`tests/test-station-loop-ps1.sh` on Windows. `pigeonhole.sh` needs an Azure
account and nothing round-trips it.
`TestEveryStatusWriterInEveryStationPublishesTheActionMode` reads source to
cover that one and to catch a SIXTH writer added later that nobody thinks to
round-trip; it asserts the count, so a regex that stops matching fails loudly
rather than passing vacuously.

**`actions:` and `trust:` are orthogonal and a fleet view needs both columns.**
The trusted set says who may ask; the action mode says what the station will do
when asked. Gate 3 is untouched by trust at `station/bash/station.sh:887`, so a
request signed by a key in the set still gets no action out of a station
started without `--allow-actions`. Both are published in the same document and
`/station` says so, because a reader meeting both will otherwise assume one
implies the other.

### What login and push found

**The spool held one status document, and a run is keyed by the id inside one.**
`spoolStatus` wrote `<spool>/status` and overwrote it every drain. The archive
keys a run by the `id:` inside its own status document, and the sealed envelope
binds the estate, station, direction, kind and sequence - a run id is none of
them, so no other copy of that id exists on this side. Eleven collected logs and
one status meant ten runs this control node could name and not identify. The
case that broke it is two statuses in ONE drain: `lastStatus` is overwritten by
the next in the batch, and the station publishes on every transition, so
`running` and `idle` for one run routinely travel together and the first was
dropped before it reached disk. `keepStatus` files every one by its signed
sequence and never overwrites.

**The gap report was stating an inference as an observation, on every healthy
run.** The relay assigns a sequence to every message it carries - a status, a
progress snapshot and a finished log each take one - and the spool records a
sequence in a name only sometimes: a status always carries its own, a log
carries its own only when no status named it. So an ordinary run leaves status
1, log 2, status 3 and the names show 1 and 3. The first push printed *"sequence
2 was never collected by this control node"* about a log sitting in `ops-logs`.
`Spool.Gaps` now states a BOUND - holes, minus collected bodies whose sequence
the spool did not record, reported as "at least N" - because which ones they
were is not knowable from here. **The same arithmetic will bite the archive**,
whose gap detector sees only the sequences that arrive on `/ingest/status`:
raised on heliograph-io/heliograph-cloud#17 with the two sequence numbers one
ordinary run produced.

**A skipped snapshot still took a sequence number, and forgetting the second
half made the bound over-report.** Since #116 a progress snapshot lands under
the station's own name with a `.partial.txt` suffix rather than under a sequence
name. `Read` does not offer it as a body, correctly - a run in flight is a
snapshot rather than evidence - and the first version dropped it entirely, so an
ordinary run reported *"at least 1 message(s) between sequence 1 and 5 were
never collected"* about a file sitting in `ops-logs`. `Spool.Snapshots` keeps
them apart rather than throwing them away: never uploadable, always counted.
Found by the end-to-end test on the rebase onto #116, not by the unit tests.

**Comparing bytes could not tell a snapshot from the log it is a snapshot of.**
The first version of that assertion compared the archived body against each
`.partial.txt` on disk. A step that finishes inside one poll leaves a snapshot
BYTE-IDENTICAL to the finished log, so "the archive holds the snapshot" and "the
archive holds the log" are the same string, and the check fired on a correct
push. It asserts what the spool reader OFFERED instead, which is observable.

**A test double more permissive than the real thing is worse than none, again.**
The smoke stub checked the credential on provisioning and rotation and not on
ingest, so *"a refusal is read as a refusal"* passed against a stub that refused
nothing. Found by reading the output rather than by the test failing. The Go
e2e had the check throughout, which is the only reason the behaviour was
actually covered.### What the blocked port found

**A fixture can be hostile and still prove nothing.** The check that the host
match is exact rather than a substring used `gitlab.corp.example`, which no
`*gitlab.com` glob matches either - so the assertion passed with the bug in
place. The fixture has to be the string the loosened pattern gets WRONG, which
is `ourgitlab.com`, and there is one per pattern now: with only the GitLab
look-alike present, loosening the GitHub half failed nothing.

**And two mutation runs in parallel poisoned each other's backup.** Both
restored the same file from the same path, so one run's mutation was captured
as the other's "clean" copy and a `|permission denied` survived into the
working tree. Caught by reading the diff rather than by any test - every test
passed with it in. Mutation runs are serial from now on, and the harness
verifies the anchor changed before it believes a result.

### What the bundle found

**The log goes flat in the bundle directory, not under `ops-logs/`.** Every
other transport nests them; `Bundle.ListLogs` on the control side reads `*.txt`
in the bundle root. A station that had followed the house pattern would have
produced a medium that was carried back perfectly and showed no logs at all -
on the one transport where the cost of getting it wrong is another walk.

The conformance driver would not have caught it: it reads wherever the driver
is told to look, so both sides of a disagreement can be self-consistent.
`tests/test-bundle.sh` therefore drives the near side with the **real CLI** and
asserts that `heliograph logs` can read what the station wrote. Mutating the
transport to write under `ops-logs/` fails four assertions, three of them on
the control side.

`--check` is also asserted to leave the medium byte-for-byte as it found it. An
operator runs the preflight on a machine where they may not yet alter anything.

### What the service installer found

**A config file only the loop could read.** The reader lived in `station.ps1`,
and the task registers `start.ps1`, which preflights first and hands over only
if it passes. So a task installed with `TRANSPORT=share ALLOW_ROOT=1` in its
config file was refused twice over - for being an Administrator, and for
running the `git` transport - and never reached the loop that would have read
either. The install reported success.

The local test passed throughout, because it asserted that *the loop* reads the
file. Testing the half you wrote rather than the half the operator runs is what
let it ship; CI on a real Windows runner is what caught it. The reader now
lives in `lib/stationenv.psm1` and both entry points call it, the test compares
the preflight's verdict from the file against its verdict from the environment,
and removing the reader fails four assertions.

Two smaller things fell out of it. The preflight prints a **`config`** line
naming which variables came from the file, because "the task is misconfigured"
and "your shell is" are otherwise the same refusal. And the reader uses cmdlets
rather than `[System.Environment]`, because `start.ps1` loads it before it has
reported what the language mode is - a table whose job is to name Constrained
Language Mode plainly cannot throw while loading a config file first.

Also corrected: the preflight still warned that *"this payload ships no service
installer"*, printed by the very script the installer registers.
### What the object store found

**A wrong signature is a 403 that names nothing**, deliberately: saying which
part disagreed would be an oracle. So a wrong secret, a wrong region, a clock
fifteen minutes out and a malformed canonical request are one symptom. There is
no S3 account to round-trip against, so the signer is held to
`tests/fixtures/sigv4-vectors.json` - emitted by `internal/transport/sigv4.go`,
pinning the canonical request, its hash, the string to sign, all four derived
keys and the signature. A disagreement says which stage.

Three bash traps, each of which read as a signer fault and was not:

- **`$( )` strips the trailing newline.** The canonical form needs a BLANK LINE
  between the header block and the signed-header list, and the block's own
  trailing newline is eaten by the substitution that builds it. Every signature
  was wrong
- **A decoded path can contain a space.** `read -r a b` split the
  `path-needing-escapes` case in half and called the remainder a query string.
  That case exists *because* the path has a space in it
- **A body's trailing newline vanished the same way**, so the payload hash
  differed on the one vector with a body

The signer also had to grow `Content-Type`, because the Go client sends
`text/plain; charset=utf-8` on every write and it is a SIGNED header. Two
clients writing objects of different types into one bucket is a difference a
reader can see.

Verified by mutation: lowercasing a header name, dropping the path escaping,
corrupting any of the four key-derivation stages, and changing the credential
scope are each caught.

### What the relay found

**`NaCl.Core` cannot be used, and neither can BouncyCastle.** The merged design
recommended the first; it is `Span<T>`, `stackalloc` and `System.Buffers` in
every file, and `Span<T>` does not exist on .NET Framework - which is what
Windows PowerShell 5.1's `Add-Type` compiles against, at C# 5, through the
CodeDOM compiler. BouncyCastle was measured too and is worse for the same
reason it was rejected before: its `ChaCha20Poly1305` closure reaches ~6,000
lines and pulls in `BigInteger` through `Arrays.cs`, for an AEAD. So ChaCha20
and the framing are ours, over the vendored poly1305-donna - the 130-bit
arithmetic, which is the part with a subtle failure mode, is not.

**`Ed25519.KeyExchange` is deleted from the vendored source** rather than left
unused. It returns `crypto_box_beforenm`, not the raw RFC 7748 secret. An
unused wrong function is one autocomplete away from being the used one, and no
test catches a call nobody has written yet - so a test asserts the method is
absent, and `MontgomeryCurve25519` is not vendored at all.

**Nothing rests on a round trip.** `internal/seal` emits golden vectors from
fixed keys - six cases and six refusals, every stage pinned - and the
PowerShell side reproduces them byte for byte and opens Go's own bytes. Each
primitive is separately checked against RFC 7748 §6.1, RFC 8032 §7.1, RFC 8439
§2.3.2/2.4.2/2.5.2/2.8.2 and RFC 5869 TC1. One field-order swap in
`Meta.canonical` fails 30 assertions on the PowerShell side and 4 on the Go
side.

**`tests/test-seal-ps1.sh` builds the tree as net48 with LangVersion 5.** That
is the one thing a Linux runner cannot otherwise infer: pwsh 7 compiles this
with Roslyn against .NET 10 and would accept a construct that 5.1 refuses at
`Add-Type`, on the exact estate the payload exists for.

Three things fell out that had nothing to do with the relay:

- **The conformance suite's p8 wait has never run.** `grep -c ' | ' f || echo 0`
  prints `0` AND exits 1 on a file with no matches, so the value was the two
  lines `"0\n0"`, `[` refused it, and a non-zero condition ends a `while`. The
  loop exited on its first turn, every time, on every transport and both
  drivers. The property still passed because the `sleep 1` after it is usually
  enough - which is what made it invisible, and it is the same shape as the
  race the wait was written to fix
- **CI has never parse-checked a `.psm1`.** The job globs `*.ps1`, which does
  not match them: 14 files checked, 8 skipped, and the eight are `caplib.psm1`,
  every transport, the cancel and now the seal - where nearly all the logic
  lives. They all parse today, which is the only reason widening it was one line
- **The service installer's CI wait had p8's shape too**, and is fixed in #96:
  it waited for the status file to EXIST, and the loop publishes `running`
  before it starts the step

## Landed 2026-09-13

| PR | |
|---|---|
| #109 | **the bash station has published no progress snapshot since steps were sent by path** (heliograph-io/heliograph-cloud#88) - `station.sh` globbed `ops-logs/"${STEP}"-*.txt`, so a step sent as `./steps/probe.sh` looked for `ops-logs/./steps/probe.sh-*.txt`, matched nothing, and `publish_progress` returned on its first line. No error, no log line, nothing published. The 60-second partial-log push is the only live signal a long step has, and it was off for every step sent by path, on every transport. The same bug had already been found and fixed at the delivery call site twenty lines below, where it had a visible symptom (`log: <none>`); this one had none, which is why it survived. The derivation is now a `step_log` helper called by both sites, matching `station.ps1`'s `Find-StepLog` |

### What the progress snapshot found

**An absence is not a symptom, and a count is the only assertion that catches
one.** `tests/test-station-progress.sh` runs a twelve-second step at
`PROGRESS_EVERY=1` and asserts the NUMBER of snapshots on the far side: 11
against the fix, **0** against the unfixed glob. Every weaker shape passes while
broken - the status document still says `running` and then `idle`, and a
finished log still arrives - because the loop publishes both of those through a
different path. Only the count distinguishes them.

**The fix made a latent control-side defect fire on every relay run.**
`internal/transport/relay.go` let the status name a collected log only when the
drain held exactly one log body, and a progress snapshot is a log body. So the
first station to publish one cost its own finished log its name: `heliograph
logs` answered `relay-000002.txt` and `relay-000004.txt`, one of them a
truncated file. Counted over FINISHED bodies now, and a snapshot is spooled as
`<name>.partial.txt` and hidden from `ListLogs` - the object store's convention,
copied rather than reinvented, because two implementations of one pattern is
what caused this whole entry.

**It was already live on the PowerShell relay station**, which publishes
progress the same way (`station/powershell/transports/relay.psm1:502`) and fires
its first snapshot on the first in-run poll whatever `PROGRESS_EVERY` says
(`station.ps1:1082`). Recorded as heliograph-io/heliograph-cloud#134 even though
this PR fixes it: a finding is published once its fix has shipped, and an
unrecorded defect cannot be published.

**And the first version of two new assertions failed against correct code**, in
both directions. One read `git log` in git's own order and reported that a
running step's line count FELL. The other read the LAST progress snapshot, which
is published after delivery has already committed the log, and called a status
document arriving alone "the partial log did not travel". Both were fixed by
changing the assertion, not the behaviour.

## Landed 2026-09-25

Fixes for the issues filed from the 24 Sep review of the skill, #147 to #160.
One issue, one PR.

| PR | |
|---|---|
| #161 | **`watch` reported the previous run straight after a send** (#147) - it stopped on the first finished state and never compared ids, and for a poll interval after a send the status still describes the last request the station read. After an earlier refusal it told the reader to restart the station with `--allow-actions`. `send` now records the id per estate, `watch [id]` waits for it and says `not picked up yet` until the status names it, and stops when the station has moved past it. `status` and `heliograph_status` (new optional `id`) say the same. The Glama listing is still behind, now by one more schema change |
| #162 | **`heliograph_send` requests never expired and named no station** (#149) - the MCP tool built its own request and left out the target, the 24-hour expiry and the mode, and skipped `Validate`. So an agent's request was valid for ever and bound to no station: the replay the CLI's defaults exist to prevent. One builder, `newRequest`, now serves both; the tool gains `mode` and `expires`, and refuses a numeric `expires` because `0` would have silently meant a day. Its first CI run failed after every assertion had passed, in #161's test: `TempDir RemoveAll cleanup: unlinkat .../origin.git/objects: directory not empty`. The env-level `gc.auto=0` never reaches the bare origin, because git strips `GIT_CONFIG_COUNT` from a local receive-pack (checked with a hook), so the origin ran its own maintenance after the push. Every bare origin in `cmd/heliograph` now turns it off in its own config |

## The signalling toolkit (in design)

A program that adds the third shape - the **beam**, a held-open live channel -
renames the shapes onto one medium (**beacon** / **flare** / **beam**, from
pigeonhole / intercom / the new open line), and drops the compliance-label
framing throughout. Six designs, each its own spec and PR, tracked by the
umbrella issue #85 and coordinated by
[`docs/plans/2026-09-11-signalling-toolkit-roadmap.md`](docs/plans/2026-09-11-signalling-toolkit-roadmap.md).

| id | issue | spec | state |
|---|---|---|---|
| S1a | #86 | [three shapes and the signalling names](docs/specs/2026-09-11-three-shapes-and-signalling-names-design.md) - the docs half | **done in PR #94** |
| S1b | #102 | the script and env-var rename (`pigeonhole.sh`/`intercom.sh`/`intercom.py` and `PIGEONHOLE_*`/`INTERCOM_*`), with aliases | to build |
| S2 | #87 | [discrete transports completed](docs/specs/2026-09-11-discrete-transports-completed-design.md) (relay CLI selection, flare transport) | spec ready |
| S3 | #89 | [`heliograph shell`](docs/specs/2026-09-11-heliograph-shell-design.md) (REPL over flare, SSH front door) | spec ready |
| S4 | #90 | [the beam: the live `Channel` and the relayed beam](docs/specs/2026-09-11-beam-live-channel-design.md) | drafted, open questions |
| S5 | #91 | [SSH and interactive over the beam](docs/specs/2026-09-11-ssh-and-interactive-over-the-beam-design.md) (PTY, `ssh` passthrough, gated TCP forward) | drafted, open questions |
| S6 | #92 | [the direct beam](docs/specs/2026-09-11-direct-beam-p2p-design.md) (P2P: ICE, STUN, WebRTC data channel; relayed-beam fallback, no TURN) | drafted, open questions |
| - | #103 | guard the claim, not just the word - a test needle for "does not tunnel" with an allowlist of pages that qualify it | follow-up |
| - | #93 | reproducible builds for the beam binary, and seams a cloud layer can extend | decided; folded into S4 and S5 |

**This reverses a stated anti-goal**: the beam is the reverse connection the
raw-TCP transport was dropped for being. S1 rewrites the "what it will not do"
prose into an honest characterisation rather than pretending the line did not
move. Decided by the owner with the C2 trade-off on the table.

### What the twin comparison found

**Windows environment variable names are case-insensitive, and the guard was
not.** The child environment is a `StringDictionary` on .NET Framework, so
`transport=relay` and `TRANSPORT=relay` are the SAME entry and the second
overwrites the first. A case-sensitive guard refuses the uppercase spelling,
allows the lowercase one, and Windows honours it - the whole defect, spelled in
lowercase, on the only platform that payload targets.

Measured rather than assumed: the same dictionary on .NET on Linux keeps two
distinct keys, so the hole is Windows-only and a Linux runner would never see
it. That check is now the ONE case-insensitive comparison in the PowerShell
station, and it says why at the point it is made. The bash twin needs no
equivalent - there `transport=relay` sets a genuinely different variable that
nothing reads.

## Next, in order

Every item is an issue, so a priority can be linked to rather than remembered.
The ranking rule this repository keeps proving: **a claim that is not true
outranks a capability that does not exist.**

| | | |
|---|---|---|
| 1 | **The blocked-port diagnosis** (#66) | A defect rather than a feature, and hours rather than days. A station behind a firewall that drops 22 is told to check its URL and its credential, which are both fine - the same class of red herring already fixed once on the write check, in the one message an operator who cannot debug will read |
| 2 | **The near side without the CLI** (#62) | Near-free: it documents something that already works, and by this repository's own experience writing a component's page is how its defects get found |
| 3 | **Prove GCS through the object store** (#57) | One CI job. Either a supported store gets documented or a reason gets recorded, and both beat the current silence |
| 4 | **The artifact repository transport** (#56) | **The most valuable item on the list** and the only one measured in days, which is the sole reason it sits below three cheaper things. Largest population of any candidate, `blob.sh` is the template, and it unblocks #61 |
| 5 | **GitLab CI** (#58) and **the Kubernetes CronJob** (#59) | One file each, against patterns that already exist |
| 6 | **Claude Code on the web** (#64), then **Termux and Crostini** (#63) | Proving runs. #64 answers a question that will be asked more often |
| 7 | **Arista EOS and the network devices** (#61) | Blocked twice: needs #56 to land, because git is absent on a switch, and needs a device to prove it on |
| 8 | **The AWS host family** (#60) | Blocked on an AWS account. Until there is one, #5's decision stands and Fargate stays a recipe. Do not merge a template that has never started a station |
| - | **Review and merge the trusted set** (`heliograph-cloud#29`, `#28`) | Out of the numbered ranking because it is not a capability to schedule: it is a claim that is currently overstated, and the branch that makes it true is written and held at the PR. Reviewing it outranks everything above |

Items 1 to 8 come from a survey of every transport, host and control node
anyone has proposed, with the ones ruled out and why:
[`docs/specs/2026-09-10-new-transports-and-stations-design.md`](docs/specs/2026-09-10-new-transports-and-stations-design.md)
holds the verdicts and
[`docs/research/2026-09-10-transports-hosts-and-control-nodes.md`](docs/research/2026-09-10-transports-hosts-and-control-nodes.md)
holds the evidence, measurements and sources. Both are published as
[`/roadmap`](site/content/roadmap.md).

## Known defects, recorded rather than fixed

- **The Windows credential-injection assertion has failed once, unexplained.**
  `tests/test-transports-ps1.sh:273` runs `Invoke-CapGit config --get
  http.extraHeader` with `GIT_TOKEN` set and asserts git received an
  `Authorization` header. On 2026-09-12 it failed on 45517b3 (#84) with "git
  received no Authorization header at all" and passed on the two runs since,
  285ca02 and 9860c22, same job and same runner image. One failure in three is
  not a flake anybody has characterised: the assertion is deliberately written
  to ask git what it received rather than to grep the source, so a red here
  means the injection genuinely did not happen that time. Worth catching the
  next occurrence with the resolved `GIT_CONFIG_*` environment dumped on
  failure, rather than guessing at a race now
- **And a SECOND assertion in that same file now fails intermittently on
  Windows**, which makes one shared cause likelier than two coincidences.
  `tests/test-transports-ps1.sh:256` asserts `Get-TpDescribe` masks a
  credential in a remote URL **and still names the host**. The masking half
  passes; the host half failed on `main` twice on 2026-09-13 - on 4e1f2a7
  (#113) and on 1f730c6 (#115) - reporting `58 passed, 1 failed` both times,
  and passed on the five commits between and either side. Neither commit
  touches a file under `station/` or `tests/`, and #115's own PR run of the
  same job was green on identical tree content.
  Both assertions sit inside a `for` over two remote URLs with a
  `git remote remove` and `git remote add` between iterations, and both read
  `$TP_OUT` captured from a PowerShell invocation - so a stale `TP_OUT` or a
  `git remote add` that had not taken effect would fail the assertion that
  depends on WHICH url is current and pass the one that only looks for the
  absence of a secret. That is a hypothesis and nobody has the evidence.
  Filed as `heliograph-io/heliograph-cloud#150` with the run ids, and
  deliberately NOT re-run: a re-run that goes green is a diagnosis nobody made,
  and the evidence that would settle it is the kind the next run destroys
- **Delivery pushes to the configured upstream, not to `origin` explicitly.**
  `cap_push` (bash) and `Send-TpLog` (PowerShell) both use a bare `git push`, so
  a branch tracking another remote takes every log somewhere the control side
  never reads and reports success. The status path on both sides names `origin`
  and the branch explicitly and is not affected. **Both implementations share
  this**, so it must be fixed on both together with a test that watches the
  remote rather than the exit code - fixing one side would make the twins
  disagree about where a log goes, which is the one thing they may not do
- **A push the server completed can be reported as failed** if the
  acknowledgement is lost. Shared by both implementations, same argument
- **Progress publishes on the FIRST in-run poll**, not after `PROGRESS_EVERY`
  seconds: `LAST_PROGRESS=0` in bash and `DateTime.MinValue` in PowerShell both
  compare as "long overdue". Every run lasting more than one `INTERVAL` gets an
  extra status and partial-log publication that the documentation does not
  promise. Harmless, arguably useful, and worth knowing before reading a git
  history and wondering where the extra commit came from
- **A PowerShell station killed with SIGTERM leaves `.station.lock`.** Windows
  PowerShell 5.1 cannot catch the signal, so the `finally` never runs. The next
  station reads the pid, finds it dead, and clears it - which is the designed
  recovery and is tested. `station.sh` traps the signal and does remove it

## Operational notes

- **HTTPS is enforced on the Pages site** as of 2026-09-11. Plain HTTP served
  the whole site with no redirect until then, which for a `curl | chmod`
  install page is worse than untidy. The setting is
  `gh api -X PUT repos/heliograph-io/heliograph/pages -F https_enforced=true`, and
  it survives a deploy. GitHub adds HSTS with it

- **A relay station in a container was driven against the deployed relay on
  2026-09-09.** The image carries `heliograph-seal` built from the same commit,
  and the log came back with a non-zero exit reported honestly. The station name
  used was `in-a-container`
- **The site reports into the dbhq.uk GA4 property** (`544327698`, stream
  `G-3H3NFGSX85`), not a property of its own. One web stream per site
  including subdomains is Google's guidance; separate the docs in reports by
  the **Hostname** dimension. The tag loads only after consent and only on
  `heliograph.dbhq.uk`. Nothing was created in the GA4 account
- **Search Console is the `sc-domain:dbhq.uk` Domain property**, which covers
  every subdomain. `https://heliograph.dbhq.uk/sitemap.xml` was submitted
  through the API on 2026-09-09 using the service account in
  `~/.dbhq-seo/env.sh`. At that moment the home page was "unknown to Google"
  and `/install` was "discovered, not indexed": the site had never been
  crawled. Check again in a week with the URL Inspection API before
  concluding anything from GA
- **The site build refuses a shallow clone.** `lastmod` comes from git, and a
  depth-1 checkout dates every page today. Every job that builds the site OR
  runs `go test ./...` needs `fetch-depth: 0`: the Pages deploy, the site job,
  and the Go job. The Go job was missed first time and failed on PR #43
- **The relay estate is `heliograph`**, on `heliograph-relay.dbhq.uk`. Its
  control and station tokens are in 1Password, DBHQ vault, *heliograph relay -
  estate tokens*. **That is the only copy**: Cloudflare secrets are write-only,
  so `wrangler secret put HELIOGRAPH_RELAY_ESTATES` replaces a value nobody can
  read back. The previous value was unrecoverable and was replaced on
  2026-09-09; record any future one before setting it
- The same control token is a repository secret, so CI checks on every push to
  `main` that the deployed relay still answers it. Pull requests skip that step:
  a fork gets no secrets, and a false negative for a contributor is worse than
  the check

## Known defects, recorded and NOT fixed

Stated on the site rather than hidden, so nobody plans around a promise.

- **A cancelled run's partial log does not ship on blob or relay.** The station
  passes it as `tp_put_status`'s third argument, which only git and the share
  honour
- **Delivery pushes to the branch's configured upstream, not to `origin`.**
  Both implementations do this - `cap_push` and `Send-TpLog` alike. If a branch
  tracks the same-named branch on a DIFFERENT remote, a bare `git push`
  succeeds, delivery is reported as done, and `origin` - the remote the
  preflight named as the far side - receives nothing. The fix is to push
  `HEAD:refs/heads/<branch>` to `origin` explicitly and to rebase from
  `origin/<branch>`, in BOTH implementations together: fixing one would make
  the twins disagree, which is the one thing they may not do. Found by an
  adversarial read on 2026-09-10
- **A push that the server completed can be reported as a failure.** If the
  connection drops after the ref is updated but before the acknowledgement
  reaches git, both push attempts return non-zero while the far side has the
  commit. The station then says DELIVERY FAILED about a log that arrived. This
  errs in the safe direction - it never claims a success it did not have - and
  the fix is to query the remote ref after a failed push and compare. Both
  implementations
- **The two captures disagree about a bare carriage return.** A progress bar
  writing `step 1\rstep 2\rstep 3\n` is ONE line with embedded `^M` to the
  bash capture, because `read` splits on LF alone, and THREE lines to
  caplib.psm1, because .NET's `ReadLine` treats a lone CR as a terminator.
  .NET's is the better answer - an embedded `^M` in a committed log is the same
  defect the trailing-CR strip exists to remove - so the fix belongs on the bash
  side and changes `cap_run`'s read loop. Found on 2026-09-09 by writing
  property 10, which is also what found that bash was DROPPING the final line
  when it had no newline after it. That one is fixed
- **The ACI templates are not twins.** `aci/main.tf` declares an `ip_address`
  block with TCP 65000 and `aci/main.bicep` omits `ipAddress` entirely, so the
  two produce different resources from the same inputs - network policy and
  audit tooling see an exposed private port only under Terraform. Pre-existing,
  found by an adversarial read on 2026-09-09, and NOT fixed here because which
  of the two is right is a deployment question: the Terraform provider refuses a
  VNet-injected group with no ports (that refusal is documented in azure.md),
  and bicep does not. Deciding needs a deployment, not a diff
- **A value an operator types reaches the VM's cloud-init unescaped.**
  `repoUrl`, `gitToken` and `gitTokenUser` are substituted straight into
  double-quoted shell assignments in a script that runs as root at first boot,
  so a quote or a `$` in one is code rather than data. Pre-existing, and the
  same person chose the value and owns the VM, so it is a robustness problem
  rather than an escalation. The transport's environment block was added
  base64-encoded specifically so as not to widen it
**Fixed on 2026-09-09, and recorded because it was on this list: no station has
ever run under launchd.** `test-launchd.sh` had failed four times on *"launchd
restarted the loop as pid N after a clean exit"*, and every occurrence was
re-run clean by somebody, so nobody read it. On the fourth the test captured
`launchctl print` itself, and the answer was one line: `last exit code = 1`,
with `PATH => /usr/bin:/bin:/usr/sbin:/sbin` above it and *"FAIL bash need 4 or
newer, found 3.2.57"* in the station's log.

macOS ships bash 3.2 at `/bin/bash`. A Mac that runs stations has a newer one
from Homebrew and the operator's PATH finds it, so `service.sh install` passes
every check it makes. A LaunchAgent does not inherit that PATH, so it found 3.2,
the preflight refused it, the station exited 1, and `KeepAlive
{ SuccessfulExit: false }` restarted it - correctly. The plist was blameless and
the assertion was right. The station simply never started, and a poll for *"is a
loop running"* kept finding one because a crash loop always has a pid.

`service.sh` now resolves an absolute bash 4-or-newer at install time,
`pick_bash`, writes it into `ProgramArguments`, and prepends its directory to
the agent's PATH; with none on the machine it refuses to install rather than
leaving a crash loop behind. `test-service.sh` asserts all of that on Linux, and
`test-launchd.sh` now checks the plist's bash and the log for *"Not starting the
station"* before believing a pid.

**Fixed on 2026-09-08, and recorded because they were on this list:** the relay
sequence collision between the loop and the runner is closed by a `mkdir` lock
and a max-taking state write. It was reproducible the moment a round trip
existed to run.

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

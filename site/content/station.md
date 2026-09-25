# The station

The far side. A directory of plain text, planted into a private transport repo,
that watches for a request, runs one step, and sends the log back.

It is the half of heliograph you cannot reach, so it is the half most worth
reading before you run it. Everything here is text you can open in an editor on
the machine it will run on.

```diagram loop
The operator starts it once. Everything after that is the transport.
```

## Two stations, and a launcher

| | what it is |
|---|---|
| **`station/bash/`** | the station. Bash 4+, and what almost every host runs |
| **`station/powershell/`** | the twin, for a Windows estate with **no bash and no permission to install any**. Plant it with `--flavour powershell` |
| **`station/bash/station.ps1`** | a **launcher**, not a station. It finds the bash that Git for Windows installed and hands over to `start.sh`. Do not confuse it with `station/powershell/station.ps1`, which is the loop itself |

**Prefer the bash station wherever it will run.** One implementation of the
capture is better than two, and a Windows box with Git for Windows should use
the launcher rather than the twin.

### A second implementation is permitted only while it passes the contract

That is the rule, and it replaced a blanket prohibition. The argument against a
port was never about PowerShell - it was about **untested drift**, and a
buffered port is the worst kind: it gives every line the same timestamp, which
reads like a working log while destroying the only property the log is for.

So the rule is now a gate rather than a ban. `station/powershell/` passes all
ten properties of [the capture contract](/conformance), over both transports it
ships, on Windows PowerShell 5.1 and on 7, in CI, on every change. If it ever
stops passing, it stops shipping.

The twin carries the same request document, the same published status, the same
four gates and the same exit codes. A control side reads one document and
cannot tell which of them wrote it, and a test asserts exactly that.

What it does **not** have is recorded on [Windows](/windows): a self-update that
needs a restart, and Constrained Language Mode stops it entirely.

## What it depends on

The bash station needs bash 4+ and GNU coreutils. The PowerShell station needs
Windows PowerShell 5.1, which is in-box on Server 2016 and later. Then whatever
the transport needs: `git` for the git transport, `curl` for blob and relay,
nothing at all for a file share.

That is the whole list, and it is close to the entire proposition - on a
locked-down box, installing anything is its own change request.

**Which compiled things a station may need is a written policy, not a habit.**
[`station/FAR-SIDE-BINARIES`](https://github.com/heliograph-io/heliograph/blob/main/station/FAR-SIDE-BINARIES)
is the list, CI reads that file, and a program under `cmd/` referenced anywhere
under `station/` and absent from the list fails the build. No Go source may
appear under `station/` either; the only Go permitted there is
`station/embed.go`, which lets the CLI carry the payload, and its test -
neither ships anywhere.

The list has one entry and is meant to stay that way. The **bash** relay
transport needs `heliograph-seal`, because its construction is X25519,
HKDF-SHA256, ChaCha20-Poly1305 and Ed25519, and hand-assembling those in shell
across openssl versions is where crypto bugs live and where they are silent.
The trusted set needed Ed25519 verification on the far side too and reused the
same binary rather than adding a second, which is the rule the list states:
what matters to an estate is how many binaries it has to accept, not how many
features wanted one.

**Nothing else is compiled.** Git, a file share, a bundle and an object store
need no binary anywhere on the far side, on either station. An estate that
forbids compiled code entirely loses the relay on a bash station, and the beam
when it lands - two shapes, not the tool.

Listing a binary costs something and the list says so: "read it before you run
it" stops working, and is replaced by "verify the binary matches the source you
read". That is only true because `packaging/reproduce.sh` builds it, the
checksum is published, and the station refuses a seal whose hash does not
match.

**The PowerShell relay needs no binary at all**, and that is the better answer
rather than a lucky one. An estate that will not let you install a native
binary is precisely the estate this payload exists for, so the seal ships as
**managed C# source** under `lib/seal/` and is compiled by `Add-Type` at
startup: X25519, Ed25519 and Poly1305 from a vendored Chaos.NaCl - djb's ref10,
MIT - with ChaCha20, the RFC 8439 framing and HKDF written beside them. Still
plain text an operator can read before running it, which is the property the
list exists to protect.

`Add-Type` needs FullLanguage, so Constrained Language Mode rules the relay
out. That costs nothing extra: CLM already stops the whole station, because the
capture is mostly .NET calls, and `start.ps1` checks for it before anything
else.

## The files

| | bash | PowerShell |
|---|---|---|
| the preflight, and the one command the operator types | `start.sh` | `start.ps1` |
| the loop: poll, decide, dispatch, publish | `station.sh` | `station.ps1` |
| the step runner. Owns the log, the timestamps and the delivery | `run.sh` | `run.ps1` |
| the capture itself | `caplib.sh` | `caplib.psm1` |
| one file per channel | `transports/git.sh`, `share.sh`, `bundle.sh`, `blob.sh`, `relay.sh` | `transports/git.psm1`, `share.psm1` |
| one file per question, and a template to start from | `steps/` | `steps/` |
| helpers a step can use | `lib/` | `lib/` |
| where captured logs land | `ops-logs/` | `ops-logs/` |
| what to run, and what happened | `station/request`, `station/status` | the same |

Both payloads carry a `service.ps1` for Windows, and they are different files:
the bash one registers the launcher, the PowerShell one registers `start.ps1`
and carries the transport's variables into a restricted file, because a
scheduled task inherits none of them. The bash payload also has `caprun.sh` -
the same capture around an arbitrary command - and `secret.sh`; the PowerShell
payload has neither yet.

Details of each: [the runner](/runner), [writing a step](/steps),
[Windows](/windows).

## The loop, precisely

1. Poll the transport for a request. Default every 5 seconds
2. **The trigger is the `id`, never a new commit.** Documentation and step edits
   land constantly; if any change fired a run, the station would fire on all of
   them. A run is always something somebody asked for on purpose
3. Ask `run.sh --mode` what the step declares itself to be, and apply the gates
4. Publish `running`, then dispatch the step in its own process group
5. Keep polling while it works, so a `cancel` is heard and an hour-long step
   does not make the station deaf for an hour
6. Push a partial log every `PROGRESS_EVERY` seconds, so a long run can be
   watched rather than waited out
7. Deliver the finished log, then publish `idle` - or `undelivered`, if the log
   was captured and the transport would not take it

## The states it publishes

| state | |
|---|---|
| `starting` | the loop is up and its credential works. Nothing asked yet |
| `running` | a step is in flight |
| `idle` | the run finished **and the log was delivered**. Only a confirmed delivery earns it |
| `undelivered` | the run finished and the log did not arrive - refused by the transport, skipped, or the runner never reached delivery. The reason is published with it |
| `refused` | a gate said no, and says which one |
| `cancelled` | signalled mid-run. The partial log is kept |
| `stopped` | the loop ended, by `stop: yes` or by Ctrl-C |

Every status also carries `host:` and `payload:`. The payload is a digest of
`station.sh`, `run.sh` and `caplib.sh` - what a step's behaviour actually rests
on. `HEAD` cannot answer "which payload is running", because every status
commit and every log advances it, so two stations on identical payloads report
different revisions within a minute. Branches carry independent copies and
self-update pulls only its own, so drift between stations is real, and worth
seeing rather than discovering when a step behaves differently on one machine.

The steps themselves are deliberately **not** in the digest: they are supposed
to differ per branch, and including them would make it change for the ordinary
reason and stop meaning anything.

`undelivered` matters more than it looks. Without it, "the log exists and
cannot be shipped" and "the step is still running" are the same silence from
your side, and only one of them is worth waiting on.

Every status also carries `branch:`, the branch the station runs on, and that is
the one status a git station publishes as soon as it starts, before anybody asks
it anything - but only when the status it finds names a different branch. A
branch cut from another carries that branch's status, and the control side
refuses to send to a branch whose status names a different one, because by that
status no station reads it. A status that already names this branch is this
station's last run, and a restart leaves it alone.

## The action mode it publishes

Every status also carries `actions:`, which is `allowed` or `refused`. It is
not about the run. It says what this station will permit for the whole life of
the process, and it is settled by `--allow-actions` at startup:

| | |
|---|---|
| `actions: allowed` | started with `--allow-actions`. A step declaring `action` runs, still needing `CONFIRM=yes` on the request |
| `actions: refused` | the default. A step declaring `action` is refused, and the refusal names the flag |

It is published because the alternative is to infer it, and inference is wrong
in both directions. A station restarted without the flag still has action logs
sitting in the transport repo, and a station started with the flag may never
have been asked for one. Anything showing a column of stations - `heliograph
status`, a fleet view, a dashboard of your own - reads this field and never
guesses from history.

**A station that publishes no `actions:` line is not read-only.** It is a
station planted before the field existed, and there is no way to ask it from
your side. `heliograph status` says `not reported` for that case, which is a
third answer and not a polite way of saying refused. Treating silence as
read-only would tell somebody an estate is safe on the strength of a station
that never said so.

`actions:` and `trust:` answer different questions and neither substitutes for
the other. The trusted set says **who may ask**; the action mode says **what
this station will do when asked**. They do not interact: a request signed by a
key in the trusted set still gets no action out of a station started without
`--allow-actions`, and the refusal is published exactly as it would be for an
unsigned one. A station can be wide open to actions and verify every signature,
or trust nobody and still be started with the flag, so a fleet view needs both
columns.

## Two properties everything else rests on

**Every captured line carries a UTC timestamp**, applied by a pure-bash read
loop reading straight from the command, *before* any other stage. That ordering
is load-bearing. It used to be applied last, which made the property depend on
`sed -u`; a sed without it gave every line in a block the same time while the
log still read perfectly. After the fact, in an untimed log, a hang and slow
progress are indistinguishable.

**A failed run still ships, and a failed delivery never loses the log.** The
log is delivered whether the step passed or failed, and the real exit code
survives the pipeline via `PIPESTATUS`. Each round trip through an operator is
expensive; none may be wasted by tooling that only reports success.

Both are asserted by [the conformance suite](/conformance), which is the
executable form of the contract rather than a description of it.

## Stopping, cancelling, and surviving a logout

`stop: yes` in the request ends the loop from your side, which matters because
nobody is sitting at that terminal. `cancel: yes` kills the step running right
now; `cancel: <id>` kills it only if that id is the one running, so a stale
cancel cannot reap a later run. The partial log is always kept **on the
station**, and on the git transport it is delivered with the cancellation; on
blob and relay it currently is not, and stays local.

`station.sh` deliberately does **not** trap `HUP`. Its cleanup signals the
running step's process group, so trapping `HUP` would kill an in-flight step
every time a connection dropped. To survive a logout properly, see
[running it as a service](/service).

## Getting one onto the far side

[Planting a station](/bootstrap). The operator's whole job is: clone the repo,
run `./start.sh`, walk away.

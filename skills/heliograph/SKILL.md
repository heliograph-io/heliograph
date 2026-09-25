---
name: heliograph
description: Debug and change a machine you cannot log into, through an operator who cannot debug it, by driving the heliograph CLI - git as the transport in both directions. Plants the station, configures the estate, publishes steps, and reads the pushed logs. Trigger on phrases like "heliograph", "I can't get on that box", "no access to that environment", "the only person who can reach it is X", "air-gapped", "can you give me something to run", "they keep pasting output at me", "run it on the control node", "capture the log and push it back". Not for machines you can SSH into yourself.
---

# heliograph

Someone can reach the machine. You cannot, and you are the one who knows what
to ask it. heliograph runs that gap as a loop instead of a relay: a transport
carries the step out and the log back, and the operator types one command that
never changes.

```
you        heliograph send <step> ────────────────────▶ transport
station    picks it up within seconds, runs ./run.sh
           pushes station/status, then the log ───────▶ transport
you        heliograph watch / logs --last --gaps ◀─────
```

Every captured line carries a UTC timestamp, ANSI is stripped, obvious secrets
are masked, and the log comes back **whether the run passed or failed**.

## When this applies

- The machine is in an environment you have no interactive access to.
- The only person who can reach it has other work to do and should not be your terminal.
- Several rounds of "run this and paste the output" have already gone badly.
- The repo that has to *change* is also on the far side (see
  [references/remote-repo.md](references/remote-repo.md)).

If you can SSH in yourself, do that instead and do not use this skill.

## This skill drives the CLI

Everything below goes through the `heliograph` binary. It is a single static
Go binary, it holds the gates in one place, and `heliograph bootstrap` plants
the exact station payload the binary was built with. Check for it first:

```bash
command -v heliograph >/dev/null || echo "MISSING"
```

**If it is missing, install it and do not improvise around it:**

```bash
curl -sSL https://github.com/heliograph-io/heliograph/releases/latest/download/heliograph-linux-amd64 \
  -o /usr/local/bin/heliograph && chmod +x /usr/local/bin/heliograph
# or: go install github.com/heliograph-io/heliograph/cmd/heliograph@latest
```

If you cannot install it (no network, no permission), stop and say so. The
no-CLI fallback is a procedure for a person, not for you: clone
[heliograph-io/heliograph](https://github.com/heliograph-io/heliograph) and run
`station/bootstrap.sh` by hand - the station is plain text and stands on its
own, and `--flavour powershell` plants the twin for a box with no bash. Do not reimplement `send`, `watch` or the gates by editing files: one
driver is the point.

The far side needs bash 4+, git and GNU coreutils, nothing else, and that
constraint is the whole proposition. Nothing you do on the control side ever
adds a requirement over there.

## 1. Set up

```bash
heliograph bootstrap ~/transport/payments     # plant the station payload
cd ~/transport/payments && git init && git add -A && git commit -m 'heliograph: transport repo'
# add a PRIVATE remote, push, then:
heliograph init payments --dir ~/transport/payments
heliograph doctor                             # will this work from here
heliograph plant                              # the message to send the operator
```

**The transport repo must be private, and must be its own repo.** Captured
logs are committed to it, so everything the operator's commands print lands in
that history permanently. Never bootstrap into a repo that holds anything
else, and never into a public one. Re-running `bootstrap` over an existing
transport repo is safe: it installs what is missing and leaves what is there
alone.

`plant` prints the operator's whole job: clone, `./start.sh`, walk away. It
carries no credential, deliberately. If the loop is to run unattended, decide
the credential now - a forwarded ssh agent key dies with the session; an
unattended loop needs a key on disk, a deploy key, or a token in
`~/.git-token`. See [references/transport.md](references/transport.md).

Git is the default. A mounted file share, a signed bundle for a true air gap,
an S3-compatible object store and the relay are all available at `init`, and
the loop is identical whichever you pick. Which flags each needs is on the
site, next to the binary that implements them:
<https://heliograph.dbhq.uk/transports>.

## 2. Baseline before theorising

```bash
heliograph send env
heliograph watch
```

`env` answers what that box actually is: OS, tools, sudo, proxy, DNS, cloud
auth, and which commit is checked out. It is the right first step of any
investigation, whatever it turns out to be about. A prior finding is a
hypothesis to re-test, never a premise to build on.

## 3. Start a task

Steps live in the transport repo, one file per question:

1. `git checkout -b task/<slug>` in the transport repo
2. Fill in `TASK.md`: the question, what is known, what would settle it. It is
   what stops the steps becoming a fishing trip
3. `cp steps/_template.sh steps/<name>.sh`, write the probes
4. Register it in the `case` table in `run.sh` **and** the step-list comment
   above it, so `--list` stays honest
5. `git add` and `git commit`. No manual push needed: `heliograph send`
   rebases onto the remote and pushes `HEAD`, so your commits and the request
   travel together

**`main` is the template; `task/<slug>` is one investigation.** Task branches
are not merged back. Only genuinely generic tooling returns to `main` via a
normal PR, stripped of anything task-specific.

Writing the step itself: [references/steps.md](references/steps.md). Read it
before the first one. Every rule in it cost a round trip.

## 4. Drive it

```bash
heliograph send net-probe HOSTS="sql01 sql02"   # publish a request, and return
heliograph watch                                # follow it until it ends
heliograph status                               # what the station is doing now
heliograph logs --last                          # the whole log
heliograph logs --last --gaps                   # where it stalled
```

Everything after the step name is environment, passed verbatim; values with
spaces are re-quoted on the way out. With more than one estate configured,
every command needs `-e <estate>`: a request to the wrong estate runs a
command on the wrong machine, and that is not recoverable by apologising.

`watch` waits for the request `send` just published, not for whatever the
station finishes next. Until the station reads it, `watch` and `status` say
`not picked up yet`: the status on the far side still describes the previous
run, so never read that run's result, or its refusal, as this one's.
`heliograph watch <id>` follows a named request instead.

What the CLI already handles, so do not do it by hand: the `git pull --rebase`
discipline (two writers share the branch, and the station pushes far more
often than you do), inventing request ids, and the timestamp arithmetic.

The trigger is the **id**, not a new commit, so docs and step edits never fire
runs nobody asked for. A new `send` while a step runs **queues**; it does not
cancel. To kill the running step, set `cancel: yes` in `station/request` (or
`cancel: <id>` to kill only that id), commit and push - the station stays
responsive while a step runs. `stop: yes` ends the loop from your side, which
matters because nobody is sitting at that terminal.

**The gates. The loop is read-only by default.** Every step declares itself in
its own file - `# heliograph-mode: read-only` or `action` - and a step that
declares neither does not run. A state-changing step needs `CONFIRM=yes` in
the request's env **and** the station must have been started with
`--allow-actions`, or the refusal is published to `station/status` within one
poll. The loop refuses to run as root. These gates live in the station and the
CLI; never work around them.

A long run is not a black box: the partial log is pushed every 60 seconds with
a line count and the last real line, so `heliograph status` shows where it has
got to. The finished log lands in `ops-logs/` in the transport repo, committed
and pushed - that is how a run escapes a machine nobody can reach.

While a station is running, **say so and wait for the log**. Ask the operator
only for what the transport cannot carry: an interactive cloud login, a
decision, or a fact only they have.

### When git is not the transport that works

Two cases live in the station payload rather than the CLI today, and for
these two you drive the station's own script in the transport repo - not
because two drivers are fine, but because the CLI has no transport for them
yet:

- **The control node cannot reach git at all.** `./drop.sh send <id> <step>`
  and `./drop.sh watch <id>` carry the same contract over Azure Blob Storage;
  neither side ever reaches the other. Measure before reaching for it - see
  [references/beacon.md](references/beacon.md).
- **You can reach the station directly.** An Azure Function App inside the
  VNet with a public HTTPS endpoint makes storage pointless indirection:
  `./intercom.sh run steps/<name>.sh K=V`. Read
  [references/flare.md](references/flare.md) before exposing it - the
  function key and IP allowlist become the real gates.

## 5. Read the log

- `heliograph logs --last --gaps` first. A gap is a finding: in an untimed
  log a hang and slow progress are indistinguishable. A log where every line
  carries the same timestamp is reported as an **error**, not as "no gaps".
- **Header block next**: branch, commit, host, user. A divergence between the
  commit you pushed and the one they ran explains a surprising share of "but
  I fixed that".
- `probe_summary` gives the tally, the footer gives the real exit code.
- **Read the whole log, including the parts that worked.** A passing probe
  beside a failing one is the control that tells you what the failure means.
- Record what was *measured* in `TASK.md`, separately from what you
  concluded. Measurements stay true; conclusions get revised.

**A green exit means the probes that ran passed, not that the work happened.**
Verify the outcome, not the exit code.

## Hard rules

These outrank convenience. Each one is here because breaking it cost a full
round trip or worse.

1. **Never truncate.** No `head`, no `tail -20`, no `2>/dev/null` on the
   thing being diagnosed. The line you cut is the one you needed.
2. **Measure, do not infer.** Say what a log showed, not what it implies.
3. **Keep a control.** A probe with nothing to compare against is an anecdote.
4. **Change one thing between runs.** Two changes and a different result
   tells you nothing.
5. **Read-only until earned.** A step changes state only when you can say
   precisely what it will do and why, and then it carries the `CONFIRM=yes`
   gate.
6. **Never commit task work to `main`.**
7. **Never ask the operator to hand-edit anything.** Deliver a change as a
   payload the step copies into place. An unlogged manual edit is exactly the
   divergence these logs exist to rule out.

The full method, and the mistakes behind each rule:
[references/method.md](references/method.md). Worth reading in full before a
hard investigation.

## Running the station in Azure, instead of on somebody's terminal

Sometimes there is no willing human to start `./start.sh` and leave it
running. The station payload's `azure/` runs it as Azure infrastructure
instead: Container Instances, Web App for Containers and a scheduled
Container Apps Job are deployed and proven; a VM with a systemd unit and a
Function App on Flex Consumption are written and validated. All
bring-your-own-network, and the checkout is transient - git is the
persistence.

Two things that will waste your time if you do not know them: the published
image tag has no `v` (git tag `v1.0.0-rc1`, image
`ghcr.io/dbhq-uk/heliograph-toolkit:1.0.0-rc1`), and a GitHub transport repo
needs `GIT_TOKEN_USER=x-access-token` or git reports a missing username
rather than a wrong one. Everything else:
[references/azure.md](references/azure.md).

## Secrets

Logs are committed and pushed, so anything a command prints is in history
permanently. `cap_redact` masks the obvious shapes and is a safety net, not a
guarantee. **Name secrets, never read them** - listing secret names settles
"does this exist here"; the value is never the question.

When a value has to travel the *other* way, `./secret.sh` in the transport
repo carries it as ciphertext with a passphrase defined by a human on both
machines and never committed. It is transport, not storage: the ciphertext is
in history forever. Details: [references/secrets.md](references/secrets.md).

## References

Near side, on the web, because it changes with the binary and one copy is
better than two:

| | |
|---|---|
| <https://heliograph.dbhq.uk/cli> | every CLI command, and the reasoning behind the ones that are not obvious |
| <https://heliograph.dbhq.uk/mcp> | the MCP tools, for driving this from an agent |
| <https://heliograph.dbhq.uk/transports> | git, file share, bundle, object store, relay |

Far side, here, because it documents the payload:

| | |
|---|---|
| [references/steps.md](references/steps.md) | writing a step, and the traps that cost round trips |
| [references/runner.md](references/runner.md) | `start.sh`, `run.sh`, `station.sh`, `caprun.sh`, every `cap_*` and knob |
| [references/method.md](references/method.md) | how to debug across a gap. The expensive lessons |
| [references/transport.md](references/transport.md) | how the control node authenticates to the git host |
| [references/beacon.md](references/beacon.md) | the blob transport, for a control node that cannot reach git at all |
| [references/flare.md](references/flare.md) | the HTTP transport, for the rarer case where you can reach the station |
| [references/azure.md](references/azure.md) | running the station in Azure, and what deploying it taught us |
| [references/secrets.md](references/secrets.md) | `secret.sh`, for a value that has to reach the far side |
| [references/remote-repo.md](references/remote-repo.md) | changing a repo that is also on the far side |
| [references/container.md](references/container.md) | running the control node in a container: what ships, why, and the honest limits |
| [references/windows.md](references/windows.md) | a Windows control node, steps written in PowerShell, and what line endings really do |
| [references/service.md](references/service.md) | making the loop outlive the session that started it |
| [references/hosts.md](references/hosts.md) | every host, the contract it must meet, and which ones are actually proven |

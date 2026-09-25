# CLI reference

Every command the control side has, and the reasoning behind the ones that are
not obvious.

```
heliograph bootstrap <dir> [--flavour bash|powershell|both]
heliograph init <estate> --dir <path> [--transport git|share|bundle|objstore]
                          [--scope <name>] [--bucket <b>] [--prefix <p>] [--region <r>]
heliograph estates
heliograph plant [--service] [--script]
heliograph send <step> [KEY=VALUE ...] [--note <text>]
heliograph watch [<id>] [--interval 10s] [--timeout 0]
heliograph status
heliograph logs [--last] [<name>] [--gaps] [--min 10s]
heliograph doctor
heliograph mcp
heliograph version
```

Every command takes `-e` / `--estate`. With exactly one configured, it is
optional. With several it is required: sending a request to the wrong estate
runs a command on the wrong machine, and that is not recoverable by apologising.

## bootstrap

Plants the station payload into a transport repo. The payload is embedded in
the binary at build time, so a release plants exactly the station it was
tested against, and "which station is this estate running" has the same
answer as "which binary planted it".

Nothing is overwritten, ever: an existing file is left alone and reported,
because the second run is usually an upgrade over a repo with a task in
flight.

`--flavour bash | powershell | both` chooses the payload, and `bash` is the
default. `powershell` plants the pure PowerShell station for an estate with no
bash at all - see [Windows](/windows). `both` puts both in one repo for a
transport repo serving two kinds of machine; it is not a recommendation.

`station/bootstrap.sh` and `station/bootstrap.ps1` lay down the same files for
a machine with no CLI - the second for a Windows box with no bash either - and
CI asserts all three produce identical trees, for both flavours.

A station's own runtime state is never planted and never embedded:
`.station-env` holds a token, and `go:embed` reads the working tree rather than
the repository, so a build on a machine that had run a station would otherwise
carry it into every download.

## init

Remembers a transport by name, so every later command can be typed without a
path. It **attaches before saving**: an estate that names a directory which is
not a usable transport is worse than no estate at all, because it fails later,
from a command that had every reason to expect it to work.

## station add

A second station on the same repository, on its own branch.

```bash
heliograph station add db-a
heliograph send net-probe -e db-a     # reaches that machine and no other
```

It does three things that have to happen together, because doing two is worse
than doing none:

1. creates `station/db-a` and pushes it **with an upstream** - without one the
   station's own first push fails on the far side, where nobody can see it
2. checks it out into a git worktree beside the existing clone, so the control
   side has one checkout per station and never switches between them
3. records the estate, so `-e db-a` routes to that machine

And it removes the station status the new branch inherited from the one it was
cut from. That status describes another machine, and `send` would refuse to
publish under it.

Then it prints what to send the operator, which is the point of the other three.

`--dir` puts the checkout somewhere other than beside the existing one.

**It refuses a branch origin already has**, because that is somebody else's
station and creating it from this HEAD would be about to rewrite their history.
It does not move your checkout either: it uses `git branch`, not `checkout -b`.

### An estate it creates is pinned to its branch

`station add` records the branch as the estate's **scope**, and every later
command verifies the checkout is still on it. Move that checkout and the CLI
refuses, naming both branches, rather than sending your next request to a
different machine.

An estate from `init` is **not** pinned - it records the branch it found and
follows the checkout - because working on `task/<slug>` and then sending is the
ordinary workflow.

Several stations in one repository only makes sense where they share a blast
radius: a repo credential usually spans every branch. See
[transports](/transports#one-repository-several-stations).

## plant

Prints the message to send the operator. Generated rather than typed, because
every retyping of a clone URL is a chance to get it wrong on a machine nobody
can check afterwards.

It carries **no credential**, deliberately. A token pasted into a chat window is
in that history forever, and the operator usually already has one.

It also says what the loop will *not* do: refuses root, runs nothing that
changes state without `--allow-actions`, holds no credentials of its own. That
is not padding. Somebody is being asked to run a stranger's script on a
production machine, and the honest answer to "what does this do" is what gets it
approved.

## send

Publishes a request. The `id` is the trigger and nothing else is: documentation
and step edits land on a branch constantly, and if any change fired a run the
station would run on all of them.

Everything after the step name is environment, passed verbatim:

```bash
heliograph send net-probe HOSTS="sql01 sql02" PORTS=1433
```

Values containing spaces are re-quoted on the way out. The shell that invoked
the CLI has already eaten your quotes, and the station splits that line the way
a shell would, so an unquoted value would set the first word and try to *run*
the rest.

### Mode and expiry

Two flags bind a request beyond its step and environment:

```bash
heliograph send steps/fix-dns.sh --mode action CONFIRM=yes   # refused if the step no longer declares action
heliograph send env --expires 72h                            # valid for three days instead of one
```

`--mode` is the mode you expect the step to declare, `read-only` or `action`.
The step file still decides what the gates do. This refuses a request whose
author was looking at something else: a step edited from read-only to action
after the request was written would otherwise run with the earlier decision's
authority.

`--expires` is how long the request stays valid, 24 hours by default. A station
that reads it later refuses it and says so in its status. Without a limit, a
request lifted out of a transport repo would be good for ever, and
`--allow-actions` and `CONFIRM=yes` were decided before it. `--expires 0` turns
the limit off, for an estate that plants its station days after the request is
written.

### It refuses a branch no station reads

The status a station publishes names the branch it runs on. `send` reads it
first, and if it names a different branch from the one this checkout sends to,
it publishes nothing and says both:

```
heliograph: not sent: the station last published from "main", and this estate sends to "task/x".
```

That is what a task branch looks like before a station is on it. `git checkout
-b` copies the parent branch's status, and a station still on the parent never
reads the new branch, so a request there waits for nothing while `watch` and
`doctor` read the parent's last run as the answer. `watch` warns about the same
thing and `doctor` fails on it.

Cut and push the branch, then have the operator restart the station on it:
`heliograph plant` prints the commands. A station publishes its own status as
soon as it starts on a branch whose status names another, and `send` works from
then on. `station add` removes the status its new branch inherits, so the send
it prints works before that station has run.

A station older than this does not publish when it starts, only when it runs
something. Until it is updated, remove the inherited status by hand -
`git rm station/status`, commit, push - and `send` treats the branch as one
whose station has not published yet.

## status

What the station is doing, from the document it publishes on every transition.

One line on that page is not about the run. `actions:` says what the station
will permit for the whole life of its process, which is settled by
`--allow-actions` when the operator starts it:

```
actions:  allowed - this station runs a step declaring 'action', with CONFIRM=yes on the request
actions:  refused - this station is read-only. The operator restarts it with --allow-actions
actions:  not reported - this station is older than the field. That is not the same as read-only
```

Three answers, not two, and the third is the one worth reading carefully. A
station planted before this field publishes nothing for it, and there is no way
to ask from this side. Rendering that silence as read-only would say an estate
is safe on the strength of a station that never said so, and the answer is
never inferred from whether an action has run there before: a station restarted
without the flag still has its old action logs, and one started with the flag
may never have been asked. See [the station page](/station#the-action-mode-it-publishes).

A mode this build does not recognise is shown verbatim and claimed for neither
side, for the same reason an unknown state is not treated as finished.

## watch

Follows one request until the station finishes it: the last one `send`
published from this machine, or the `<id>` you name.

It waits for **that** request, not for the first finished state it sees. The
status on the far side describes the last request the station read, and for a
whole poll interval after a send that is the previous one. Until the ids match,
`watch` prints `not picked up yet` rather than a result, and `status` says the
same above everything else it prints. Reporting the earlier run instead reads as
this request's answer - and after an earlier refusal it sends the reader off to
restart a station that never saw the request.

If the station has moved **past** the request, because a later one was sent
after it, the status will never describe it again. `watch` says so and stops;
`heliograph logs` still lists a log for every run.

A refusal ends the watch, and `watch` and `status` both print the station's own
`reason:`. It names what would change the station's mind, and that is often not
a flag: a step the station does not know, a step that declares no mode, a
request that has expired. The general advice about `--allow-actions` and
`CONFIRM=yes` is printed only for a station too old to publish a reason.

`--timeout` stops the watch, never the run.

## mcp

Serves every command above as typed tools to any MCP-capable agent, over stdio.

```bash
claude mcp add heliograph -- heliograph mcp
```

It is the same binary, so there is nothing extra to install, and the tools call
the same code the commands do. Full detail on the [MCP page](/mcp).

The gates do not move. A tool call publishes a request; the station still
decides whether to run it.

## Object store estates

`--transport objstore` needs three things the other transports do not: where the
store is, which bucket, and which lane.

```bash
export HELIOGRAPH_S3_ACCESS_KEY=... HELIOGRAPH_S3_SECRET_KEY=...

heliograph init payments --transport objstore \
  --dir https://s3.eu-west-2.amazonaws.com \
  --bucket heliograph-transport \
  --scope net-probe
```

The keys come from the environment and are **never written to the estate file**.
That file is on disk, gets copied between machines and ends up in backups; a
secret in it would be a secret in all three.

`--scope` is the lane: one per investigation, so two running at once do not
overwrite each other. `--region` defaults to `auto`, which is what R2 and MinIO
want. See [transports](/transports).

## Relay estates

`--transport relay` is the only one whose enrolment is a two-way exchange, and
it is a key exchange rather than a credential. `relay peer` is the command that
records the half arriving last.

```bash
heliograph init payments --transport relay \
  --dir https://heliograph-relay.dbhq.uk \
  --relay-estate payments \
  --scope db-a

heliograph plant -e payments        # what to send the operator
heliograph relay peer -e payments <the line they send back>

export HELIOGRAPH_RELAY_TOKEN=...   # the CONTROL token for that estate
heliograph send steps/probe.sh
```

`--relay-estate` is the id the **relay** routes on, chosen by whoever runs the
relay. It is not this estate's local name, and conflating them would mean
renaming an estate here silently re-pointed it at a route that does not exist.
`--scope` is the station.

`--dir` is the relay's base URL. `heliograph-relay.dbhq.uk` above is the relay
DBHQ hosts: it is free to use, it has no sign-up page, and the estate id and
both tokens are issued by hand. What to ask for, the limits and the notice you
get if it changes are on
[the relay page](/relay#the-hosted-relay-and-how-to-ask-for-a-token).

`init` generates the control identity if you do not supply one, beside the
estate at mode 600, and prints its fingerprint. The **token** comes from
`HELIOGRAPH_RELAY_TOKEN` and is never written to the estate file, exactly as
the object store's keys are not.

### Nothing works until the fingerprints match

`plant` prints the control's public identity for the station's `RELAY_PEER`, and
the operator sends back theirs. **Compare the two fingerprints over a channel
they already trust** - a phone call, not the relay. It is the only step here a
machine cannot do, and it is what stops a relay substituting its own key.

Skipping it does not fail loudly. The station starts, polls happily, and drops
every request because it cannot verify a signature - which from the far side is
indistinguishable from nobody sending anything. So `send` refuses until a peer
is recorded, and names the command that records one.

The station's **secret never reaches this side**, even if somebody sends their
whole identity file rather than the one line: `relay peer` decodes to a public
identity and re-encodes it.

### A relay is a queue, not a store

It deletes on collection, so a log arrives exactly once and is then gone. The
control node keeps what it collects, which is why `heliograph logs` works here
at all - and why `status` is repeatable rather than reporting a station that has
gone away the second time you ask.

That store is called the spool, and it is what `heliograph push` forwards.

## trust: who may command a station

One key per estate is enough for one person. For four engineers on a client
estate it is not: the archive cannot say *who* asked, somebody leaving means
re-enrolling every station they could reach, and there is no revocation short
of that.

A station may instead hold a **trusted set** - several keys, each belonging to
one person - and verify a request against any active member of it.

```bash
heliograph trust init -e payments          # record the anchor, and print what the operator plants
heliograph trust show -e payments          # who may command this station
heliograph trust add -e payments alice <alice's public identity>
heliograph trust revoke -e payments alice
heliograph doctor -e payments              # compare our copy against what the station published
```

### The anchor, and why it only changes on the machine

The set starts with an **anchor**: one key, planted by the operator, on the
machine, at the same moment they plant the station.

```
ANCHOR   owner   4d18-...   planted on the machine. Changeable ONLY there
alice            9f3c-...   added 2026-01-04, signed by owner
bob              2a71-...   added 2026-02-11, signed by alice
carol            c40e-...   added 2026-03-02, signed by alice   REVOKED by bob 2026-04-18
```

Any trusted key may add or revoke any key **except the anchor**. That one
exception is the recovery property: a compromised key can evict every other
engineer, and it cannot evict the anchor, so putting the estate back is a signed
change from whoever holds it rather than a site visit. It also means the estate
owner **is never locked out of their own machine by anything remote**.

Rotating an anchor is a command run on the machine and nowhere else:

```bash
./heliograph-seal trust anchor --set .station-trusted-set --anchor <new key>
```

### A change is a signed document, and nothing else is on the path

`heliograph trust add` signs a change with the key on **your** machine, applies
it to your copy, and sends it over the transport the estate already uses. The
station verifies it against the set as it stands and applies it, or refuses it
and publishes the reason.

Nothing in between authors anything. A service can display a set, propose a
change and record that one happened; producing one needs a key. So a change
lands with Heliograph Cloud unreachable, and compromising a service is not
equivalent to holding a key.

### Revocation is eventual, and that is worth saying out loud

The station learns of a revocation **on its next poll**. Between the change
being sent and that poll, the revoked key still works. An already-running step
is not interrupted, either: revocation removes the ability to ask for the next
one.

For a station polling every five seconds that is seconds. For one on a long
interval it is that interval. Neither is instant, and "revoked" read as
"instant" is the kind of assumption that gets discovered during an incident.

### What it needs on the far side

Verification is Ed25519, which bash and coreutils cannot do, so a trusted set
needs `heliograph-seal` on the station - the one binary the relay transport
already installs there. A station on any other transport can use a trusted set
by carrying that binary too; without it, `TRUST_SET` makes the station refuse to
start rather than accept everything quietly.
## login

Signs in to a hosted heliograph service. **There is nothing to paste.**

```bash
heliograph login --service https://<the service>
```

It prints a short code and a URL, you enter the code in a browser, and the
credential comes back over the connection the CLI already opened. It is written
to `~/.config/heliograph/credentials.json` at mode 600 and is never printed - not
by `login`, and not by `heliograph login --status`, which shows what is stored
without showing any value.

This build has **no service URL compiled into it**. A hostname in a released
binary is a promise that outlives the binary, and a station pointed at a name
that used to resolve fails on the far side, silently, in front of somebody who
cannot debug it. So `--service` or `HELIOGRAPH_CLOUD_URL` is required.

`heliograph login --logout` forgets the credential on this machine. It does not
revoke it: revoke it in the console if it may have been seen.

### A hosted estate, with no relay to stand up

```bash
heliograph init payments --transport relay --hosted
```

`--hosted` supplies the three things you would otherwise have obtained by
standing up a relay: the URL, the estate id the relay routes on, and the control
credential. There is no container to run and no TLS for you to terminate,
because both ends dial out over ordinary HTTPS. It prints the line to send the
operator, which carries the enrolment key and is shown once.

The identity is still made **here**. The service provisions routing and
credentials and never sees a key that can open or sign anything.

## push

Forwards the spool this control node already keeps.

```bash
heliograph push -e payments
heliograph push -e payments --dry-run     # what would be sent, and send nothing
```

The status documents go first, because the archive builds its record from those
bytes and keys a run by the `id:` inside one. Then a manifest, so the client
learns what to skip; then the log bodies, in chunks with a digest each; then a
completion that verifies the whole body. Each step returns a receipt.

Four properties worth knowing, because each is asserted in a test rather than
promised:

- **`push` never authors a request.** It cannot reach the code that signs one or
  the code that publishes one, and driving it with a station and a relay both
  running sends nothing to the station's request queue
- **The spool is untouched.** It is read and never written, compared as a whole
  tree before and after
- **It is idempotent**, so running it at the end of every session is a habit
  rather than a decision. The manifest is what makes a repeat push cheap
- **An interrupted push resumes.** The service says which byte offsets it
  already holds and only the rest is sent

A failed push names the local path of every log it could not send. Nothing is
deleted and nothing is moved, so a push that fails costs a retry and never a
round trip through the operator.

### What a relay-only estate does not get

An estate that reaches the service only by `push` gets the archive and the
history. **It does not get gone-quiet alerting**, because nothing reaches the
service while this control node is closed: you cannot alert on silence when your
only source is a laptop that also goes silent. The archive is as current as the
last push and no more.

Running a git transport alongside is what closes that, and it costs nothing.

## rotate

Replaces an estate's control credential.

```bash
heliograph rotate -e payments          # prints the warning, changes nothing
heliograph rotate -e payments --yes    # having read it
```

The warning is printed **before** the question rather than after the answer,
because the two credentials are not the same kind of thing. A control credential
lives on this machine, so replacing it costs one command. A **station**
credential lives on a machine you cannot reach, in front of an operator with
their own schedule, so replacing one is not a rotation at all - it is a
re-enrolment, and somebody has to run the planting line there again.

Rotating a control credential rotates no station credential. Nothing here will
offer to rotate one as if it were an ordinary action.
## logs --gaps

The reason the binary is worth installing.

```
$ heliograph logs --last --gaps
net-probe-20260906T091400Z.txt
412 captured lines

2 interval(s) of 10s or more, longest first.
Each is attributed to the line BEFORE it, which is what was running.

   3m12s  after  09:14:02 | Refreshing state...
     45s  after  09:17:14 | ---------- openssl s_client ----------
```

A log where **every line carries the same timestamp** is reported as an error
rather than "no gaps found". That log is a buffered capture, it reads perfectly,
and calling it clean would be the exact opposite of true.

## doctor

`heliograph check` is the same command under another name.

Answers "will this work from here" and changes nothing. Every line that reports
a problem also says what to do about it: a preflight line that names a fault
without a remedy is a defect, because the person reading it usually cannot ask
anybody.

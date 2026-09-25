# heliograph, the skill

Debug and change a machine you cannot log into, through an operator who cannot
debug it. The skill drives the `heliograph` CLI; the CLI drives a station
across the gap.

## The problem it solves

The machine is in a client-owned, air-gapped or change-controlled environment.
You are the one who knows what to ask it, and you are never getting SSH. The
person who *can* reach it has their own work and should not be your terminal.

So the loop stops being a relay. You publish a step; they run one command that
never changes; the whole run comes back as a log that is committed and pushed.

## How it works

1. **`heliograph bootstrap`** plants the station payload into a fresh,
   private transport repo, and **`heliograph init`** names it as an estate
2. **Baseline** with `heliograph send env` before theorising about anything
3. **One branch per investigation**, one step per question, `TASK.md` holding
   what was measured apart from what was concluded
4. **The operator runs `./start.sh` once** and stops relaying. It proves the
   machine can capture and push, then starts the station, which watches for a
   request and runs when the `id` changes
5. **`heliograph logs --last --gaps`**, read the whole log, record the
   measurement, decide the next step

## The two properties that make it work

**Every captured line carries a UTC timestamp**, so a hang shows as a gap. In
an untimed log, a hang and slow progress are indistinguishable after the fact.

**The log is pushed even on failure**, with the real exit code intact, so a
failed run reads as clearly as a successful one and no round trip is wasted.

## Where this sits

This directory is the **control side's agent interface**: the workflow, the
hard rules, and the references that document the station payload. The gates -
read-only by default, `CONFIRM=yes`, `--allow-actions` - live in the CLI and
the station, not here, so there is exactly one driver and nothing to drift.

The station itself is [`station/bash/`](../../station/): plain bash, no
credentials of its own. **No Go source will ever be added under
`station/bash/`** - CI enforces it. The one compiled thing a station may need
is `heliograph-seal`, for the relay or a trusted set. It is named in
[`station/FAR-SIDE-BINARIES`](../../station/FAR-SIDE-BINARIES) and built
reproducibly, so it can be checked against the source it came from.
Everything else that crosses the gap is plain bash you can read before you
run it.

## What is where

| | |
|---|---|
| [`SKILL.md`](SKILL.md) | the workflow and the hard rules |
| [`references/method.md`](references/method.md) | how to debug across a gap. The expensive lessons |
| [`references/steps.md`](references/steps.md) | writing a step, and the traps that cost round trips |
| [`references/runner.md`](references/runner.md) | every runner, `cap_*` function and knob |
| [`references/transport.md`](references/transport.md) | how the control node authenticates to the git host |
| [`references/remote-repo.md`](references/remote-repo.md) | changing a repo that is also on the far side |
| [`references/secrets.md`](references/secrets.md) | `secret.sh`, for a value that has to reach the far side |
| [`references/container.md`](references/container.md) | running the control node in a container: what ships, why, and the honest limits |
| [`../../station/bash/`](../../station/) | the payload: `start.sh`, `run.sh`, `station.sh`, `caprun.sh`, `caplib.sh`, `secret.sh`, `lib/`, `steps/`, `docker/`, `azure/` |

Nothing under `station/bash/` runs from here. It is planted into a transport
repo and runs on a machine you will never see, in front of someone who cannot
debug it. Edit it accordingly.

## What it will not do

Give you access you do not have. There is no tunnel, no proxy and no held
connection. Every command runs because someone with legitimate access chose to
run it, and the only thing crossing the gap is a commit.

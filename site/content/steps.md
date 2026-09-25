# Writing a step

A step is one file that answers one question. It prints to stdout and knows
nothing about logging, timestamps or delivery - the runner owns all of that.
That is what makes a step runnable on its own, and it is the whole contract.

Every rule on this page cost a round trip through somebody who could not debug
the machine.

## The shape

```bash
#!/usr/bin/env bash
# heliograph-mode: read-only
#
# What question this answers, and what would settle it.
set -uo pipefail

echo "---------- DNS ----------"
getent hosts sql01 || echo "  no A record"
```

Copy `steps/_template.sh` and start there. Register it in the `case` table in
`run.sh` **and** in the step-list comment above it, so `--list` stays honest.

## Declare what it is, or it will not run

In the first 30 lines of the step's own file:

```bash
# heliograph-mode: read-only        # measures, changes nothing
# heliograph-mode: action           # changes state; needs CONFIRM=yes
```

A step that declares neither **does not run at all**, exit 3. That fails
closed, because the alternative is inferring authority from a step that never
claimed any.

The gate used to be a list of step names - `reset|destroy|apply|deploy` - and
the hole was not subtle: `cleanup-disk` matched none of them and was waved
through as a diagnostic, while a read-only step that happened to be called
`deploy` was gated for its spelling. **A filename is not evidence about
behaviour.**

What this does not do, and the code says so too: stop an author declaring
`read-only` and then writing `rm -rf`. Nothing in a shell runner can. It makes
the classification an explicit statement in the file being run, checked at the
boundary, instead of a guess made from its name.

## `set -uo pipefail`, never `set -e`

The opposite of the usual house rule, deliberately. A diagnostic wants every
probe's result, not the first failure. A step that stops at the first missing
tool has told you one thing; a step that runs all twelve probes has told you
what the box is.

## Never prompt

No interactive sudo, no host-key questions, no `read`. A prompt through the
capture pipeline is invisible, and the run hangs with nobody there to notice.

If the step must escalate, run it with `SUDO=1` so the runner caches the
credential up front rather than letting it hang mid-capture.

## Never truncate

No `head`, no `tail -20`, no `2>/dev/null` on the thing being diagnosed. The
line you cut is the line you needed, and getting it back costs a whole round
trip. This is the single most expensive habit to bring to these logs.

Where output really is enormous, say so and print it anyway. A long log is
cheap; a second trip is not.

## Keep a control

A probe with nothing to compare against is an anecdote. If you are testing
whether `sql01:1433` is reachable, test something you expect to work in the
same run. A passing probe beside a failing one is what tells you what the
failure means.

## Say what a failure means

```bash
if ! nc -z -w3 sql01 1433; then
  echo "  sql01:1433 UNREACHABLE - so either the firewall, or nothing listening"
fi
```

The person reading the log usually cannot run anything else. An unexplained
non-zero exit costs a round trip that a sentence would have saved.

## The helpers in `lib/`

Source them; they are there so twelve steps do not each write their own.

| | |
|---|---|
| `lib/probe.sh` | `sec`, `probe`, `probe_opt`, `have` and `probe_summary` - the tally at the end of a log. Sourced by every step |
| `lib/remote.sh` | `rt_dns`, `rt_ping`, `rt_tcp` (pure bash, no `nc`), `rt_matrix` (host by port), `rt_ssh` (BatchMode, time-bounded), `rt_ps` and `rt_win_info` (PowerShell on a Windows host over SSH) |
| `lib/terraform.sh` | `tf_init`, `tf_validate`, `tf_plan`, `tf_show`, `tf_state_list`, `tf_output` and friends. Read-only on purpose: no apply, no destroy, no `state rm` |
| `lib/tfguard.sh` | `tf_lock_guard` puts back a tracked `.terraform.lock.hcl` that something moved, and `tg` runs terragrunt, retrying only when the subcommand name was rejected |
| `lib/ansible.sh` | `an_ping`, `an_win_ping`, `an_facts`, `an_play`, `an_check`, `an_list`, `an_inventory` |

`probe_summary` is worth using in every step. A log that ends with `9 passed, 2
failed` is one somebody can act on from the first screen.

## Steps written in PowerShell

A step is an argv array, so the runner does not care what language it is in. A
Windows question wants `Get-WinEvent`, not a bash reimplementation of it.

Register it with `ps_step`:

```bash
winev)  ps_step ./steps/win-events.ps1 ;;
```

`ps_step` fixes the things that make PowerShell output unreadable in a captured
log - CRLF, OSC 8 hyperlinks, encoding, and the exit code - in one place rather
than in every step by every author who remembers. See [Windows](/windows).

### On the PowerShell station, a step is just a step

The above is the **bash** station running a PowerShell step. On the [PowerShell
station](/windows#the-powershell-station-for-a-box-with-no-bash) every step is
PowerShell already, so there is no `ps_step` and nothing to wrap. Register it in
`run.ps1`'s table:

```powershell
$StepTable['winev'] = 'steps/win-events.ps1'
```

That table is **case-sensitive** - ordinal, deliberately - because `run.sh`'s
`case` is, and a step name that resolves on one implementation and is unknown on
the other is the kind of difference that makes a twin useless.

Two rules that differ from the bash side, both of which refuse the step rather
than mangling it:

- **Save the file as UTF-8 without a BOM.** Windows editors add one by default.
  A BOM is three invisible bytes before the first character, so the
  `# heliograph-mode:` line stops being first on its line. `run.ps1` refuses a
  BOM outright and says so, because "your editor added three invisible bytes"
  is a fixable answer and "declares no mode" is not.
- **Do not redact anything yourself.** `caplib.psm1` masks secrets on the way
  into the log, line by line. A step that masks its own output hides what the
  redactor would have caught and proves nothing about whether it works.

`steps/_template.ps1` in that payload is the one to copy.

## What ships on `main`

| | |
|---|---|
| `env` | what the box actually is: OS, tools, sudo, proxy, DNS, cloud auth, commit |
| `net` or `net-probe` | connectivity matrix to `HOSTS` on `PORTS`: DNS, ICMP, TCP |
| `tools` | every tool, python module and ODBC driver this host has |
| `win` | Windows snapshot: OS, hotfixes, services, events |

`env` is the right first step of any investigation, whatever it turns out to be
about. **A prior finding is a hypothesis to re-test, never a premise to build
on.**

## `main` is the template

Task work lives on `task/<slug>` and is not merged back. Only genuinely generic
tooling returns to `main`, stripped of anything task-specific.

No host names, environments, findings or logs on `main` - in this repo or in a
transport repo.

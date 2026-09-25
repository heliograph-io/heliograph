#!/usr/bin/env bash
# =============================================================================
#  test-station-loop-ps1.sh - station.ps1: gate 3, and the round trip
# =============================================================================
# The conformance suite asks whether a CAPTURE is honest. It says nothing about
# a loop, because a loop is not a capture: it decides WHETHER a step runs, and
# it is the only thing that ever publishes a refusal. Those are exactly the
# questions nobody can answer by reading a log afterwards.
#
# EVERY ASSERTION HERE READS THE FAR SIDE. Not the working tree, not the
# station's terminal output. A station that refuses a step correctly and
# publishes nothing is indistinguishable from a station that died, and the
# far side is the only place that difference shows. The bash loop learned this
# the expensive way: `publish_status "refused"` is what made a safe default
# affordable at all, because without it a refusal cost a wasted day.
#
# GATE 3 IS THE POINT OF THIS FILE. run.ps1 carries gates 1, 2 and 4 and is
# tested for them in test-run-ps1.sh. Gate 3 - the station must have been
# STARTED with --allow-actions - cannot live in the runner, because a runner
# invoked by hand has no station behind it to ask. It lives here, so it is
# tested here, and it is tested by watching what the far side receives.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
PSDIR="$(cd "$HERE/../station/powershell" && pwd)"

PS_CANDIDATES=()
[ -n "${CONF_PS_SHELL:-}" ] && PS_CANDIDATES+=("$CONF_PS_SHELL")
PS_CANDIDATES+=(pwsh powershell powershell.exe)
PS_BIN=""
for c in "${PS_CANDIDATES[@]}"; do
  if command -v "$c" >/dev/null 2>&1; then PS_BIN="$c"; break; fi
done
if [ -z "$PS_BIN" ]; then
  t_skip "no PowerShell interpreter: the loop and gate 3 were NOT exercised."
  t_summary
  exit 0
fi
t_ok "a PowerShell interpreter is present ($PS_BIN), so the assertions below ran"

WORK="$(mktemp -d)"
cleanup() {
  # Anything still polling. A station started without --once and never stopped
  # would outlive this file and poll a deleted directory for ever.
  if [ -n "${LOOP_PID:-}" ]; then
    kill -TERM "$LOOP_PID" 2>/dev/null
    wait "$LOOP_PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# A PATH POWERSHELL WILL UNDERSTAND. Git-Bash converts Unix-looking paths at
# the exec boundary, so an argument arrives native - but a path EMBEDDED IN A
# SCRIPT gets no such conversion and PowerShell reads /tmp/x as C:\tmp\x.
winpath() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# --- IS THIS ACCOUNT ALREADY PRIVILEGED? -------------------------------------
# MEASURED, NOT ASSUMED, for the reason test-run-ps1.sh measures it: GitHub's
# Windows runner is an Administrator, so gate 4 refuses every run and every
# assertion about gate 3 fails for a reason that has nothing to do with gate 3.
# The privileged gate has its own assertions further down, which do NOT set
# this - so the gate is still proved to refuse, by the checks written for it.
ROOT_ENV=()
if [ "$( "$PS_BIN" -NoProfile -Command \
        "Import-Module '$(winpath "$PSDIR/caplib.psm1")' -Force; if (Test-CapPrivileged) { 'yes' } else { 'no' }" \
        2>/dev/null | tr -d '\r' )" = "yes" ]; then
  ROOT_ENV=(ALLOW_ROOT=1)
  t_ok "this account is privileged, so ALLOW_ROOT=1 is set for the runs that are not about gate 4"
else
  t_ok "this account is unprivileged, so gate 4 is out of the way of the runs below"
fi

# --- a payload and a far side -------------------------------------------------
N=0
plant() {  # plant -> sets D (payload) and S (share root), with a fresh scope
  N=$((N + 1))
  D="$WORK/p$N"
  S="$WORK/s$N"
  mkdir -p "$D/steps" "$D/ops-logs" "$S/scope"
  cp -r "$PSDIR/." "$D/"
}

step_file() {  # step_file <name> <mode> <body...>
  local name="$1" mode="$2"; shift 2
  {
    printf '# heliograph-mode: %s\n' "$mode"
    printf '%s\n' "$@"
  } > "$D/steps/$name.ps1"
}

request() { printf '%s\n' "$@" > "$S/scope/request"; }

# Run the loop once. Output goes to LOOP_OUT, the exit code to LOOP_RC.
# Anything in EXTRA_ENV is added to the environment.
EXTRA_ENV=()
loop_once() {  # loop_once [station args...]
  LOOP_OUT="$(
    cd "$D" && env TRANSPORT=share \
      "SHARE_DIR=$(winpath "$S")" SHARE_SCOPE=scope \
      "${ROOT_ENV[@]+"${ROOT_ENV[@]}"}" "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
      timeout 120 "$PS_BIN" -NoProfile -File ./station.ps1 --once --interval 1 "$@" 2>&1
  )"
  LOOP_RC=$?
}

# POLL FOR A FEW SECONDS AND STOP, for the cases where the station has nothing
# new to do.
#
# `--once` means "do one requested RUN and exit", not "poll once and exit": a
# station whose request it has already answered keeps polling, exactly as
# station.sh does. So a check that asks "does it leave this alone" cannot use
# --once - it would sit there until the timeout, which is how two of these
# checks came to take two minutes each and then fail intermittently on the lock
# the kill left behind.
#
# The lock IS removed here, deliberately and with its reason: a PowerShell
# station killed with SIGTERM cannot run its own finally, because 5.1 has no way
# to catch that signal. A real station's next start clears it - which is its own
# assertion further down - and clearing it here keeps that behaviour from
# leaking into checks that are about something else.
loop_briefly() {  # loop_briefly <seconds> [station args...]
  local secs="$1"; shift
  ( cd "$D" && env TRANSPORT=share \
      "SHARE_DIR=$(winpath "$S")" SHARE_SCOPE=scope \
      "${ROOT_ENV[@]+"${ROOT_ENV[@]}"}" "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
      timeout "$secs" "$PS_BIN" -NoProfile -File ./station.ps1 --interval 1 "$@" ) >/dev/null 2>&1
  rm -f "$D/.station.lock"
}

# WAIT BY THE CLOCK, NOT BY A COUNT OF ITERATIONS.
#
# `for i in 1..400; sleep 0.1` is not 40 seconds. Every iteration of these waits
# spawns several processes - a sed, an ls, a cat, a grep - and process creation
# on Windows costs an order of magnitude more than on Linux. The first version
# of the progress check counted iterations, and on the Windows runner those 400
# iterations took longer than the 40-second step they were watching: by the time
# the condition was met the run had finished and DELIVERED, so the assertions
# read a complete log and called it a partial one.
#
# A deadline in seconds means the same wait on both platforms, which is what
# "wait for up to 90 seconds" was supposed to mean in the first place.
# IT TAKES THE NAME OF A PREDICATE, not a command line. `wait_until 120 test -n
# "$(published progress)"` looks right and is a busy-loop that can never
# succeed: the $( ) is expanded ONCE, by the caller, before wait_until runs at
# all - so the same stale value is tested every time round.
wait_until() {  # wait_until <seconds> <predicate-fn> - 0 if it came true in time
  local budget="$1" pred="$2"
  local deadline=$((SECONDS + budget))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$pred"; then return 0; fi
    sleep 0.2
  done
  return 1
}

loop_gone() { [ -n "${LOOP_PID:-}" ] && ! kill -0 "$LOOP_PID" 2>/dev/null; }

# THE FAR SIDE, and only the far side.
published() { sed -n "s/^$1:[[:space:]]*//p" "$S/scope/status" 2>/dev/null | head -1; }
delivered_names() { ls -1 "$S/scope/ops-logs/" 2>/dev/null; }
delivered_body() {
  local newest
  newest="$(ls -1t "$S/scope/ops-logs/"*.txt 2>/dev/null | head -1)"
  [ -n "$newest" ] && cat "$newest"
}

# =============================================================================
#  1. The round trip: a request in, a log and a status out
# =============================================================================
plant
step_file probe read-only "Write-Output 'the evidence'" 'exit 7'
request 'id: r1' 'step: ./steps/probe.ps1'
loop_once

assert_eq "the round trip publishes state idle" "idle" "$(published state)"
assert_eq "  and the id it answered" "r1" "$(published id)"
# THE STEP'S OWN EXIT CODE, not the loop's. A loop that reported its own success
# as the step's would make every failing step look like a clean run, which is
# the single most expensive thing this whole toolkit could get wrong.
assert_eq "  and the STEP's exit code, not the loop's" "7" "$(published exit)"
assert_contains "  and the log it delivered, by name" "ops-logs/probe-" "$(published log)"
assert_contains "the log actually reached the far side" "the evidence" "$(delivered_body)"
# `idle` IS A CLAIM ABOUT DELIVERY. The name of a log in the status proves
# nothing on its own - the bash loop published `idle` for stranded logs for a
# while, because anything that was not literally `no` became `idle`.
assert_eq "the far side holds exactly one log" "1" "$(delivered_names | grep -c .)"

# --- a step that does not exist says so --------------------------------------
# run.ps1 answers `--mode` with 2 for no such step and 3 for no declaration. The
# loop read only the printed line, so an unknown step was refused as one that
# "declares no mode" - and the reader was told to add a header to a file that
# does not exist. station.sh publishes the same reason.
plant
request 'id: u1' 'step: no-such-step'
loop_once
assert_eq "an unknown step is refused" "refused" "$(published state)"
assert_contains "  and the reason says the step is unknown, not that it declares no mode" \
  "unknown step" "$(published reason)"

# =============================================================================
#  2. GATE 3 - an action is refused unless the STATION was started for it
# =============================================================================
plant
step_file deploy action "Write-Output 'changed something'" \
  "New-Item -ItemType File -Force -Path '$(winpath "$WORK/gate3-ran")' | Out-Null"
rm -f "$WORK/gate3-ran"
request 'id: a1' 'step: ./steps/deploy.ps1' 'env: CONFIRM=yes'
loop_once

assert_eq "gate 3: an action is refused on a station started without --allow-actions" \
  "refused" "$(published state)"
# THE REFUSAL REACHES THE FAR SIDE WITH ITS REMEDY. A refusal the far side
# cannot act on costs the round trip a safe default is supposed to save.
assert_contains "  and the published reason names the flag that would allow it" \
  "--allow-actions" "$(published reason)"
# THE PROOF THE GATE HELD is the marker, not the word "refused". A gate that
# published a refusal AND ran the step would pass every assertion above.
assert_eq "  and the step did NOT run" "no" \
  "$([ -e "$WORK/gate3-ran" ] && echo yes || echo no)"
assert_eq "  and nothing was delivered" "0" "$(delivered_names | grep -c .)"
# THE MODE THE STATION PUBLISHES MUST AGREE WITH THE GATE THAT JUST FIRED.
# `actions:` is what a fleet view reads to answer "can this station make
# changes", and the answer is worthless unless it is the same fact the gate
# enforces. Two sources for one property is how a column starts lying.
assert_eq "  and the station published its action mode as refused" \
  "refused" "$(published actions)"

# A REFUSAL RECORDS THE ID, so the same request is not re-refused on every poll.
# Without that the station republishes a refusal every few seconds for ever,
# which on git is a commit and a push each time - and the far side cannot tell a
# loop that answered once from one that is stuck answering.
#
# Proved by making the refusal impossible to repeat: the station is restarted
# with --allow-actions, and the request it already answered must be left alone
# rather than run now that the gate would permit it. An id that was not recorded
# would look new, and the step would execute.
rm -f "$WORK/gate3-ran"
loop_briefly 8 --allow-actions
assert_eq "  and the refusal recorded the id, so the same request is not reconsidered" "no" \
  "$([ -e "$WORK/gate3-ran" ] && echo yes || echo no)"


# The same request, on a station started for it. CONFIRM=yes is still required
# by run.ps1's gate 2, and is in the env line above.
request 'id: a2' 'step: ./steps/deploy.ps1' 'env: CONFIRM=yes'
loop_once --allow-actions
assert_eq "gate 3: the same action RUNS when the station was started with --allow-actions" \
  "idle" "$(published state)"
assert_eq "  and the step really executed" "yes" \
  "$([ -e "$WORK/gate3-ran" ] && echo yes || echo no)"
# The other half, from the SAME payload, so the two values cannot both be a
# constant that happens to read correctly in one case.
assert_eq "  and the station published its action mode as allowed" \
  "allowed" "$(published actions)"

# =============================================================================
#  2b. A refusal is published ONCE, not on every poll
# =============================================================================
# IT HAS TO BE ITS OWN SECTION, because it plants a fresh payload - and the
# first version of it sat in the middle of section 2, so every later assertion
# there silently ran against the NEW payload. `gate 3: the same action RUNS`
# still passed, because a station DID run a step; the marker check failed,
# because it was looking for a file the new payload's step never writes.

# --- AND THE SAME THING WITHOUT A RESTART ------------------------------------
# The check above proves the STATE FILE was written, which is what a restarted
# station reads. It says nothing about the running one: the loop compares
# against a variable, and that variable is set from inside a function. If the
# scope were wrong the file would still be correct and a live station would
# republish the same refusal on every single poll - a commit and a push each
# time on git, and a far side that cannot tell a loop which answered once from
# one that is stuck answering.
#
# So this runs the station for real, without --once, and counts.
plant
step_file deploy action "Write-Output 'changed something'"
request 'id: rr1' 'step: ./steps/deploy.ps1'
( cd "$D" && env TRANSPORT=share "SHARE_DIR=$(winpath "$S")" SHARE_SCOPE=scope \
    "${ROOT_ENV[@]+"${ROOT_ENV[@]}"}" \
    "$PS_BIN" -NoProfile -File ./station.ps1 --interval 1 ) >"$WORK/rerefuse.out" 2>&1 &
LOOP_PID=$!
refusal_seen() { grep -q 'REFUSED' "$WORK/rerefuse.out" 2>/dev/null; }
if ! wait_until 60 refusal_seen; then
  t_skip "the station never refused within 60s, so the re-refusal check did NOT run"
  kill -TERM "$LOOP_PID" 2>/dev/null; wait "$LOOP_PID" 2>/dev/null; LOOP_PID=""
else
  # Long enough for eight more polls at one second. A loop that reconsidered
  # the request would have refused it eight more times by now.
  sleep 8
  kill -TERM "$LOOP_PID" 2>/dev/null; wait "$LOOP_PID" 2>/dev/null; LOOP_PID=""
  assert_eq "a running station refuses a request ONCE, not on every poll" "1" \
    "$(grep -c 'REFUSED' "$WORK/rerefuse.out")"
fi

# =============================================================================
#  3. GATE 3 sees what a DECLARATION cannot: env that turns a step into an action
# =============================================================================
# A step that plans is read-only until `env: APPLY=1` makes it apply. No
# declaration can see that, so ACTION_ENV is matched against the request.
plant
step_file plan read-only "Write-Output 'planning'"
request 'id: e1' 'step: ./steps/plan.ps1' 'env: APPLY=1'
loop_once

assert_eq "a read-only step with 'env: APPLY=1' is still gated as an action" \
  "refused" "$(published state)"
assert_contains "  and the reason says so" "changes state" "$(published reason)"

# The control: the SAME step with a harmless env line runs. Without this, a
# station that refused everything would pass the assertion above.
request 'id: e2' 'step: ./steps/plan.ps1' 'env: NOISE=1'
loop_once
assert_eq "  while the same step with an ordinary env line runs" "idle" "$(published state)"

# =============================================================================
#  4. The request may not choose the variables that control delivery
# =============================================================================
# PUSH=0 captures and delivers NOTHING while the run still looks clean from
# here, which is the defect delivery exists to remove handed to whoever can
# write a request.
#
# THE QUOTED SPELLING IS THE ONE THAT MATTERS. The bash loop once matched
# ` TRANSPORT=` against the raw line, and `FOO=1 "TRANSPORT=relay"` walks
# straight through that while still reaching the step as a plain assignment. So
# the check has to be on the PARSED name, and this proves it is.
plant
step_file probe read-only "Write-Output 'the evidence'"
n=0
#
# THE TRANSPORT'S OWN VARIABLES ARE IN HERE TOO, and they are the ones the
# original four-name list missed. Test-TpNeed reads them straight out of the
# environment - that is how every transport is configured - so a request
# setting RELAY_URL delivers the log to a relay of the author's choice, and
# RELAY_PEER is BOTH what a request is verified against and who the log is
# sealed to. A read-only step does it and no gate fires.
#
# It reached this station the moment it got a relay transport, which is why the
# assertion is here and not only on the bash twin.
for spelling in 'env: PUSH=0' 'env: FOO=1 "TRANSPORT=relay"' "env: T'RANSPORT'=relay" \
                'env: LOG_DIR=/tmp/elsewhere' 'env: RELAY_URL=https://not-yours.invalid' \
                'env: RELAY_PEER=/tmp/theirs.pub' 'env: SHARE_DIR=/tmp/elsewhere' \
                'env: OBJSTORE_ENDPOINT=https://not-yours.invalid' 'env: ALLOW_ROOT=1'; do
  n=$((n + 1))
  want="${spelling#env: }"; want="${want##* }"; want="${want%%=*}"
  want="$(printf '%s' "$want" | tr -d "\"'")"
  request "id: v-$n" 'step: ./steps/probe.ps1' "$spelling"
  loop_once
  assert_eq "a request setting a delivery variable is refused [$spelling]" \
    "refused" "$(published state)"
  # NAMED IN THE PUBLISHED REASON, per spelling. Asserting this once after the
  # loop would only ever check the LAST one, which is how the first version of
  # this check passed while proving nothing about the three before it.
  assert_contains "  and the reason names $want" "$want" "$(published reason)"
done

# A LOWERCASE SPELLING IS REFUSED, AND ON WINDOWS THAT IS NOT PEDANTRY.
#
# Windows environment variable names are CASE-INSENSITIVE. The child
# environment is a StringDictionary on .NET Framework, so `transport=relay` and
# `TRANSPORT=relay` are the same entry and the second overwrites the first. A
# case-sensitive guard would refuse the uppercase spelling, allow the lowercase
# one, and Windows would honour it - the whole defect, in lowercase.
#
# Measured: on .NET on Linux that dictionary keeps two distinct keys, so the
# hole is Windows-only and this test would pass on Linux either way. It is here
# because the station targets Windows, and because a check that only holds on
# the platform nobody deploys to is not a check.
for spelling in 'env: transport=relay' 'env: Relay_Url=https://not-yours.invalid' 'env: push=0'; do
  request "id: v-case-$RANDOM" 'step: ./steps/probe.ps1' "$spelling"
  loop_once
  assert_eq "a reserved name in another case is still refused [$spelling]" \
    "refused" "$(published state)"
done

# The control, again: an ordinary assignment is not refused, and REACHES THE
# STEP. A loop that refused every env line would pass all four assertions above.
step_file shows read-only 'Write-Output "GREETING=[$env:GREETING]"'
request 'id: v-ok' 'step: ./steps/shows.ps1' 'env: GREETING=hello'
loop_once
assert_eq "  while an ordinary assignment is allowed" "idle" "$(published state)"
assert_contains "  and it reaches the step" "GREETING=[hello]" "$(delivered_body)"

# A VALUE WITH A SPACE IN IT, quoted, arrives as ONE value. Plain word-splitting
# would deliver `a` and leave `b` as a second word - which on the bash side made
# the step die with `env: 'b': No such file or directory` and read as a broken
# step rather than a malformed request. HOSTS is the toolkit's own documented
# example of a value with a space in it.
step_file hosts read-only 'Write-Output "HOSTS=[$env:HOSTS]"' 'Write-Output "PORT=[$env:PORT]"'
request 'id: v-quoted' 'step: ./steps/hosts.ps1' 'env: HOSTS="a b" PORT=443'
loop_once
assert_contains "a quoted value with a space arrives as one value" \
  "HOSTS=[a b]" "$(delivered_body)"
assert_contains "  and the assignment after it is not swallowed" \
  "PORT=[443]" "$(delivered_body)"

# =============================================================================
#  5. Nothing is evaluated
# =============================================================================
plant
step_file probe read-only "Write-Output 'the evidence'"
rm -f "$WORK/evaluated"
request 'id: m1' 'step: ./steps/probe.ps1' \
  "env: FOO=\$(New-Item -ItemType File -Force -Path '$(winpath "$WORK/evaluated")')"
loop_once
assert_eq "an env line with a shell metacharacter is refused" "refused" "$(published state)"
assert_eq "  and nothing in it was evaluated" "no" \
  "$([ -e "$WORK/evaluated" ] && echo yes || echo no)"
assert_contains "  and the reason names the character" "metacharacter" "$(published reason)"

# --- THE CASE THAT PROVES THE GUARD IS LOAD-BEARING --------------------------
# The two assertions above pass with the metacharacter list EMPTIED, and that is
# worth knowing rather than glossing over: `FOO=$(...)` then falls through to the
# name check and is refused for not being a NAME=value assignment, and nothing
# is evaluated either way because this station evaluates nothing at all. So they
# test a real property and not this guard.
#
# `FOO=a;DANGER=1` is the case that separates them. It IS a valid NAME=value
# assignment - name FOO, value `a;DANGER=1` - so with the list emptied this
# station accepts it and hands the step that value. station.sh refuses it on the
# `;`, because over there the line reaches an `eval` and a semicolon is a
# command separator. The twins would then disagree about which requests are
# legal, from the same document, which is the one thing they may not do.
request 'id: m1b' 'step: ./steps/probe.ps1' 'env: FOO=a;DANGER=1'
loop_once
assert_eq "a metacharacter INSIDE a valid-looking assignment is refused too" \
  "refused" "$(published state)"

request 'id: m2' 'step: ./steps/probe.ps1' 'env: FOO="unbalanced'
loop_once
assert_eq "an unbalanced quote is refused rather than silently closed" \
  "refused" "$(published state)"

# =============================================================================
#  6. An undeclared step is refused, with a reason, before it runs
# =============================================================================
plant
rm -f "$WORK/undeclared-ran"
{
  printf "Write-Output 'this declares nothing'\n"
  printf "New-Item -ItemType File -Force -Path '%s' | Out-Null\n" "$(winpath "$WORK/undeclared-ran")"
} > "$D/steps/bare.ps1"
request 'id: u1' 'step: ./steps/bare.ps1'
loop_once
assert_eq "an undeclared step is refused" "refused" "$(published state)"
assert_contains "  and the reason says what to add to the file" \
  "heliograph-mode" "$(published reason)"
assert_eq "  and it did not run" "no" \
  "$([ -e "$WORK/undeclared-ran" ] && echo yes || echo no)"

# =============================================================================
#  7. The trigger is the id, not "something changed"
# =============================================================================
# Steps and documentation change constantly. If any change fired a run, the
# station would fire on all of them.
plant
step_file counter read-only \
  "Add-Content -Path '$(winpath "$WORK/runs")' -Value 'ran'" \
  "Write-Output 'counted'"
rm -f "$WORK/runs"
request 'id: t1' 'step: ./steps/counter.ps1'
loop_once
# The SAME id, a second time. loop_briefly rather than loop_once, because a
# station with nothing new to do does not exit - it polls, which is the whole
# point of the check.
loop_briefly 8
assert_eq "the same id does not run twice" "1" "$(grep -c . "$WORK/runs" 2>/dev/null || echo 0)"

request 'id: t2' 'step: ./steps/counter.ps1'
loop_once
assert_eq "  and a NEW id does run" "2" "$(grep -c . "$WORK/runs" 2>/dev/null || echo 0)"

# =============================================================================
#  8. stop: yes, from the far side
# =============================================================================
# Honoured from the far side precisely because nobody is sitting at the station.
plant
step_file probe read-only "Write-Output 'the evidence'"
request 'id: s1' 'stop: yes'
loop_once
assert_eq "'stop: yes' stops the station" "stopped" "$(published state)"
assert_eq "  and the station exited cleanly" "0" "$LOOP_RC"

# =============================================================================
#  9. GATE 4 - the privileged account, and the flag that permits it
# =============================================================================
# HELIOGRAPH_ASSUME_PRIVILEGED is ONE-DIRECTIONAL: it can only make the gate
# refuse. There is no value of it that permits a run, which is what stops a test
# hook being a backdoor with a test's name on it.
plant
step_file probe read-only "Write-Output 'the evidence'"
request 'id: p1' 'step: ./steps/probe.ps1'
PRIV_OUT="$(
  cd "$D" && env -u ALLOW_ROOT TRANSPORT=share "SHARE_DIR=$(winpath "$S")" SHARE_SCOPE=scope \
    HELIOGRAPH_ASSUME_PRIVILEGED=1 \
    timeout 60 "$PS_BIN" -NoProfile -File ./station.ps1 --once --interval 1 2>&1
)"
PRIV_RC=$?
assert_eq "gate 4: a privileged station refuses to start, exit 5" "5" "$PRIV_RC"
assert_contains "  and says which variable would permit it" "ALLOW_ROOT" "$PRIV_OUT"
assert_eq "  and ran nothing" "0" "$(delivered_names | grep -c .)"

# --- and the flag that permits it REACHES THE RUNNER -------------------------
# THE DEFECT THIS PAIR EXISTS FOR, found in the bash station and fixed there in
# the same change: `--allow-root` set a variable that was never exported, so it
# satisfied the LOOP's gate and reached nothing else. run.sh is a separate
# process with a root gate of its own, so every step was then refused with exit
# 5 while the status said "the runner exited before it reached delivery" - the
# symptom, and not one word of the cause.
#
# Asserting the station STARTS is not enough to catch that, and was the shape of
# the hole. What catches it is a DELIVERED LOG: the flag has only done its job
# when the step ran, and the step only runs if the flag crossed a process
# boundary.
request 'id: p2' 'step: ./steps/probe.ps1'
# THE STATION'S OWN OUTPUT IS NOT THE EVIDENCE and is discarded. What proves
# the flag crossed a process boundary into run.ps1 is a LOG ON THE FAR SIDE,
# which is what the two assertions below read.
( cd "$D" && env -u ALLOW_ROOT TRANSPORT=share "SHARE_DIR=$(winpath "$S")" SHARE_SCOPE=scope \
    HELIOGRAPH_ASSUME_PRIVILEGED=1 \
    timeout 60 "$PS_BIN" -NoProfile -File ./station.ps1 --once --interval 1 --allow-root ) >/dev/null 2>&1
assert_eq "gate 4: --allow-root lets a privileged station run a step" "idle" "$(published state)"
assert_contains "  and the log reached the far side, which is the only proof the flag crossed into run.ps1" \
  "the evidence" "$(delivered_body)"

# =============================================================================
#  10. A cancel stops a RUNNING step, and the partial log still gets out
# =============================================================================
plant
step_file slow read-only \
  "Write-Output 'starting the long probe'" \
  'foreach ($i in 1..60) { Write-Output "probe $i"; Start-Sleep -Seconds 1 }' \
  "Write-Output 'finished'"
request 'id: c1' 'step: ./steps/slow.ps1'

( cd "$D" && env TRANSPORT=share "SHARE_DIR=$(winpath "$S")" SHARE_SCOPE=scope \
    "${ROOT_ENV[@]+"${ROOT_ENV[@]}"}" PROGRESS_EVERY=2 \
    "$PS_BIN" -NoProfile -File ./station.ps1 --once --interval 1 ) >"$WORK/cancel.out" 2>&1 &
LOOP_PID=$!

# WAIT FOR THE RUN TO ACTUALLY BE UNDER WAY. A cancel of a step that never
# started proves nothing at all - the two absences agree and the assertion reads
# as a pass. So wait for the step's own output to reach the far side's log.
step_is_under_way() {
  [ -n "$(ls -1 "$D/ops-logs/"slow-*.txt 2>/dev/null)" ] &&
    grep -q 'probe 2' "$D/ops-logs/"slow-*.txt 2>/dev/null
}
if ! wait_until 90 step_is_under_way; then
  t_skip "the slow step never produced two lines, so the cancel was NOT exercised"
else
  t_ok "the step is running and has produced output, so there is something to cancel"
  request 'id: c1' 'step: ./steps/slow.ps1' 'cancel: yes'
  wait "$LOOP_PID" 2>/dev/null
  LOOP_PID=""

  assert_eq "a cancel publishes state cancelled" "cancelled" "$(published state)"
  assert_contains "  and says the log is partial" "partial" "$(published note)"
  # THE PARTIAL LOG IS THE EVIDENCE, and it is usually the thing that was
  # wanted. run.ps1 never reached delivery, so the LOOP is the only thing that
  # will carry it out.
  assert_contains "  and the partial log reached the far side anyway" \
    "starting the long probe" "$(delivered_body)"
  assert_eq "  and the step did NOT run to completion" "no" \
    "$(delivered_body | grep -q '^.*finished$' && echo yes || echo no)"

  # THE STEP ITSELF IS DEAD, not merely the runner above it.
  #
  # THIS IS THE ASSERTION THE OTHERS CANNOT MAKE. If a cancel kills run.ps1 and
  # stops there, the capture stops, the log stops growing, and every check below
  # passes - while the step carries on changing the estate with the operator
  # told it was cancelled. That is the worst outcome available to this file, and
  # it was the real behaviour on Unix until the loop started the step under
  # `setsid`: Process.Start puts the child in the STATION'S group, and
  # Stop-CapTree rightly refuses to signal a group it is itself in.
  #
  # Matched on the step's own path, because that is the process that would
  # survive. `ps -eo args` rather than pgrep: pgrep is not on a stock Git-Bash.
  step_procs() { ps -eo args 2>/dev/null | grep -c "steps/slow\.ps1" ; }
  sleep 3
  LEFT="$(step_procs)"
  # One match is this pipeline's own grep on some platforms, none on others.
  assert_eq "  and the STEP is gone too, not just the runner above it" "yes" \
    "$([ "${LEFT:-0}" -le 1 ] && echo yes || echo no)"

  sleep 2
  before="$(ls -1 "$D/ops-logs/"slow-*.txt 2>/dev/null | head -1)"
  size1="$(wc -c < "$before" 2>/dev/null || echo 0)"
  sleep 3
  size2="$(wc -c < "$before" 2>/dev/null || echo 0)"
  assert_eq "  and the log STOPS GROWING, which is the only proof the step is dead" \
    "$size1" "$size2"
fi

# =============================================================================
#  11. One station per payload
# =============================================================================
# Two would double-run every request and race on publication.
plant
step_file slow read-only 'foreach ($i in 1..30) { Write-Output "probe $i"; Start-Sleep -Seconds 1 }'
request 'id: l1' 'step: ./steps/slow.ps1'
( cd "$D" && env TRANSPORT=share "SHARE_DIR=$(winpath "$S")" SHARE_SCOPE=scope \
    "${ROOT_ENV[@]+"${ROOT_ENV[@]}"}" \
    "$PS_BIN" -NoProfile -File ./station.ps1 --once --interval 1 ) >/dev/null 2>&1 &
LOOP_PID=$!
lock_taken() { [ -s "$D/.station.lock" ]; }
wait_until 60 lock_taken

if ! lock_taken; then
  t_skip "the first station never took a lock, so the second could not be tested"
else
  SECOND="$(
    cd "$D" && env TRANSPORT=share "SHARE_DIR=$(winpath "$S")" SHARE_SCOPE=scope \
      "${ROOT_ENV[@]+"${ROOT_ENV[@]}"}" \
      timeout 30 "$PS_BIN" -NoProfile -File ./station.ps1 --once --interval 1 2>&1
  )"
  SECOND_RC=$?
  assert_eq "a second station in the same payload refuses to start, exit 3" "3" "$SECOND_RC"
  assert_contains "  and names the pid that holds it" "already running here as pid" "$SECOND"
fi
kill -TERM "$LOOP_PID" 2>/dev/null; wait "$LOOP_PID" 2>/dev/null; LOOP_PID=""

# --- A KILLED STATION LEAVES ITS LOCK, AND THE NEXT ONE CLEARS IT ------------
# Asserting that the lock is GONE here would be asserting something PowerShell
# cannot do: 5.1 has no way to catch a SIGTERM, so the finally block never runs
# and the file survives the process. station.sh traps TERM and does remove it.
#
# What must hold on both is the property that actually matters: a lock never
# outlives its process AND is trusted. So the next station reads the pid, finds
# it dead, says so, and starts. Without that check a single `kill` would leave a
# station that refuses to start for ever, on a machine nobody can log into -
# which is the failure this whole toolkit exists to prevent.
request 'id: l2' 'step: ./steps/probe.ps1'
step_file probe read-only "Write-Output 'the evidence'"
loop_once
assert_contains "a station killed with SIGTERM leaves a lock the next start clears" \
  "clearing a stale lock" "$LOOP_OUT"
assert_eq "  and that next station runs the request" "idle" "$(published state)"

# =============================================================================
#  12. `undelivered`, and it is not inherited from the previous run
# =============================================================================
# `idle` MEANS THE LOG ARRIVED. The bash loop had this inverted once - anything
# that was not literally `no` became `idle` - so a runner that exited before it
# ever reached delivery was reported as a clean run with a log nobody would
# receive.
plant
step_file probe read-only "Write-Output 'the evidence'"

# PROGRESS OFF FOR THIS SECTION, and the reason is worth writing down because
# it looks like a defect on the way past.
#
# The progress publisher fires on the FIRST in-run poll, not after
# PROGRESS_EVERY seconds - `$lastProgress` starts at DateTime.MinValue, and
# station.sh's LAST_PROGRESS starts at 0, so both twins publish a snapshot of
# the log about one INTERVAL into every run that lasts that long. That is a
# partial log arriving on the far side through a path that is not delivery, so
# with it on, "delivery was neutered and nothing arrived" is not a question this
# section can ask. Turning it off is the honest way to ask it; the progress path
# has its own check below.
EXTRA_ENV=(PROGRESS_EVERY=0)

# First, a run that DOES deliver, so `.station-delivery` holds `yes`.
request 'id: d1' 'step: ./steps/probe.ps1'
loop_once
assert_eq "a delivering run publishes idle" "idle" "$(published state)"

# Now neuter delivery in the payload the station actually runs, and ask again.
# APPENDED, because a later definition wins in PowerShell - so this needs no
# knowledge of how the original is written, and a sed that matched nothing would
# leave the real one in place and make this assertion report a pass it never
# earned.
printf '\nfunction Send-TpLog { return $false }\n' >> "$D/transports/share.psm1"
grep -qxF 'function Send-TpLog { return $false }' "$D/transports/share.psm1" ||
  t_no "the mutation did not reach the planted transport, so the check below proves nothing"
rm -f "$S/scope/ops-logs/"*.txt
request 'id: d2' 'step: ./steps/probe.ps1'
loop_once

assert_eq "a run whose delivery failed publishes undelivered, NOT idle" \
  "undelivered" "$(published state)"
assert_contains "  and says why" "would not take it" "$(published note)"
assert_eq "  and the far side really has nothing" "0" "$(delivered_names | grep -c .)"
assert_eq "  and it is this run being reported" "d2" "$(published id)"

# --- THE VERDICT IS NOT INHERITED FROM THE PREVIOUS RUN ----------------------
# `.station-delivery` is written by run.ps1 at the END. A runner that exits
# BEFORE delivery - refused by its own gate 2, killed, an unknown step - never
# writes it, so whatever the last run left there is still sitting on disk. The
# loop clears it first, and its ABSENCE is what makes `undelivered` the honest
# answer.
#
# Without that clear this run would inherit `yes` and be published as `idle`: a
# clean run, with a log named in the status, for a step that never executed at
# all. That is the single worst lie available to this loop, and it is told to
# somebody who cannot check.
plant
step_file probe read-only "Write-Output 'the evidence'"
step_file deploy action "Write-Output 'changed something'"
EXTRA_ENV=(PROGRESS_EVERY=0)
request 'id: i1' 'step: ./steps/probe.ps1'
loop_once
assert_eq "a delivering run leaves a 'yes' behind" "idle" "$(published state)"

# An action, on a station started with --allow-actions but WITHOUT CONFIRM=yes
# in the request. Gate 3 lets it past; run.ps1's gate 2 refuses it with exit 3,
# so the runner exits long before delivery and writes no record at all.
request 'id: i2' 'step: ./steps/deploy.ps1'
loop_once --allow-actions
assert_eq "a runner that exits before delivery is NOT published as idle" \
  "undelivered" "$(published state)"
assert_contains "  and the note says the runner never reached delivery" \
  "before it reached delivery" "$(published note)"
assert_eq "  and the exit code is the gate's, unchanged" "3" "$(published exit)"
EXTRA_ENV=()

# =============================================================================
#  12b. Progress: a long step is watchable while it runs
# =============================================================================
# Without this a long step is a black box: nothing reaches the far side until it
# finishes, so "running for forty minutes" and "wedged" look identical from the
# only side that can see anything.
plant
# LONG ENOUGH TO OUTLAST THE WAIT, AND NO LONGER. The step has to still be
# running when the assertions read the far side, and a Windows runner is slow
# enough that a 40-second step finished before the first version of this check
# got to look - so it read a DELIVERED log and called it a partial one.
#
# 150 seconds against a 60-second budget is two and a half times the headroom.
# Five minutes was the over-correction, and it cost ten minutes of Windows CI:
# the step is CANCELLED below rather than killed with the station, because a
# station killed with SIGTERM cannot run its own finally and leaves the step
# running to the end.
step_file slow read-only \
  "Write-Output 'the first line'" \
  'foreach ($i in 1..150) { Write-Output "probe $i"; Start-Sleep -Seconds 1 }'
request 'id: pr1' 'step: ./steps/slow.ps1'
( cd "$D" && env TRANSPORT=share "SHARE_DIR=$(winpath "$S")" SHARE_SCOPE=scope \
    "${ROOT_ENV[@]+"${ROOT_ENV[@]}"}" PROGRESS_EVERY=1 \
    "$PS_BIN" -NoProfile -File ./station.ps1 --once --interval 1 ) >/dev/null 2>&1 &
LOOP_PID=$!
# WAIT FOR A PROGRESS PUBLICATION, which is the thing under test.
#
# Neither weaker signal will do, and the first version used both of them. A
# status saying `running` proves nothing: the loop writes one of those BEFORE
# the step starts. A log on the far side proves nothing either: delivery puts
# one there too, at the end. Only `progress:` is written by the progress path
# and by nothing else.
# BOTH HALVES, and each rules out a different wrong answer.
#
# `progress:` alone is satisfied about one second in, by the FIRST snapshot -
# which is the header run.ps1 writes before the child has started. Asserting
# against that fails on "the partial log carries the step's output", because at
# that moment it does not.
#
# The step's output alone is satisfied by DELIVERY, which also puts a log on the
# far side - and that one is complete, so it fails "no footer yet". The first
# version of this check used exactly that, and on Windows it read a delivered
# log and called it partial.
#
# Together they can only be a progress publication carrying the step's own
# output, which is the property. The step outlasts the budget by minutes, so
# delivery cannot be what satisfies it.
progress_carries_output() {
  [ -n "$(published progress)" ] && delivered_body 2>/dev/null | grep -q 'the first line'
}
if ! wait_until 60 progress_carries_output; then
  t_skip "no progress carrying the step's output reached the far side in 60s, so the progress path was NOT exercised"
else
  assert_eq "while a step runs the far side sees state running" "running" "$(published state)"
  assert_contains "  with a line count" "lines" "$(published progress)"
  # THE PARTIAL LOG ITSELF, not just a count. A progress line saying "12 lines"
  # with no log beside it is a number nobody can act on.
  assert_contains "  and the partial log, so the run can actually be followed" \
    "the first line" "$(delivered_body)"
  # AND IT IS NOT COMPLETE. A "partial" log carrying the footer would mean this
  # was reading a finished run and proving nothing about progress at all - which
  # is exactly what it did on Windows before the step was made long enough to
  # outlast the check.
  assert_eq "  and it is genuinely partial - no footer yet" "no" \
    "$(delivered_body | grep -q 'finished UTC' && echo yes || echo no)"
fi

# CANCELLED, NOT KILLED, and the difference is a process left running.
#
# `kill -TERM` on the station does not stop the STEP on Unix: PowerShell cannot
# catch that signal, so the finally that signals the child never runs and the
# step carries on to its end. Measured - five step processes before the kill and
# five after. On Windows the Job Object covers it, which is why this only shows
# up as an orphan on Linux and as ten minutes of wasted CI on Windows.
#
# So this asks the station to cancel, which is its own mechanism and is tested
# in its own section, and only then stops the station.
request 'id: pr1' 'step: ./steps/slow.ps1' 'cancel: yes'
wait_until 30 loop_gone || kill -TERM "$LOOP_PID" 2>/dev/null
wait "$LOOP_PID" 2>/dev/null; LOOP_PID=""

# =============================================================================
#  13. Pinning: only what the operator approved
# =============================================================================
plant
step_file probe read-only "Write-Output 'the evidence'"
request 'id: n1' 'step: ./steps/probe.ps1'

# The same run as loop_once, with pinning on. REQUIRE_PIN goes through the
# environment rather than a flag because that is the only way the station takes
# it - `--pin` is the verb that APPROVES, not the one that enforces, and
# conflating the two is how somebody ends up believing a station is enforcing a
# pin it was never told to enforce.
loop_once_pinned() {
  LOOP_OUT="$(
    cd "$D" && env TRANSPORT=share "SHARE_DIR=$(winpath "$S")" SHARE_SCOPE=scope \
      "${ROOT_ENV[@]+"${ROOT_ENV[@]}"}" REQUIRE_PIN=1 \
      timeout 120 "$PS_BIN" -NoProfile -File ./station.ps1 --once --interval 1 2>&1
  )"
  LOOP_RC=$?
}

loop_once_pinned
assert_eq "with pinning on and nothing approved, a request is refused" \
  "refused" "$(published state)"
assert_contains "  and the reason names --pin" "--pin" "$(published reason)"

( cd "$D" && env TRANSPORT=share "SHARE_DIR=$(winpath "$S")" SHARE_SCOPE=scope \
    "${ROOT_ENV[@]+"${ROOT_ENV[@]}"}" \
    "$PS_BIN" -NoProfile -File ./station.ps1 --pin ) >/dev/null 2>&1
request 'id: n2' 'step: ./steps/probe.ps1'
loop_once_pinned
assert_eq "  and runs once the operator has approved it" "idle" "$(published state)"

# AN EDITED STEP IS A DIFFERENT STEP. Pinning by NAME would wave this through,
# which is the whole reason it pins a hash.
printf "\nWrite-Output 'and something new'\n" >> "$D/steps/probe.ps1"
request 'id: n3' 'step: ./steps/probe.ps1'
loop_once_pinned
assert_eq "  and refuses it again after the file is edited" "refused" "$(published state)"
assert_contains "  naming the file that changed" "probe.ps1" "$(published reason)"

# --- THE PIN FILE IS THE POWERSHELL ONE, and that matters ---------------------
# The two payloads pin different files and each --pin truncates before writing,
# so sharing .station-approved would mean each implementation silently
# unapproved the other's.
assert_eq "pinning writes its own file, not the bash station's" "yes" \
  "$([ -e "$D/.station-approved-ps" ] && echo yes || echo no)"
assert_eq "  and leaves .station-approved alone" "no" \
  "$([ -e "$D/.station-approved" ] && echo yes || echo no)"

# =============================================================================
#  14. The twins publish the same status keys
# =============================================================================
# A control side reads ONE document from either implementation. A key that one
# publishes and the other does not is a control side that works against one
# station and not its twin - and the difference shows up as a field silently
# missing, which reads as "this station is old" rather than as a defect.
plant
step_file probe read-only "Write-Output 'the evidence'"
request 'id: tw1' 'step: ./steps/probe.ps1'
loop_once
PS_KEYS="$(sed -n 's/^\([a-z]*\):.*/\1/p' "$S/scope/status" 2>/dev/null | sort -u | tr '\n' ' ')"

if ! command -v bash >/dev/null 2>&1 || [ ! -x "$HERE/../station/bash/station.sh" ]; then
  t_skip "no bash station to compare against, so the twins were NOT compared"
else
  BD="$WORK/bash-twin"; BS="$WORK/bash-twin-share"
  mkdir -p "$BS/scope"
  bash "$HERE/../station/bootstrap.sh" "$BD" >/dev/null 2>&1
  cat > "$BD/steps/probe.sh" <<'EOS'
#!/usr/bin/env bash
# heliograph-mode: read-only
echo the evidence
EOS
  chmod +x "$BD/steps/probe.sh"
  printf 'id: tw1\nstep: steps/probe.sh\n' > "$BS/scope/request"
  ( cd "$BD" && env TRANSPORT=share "SHARE_DIR=$BS" SHARE_SCOPE=scope ALLOW_ROOT=1 \
      timeout 120 ./station.sh --once --interval 1 ) >/dev/null 2>&1
  SH_KEYS="$(sed -n 's/^\([a-z]*\):.*/\1/p' "$BS/scope/status" 2>/dev/null | sort -u | tr '\n' ' ')"
  if [ -z "$SH_KEYS" ]; then
    t_skip "the bash station published nothing here, so the twins were NOT compared"
  else
    assert_eq "station.ps1 and station.sh publish the same status keys" "$SH_KEYS" "$PS_KEYS"
  fi
fi

# =============================================================================
#  15. The env line splits the same way on both implementations
# =============================================================================
# `station.sh` hands the env line to an `eval` and gets shell word splitting for
# free. `station.ps1` cannot - it evaluates nothing - so it IMPLEMENTS that
# splitting, and an implementation of a rule is a place the rule can be got
# subtly wrong.
#
# THE WAY IT WOULD BE WRONG IS THE BACKSLASH, and on Windows that is not exotic:
# a value is usually a path. `FOO=C:\tmp` unquoted loses the backslash on BOTH
# sides, because outside quotes a shell eats it. Quoted - single OR double - it
# survives on both, because a backslash before `t` is an escape in neither.
#
# Get one of those four wrong and a step receives a different path depending on
# which station ran it, from the same request. Nothing fails; the step just
# looks in the wrong directory and reports honestly about it.
#
# So both are MEASURED against the same inputs rather than argued about, with
# bash's own `eval` as the reference, because that is what the bash station
# actually does.
if ! command -v bash >/dev/null 2>&1; then
  t_skip "no bash, so the two env splitters were NOT compared"
else
  cat > "$WORK/bash-split.sh" <<'EOS'
#!/usr/bin/env bash
eval "A=($1)" 2>/dev/null || { printf 'REFUSED'; exit 0; }
printf '%s' "${A[*]+${A[*]}}"
EOS
  chmod +x "$WORK/bash-split.sh"

  cat > "$WORK/ps-split.ps1" <<PSEOF
\$src = [System.IO.File]::ReadAllText('$(winpath "$PSDIR/station.ps1")')
\$m = [regex]::Match(\$src, '(?s)function Split-EnvLine \{.*?\n\}\n')
if (-not \$m.Success) { Write-Output 'NO-SPLIT-ENVLINE-FOUND'; exit 1 }
Invoke-Expression \$m.Value
\$r = Split-EnvLine -Line \$args[0]
if (\$null -eq \$r) { Write-Output 'REFUSED'; exit 0 }
Write-Output (\$r -join ' ')
PSEOF

  compared=0
  for line in 'FOO=C:\tmp' "FOO='C:\\tmp'" 'FOO="C:\tmp"' 'FOO=a\\b' \
              'HOSTS="a b" PORT=443' "A='x y' B=z" 'ONE=1 TWO=2' 'PAD=one   OUT=2'; do
    want="$(bash "$WORK/bash-split.sh" "$line")"
    got="$( "$PS_BIN" -NoProfile -File "$WORK/ps-split.ps1" "$line" 2>/dev/null | tr -d '\r' )"
    compared=$((compared + 1))
    assert_eq "the two implementations split [$line] identically" "$want" "$got"
  done
  # A COUNT, because a loop over a list that had somehow become empty would
  # assert nothing and read as a clean section.
  assert_eq "  and every case in the table was actually compared" "8" "$compared"
fi


# =============================================================================
#  16. A log can be READ while the capture is still writing it
# =============================================================================
# THIS IS A WINDOWS ASSERTION THAT COSTS NOTHING ON LINUX, and it is here
# because the property it guards is invisible on Linux entirely.
#
# Invoke-CapRun holds the log open for the whole run through
# `[System.IO.File]::AppendText`, which opens with FileShare.Read. A SECOND open
# must also declare a share mode that tolerates the FIRST handle's access, and
# the first handle is a writer - so `File.ReadAllLines` and `Copy-Item`, which
# both open with FileShare.Read, throw a sharing violation on Windows against a
# log that is still being written.
#
# Nothing enforces any of that on Linux, so it worked perfectly here while
# progress NEVER published on Windows - for any step, silently, because the
# read is inside a try/catch that returns quietly. A long run was a black box on
# exactly the platform where a black box is most expensive. Found by the
# conformance run on a real Windows runner, not by reasoning.
#
# Section 12b is the behavioural check and is the one that caught it. This is
# the direct one, so a future reader who breaks the sharing flags gets told what
# they broke rather than "no progress reached the far side".
SHARED="$WORK/shared-read.ps1"
cat > "$SHARED" <<PSEOF
Import-Module '$(winpath "$PSDIR/caplib.psm1")' -Force
\$p = [System.IO.Path]::GetTempFileName()
\$w = [System.IO.File]::AppendText(\$p)   # exactly what Invoke-CapRun holds
\$w.WriteLine('line one'); \$w.WriteLine('line two'); \$w.Flush()
try {
    \$n = (Read-CapSharedLines -Path \$p).Count
    \$d = "\$p.copy"
    [void](Copy-CapSharedFile -Source \$p -Destination \$d)
    # THE COUNT, NOT THE BYTE LENGTH. AppendText uses Environment.NewLine, so
    # the same two lines are 18 bytes on Linux and 20 on Windows - and this
    # assertion is about whether the file could be read and copied at all, not
    # about how long it is.
    \$b = if ((Get-Item \$d).Length -gt 0) { 'nonempty' } else { 'EMPTY' }
    Write-Output "OK \$n \$b"
} catch {
    Write-Output "THREW \$(\$_.Exception.GetType().Name)"
} finally {
    \$w.Close(); Remove-Item \$p,"\$p.copy" -Force -EA SilentlyContinue
}
PSEOF
SHARED_OUT="$( "$PS_BIN" -NoProfile -File "$SHARED" 2>&1 | tr -d '\r' | tail -1 )"
assert_eq "a log held open by the capture can still be read and copied" \
  "OK 2 nonempty" "$SHARED_OUT"

t_summary

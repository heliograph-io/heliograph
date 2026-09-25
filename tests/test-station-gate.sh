#!/usr/bin/env bash
# =============================================================================
#  test-station-gate.sh - what the unattended loop will and will not run
# =============================================================================
# The agent is the part of this toolkit that runs without anyone watching, so
# its default posture is the thing most worth asserting. It is read-only by
# default: a step that declares itself an action is refused unless the operator
# started the loop with --allow-actions.
#
# That default was the other way round for a while, for a real reason - a flag
# typed once at agent start, days before the request it gated, surfaced as a
# silent refusal and wasted the round trip this tooling exists to save. The
# refusal now reaches the far side through station/status within one poll, which
# is what makes a safe default affordable again. So the assertions below check
# the refusal is PUBLISHED, not just that it happened.
#
# Every agent invocation is wrapped in `timeout`: the loop is designed to poll
# forever, and a test that hangs teaches nobody anything.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
ROOT="$(cd "$HERE/.." && pwd)"

TMP="$(mktemp -d)"
trap 'pkill -f "$TMP/tr/station.sh" 2>/dev/null; rm -rf "$TMP"' EXIT

TR="$TMP/tr"
GIT="git -c user.email=ci@example.invalid -c user.name=ci"

"$ROOT/station/bootstrap.sh" "$TR" >/dev/null 2>&1
git init -q --bare "$TMP/origin.git"
( cd "$TR" \
    && git init -q \
    && git remote add origin "$TMP/origin.git" \
    && $GIT add -A \
    && $GIT commit -qm init \
    && $GIT push -q -u origin HEAD ) >/dev/null 2>&1

# Two steps that differ only in what they declare, so every assertion below is
# about the declaration and nothing else.
add_step() {  # add_step <name> <mode>
  cat > "$TR/steps/$1.sh" <<EOF
#!/usr/bin/env bash
# heliograph-mode: $2
echo "ran $1"
EOF
  chmod +x "$TR/steps/$1.sh"
  ( cd "$TR" && sed -i "s|^  # -- add task steps here.*|  $1)  CMD=(./steps/$1.sh) ;;\n&|" run.sh )
}
add_step reader read-only
add_step writer action
( cd "$TR" && $GIT add -A && $GIT commit -qm steps && $GIT push -q ) >/dev/null 2>&1

request() {  # request <id> <step> [envline]
  { echo "id: $1"; echo "step: $2"; [ -n "${3:-}" ] && echo "env: $3"; } > "$TR/station/request"
  ( cd "$TR" && $GIT add -A && $GIT commit -qm "request $1" && $GIT push -q ) >/dev/null 2>&1
}

agent() {  # agent [args...] - one pass, output in OUT, exit code in RC
  RC=0
  OUT="$( cd "$TR" && timeout 60 ./station.sh --once --interval 1 "$@" 2>&1 )" || RC=$?
}

status_field() { sed -n "s/^$1:[[:space:]]*//p" "$TR/station/status" | head -1; }
logs_for() { ls "$TR/ops-logs/$1"-*.txt 2>/dev/null | wc -l; }

# --- the default posture ------------------------------------------------------
# The shipped request has an empty `id`, so a fresh agent starts up and waits.
# Five seconds is plenty to read its banner and nothing is lost by killing it.
banner() { OUT="$( cd "$TR" && timeout 5 ./station.sh --interval 1 "$@" 2>&1 )"; }
banner
assert_contains "the agent says at startup that actions are blocked" "BLOCKED" "$OUT"

request r1 reader
agent
assert_eq "a read-only step runs on a default agent" "1" "$(logs_for reader)"
assert_eq "and the status says it finished" "idle" "$(status_field state)"

request w1 writer "CONFIRM=yes"
agent
assert_eq "an action step is refused on a default agent" "0" "$(logs_for writer)"
assert_contains "and the refusal is said out loud" "REFUSED" "$OUT"
assert_eq "and PUBLISHED, which is what makes the safe default affordable" \
  "refused" "$(status_field state)"
assert_contains "and the reason names the flag that would allow it" \
  "allow-actions" "$(cat "$TR/station/status")"

# --- a step that does not exist says so --------------------------------------
# run.sh answers `--mode` with 2 for no such step and 3 for no declaration. The
# loop read only the printed line, so an unknown step was refused as one that
# "declares no mode ()" - and the reader was told to add a header to a file that
# does not exist.
request u1 no-such-step
agent
assert_eq "an unknown step is refused" "refused" "$(status_field state)"
assert_contains "and the reason says the step is unknown, not that it declares no mode" \
  "unknown step" "$(sed -n 's/^reason:[[:space:]]*//p' "$TR/station/status" | head -1)"

# `net-probe` is the name every page of the documentation sends. It was not
# registered, so the flagship example was refused on every stock station. With
# no HOSTS the step exits 2 and says why, which is still a run and a log.
request n1 net-probe
agent
assert_eq "net-probe, the name the documentation sends, runs on a stock station" \
  "idle" "$(status_field state)"
assert_eq "and it captured a log" "1" "$(logs_for net-probe)"

# --- the operator opting in ---------------------------------------------------
request w2 writer "CONFIRM=yes"
agent --allow-actions
assert_eq "--allow-actions lets the same request through" "1" "$(logs_for writer)"
banner --allow-actions
assert_contains "and the startup banner says so" "ALLOWED" "$OUT"

# CONFIRM is still required by run.sh itself. Two gates, and --allow-actions is
# only the outer one: an action step pushed WITHOUT CONFIRM must still fail.
request w3 writer
agent --allow-actions
assert_eq "without CONFIRM in the request, run.sh still refuses it" "1" "$(logs_for writer)"
assert_eq "and the exit code reaches the status as a failure" "3" "$(status_field exit)"

# --- env promotion: a read-only step turned into a writing one ----------------
# The declaration cannot see this. `env: APPLY=1` is how a plan becomes an apply
# in every wrapper anyone writes, so ACTION_ENV stays as a second recogniser.
request p1 reader "APPLY=1"
agent
assert_eq "a read-only step carrying APPLY=1 is refused by default" "refused" "$(status_field state)"

request p2 reader "APPLY=1"
agent --allow-actions
assert_eq "and allowed when the operator opted in" "2" "$(logs_for reader)"

# --- pinning: opt-in, and off by default --------------------------------------
# REQUIRE_PIN=1 is for an estate that wants "runs only what I approved". It
# costs the thing the unattended loop exists for - a new step now waits for the
# operator - so it is off unless asked for.
assert_eq "pinning is off by default: an unpinned step still runs" "2" "$(logs_for reader)"

request r2 reader
RC=0
OUT="$( cd "$TR" && REQUIRE_PIN=1 timeout 60 ./station.sh --once --interval 1 2>&1 )" || RC=$?
assert_eq "with REQUIRE_PIN=1 and nothing approved, the step is refused" \
  "refused" "$(status_field state)"
assert_contains "and the reason says it is not approved" "not approved" "$(cat "$TR/station/status")"
assert_eq "and it captured nothing" "2" "$(logs_for reader)"

( cd "$TR" && ./station.sh --pin >/dev/null 2>&1 )
assert_eq "--pin writes the approvals locally" "1" \
  "$( [ -f "$TR/.station-approved" ] && echo 1 || echo 0 )"

# Local, and gitignored: an approval recorded in the transport repo could be
# edited from the far side, which is the only side the pin exists to distrust.
assert_eq ".station-approved is gitignored, because trust must not be pushable" "0" \
  "$( cd "$TR" && git check-ignore -q .station-approved && echo 0 || echo 1 )"

request r3 reader
RC=0
OUT="$( cd "$TR" && REQUIRE_PIN=1 timeout 60 ./station.sh --once --interval 1 2>&1 )" || RC=$?
assert_eq "after --pin, the approved step runs" "3" "$(logs_for reader)"

# The point of hashing rather than listing names: an EDIT to an approved step is
# a different step, and the pin must notice.
printf 'echo "changed after approval"\n' >> "$TR/steps/reader.sh"
( cd "$TR" && $GIT add -A && $GIT commit -qm edit && $GIT push -q ) >/dev/null 2>&1
request r4 reader
RC=0
OUT="$( cd "$TR" && REQUIRE_PIN=1 timeout 60 ./station.sh --once --interval 1 2>&1 )" || RC=$?
assert_eq "an approved step that has since changed is refused" "refused" "$(status_field state)"
assert_eq "and did not run" "3" "$(logs_for reader)"
# A refusal is an answer: --once has answered its one request and must exit
# cleanly rather than sitting there polling over a question it has responded to.
assert_eq "and --once exits 0, because a refusal is an answer" "0" "$RC"

# --- delivery: did the log actually leave the machine ------------------------
# Everything above asserts what the loop RUNS. This asserts what the far side
# RECEIVES, which is a different question and was the one nobody was asking.
#
# run.sh used to end at cap_push, which is git unconditionally, so on the relay
# and blob transports a perfect log was captured and never shipped. The status
# said `idle` either way, so from the far side a delivered log and a stranded
# one were the same event.
DELIVERY="$TR/.station-delivery"
delivery_field() { sed -n "s/^$1:[[:space:]]*//p" "$DELIVERY" 2>/dev/null | head -1; }

# Read back from the BARE REMOTE, never the working tree: the tree holds the log
# whether or not it was ever delivered.
remote_logs() { git -C "$TMP/origin.git" ls-tree -r --name-only HEAD 2>/dev/null | grep -c '^ops-logs/.*\.txt$'; }

before="$(remote_logs)"
request d1 reader
agent
assert_eq "a completed run is published as idle" "idle" "$(status_field state)"
assert_eq "and the log actually reached the remote" \
  "$((before + 1))" "$(remote_logs)"
assert_eq "and the runner recorded that it was delivered" "yes" "$(delivery_field delivered)"

# Now break WRITES ONLY, and the distinction is the whole point of the test.
#
# The first attempt at this pointed origin at a path that does not exist, which
# breaks the FETCH as well: the station never saw the request, never ran a step,
# and the assertions passed or failed on a stale marker from the previous run.
# A test that breaks the thing it is not measuring measures nothing.
#
# A pre-receive hook rejects every push while leaving fetch working, so the
# request arrives, the step runs, the log is captured, and only delivery fails -
# which is exactly the state a real credential with read but not write access
# puts a station in, and the one this whole change exists to report.
#
# The status is read from the LOCAL file, deliberately: publish_status writes it
# before pushing, so a station that cannot push can still be seen to have drawn
# the right conclusion. On git the status and the log go the same way, so a far
# side would see neither - which is honest, and is why `undelivered` also gets
# said on the operator's terminal.
cat > "$TMP/origin.git/hooks/pre-receive" <<'EOS'
#!/bin/sh
echo "remote: refusing every write, for the test" >&2
exit 1
EOS
chmod +x "$TMP/origin.git/hooks/pre-receive"

stranded_before="$(remote_logs)"
logs_before="$(logs_for reader)"
request d2 reader
agent
assert_eq "with writes refused, the step still ran and captured a log" \
  "$((logs_before + 1))" "$(logs_for reader)"
assert_eq "the runner recorded that delivery FAILED" "no" "$(delivery_field delivered)"
assert_eq "and the loop published undelivered, not idle" \
  "undelivered" "$(status_field state)"
assert_eq "and nothing reached the remote, so this was a real failure" \
  "$stranded_before" "$(remote_logs)"

# The marker is cleared before each run, so its ABSENCE means "the runner never
# reached delivery". Left stale, the previous run's verdict would be published
# as though it described this one - `undelivered` for a run that produced no log
# at all, or `idle` for one nobody received. Both are lies told to somebody who
# cannot check.
rm -f "$TMP/origin.git/hooks/pre-receive"
printf 'delivered: no\nlog:       stale\ntransport: git\n' > "$DELIVERY"
request d3 reader
agent
assert_eq "a stale 'no' from an earlier run does not leak into the next status" \
  "idle" "$(status_field state)"
assert_eq "because the marker is rewritten by the run that owns it" \
  "yes" "$(delivery_field delivered)"

# --- the request may not choose the channel, however it is spelled ------------
# The first version of this guard matched ` TRANSPORT=` against the RAW env
# line, and quoting walked straight through it: an adversarial review
# reproduced three bypasses in a minute. The check now runs on the PARSED
# assignments, so each of these has to be refused by meaning rather than by
# spelling.
protected_refused() {  # protected_refused <label> <envline>
  request "$2x" reader "$3"
  agent
  assert_eq "$1" "refused" "$(status_field state)"
}
protected_refused "a plain TRANSPORT= in the env line is refused" p1 "TRANSPORT=blob"
protected_refused "a QUOTED assignment is refused too, which the old guard missed" p2 'FOO=1 "TRANSPORT=blob"'
protected_refused "a quote INSIDE the name is refused, which it also missed" p3 'T"RANSPORT"=blob'
protected_refused "PUSH=0 is refused: it would deliver nothing and still read clean" p4 "PUSH=0"
protected_refused "REDACT=0 is refused: the log is committed and cannot be unpublished" p5 "REDACT=0"
protected_refused "LOG_DIR is refused: it moves the log where the loop cannot report it" p6 "LOG_DIR=/tmp"

# The control. Without it every assertion above would pass just as well against
# a station that refused every env line it was given.
request p7 reader "HOSTS=sql01"
agent
assert_eq "an ordinary env line still runs, so the guard is not refusing everything" \
  "idle" "$(status_field state)"

# --- an absent marker is not a delivery --------------------------------------
# `idle` used to be the default for anything that was not literally `no`, so a
# runner that exited before it ever reached delivery - refused as root, an
# unknown step, killed - was published as a clean run with a log nobody would
# ever receive.
request p8 reader
rm -f "$DELIVERY"
# Run the loop with the marker removed and the runner unable to write one.
( cd "$TR" && chmod a-w . 2>/dev/null ) || true
agent
( cd "$TR" && chmod u+w . 2>/dev/null ) || true
d8="$(delivery_field delivered)"
if [ "$d8" = "yes" ]; then
  t_ok "p8: the runner recorded a delivery, so this environment could not stage the case"
else
  assert_eq "a run with no recorded delivery is NOT published as idle" \
    "undelivered" "$(status_field state)"
fi

# --- a transport's own variables are the request's to set, and are not ---------
# This was a real defect. The guard was a denylist of four names - TRANSPORT,
# PUSH, REDACT, LOG_DIR - while `cap_need` in caplib.sh reads every transport's
# configuration straight out of the environment. So RELAY_URL delivered the log
# to somebody else's relay, and RELAY_PEER sealed it to a public key the
# requester chose, because relay.sh passes --peer to `seal seal` as well as to
# `seal open`. A read-only step did it and no gate fired.
for _v in RELAY_URL RELAY_PEER RELAY_IDENTITY SHARE_DIR PIGEONHOLE_ACCOUNT CAP_TRANSPORT ALLOW_ROOT; do
  request "env-$_v" reader "$_v=/tmp/somewhere-else"
  agent
  assert_eq "a request setting $_v is refused" "refused" "$(status_field state)"
done

# ...and the refusal is published with a reason, because a silent one sends the
# reader to the wrong side of the gap.
assert_contains "and the published reason names the variable" \
  "ALLOW_ROOT" "$(sed -n 's/^reason:[[:space:]]*//p' "$TR/station/status" | head -1)"

# --- the guard cannot be outgrown by a new transport --------------------------
# The pattern is reserved by PREFIX, and this asserts that every variable any
# transport actually asks for is covered by it. Add a transport with a new
# prefix and forget to reserve it, and this fails rather than shipping the
# defect again.
_pat="$(sed -n 's/^ *\(TRANSPORT|PUSH|REDACT|LOG_DIR.*\))$/\1/p' "$TR/station.sh" | head -1)"
if [ -z "$_pat" ]; then
  t_no "could not read the reserved-env pattern out of station.sh"
else
  _uncovered=""
  for _name in $(grep -ho 'cap_need [A-Z_][A-Z0-9_]*' "$TR"/transports/*.sh | awk '{print $2}' | sort -u); do
    _hit=0
    _ifs="$IFS"; IFS='|'
    for _alt in $_pat; do
      # shellcheck disable=SC2254
      case "$_name" in $_alt) _hit=1; break ;; esac
    done
    IFS="$_ifs"
    [ "$_hit" = "1" ] || _uncovered="$_uncovered $_name"
  done
  assert_eq "every cap_need variable across all transports is reserved" "" "$_uncovered"
fi

# --- AND THE POWERSHELL TWIN RESERVES THE SAME THINGS -------------------------
# A control side cannot tell which implementation answered a request, so a
# security gate that differs between the two means the same request is refused
# on one machine and honoured on another.
#
# THIS IS NOT HYPOTHETICAL FOR THIS PARTICULAR GATE. The bash side was fixed to
# reserve by prefix while station.ps1 still carried the original four names -
# and by then the PowerShell payload had a relay transport, so RELAY_PEER on
# that station was exactly the redirection the bash fix had just closed.
#
# The twins have diverged on a gate before: three case-sensitivity differences
# in run.ps1, two of them in a security check. That is why this compares them
# rather than reading both and hoping.
PS_STATION="$HERE/../station/powershell/station.ps1"
if [ ! -f "$PS_STATION" ]; then
  t_no "the PowerShell station is missing, so the twin comparison asserted nothing"
else
  # Read from the file the way the bash pattern is read: out of the source, so
  # this cannot pass by agreeing with a copy of the rule kept in the test.
  _pspat="$(sed -n "s/^\$ReservedEnvPattern = '^(\(.*\))\$'$/\1/p" "$PS_STATION" | head -1)"
  if [ -z "$_pspat" ]; then
    t_no "could not read the reserved-env pattern out of station.ps1"
  else
    # The bash pattern uses glob (`CAP_*`); the PowerShell one uses regex
    # (`CAP_.*`). Normalised to compare the RULE rather than the dialect.
    _bnorm="$(printf '%s' "$_pat"   | tr '|' '\n' | sed 's/\*$/.*/' | sort | tr '\n' ' ')"
    _pnorm="$(printf '%s' "$_pspat" | tr '|' '\n' | sort | tr '\n' ' ')"
    assert_eq "both stations reserve exactly the same variables, or one honours what the other refuses" \
      "$_bnorm" "$_pnorm"
  fi

  # AND EVERY POWERSHELL TRANSPORT'S OWN VARIABLES ARE COVERED, the same scan
  # the bash side gets. Test-TpNeed is the PowerShell cap_need.
  _psuncovered=""
  for _name in $(grep -ho "Test-TpNeed -Name '[A-Z_][A-Z0-9_]*'" \
                   "$HERE/../station/powershell/transports/"*.psm1 2>/dev/null \
                 | sed "s/.*-Name '//; s/'.*//" | sort -u); do
    _hit=0
    _ifs="$IFS"; IFS='|'
    for _alt in $_pspat; do
      # The PowerShell pattern is a regex, so `CAP_.*` is matched with grep -E
      # rather than with a glob.
      printf '%s' "$_name" | grep -qE "^$_alt\$" && { _hit=1; }
      [ "$_hit" = "1" ] && break
    done
    IFS="$_ifs"
    [ "$_hit" = "1" ] || _psuncovered="$_psuncovered $_name"
  done
  assert_eq "every Test-TpNeed variable across the PowerShell transports is reserved" \
    "" "$_psuncovered"
fi

t_summary

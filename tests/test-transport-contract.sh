#!/usr/bin/env bash
# =============================================================================
#  test-transport-contract.sh - every transport implements the same verbs
# =============================================================================
# A3 moved every command that crosses the gap behind tp_*, so the loop has one
# copy of the gates rather than one per transport. That only holds while every
# transport actually implements the contract.
#
# A missing verb is not a syntax error in bash. Calling one is "command not
# found", which in a loop running unattended surfaces as the station going quiet
# on a machine nobody can reach. So it is checked here, where somebody is
# listening, rather than there.
#
# Most of this asserts SHAPE: a verb is defined, and a transport that advertises
# an optional capability has actually written it.
#
# tp_put_log is the exception, and it had to be. `tp_put_log() { return 0; }`
# satisfies every shape check here, satisfies conformance property 9 as well
# (that driver runs the git transport), and reproduces precisely the defect the
# verb was added to fix - relay and blob capturing perfect logs and shipping
# nothing. A no-op reporting success IS the failure mode, so for that one verb
# the request each transport would send is asserted, against a fake curl.
#
# Still not a round trip. Behaviour against a real store needs that store, and
# test-pigeonhole.sh already covers the blob primitives.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
TOOLKIT="$(cd "$HERE/../station/bash" && pwd)"

# Required of every transport, no exceptions.
#
# tp_put_log is required rather than optional, and that is the whole point of
# it. Delivering the finished log was git's alone - run.sh called cap_push,
# which is git unconditionally - so relay and blob captured perfect logs and
# shipped nothing at all. A transport that cannot deliver a completed log is
# not a transport; there is no version of this loop worth running without it.
REQUIRED="tp_capabilities tp_init tp_scope tp_revision tp_describe tp_check
          tp_fetch_request tp_put_status tp_put_progress tp_put_log"

# Optional, but a transport that ADVERTISES one must define it. Advertising a
# verb you have not written is worse than not having it: the loop calls it.
OPTIONAL="self:tp_fetch_self live:tp_fetch_request_live"

# Source a transport in a subshell with the loop's globals stubbed, then run one
# command in it.
#
# The stubs matter: a transport that reads a loop global at source time has to
# fail here rather than at start on the far side. They are unused by this script
# itself, which is what SC2034 is about, and that is the point of them.
probe() {  # probe <transport.sh> <command...>
  local tp="$1"; shift
  (
    say() { :; }
    # shellcheck disable=SC2034
    BRANCH=""
    # shellcheck disable=SC2034
    STATUS=""
    # shellcheck disable=SC2034
    REQUEST=""
    # shellcheck disable=SC2034
    REPO_ROOT="$TOOLKIT"
    # shellcheck disable=SC1090
    . "$tp" 2>/dev/null || exit 1
    "$@" 2>/dev/null
  )
}

has_fn() { probe "$1" declare -F "$2" >/dev/null 2>&1 && echo yes || echo no; }

found=0
for tp in "$TOOLKIT"/transports/*.sh; do
  [ -f "$tp" ] || continue
  found=$((found + 1))
  name="$(basename "$tp" .sh)"

  caps="$(probe "$tp" tp_capabilities)"
  assert_eq "$name: sources cleanly and reports capabilities" \
    "0" "$([ -n "$caps" ] && echo 0 || echo 1)"

  for fn in $REQUIRED; do
    assert_eq "$name: defines $fn" "yes" "$(has_fn "$tp" "$fn")"
  done

  for pair in $OPTIONAL; do
    cap="${pair%%:*}"; fn="${pair##*:}"
    case " $caps " in
      *" $cap "*)
        assert_eq "$name: advertises '$cap', so it must define $fn" \
          "yes" "$(has_fn "$tp" "$fn")" ;;
      *)
        t_ok "$name: does not advertise '$cap', so $fn is not required" ;;
    esac
  done
done

# A green run against an empty directory would assert nothing at all, and would
# look exactly like a green run against every transport.
assert_eq "there were transports to check" "0" \
  "$([ "$found" -gt 0 ] && echo 0 || echo 1)"

# The blob transport must NOT claim self-update. There is no repository to pull
# and no working tree to replace, and a station that claimed it could update
# itself and then silently could not is the failure the capability mechanism
# exists to prevent.
case " $(probe "$TOOLKIT/transports/blob.sh" tp_capabilities) " in
  *" self "*) t_no "blob claims self-update, which it cannot do" ;;
  *) t_ok "blob does not claim self-update, which it cannot do" ;;
esac

# --- tp_put_log must actually PUT the log ------------------------------------
# Everything above asserts that a verb is DEFINED. That is not enough for this
# one, and the reason is uncomfortable: `tp_put_log() { return 0; }` satisfies
# every check so far, satisfies conformance property 9 as well - because the
# conformance driver runs the git transport - and reproduces exactly the defect
# the verb was added to fix. A no-op that reports success is the failure mode.
#
# So the two transports the conformance suite cannot reach are exercised here,
# against a fake `curl` on PATH, asserting the REQUEST THEY WOULD SEND. Shape
# rather than a round trip, but the shape is what was missing.
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
cat > "$FAKE/curl" <<'EOS'
#!/usr/bin/env bash
# Record the whole invocation, answer with whatever the caller wants to see.
printf '%s\n' "$*" >> "$FAKE_CALLS"
for a in "$@"; do case "$a" in --data-binary) : ;; esac; done
case " $* " in *' -X PUT '*) printf '201' ;; *' -X POST '*) printf '202' ;; *) printf '200' ;; esac
EOS
chmod +x "$FAKE/curl"

# --- blob ---------------------------------------------------------------------
BLOB_CALLS="$FAKE/blob.calls"; : > "$BLOB_CALLS"
printf 'the finished log\n' > "$FAKE/reader-20260908T120000Z.txt"
(
  export PATH="$FAKE:$PATH" FAKE_CALLS="$BLOB_CALLS"
  export PIGEONHOLE_ACCOUNT=acct PIGEONHOLE_LANE=lane1 PIGEONHOLE_SAS='sv=x&sig=y'
  REPO_ROOT="$TOOLKIT"
  # caplib first: tp_init calls cap_need, and without it the check that reports
  # a missing variable is itself "command not found" - which fails tp_init for
  # the wrong reason and would make these assertions pass on a broken transport.
  # shellcheck disable=SC1091
  . "$TOOLKIT/caplib.sh"
  # shellcheck disable=SC1091
  . "$TOOLKIT/transports/blob.sh"
  tp_init >/dev/null 2>&1
  tp_put_log "$FAKE/reader-20260908T120000Z.txt" "msg"
) >/dev/null 2>&1
blob_put="$(grep -- '-X PUT' "$BLOB_CALLS" 2>/dev/null | tail -1)"

assert_eq "blob: tp_put_log actually issues a PUT, rather than returning 0" \
  "1" "$([ -n "$blob_put" ] && echo 1 || echo 0)"
assert_contains "blob: it PUTs the log under the lane" "lane1" "$blob_put"
assert_contains "blob: under logs/, so a finished log is not overwritten by the next run's progress" \
  "logs/reader-20260908T120000Z.txt" "$blob_put"
assert_contains "blob: and it sends the log FILE, not the status body" \
  "reader-20260908T120000Z.txt" "$blob_put"

# --- relay --------------------------------------------------------------------
# heliograph-seal is faked too: this asserts what the transport ASKS for, which
# is the part that can silently be wrong. The cryptography has its own tests.
RELAY_CALLS="$FAKE/relay.calls"; : > "$RELAY_CALLS"
SEAL_CALLS="$FAKE/seal.calls"; : > "$SEAL_CALLS"
cat > "$FAKE/seal" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SEAL_CALLS"
for i in $(seq 1 $#); do
  if [ "${!i}" = "--out" ]; then j=$((i + 1)); printf 'sealed\n' > "${!j}"; fi
done
exit 0
EOS
chmod +x "$FAKE/seal"
printf 'the finished log\n' > "$FAKE/relay-log.txt"
(
  export PATH="$FAKE:$PATH" FAKE_CALLS="$RELAY_CALLS" SEAL_CALLS="$SEAL_CALLS"
  export RELAY_URL=https://relay.invalid RELAY_ESTATE=e1 RELAY_STATION=s1 \
         RELAY_TOKEN=tok RELAY_IDENTITY="$FAKE/id" RELAY_PEER="$FAKE/peer" \
         RELAY_SEAL="$FAKE/seal" RELAY_STATE="$FAKE/relay.state"
  : > "$FAKE/id"; : > "$FAKE/peer"
  # Read by relay.sh at source time to default RELAY_SEAL and RELAY_STATE.
  # shellcheck disable=SC2034
  REPO_ROOT="$TOOLKIT"
  # shellcheck disable=SC1091
  . "$TOOLKIT/caplib.sh"
  # shellcheck disable=SC1091
  . "$TOOLKIT/transports/relay.sh"
  tp_init >/dev/null 2>&1
  tp_put_log "$FAKE/relay-log.txt" "msg"
) >/dev/null 2>&1
seal_log="$(grep -- '--kind log' "$SEAL_CALLS" 2>/dev/null | tail -1)"

assert_eq "relay: tp_put_log actually seals something, rather than returning 0" \
  "1" "$([ -n "$seal_log" ] && echo 1 || echo 0)"
assert_contains "relay: it seals the log under its OWN kind, so the far side can tell a finished log from a progress snapshot" \
  "--kind log" "$seal_log"
assert_contains "relay: station to control, never the other way" "--dir s2c" "$seal_log"
assert_contains "relay: and it seals the log FILE" "relay-log.txt" "$seal_log"
assert_eq "relay: and POSTs the sealed envelope" "1" \
  "$([ -n "$(grep -- '-X POST' "$RELAY_CALLS" 2>/dev/null)" ] && echo 1 || echo 0)"

# =============================================================================
#  A CANCELLED RUN'S PARTIAL LOG, which two transports dropped on the floor
# =============================================================================
# `tp_put_status <body> <msg> [partial-log]`. The third argument is what a
# CANCELLED run captured before it was killed - somebody stopped a step, and
# that output is the evidence they stopped it for. It is the last thing the far
# side will ever see of that run.
#
# git, share and bundle honoured it. blob and relay did not, and had not since
# either was written: neither even NAMED the parameter, so nothing a reader saw
# in those functions said it was being ignored. It was recorded as a known
# defect rather than found by a test, which is the gap this section closes.
#
# THE SHAPE CHECK IS GENERIC, so the next transport cannot repeat it. A
# behaviour check per transport would only ever cover the transports somebody
# remembered to add.
for tp in "$TOOLKIT"/transports/*.sh; do
  name="$(basename "$tp" .sh)"
  body="$(sed -n '/^tp_put_status()/,/^}/p' "$tp")"
  assert_eq "$name: tp_put_status reads its third argument, the cancelled run's partial log" \
    "yes" "$(printf '%s' "$body" | grep -qE '\$\{?3' && echo yes || echo no)"
done

# --- blob: it reaches the store -----------------------------------------------
printf 'the partial log\n' > "$FAKE/cancelled-20260908T120000Z.txt"
: > "$BLOB_CALLS"
(
  export PATH="$FAKE:$PATH" FAKE_CALLS="$BLOB_CALLS"
  export PIGEONHOLE_ACCOUNT=acct PIGEONHOLE_LANE=lane1 PIGEONHOLE_SAS='sv=x&sig=y'
  # shellcheck disable=SC2034
  REPO_ROOT="$TOOLKIT"
  # shellcheck disable=SC1091
  . "$TOOLKIT/caplib.sh"
  # shellcheck disable=SC1091
  . "$TOOLKIT/transports/blob.sh"
  tp_init >/dev/null 2>&1
  tp_put_status 'state: cancelled' 'msg' "$FAKE/cancelled-20260908T120000Z.txt"
) >/dev/null 2>&1
blob_partial="$(grep -- '-X PUT' "$BLOB_CALLS" 2>/dev/null | grep -- 'cancelled-20260908T120000Z' | tail -1)"
assert_eq "blob: a cancelled run's partial log is actually uploaded" \
  "1" "$([ -n "$blob_partial" ] && echo 1 || echo 0)"
# UNDER logs/, where a reader looks. Publishing it anywhere else is publishing
# it nowhere: the control side lists one prefix.
assert_contains "blob:   under logs/, where every other log is" \
  "logs/cancelled-20260908T120000Z.txt" "$blob_partial"
# AND THE STATUS STILL WENT. A partial log that displaced the status would
# leave the far side reading `running` for ever on a run that was cancelled.
assert_eq "blob:   and the status went too, rather than being displaced by it" "1" \
  "$([ -n "$(grep -- '-X PUT' "$BLOB_CALLS" 2>/dev/null | grep -c 'status')" ] && echo 1 || echo 0)"

# --- relay: it is sealed and sent ---------------------------------------------
printf 'the partial log\n' > "$FAKE/relay-cancelled.txt"
: > "$SEAL_CALLS"; : > "$RELAY_CALLS"
(
  export PATH="$FAKE:$PATH" FAKE_CALLS="$RELAY_CALLS" SEAL_CALLS="$SEAL_CALLS"
  export RELAY_URL=https://relay.invalid RELAY_ESTATE=e1 RELAY_STATION=s1 \
         RELAY_TOKEN=tok RELAY_IDENTITY="$FAKE/id" RELAY_PEER="$FAKE/peer" \
         RELAY_SEAL="$FAKE/seal" RELAY_STATE="$FAKE/relay2.state"
  # shellcheck disable=SC2034
  REPO_ROOT="$TOOLKIT"
  # shellcheck disable=SC1091
  . "$TOOLKIT/caplib.sh"
  # shellcheck disable=SC1091
  . "$TOOLKIT/transports/relay.sh"
  tp_init >/dev/null 2>&1
  tp_put_status 'state: cancelled' 'msg' "$FAKE/relay-cancelled.txt"
) >/dev/null 2>&1
seal_partial="$(grep -- 'relay-cancelled.txt' "$SEAL_CALLS" 2>/dev/null | tail -1)"
assert_eq "relay: a cancelled run's partial log is actually sealed and sent" \
  "1" "$([ -n "$seal_partial" ] && echo 1 || echo 0)"
# `log` AND NOT `progress`. The run is over, and the kind is a SIGNED field, so
# it is how the control side knows it has the last of it without trusting the
# relay's labelling.
assert_contains "relay:   as kind log, because the run is over and the reader has to know that" \
  "--kind log" "$seal_partial"
assert_eq "relay:   and it took its own sequence number, or the receiver drops it as a replay" "2" \
  "$(grep -c -- '--kind' "$SEAL_CALLS" 2>/dev/null)"

# --- the two verbs only start.sh calls ----------------------------------------
# tp_preflight and tp_sync are optional, so they are not in REQUIRED, and they
# are not tied to a declared capability, so they are not in OPTIONAL either.
# That leaves them unguarded, and losing tp_preflight is not a loud failure: a
# git station would quietly drop from "proves it can PUSH" to "can reach the
# remote", which is the exact difference between catching a read-only deploy key
# now and catching it after an hour-long step has captured a log it cannot ship.
assert_eq "git defines tp_preflight, so the write check cannot be lost silently" \
  "yes" "$(has_fn "$TOOLKIT/transports/git.sh" tp_preflight)"
assert_eq "git defines tp_sync, so the payload is still brought up to date before the loop starts" \
  "yes" "$(has_fn "$TOOLKIT/transports/git.sh" tp_sync)"

# --- tp_describe is PRINTED, so it may not carry a secret ---------------------
# station.sh says `transport: $(tp_describe)` at start, straight to the terminal
# and to whatever journal is capturing it, and start.sh puts it in the preflight
# table. cap_redact never sees either: that is a stream filter on the capture
# path, and neither line goes down it.
#
# git's returned `git remote get-url origin` verbatim, and
# `https://ci-user:glpat-...@host/repo` is a shape the transports page tells
# people they will meet. So every station using that form printed its own token
# on its first line of output, once per restart, into a log somebody keeps.
DESC="$(
  cd "$(mktemp -d)" || exit 1
  git init -q . 2>/dev/null
  git -c user.email=ci@example.com -c user.name=ci commit -q --allow-empty -m init 2>/dev/null
  git remote add origin 'https://ci-user:glpat-SECRETVALUE@git.invalid/org/repo.git' 2>/dev/null
  # Read by caplib at source time. Unused by this script itself, which is what
  # SC2034 is about, and that is the point of it.
  # shellcheck disable=SC2034
  REPO_ROOT="$TOOLKIT"
  # shellcheck disable=SC1091
  . "$TOOLKIT/caplib.sh"
  # shellcheck disable=SC1091
  . "$TOOLKIT/transports/git.sh"
  tp_init >/dev/null 2>&1
  tp_describe
)"
assert_eq "git: tp_describe never returns a token, because both callers print it" \
  "" "$(printf '%s' "$DESC" | grep -o 'glpat-SECRETVALUE')"
assert_contains "git: and the rest of the remote survives, or the line identifies nothing" \
  "git.invalid/org/repo.git" "$DESC"

t_summary

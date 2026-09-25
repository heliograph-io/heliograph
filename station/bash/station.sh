#!/usr/bin/env bash
# =============================================================================
#  station.sh - run this ONCE on the control node and walk away
# =============================================================================
#     ./station.sh                    # poll, run, push, repeat - READ-ONLY
#     ./station.sh --once             # do one requested run, then exit
#     ./station.sh --interval 15      # seconds between polls (default 5)
#     ./station.sh --allow-actions    # also run steps that declare themselves actions
#     ./station.sh --allow-root       # permit running as root (see SAFETY below)
#     ./station.sh --pin              # approve the current steps, for REQUIRE_PIN=1
#
#  It watches this branch for a new request, runs the step, and pushes the log
#  back - so the loop stops needing a human to relay each run:
#
#     Claude   edits station/request (new id), pushes ─────────────▶ repo
#     station    sees it within seconds, runs ./run.sh
#              pushes station/status "running" ────────────────────▶ repo
#              run.sh pushes ops-logs/<step>-<UTC>.txt ──────────▶ repo
#              pushes station/status "idle exit=N" ────────────────▶ repo
#     Claude   polls, reads the log, decides the next step ◀──────
#
#  The operator types one command, once. Everything after that is git.
#
#  THE TRIGGER IS `id`, NOT "a new commit". Documentation and step edits land in
#  this branch constantly; if any commit triggered a run, the station would fire on
#  all of them. It runs only when the `id:` line in station/request changes, so a
#  run is always something someone asked for on purpose.
#
#  STOPPING: `stop: yes` in station/request, or Ctrl-C. The stop flag is honoured
#  from the far side precisely because nobody is sitting at this terminal.
#
#  WATCHING: while a step runs the station pushes the partial log every
#  PROGRESS_EVERY seconds (default 60, 0 disables) with a line count and the last
#  real line, so a long run can be followed instead of waited out.
#
#  CANCELLING: `cancel: yes` kills the step that is running right now; `cancel:
#  <id>` kills it only if that id is the one running, so a stale cancel cannot
#  reap a later run. The step runs in its own process group in the background and
#  the loop keeps polling while it works - an hour-long step no longer makes the
#  station deaf for an hour. A cancelled run publishes state `cancelled` and leaves
#  whatever the log had reached, which is usually the evidence you wanted anyway.
#
#  SAFETY, and this loop's whole posture is in this paragraph.
#
#  READ-ONLY BY DEFAULT. A step says what it is in its own file
#  (`# heliograph-mode: read-only` or `action`); this asks run.sh --mode and
#  refuses an action outright unless started with --allow-actions. The refusal
#  is PUBLISHED to station/status within one poll, so the far side learns in
#  seconds rather than waiting out a round trip - which is what makes a safe
#  default affordable. An action that is allowed still has to carry CONFIRM=yes
#  in the request's `env:` and get past run.sh's own gate. ACTION_ENV catches
#  the case a declaration cannot see: `env: APPLY=1` turning a read-only step
#  into a writing one.
#
#  NOT AS ROOT. The account this runs as IS the blast radius - there are no
#  other credentials in this toolkit - so running it as root makes that radius
#  the whole machine. Refused unless --allow-root (or ALLOW_ROOT=1) says the
#  estate has no other option.
#
#  REQUIRE_PIN=1 refuses any step whose file hash the operator has not approved
#  with `./station.sh --pin`. Off by default: it makes every new step wait for the
#  operator, which is the relaying this loop exists to remove. It is here for an
#  estate that wants "runs only what I approved" and knows what it costs.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1
# shellcheck source=caplib.sh disable=SC1091
. "$REPO_ROOT/caplib.sh"

# Kept so the station can re-exec itself into a newer version of this file - see
# the self-update check in the loop. The option parser below consumes "$@".
ORIG_ARGS=("$@")
SELF_HASH="$(sha256sum "$REPO_ROOT/station.sh" 2>/dev/null | cut -d' ' -f1)"

# WHICH PAYLOAD IS RUNNING, published so it can be compared without asking.
#
# `HEAD` cannot answer this: every status commit and every log advances it, so
# two stations on the same payload report different revisions within a minute
# of each other. Branches carry independent copies of the station and
# self-update pulls only its own, so drift between stations is real - and with
# nothing published it is discovered by a step behaving differently on one
# machine, which is the most expensive way to find out.
#
# The runner and the capture, because those are what a step's behaviour
# actually rests on. Not the steps themselves: those are SUPPOSED to differ per
# branch, and including them would make the digest change for the ordinary
# reason and stop meaning anything.
payload_digest() {
  cat "$REPO_ROOT/station.sh" "$REPO_ROOT/run.sh" "$REPO_ROOT/caplib.sh" 2>/dev/null |
    sha256sum 2>/dev/null | cut -c1-12
}
PAYLOAD="$(payload_digest)"

INTERVAL="${INTERVAL:-5}"
ONCE=0
PIN_ONLY=0
# 1 = the station may run steps that change state, when the request asks for one.
#
# DEFAULT 0. This was 1 for a while and the reason was a real one: the flag is
# typed once at station start, often days before the request it gates, and a
# forgotten one surfaced as a silent "refused" long after the push - wasting
# exactly the round trip this tooling exists to save.
#
# What retired that argument was publish_status "refused": the refusal now
# reaches the far side, with its reason and the flag that would allow it, within
# one poll interval. The cost of a safe default fell from a wasted day to a few
# seconds, and an unattended loop that can change infrastructure because a file
# changed is not a default anything should ship.
ALLOW_ACTIONS="${ALLOW_ACTIONS:-0}"
# Running as root makes the blast radius the whole machine - see SAFETY above.
#
# EXPORTED, and it was not, which made `--allow-root` do half of what it says.
#
# run.sh is a separate process and has its OWN root gate, reading ALLOW_ROOT
# from its environment. Set as a plain shell variable this reached the loop's
# check and nothing else, so `./station.sh --allow-root` started perfectly and
# then refused every single step with exit 5 - publishing `undelivered` with
# "the runner exited before it reached delivery", which names the symptom and
# not one word of the cause.
#
# `ALLOW_ROOT=1 ./station.sh` worked the whole time, because that form is
# already in the environment. So the variable worked and the flag documented
# beside it did not, which is the worst of the two to get wrong: the flag is
# what the appliance and minimal-image case in SAFETY tells people to use, and
# that case is precisely the one with no other account to fall back to.
export ALLOW_ROOT="${ALLOW_ROOT:-0}"
# 1 = refuse any step whose file hash is not in .station-approved.
REQUIRE_PIN="${REQUIRE_PIN:-0}"

REQUEST="station/request"
STATUS="station/status"
STATE_FILE=".station-state"        # gitignored: the last id we ran
APPROVED=".station-approved"       # gitignored: hashes the operator has approved
LOCK=".station.lock"

# --- the trusted set: who may command this station ---------------------------
#
# OFF UNLESS THE OPERATOR PLANTED ONE. A station with no TRUST_SET behaves
# exactly as it always has, which matters because every station in the field
# today has none and upgrading one means somebody standing at a machine.
#
# THE FILE IS LOCAL AND GITIGNORED, for the same reason .station-approved is:
# recorded in the transport repo it could be edited from the far side, and the
# far side is the only side a trust root exists to distrust. What gets PUBLISHED
# is a read-only copy, in the status and at station/trusted-set, so the estate
# owner can audit who may command their machine without asking us.
#
# TRUST_SEAL is heliograph-seal, the one binary already argued for past the
# station boundary. Ed25519 verification is not something bash and coreutils can
# do, and the relay transport already ships it. Nothing NEW is required on the
# far side: a station without the binary cannot use a trusted set, and refuses
# to start with one configured rather than accepting everything quietly.
TRUST_SET="${TRUST_SET:-}"
TRUST_SEAL="${TRUST_SEAL:-${RELAY_SEAL:-$REPO_ROOT/heliograph-seal}}"
TRUST_PUBLISH="station/trusted-set"
# Every request id this station has ACTED ON. The replay defence, and it is on
# disk precisely so it survives a restart - a station restarts when the machine
# does, which is exactly when nobody is watching. `.station-state` holds only
# the LAST id, so a request from the day before yesterday, replayed, ran again.
SEEN_IDS=".station-seen-ids"
SEEN_IDS_KEEP="${SEEN_IDS_KEEP:-2000}"

# --- compat: a transport repo bootstrapped before the rename -----------------
# This loop was called the "agent" until the vocabulary changed, and its paths
# with it. A transport repo is a SEPARATE repo on a machine nobody here can
# reach, so it does not get upgraded when this one does: the far side pulls
# whatever it pulls, and an operator who bootstrapped last month still has
# `agent/request` sitting in their checkout.
#
# Refusing that would present as the loop going deaf - polling happily,
# answering nothing, with the request they just pushed apparently ignored.
# That is the exact failure this whole toolkit exists to prevent, so the old
# paths are read when the new ones are absent, and the fact is said ONCE in
# the log rather than every poll.
#
# Removed at the first major version, not before.
if [ ! -e "$REQUEST" ] && [ -e "agent/request" ]; then
  REQUEST="agent/request"
  STATUS="agent/status"
  HELIOGRAPH_COMPAT_PATHS=1
fi
[ -e "$STATE_FILE" ]  || [ ! -e ".agent-state" ]    || STATE_FILE=".agent-state"
[ -e "$APPROVED" ]    || [ ! -e ".agent-approved" ] || APPROVED=".agent-approved"
[ -e "$LOCK" ]        || [ ! -e ".agent.lock" ]     || LOCK=".agent.lock"

while [ $# -gt 0 ]; do
  case "$1" in
    --once)          ONCE=1 ;;
    --interval)      INTERVAL="$2"; shift ;;
    --allow-actions) ALLOW_ACTIONS=1 ;;
    --no-actions)    ALLOW_ACTIONS=0 ;;   # the default; kept so old invocations still work
    --allow-root)    ALLOW_ROOT=1 ;;
    --pin)           PIN_ONLY=1 ;;
    -h|--help)       sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# --- the transport -----------------------------------------------------------
# Every command that crosses the gap lives behind tp_*, so this loop no longer
# knows what it is talking to. TRANSPORT selects one; git is the default and
# the only one this build ships.
# EXPORTED, because run.sh is a separate process and now loads a transport of
# its own in order to deliver the finished log. Left unexported, every station
# would hand its runner the git default and a relay station would capture
# perfect logs and push them nowhere - which is the exact defect tp_put_log
# exists to fix, reintroduced one variable lower down.
export TRANSPORT="${TRANSPORT:-git}"
TP_FILE="$REPO_ROOT/transports/${TRANSPORT}.sh"
[ -f "$TP_FILE" ] || { echo "station: no transport named '$TRANSPORT' (looked for $TP_FILE)" >&2; exit 2; }
# shellcheck source=transports/git.sh disable=SC1090
. "$TP_FILE"

# Read at START, so a station can say what it will NOT be able to do later,
# while there is still somebody listening. A station that cannot self-update is
# a working station; one that discovers it when an update is needed and nobody
# is there is a wasted round trip.
TP_CAPS=" $(tp_capabilities) "

# tp_init validates whatever this transport needs locally and resolves SCOPE:
# the thing a run is bound to. For git that is a branch, for the blob transport
# a lane. The loop does not care which, and neither should its output.
tp_init || exit 2
SCOPE="$(tp_scope)"
[ -n "$SCOPE" ] || { echo "station: the transport reported no scope" >&2; exit 2; }

# Kept as `branch:` in the published status because the far side reads that key
# and a station in the field must stay readable by a control that predates this.
BRANCH="$SCOPE"

# One station per checkout. Two would double-run every request and race on push.
#
# --pin takes no lock, deliberately: approving a new step is exactly the thing
# an operator does WHILE the loop is running, and a pin that refused because the
# station was up would be useless at the only moment it is wanted.
if [ "$PIN_ONLY" = "0" ]; then
  if [ -e "$LOCK" ]; then
    pid="$(cat "$LOCK" 2>/dev/null || echo)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "station: already running here as pid $pid (remove $LOCK if that is wrong)" >&2; exit 3
    fi
    echo "station: clearing a stale lock from pid ${pid:-?}"
  fi
  echo $$ > "$LOCK"
fi

say() { printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

# Start a step in the background, in its OWN process group, so the cancel path
# can signal the whole tree - run.sh, the step, and whatever those invoke.
# Killing the child alone would orphan its grandchildren.
#
# `setsid` is util-linux and is not on a stock macOS, which this toolkit is meant
# to run on. `set -m` is the portable equivalent: with job control on, each
# background job gets its own process group. Preferring setsid keeps the common
# case free of job-control notices on stderr.
if command -v setsid >/dev/null 2>&1; then
  run_detached() { setsid "$@" & }
else
  set -m
  run_detached() { "$@" & }
fi

RUNNING=0
CHILD=""
cleanup() {
  # Only if this process took it. A --pin run holds no lock, and removing one it
  # never owned would unlock a real station that is mid-run.
  [ "$PIN_ONLY" = "0" ] && rm -f "$LOCK"
  # The step runs in its own session now, so Ctrl-C on the station no longer
  # reaches it. Signal the group explicitly: an operator who interrupts the
  # station expects the run to stop, not to carry on detached and push a log
  # afterwards with nothing watching it.
  if [ "$RUNNING" = "1" ] && [ -n "$CHILD" ]; then
    say "interrupted mid-run - signalling the step, the log may not have been pushed"
    kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
  fi
  say "stopped"
  exit 0
}
trap cleanup INT TERM

# --- request parsing ---------------------------------------------------------
# Deliberately dumb key: value. No YAML parser, nothing to install, and the file
# stays readable by whoever opens it next.
# Read a field from the request the transport last handed us, NOT from a file.
#
# A file is a git detail. A relay or an object store hands over a document with
# no path at all, and a `field` that reads $REQUEST would work only for the one
# transport it was written against - which is exactly the drift the interface
# exists to prevent.
REQ_BODY=""
field() { printf '%s\n' "$REQ_BODY" | sed -n "s/^${1}:[[:space:]]*//p" | head -1; }

# A step is an action if its OWN FILE says so, or if the request's env turns it
# into one.
#
# The declaration is read through `run.sh --mode` rather than by parsing the
# step table here. The mapping from a step name to a file belongs to run.sh, and
# a second copy of it would drift the first time somebody registered a step that
# takes arguments - drift that shows up as a writing step being waved through.
#
# The name-based list this replaced had a plainer hole: `cleanup-disk` matched
# nothing in `apply deploy destroy reset` and ran as a diagnostic.
#
# ACTION_ENV is a substring match against the request's env line, and stays
# because a declaration cannot see it: a step that plans is read-only until
# `env: APPLY=1` makes it apply. Add whatever does that on your branch.
ACTION_ENV="${ACTION_ENV:-APPLY=1 CONFIRM=yes DESTROY=1 FORCE=1 WRITE=1}"
# step_mode prints the declared mode AND returns run.sh's exit code: 0 for a
# declared step, 3 for an undeclared one, 2 for no such step. The code is the
# only thing that tells the last two apart.
step_mode() {
  local out rc
  out="$(./run.sh --mode "$1" 2>/dev/null)"; rc=$?
  printf '%s\n' "${out%%$'\n'*}"
  return "$rc"
}
step_file() { ./run.sh --file "$1" 2>/dev/null | head -1; }

# The newest log this step could have written, relative to the payload, or
# nothing.
#
# THE LABEL, NOT THE STEP NAME, and that distinction has now cost twice. run.sh
# names a log for the step file's basename without its extension, so a step
# sent as a PATH - `heliograph send steps/probe.sh`, which is the documented
# way to send one - writes ops-logs/probe-<stamp>.txt and never
# ops-logs/steps/probe.sh-<stamp>.txt.
#
# Both call sites globbed on the raw step, and the two failures did not look
# alike. At delivery it published `log: <none>`, which is at least a thing
# somebody can see. At the progress call site it published NOTHING AT ALL:
# publish_progress takes the empty result and returns on its first line, so
# every step sent by path went back to being the black box the progress path
# exists to open, on every transport, with no error, no log line and no symptom
# to notice. The delivery site was found and fixed; this one was not, because
# an absence is not a symptom.
#
# SO IT IS DERIVED ONCE AND CALLED TWICE. The correct derivation already
# existed, twenty lines below the call site that was not using it. A third
# caller copying it by hand would get it wrong the same way, and nothing would
# say so. station.ps1's Find-StepLog is this same function, with this same
# comment, so the twins answer a request identically.
#
# This is the FALLBACK and the guess. run.sh records the path it actually
# delivered, and that record is the authority wherever it exists.
step_log() {  # step_log <step>
  local label
  label="$(basename -- "$1")"
  label="${label%.sh}"
  label="${label%.ps1}"
  [ -n "$label" ] || return 0
  # shellcheck disable=SC2012
  ls -t -- ops-logs/"${label}"-*.txt 2>/dev/null | head -1
}
is_action_step() {
  local s="$1" a
  [ "$(step_mode "$s")" = "action" ] && return 0
  for a in $ACTION_ENV; do
    case "${ENVLINE:-}" in *"$a"*) return 0 ;; esac
  done
  return 1
}

# --- pinning: run only what the operator approved -----------------------------
# The hashes live in a LOCAL, gitignored file. Recorded in the transport repo
# they could be edited from the far side, which is the only side a pin exists to
# distrust - the approval would then travel with the change it is supposed to
# catch.
#
# The pinned set is everything a request can cause to execute: the step itself,
# the runner, the capture library and the helpers a step sources. Hashing rather
# than listing names is the point - an edit to an approved step is a different
# step, and the pin notices.
#
# It does NOT cover station.sh, which self-updates on pull. Say so in the docs
# rather than implying a boundary that is not there.
# --- the replay ledger: an id is used once, and that survives a restart -------
#
# `.station-state` records the LAST id, which is what stops the same request
# firing on every poll. It is not replay protection: a request from two days
# ago, put back, has an id that is not the last one, so it ran again with
# --allow-actions and CONFIRM=yes already satisfied - and on the relay the
# sequence counter caught that, while on git, share, blob, bundle and object
# store nothing did.
#
# THE LEDGER IS A FILE, and that is the requirement. An in-memory window forgets
# when the station restarts, and a station restarts when the machine does, which
# is exactly when nobody is watching.
#
# It is LOCAL and gitignored, for the reason .station-approved is: recorded in
# the transport repo, the far side could delete a line and replay the request it
# named.
seen_id() {  # seen_id <id>; true if this station has already acted on it
  [ -f "$SEEN_IDS" ] || return 1
  grep -qxF "$1" "$SEEN_IDS" 2>/dev/null
}
remember_id() {  # remember_id <id>
  printf '%s\n' "$1" >> "$SEEN_IDS" 2>/dev/null || {
    # A LEDGER THAT COULD NOT BE WRITTEN IS NOT A LEDGER. Said out loud rather
    # than swallowed: a full disk or a read-only mount would otherwise leave
    # replay protection off with nothing to say so, and the relay's sequence
    # file taught this repository that lesson once already.
    say "warn: could not record request id in $SEEN_IDS - replay protection is not being written down"
    return 1
  }
  # Trimmed, because this grows for ever otherwise and it is read on every
  # request. Keeping the most recent N is right: an id is a UTC stamp plus a
  # step name, so the oldest are the least likely to be offered again, and the
  # transports that can replay at all cannot reach back past their own
  # retention.
  local n
  n="$(wc -l < "$SEEN_IDS" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt $((SEEN_IDS_KEEP * 2)) ]; then
    tail -n "$SEEN_IDS_KEEP" "$SEEN_IDS" > "$SEEN_IDS.$$.tmp" 2>/dev/null &&
      mv -f "$SEEN_IDS.$$.tmp" "$SEEN_IDS" 2>/dev/null
    rm -f "$SEEN_IDS.$$.tmp" 2>/dev/null
  fi
  return 0
}

pin_hash() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
pin_write() {
  local f n=0
  : > "$APPROVED"
  for f in run.sh caplib.sh lib/*.sh steps/*; do
    [ -f "$f" ] || continue
    printf '%s  %s\n' "$(pin_hash "$f")" "$f" >> "$APPROVED"
    n=$((n + 1))
  done
  say "approved $n files into $APPROVED"
  say "re-run ./station.sh --pin after any step changes, or the loop will refuse them"
}
pin_check() {  # pin_check <stepfile>; prints the first unapproved path
  local f
  # `./steps/x.sh` and `steps/x.sh` are the same file and hash identically, but
  # the approval is matched as a whole line, so the spelling has to agree.
  # run.sh's step table writes the `./` form; pin_write's glob does not.
  set -- "${1#./}"
  for f in run.sh caplib.sh lib/*.sh "$1"; do
    [ -f "$f" ] || continue
    grep -qxF "$(pin_hash "$f")  $f" "$APPROVED" 2>/dev/null || { printf '%s\n' "$f"; return 1; }
  done
  return 0
}

if [ "$PIN_ONLY" = "1" ]; then
  pin_write
  exit 0
fi

# The account is the blast radius, and an unattended loop is the worst place to
# find that out afterwards. Checked once at startup rather than per run: this
# process does not change uid, and a loop that would refuse every request should
# say so before the operator walks away rather than a day later in a status file.
cap_refuse_root || { rm -f "$LOCK"; exit 5; }

# --- the action mode, published rather than inferred -------------------------
# Whether this station will run a state-changing step is decided by
# --allow-actions at startup and holds for the whole process. It is on no
# request and it was in no published document, so the far side's only way to
# answer "can this station make changes" was to infer it from the logs already
# in the repo - and that is wrong in both directions. A station restarted
# without the flag still has action logs sitting there, and a station started
# with it may never have been asked for one. Getting that answer wrong is not
# cosmetic: it is the field somebody reads to decide whether an estate is safe
# to point at.
#
# ARG PARSING IS OVER BY HERE, so this is settled once rather than re-derived at
# every transition. --allow-actions and --no-actions are both handled above and
# nothing changes it afterwards.
if [ "$ALLOW_ACTIONS" = "1" ]; then ACTIONS=allowed; else ACTIONS=refused; fi

# --- status, pushed so the far side can see what is happening ----------------
# Two extra commits per run. Worth it: without the "running" one, a long step is
# indistinguishable from a station that never woke up.
publish_status() {
  local state="$1" id="$2" step="$3" extra="${4:-}" alsofile="${5:-}"
  mkdir -p "$(dirname "$STATUS")"
  # A killed step leaves its log modified in the working tree, and progress
  # pushes have made that file TRACKED - so unless it is committed here, every
  # later `pull --rebase` refuses on a dirty tree and the station wedges with the
  # cancellation never reaching the far side. Found by cancelling a run that had
  # been publishing progress.
  [ -n "$alsofile" ] && [ -f "$alsofile" ] || alsofile=""
  {
    echo "state:    $state"
    echo "id:       $id"
    echo "step:     $step"
    echo "host:     $(hostname -f 2>/dev/null || hostname)"
    echo "branch:   $BRANCH"
    echo "utc:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "actions:  $ACTIONS"
    [ -n "$PAYLOAD" ] && echo "payload:  $PAYLOAD"
    # WHO MAY COMMAND THIS STATION, published on every transition.
    #
    # This is rule 4 of the trusted set, and it is the one the estate owner
    # actually uses: they can audit the set from their own transport, with the
    # CLI, without asking us. A key appearing that nobody authorised is then
    # independently detectable rather than something they have to trust us to
    # notice.
    if [ -n "$TRUST_SET" ]; then
      echo "trust:    $(trust_field digest)"
      echo "trust-serial: $(trust_field serial)"
      echo "trust-members: $(trust_members_line)"
    fi
    [ -n "$extra" ] && echo "$extra"
  } > "$STATUS"
  tp_put_status "$(cat "$STATUS")" "station: $state ($id) ***NO_CI***" "$alsofile" || \
    say "status push failed (will retry on the next transition)"
}

# --- progress, pushed WHILE a step runs --------------------------------------
# A long step used to be a black box: nothing reached the repo until it finished,
# so "running for forty minutes" and "wedged" looked identical from the far side.
# This pushes the partial log periodically so the run can be watched as it goes.
#
# NO PULL, NO REBASE, DELIBERATELY. The step is appending to that log through an
# open file descriptor; a rebase would rewrite the file underneath it and the
# appends would carry on at a stale offset, corrupting the very evidence we are
# trying to publish. So this only ever pushes, and a rejected push is simply
# retried next time - run.sh's own cap_push reconciles properly at the end.
#
# The runner still owns the log. This publishes a snapshot of it and never writes
# to it, so the ownership rule the whole toolkit rests on is intact.
PROGRESS_EVERY="${PROGRESS_EVERY:-60}"      # seconds; 0 disables
publish_progress() {
  local id="$1" step="$2" started="$3" logfile="$4"
  [ -n "$logfile" ] && [ -f "$logfile" ] || return 0
  local lines last
  lines="$(wc -l < "$logfile" 2>/dev/null || echo 0)"
  # The last non-blank, non-divider line says more about where a step is than a
  # line count does - it is usually the probe currently in flight.
  last="$(grep -vE '^[[:space:]]*$|^-{5,}|^={5,}' "$logfile" 2>/dev/null | tail -1 | cut -c1-160)"
  mkdir -p "$(dirname "$STATUS")"
  {
    echo "state:    running"
    echo "id:       $id"
    echo "step:     $step"
    echo "host:     $(hostname -f 2>/dev/null || hostname)"
    echo "branch:   $BRANCH"
    echo "utc:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Published here too, not only on transitions. A station mid-run is exactly
    # when a fleet view is being looked at, and a column that empties for the
    # duration of a long step is a column nobody trusts.
    echo "actions:  $ACTIONS"
    echo "started:  $started"
    echo "progress: ${lines} lines"
    echo "log:      $logfile"
    [ -n "$last" ] && echo "last:     $last"
  } > "$STATUS"
  tp_put_progress "$(cat "$STATUS")" "station: progress ($id) ${lines} lines ***NO_CI***" "$logfile" || \
    say "progress push rejected (remote moved) - will retry; the final push reconciles"
}

# --- the trusted set ----------------------------------------------------------
#
# CHECKED AT STARTUP, WHILE SOMEBODY IS STILL LISTENING. A station configured
# with a trusted set it cannot read would refuse every request afterwards, on a
# machine nobody can log into, for a reason nothing had said out loud. That is
# the exact shape of the defect RELAY_PEER had: readable was checked, usable was
# not, and every verification failed silently for a week.
#
# It refuses to START rather than carrying on without one. A station that was
# told to use a trusted set and then quietly did not is one whose owner believes
# an assurance the mechanism is not providing.
trust_show() { "$TRUST_SEAL" trust show --set "$TRUST_SET" 2>&1; }
trust_field() { trust_show | sed -n "s/^$1:[[:space:]]*//p" | head -1; }
trust_line() {
  local sh; sh="$(trust_show)"
  printf '%s' "$(printf '%s\n' "$sh" | sed -n 's/^\(anchor\|member\):[[:space:]]*\([^ ]*\)[[:space:]]*\([^ ]*\).*/\2=\3/p' | tr '\n' ' ')"
}
trust_members_line() {
  # READ AS A FIELD, not reassembled. This was a sed pipeline over `trust show`
  # and it lower-cased REVOKED, so the line this station published differed from
  # the PowerShell station's for the same set - and an owner grepping their
  # estate for REVOKED would have found it on one and not the other. There is
  # one renderer now, in Go, and both stations print what it gives them.
  trust_field members
}

if [ -n "$TRUST_SET" ]; then
  if [ ! -x "$TRUST_SEAL" ]; then
    echo "station: TRUST_SET is set but heliograph-seal is not at $TRUST_SEAL." >&2
    echo "         A trusted set is verified with Ed25519, which bash and coreutils" >&2
    echo "         cannot do. Set TRUST_SEAL to the binary, or unset TRUST_SET." >&2
    echo "         Running with a trusted set that cannot be checked is not an" >&2
    echo "         option this station offers." >&2
    rm -f "$LOCK"; exit 2
  fi
  if [ ! -r "$TRUST_SET" ]; then
    echo "station: cannot read the trusted set at $TRUST_SET." >&2
    echo "         Plant it here, on this machine:" >&2
    echo "           $TRUST_SEAL trust init --set $TRUST_SET \\" >&2
    echo "             --estate <estate> --station <station> --anchor <control public identity>" >&2
    rm -f "$LOCK"; exit 2
  fi
  if ! TRUST_DIGEST="$("$TRUST_SEAL" trust digest --set "$TRUST_SET" 2>&1)"; then
    echo "station: the trusted set at $TRUST_SET will not parse: $TRUST_DIGEST" >&2
    echo "         Every request would be refused. Re-plant it with trust init." >&2
    rm -f "$LOCK"; exit 2
  fi
fi

# publish_trusted_set writes the auditable copy the estate owner reads.
#
# A COPY, never the authority. The authoritative set is the gitignored local
# file; this one lives in the transport repo where the far side can edit it, and
# editing it changes nothing at all. Publishing it is what lets an owner see a
# key appearing that nobody authorised, without asking us and without logging
# into the machine.
publish_trusted_set() {
  [ -n "$TRUST_SET" ] || return 0
  mkdir -p "$(dirname "$TRUST_PUBLISH")" 2>/dev/null
  {
    echo "# Published by the station. The authority is a local file this repo"
    echo "# cannot reach; editing this copy changes nothing. Compare it against"
    echo "# your own with 'heliograph doctor'."
    cat "$TRUST_SET"
  } > "$TRUST_PUBLISH" 2>/dev/null || true
}

say "station up on $BRANCH at $(hostname -f 2>/dev/null || hostname), polling every ${INTERVAL}s"
say "transport: $(tp_describe)"
# Said at START rather than discovered later. A station that cannot update
# itself is a working station; one that finds that out when an update is needed,
# with nobody on this side to tell, has cost a round trip.
case "$TP_CAPS" in
  *" self "*) : ;;
  *) say "note: this transport cannot update the station. To change it, re-plant." ;;
esac
if [ "${HELIOGRAPH_COMPAT_PATHS:-0}" = "1" ]; then
  say "compat: reading agent/request and writing agent/status, because this"
  say "        transport repo predates the rename. Re-run bootstrap.sh to move"
  say "        to station/request; nothing else changes and the loop is unaffected."
fi
if [ "$ALLOW_ACTIONS" = "1" ]; then
  say "state-changing steps: ALLOWED - started with --allow-actions, still gated by CONFIRM in the request"
else
  say "state-changing steps: BLOCKED (the default) - a step declaring 'action' is refused"
fi
if [ "$REQUIRE_PIN" = "1" ]; then
  if [ -f "$APPROVED" ]; then
    say "pinning: ON - only the $(wc -l < "$APPROVED") files approved in $APPROVED will run"
  else
    say "pinning: ON, nothing approved yet - every request is refused until ./station.sh --pin"
  fi
fi
say "request 'stop: yes' or Ctrl-C to finish, 'cancel: yes' to kill a running step"
# Read before the trusted-set publish below, which names it so that a `starting`
# status does not claim the station has handled nothing.
LAST_ID_AT_START="$(cat "$STATE_FILE" 2>/dev/null || echo)"
if [ -n "$TRUST_SET" ]; then
  say "trusted set: $(trust_line)"
  say "  the anchor changes only here: ./heliograph-seal trust anchor --set $TRUST_SET --anchor <key>"
  publish_trusted_set
  # PUBLISHED AT STARTUP WHEN IT HAS CHANGED, and only then.
  #
  # The set otherwise reaches the far side on the next TRANSITION, which is fine
  # for a change that arrived as a request - the station publishes the outcome
  # anyway. It is not fine for one made HERE, with `trust anchor`, because that
  # is the recovery path: the estate owner rotates the anchor at the machine
  # precisely when the keys that could have sent a request are the problem. With
  # nothing published, `heliograph doctor` would go on reporting a match against
  # a digest from before the rotation - the alarm silent in the direction that
  # reassures.
  #
  # ONLY WHEN IT HAS CHANGED, because publishing on every start would overwrite
  # the last run's `exit:` and `log:` with a `starting` that carries neither, and
  # a station restarts for ordinary reasons.
  TRUST_PUBLISHED=".station-trust-published"
  _tp_now="$(trust_field digest)"
  _tp_last="$(cat "$TRUST_PUBLISHED" 2>/dev/null || echo)"
  if [ -n "$_tp_now" ] && [ "$_tp_now" != "$_tp_last" ]; then
    [ -n "$_tp_last" ] && say "the trusted set changed while this station was down - publishing it"
    publish_status "starting" "$LAST_ID_AT_START" ""
    printf '%s\n' "$_tp_now" > "$TRUST_PUBLISHED" 2>/dev/null || true
  fi
else
  say "trusted set: none configured - this station accepts whatever its transport verifies"
fi
LAST_ID="$(cat "$STATE_FILE" 2>/dev/null || echo)"
[ -n "$LAST_ID" ] && say "last request handled here: $LAST_ID"

FAILS=0
CLAIMED=0
while :; do
  # A fetch failure is a blip, not a reason to die - this loop is meant to
  # outlive a flapping link. Report it, back off a little, carry on.
  if ! REQ_BODY="$(tp_fetch_request)"; then
    FAILS=$((FAILS + 1))
    [ $((FAILS % 12)) = 1 ] && say "fetch failed (${FAILS}x) - still trying"
    sleep "$INTERVAL"; continue
  fi
  [ "$FAILS" != "0" ] && { say "fetch recovered"; FAILS=0; }

  # Bring a newer payload in, if this transport can. 0 = something changed,
  # 1 = nothing to do, 2 = it could not be done. A 2 is not fatal: a station
  # that cannot update itself is still a working station.
  # Only if this transport offers it. A station that cannot self-update is a
  # working station, and calling a verb a transport has declared it does not
  # have would be asking a question whose answer is already known.
  case "$TP_CAPS" in
    *" self "*) tp_fetch_self; TP_SELF=$? ;;
    *)          TP_SELF=1 ;;
  esac
  if [ "$TP_SELF" = "2" ]; then
    say "pull --rebase failed - working tree may be dirty; leaving it alone"
    sleep "$INTERVAL"; continue
  fi
  if [ "$TP_SELF" = "0" ]; then
    say "updated: $(tp_revision)"

    # Self-update. Without this, a fix to station.sh cannot take effect while the
    # station is running it, and the operator has to be told to restart - which
    # defeats the point of them starting it once and walking away. Worse, bash
    # reads a script incrementally, so editing this file underneath a running
    # loop can corrupt execution outright.
    #
    # Re-exec at this exact point, immediately after a clean pull and never
    # mid-run, so the replacement starts from a known state. exec keeps the PID,
    # so the lock has to go first or the new process refuses to start seeing
    # "another station" that is really itself.
    NEW_HASH="$(sha256sum "$REPO_ROOT/station.sh" 2>/dev/null | cut -d' ' -f1)"
    if [ -n "$NEW_HASH" ] && [ "$NEW_HASH" != "$SELF_HASH" ]; then
      say "station.sh changed - restarting into the new version"
      rm -f "$LOCK"
      exec "$REPO_ROOT/station.sh" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    fi
  fi

  # THE BODY THE TRANSPORT HANDED US, not a file on disk.
  #
  # This was `[ -f "$REQUEST" ]`, and it made the whole transport interface a
  # fiction for anything but git. blob and relay return the request document on
  # stdout and create no local file at all, so a station on either fetched a
  # perfectly good request, found no `station/request` beside it, and threw the
  # request away - every poll, forever, while reporting nothing wrong. A
  # relay station has never been able to run a step.
  #
  # CLAIM THE BRANCH, once, after the first good fetch.
  #
  # A branch cut from another carries that branch's station/status, which
  # names the other branch and describes another machine's last run. The
  # control side refuses to send to a branch whose status names a different
  # one, because by that status no station reads it. So a station that has
  # just started here publishes its own, rather than waiting for a request the
  # control side will not send until it does.
  #
  # ONLY THEN. A status that already names this branch is this station's last
  # run, and a restart must not overwrite its exit and log with a `starting`
  # that carries neither. And only over git, the one transport where a scope is
  # cut from another and carries its files.
  if [ "$CLAIMED" = "0" ] && [ "$TRANSPORT" = "git" ]; then
    CLAIMED=1
    PUBLISHED_FROM="$(sed -n 's/^branch:[[:space:]]*//p' "$STATUS" 2>/dev/null | head -1)"
    if [ -n "$PUBLISHED_FROM" ] && [ "$PUBLISHED_FROM" != "$BRANCH" ]; then
      say "the published status is from '$PUBLISHED_FROM', not '$BRANCH' - publishing this station's own"
      publish_status "starting" "$LAST_ID_AT_START" ""
    fi
  fi

  # git is unaffected: its tp_fetch_request cats that same file, so an absent
  # or empty request yields an empty body here exactly as before.
  [ -n "$REQ_BODY" ] || { sleep "$INTERVAL"; continue; }

  if [ "$(field stop)" = "yes" ]; then
    say "stop requested in $REQUEST"
    publish_status "stopped" "$(field id)" "" ""
    cleanup
  fi

  ID="$(field id)"
  [ -n "$ID" ] || { sleep "$INTERVAL"; continue; }
  [ "$ID" = "$LAST_ID" ] && { sleep "$INTERVAL"; continue; }

  STEP="$(field step)"
  ENVLINE="$(field env)"
  [ -n "$STEP" ] || STEP="$(sed -n 's/^DEFAULT_STEP="\(.*\)"/\1/p' run.sh | head -1)"

  say "request $ID -> step '$STEP'${ENVLINE:+  env: $ENVLINE}"

  # Every refusal below takes the same shape: say it here, PUBLISH it with a
  # reason the far side can act on, and record the id so the same request is not
  # re-refused every poll. The publishing is the part that matters - a refusal
  # nobody can see is indistinguishable from a station that died.
  refuse() {  # refuse <reason for the status file> <what to say locally>
    say "REFUSED: $2"
    publish_status "refused" "$ID" "$STEP" "reason:   $1"
    LAST_ID="$ID"
    echo "$ID" > "$STATE_FILE"
    [ "$ONCE" = "1" ] && cleanup
  }

  # --- a trusted-set change, which is an act and not a step -------------------
  #
  # IT RIDES IN THE REQUEST DOCUMENT, so it costs no new transport verb. Every
  # transport already carries a request; a second fetch on the relay would be
  # worse than awkward, because collection deletes and asking twice eats the
  # queue.
  #
  # It is verified INDEPENDENTLY of however the request arrived. The signature
  # is over the change, by a key in the set, so a git station with a trusted set
  # gets the same guarantee a relay station does - the transport carried it and
  # did not vouch for it.
  #
  # THE STEP PATH IS NOT REACHED. A change is one signed act; the control side
  # refuses to write a request that carries both, and this refuses to run one.
  if printf '%s\n' "$REQ_BODY" | grep -q '^trust-op:'; then
    if [ -z "$TRUST_SET" ]; then
      refuse "this station has no trusted set, so there is nothing for a trusted-set change to change. The operator plants one on the machine with 'heliograph-seal trust init'" \
             "a trusted-set change arrived and this station has no trusted set"
      sleep "$INTERVAL"; continue
    fi
    TRUST_IN="$(mktemp)" || { sleep "$INTERVAL"; continue; }
    printf '%s\n' "$REQ_BODY" > "$TRUST_IN"
    TRUST_OUT="$("$TRUST_SEAL" trust apply --set "$TRUST_SET" --in "$TRUST_IN" 2>&1)"
    TRUST_RC=$?
    rm -f "$TRUST_IN"
    case "$TRUST_RC" in
      0)
        say "TRUSTED SET: $TRUST_OUT"
        publish_trusted_set
        publish_status "idle" "$ID" "" "reason:   trusted set updated: ${TRUST_OUT#applied }"
        LAST_ID="$ID"; echo "$ID" > "$STATE_FILE"; remember_id "$ID"
        [ "$ONCE" = "1" ] && cleanup
        sleep "$INTERVAL"; continue ;;
      *)
        # EVERY REFUSAL IS PUBLISHED WITH THE REASON THE VERIFIER GAVE, which
        # names the key and says what was wrong with it. "refused" alone sends
        # somebody to re-plant a station that is working perfectly.
        refuse "${TRUST_OUT#refused }" "trusted-set change refused: ${TRUST_OUT#refused }"
        sleep "$INTERVAL"; continue ;;
    esac
  fi

  # --- the signed scope: target, expiry, mode and id --------------------------
  #
  # A signature over "run this" is not enough, and each of these closes one gap
  # that a signature alone left open. All four are fields of the request
  # document, so on a sealed transport they are already inside the signature -
  # enforcing them here is what turns that into scope.

  # TARGET: a request written for one station, replayed at another. The relay
  # binds estate and station in its envelope; every other transport had nothing,
  # so a request lifted out of one transport repo was good in any of them.
  TARGET="$(field target)"
  if [ -n "$TARGET" ] && [ "$TARGET" != "$SCOPE" ]; then
    refuse "this request names target '$TARGET' and this station is '$SCOPE'" \
           "request $ID was written for '$TARGET', not for this station"
    sleep "$INTERVAL"; continue
  fi

  # EXPIRY: a captured request stops being valid. Without it, one taken out of a
  # transport repo is good for ever, and --allow-actions plus CONFIRM=yes were
  # decided days before it.
  #
  # STRING COMPARISON ON RFC3339 UTC, deliberately. `date -d` is GNU-only and
  # this runs on macOS too; a fixed-width Z-suffixed timestamp sorts
  # lexicographically in exactly the order it sorts chronologically, which is
  # why that format is used everywhere else in this toolkit.
  EXPIRES="$(field expires)"
  if [ -n "$EXPIRES" ]; then
    NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$NOW_UTC" \> "$EXPIRES" ]; then
      refuse "this request expired at $EXPIRES and it is now $NOW_UTC" \
             "request $ID expired at $EXPIRES"
      sleep "$INTERVAL"; continue
    fi
  fi

  # REPLAY: an id this station has already acted on.
  #
  # SURVIVES A RESTART, which is the whole point. `.station-state` holds only
  # the LAST id, so a request from two days ago, replayed, ran again with every
  # gate already satisfied - and after a restart even the last id was the only
  # thing remembered. The ledger is a file.
  if seen_id "$ID"; then
    refuse "request id '$ID' has already been acted on here, and an id is used once" \
           "request $ID is a replay: this station has already acted on that id"
    sleep "$INTERVAL"; continue
  fi

  # THE EXIT CODE IS KEPT, because run.sh answers two different questions with
  # it: 2 is "there is no such step", 3 is "the step declares no mode". Reading
  # only the printed line made an unknown step look like a step with no mode,
  # so the refusal told the reader to add a header to a file that does not
  # exist - about `net-probe`, the name every page of the documentation sends.
  MODE="$(step_mode "$STEP")"; MODE_RC=$?
  if [ "$MODE_RC" = "2" ]; then
    refuse "unknown step '$STEP': run.sh does not register it and there is no step file at that path. The operator lists the registered steps with ./run.sh --list; a step file in the transport repo can be sent by its path, e.g. steps/<name>.sh" \
           "'$STEP' is not a registered step or a step file"
    sleep "$INTERVAL"; continue
  fi

  # MODE: the request says what it expected the step to be.
  #
  # A step file edited from read-only to action between authoring and running
  # would otherwise carry the earlier decision's authority. The declaration in
  # the file still decides what the gates do; this only refuses a request whose
  # author was looking at something else.
  WANT_MODE="$(field mode)"
  if [ -n "$WANT_MODE" ] && [ "$WANT_MODE" != "$MODE" ]; then
    refuse "the request was signed for a '$WANT_MODE' step and '$STEP' declares '$MODE'. The step changed after the request was written" \
           "request $ID expected '$STEP' to be $WANT_MODE and it declares $MODE"
    sleep "$INTERVAL"; continue
  fi

  case "$MODE" in
    read-only|action) ;;
    *)
      # run.sh would refuse this too, and its message is better. Catching it
      # here means the far side gets a status rather than an exit code buried in
      # a log it has to go and find.
      # THE REMEDY IS FOR THE SIDE THAT READS THIS. "see run.sh --mode" sends
      # the reader to a command on the machine they cannot log into, which is
      # the whole reason there is a status document at all. The person reading
      # it is the person who wrote the step, and what they need is the line to
      # add. run.sh's own message already says this; the published one did not.
      refuse "step '$STEP' declares no mode ($MODE), so it will not run. Add '# heliograph-mode: read-only' (measures, changes nothing) or '# heliograph-mode: action' (changes state, needs CONFIRM=yes) in its first 30 lines" \
             "'$STEP' does not declare 'heliograph-mode: read-only' or 'action', so it will not run"
      sleep "$INTERVAL"; continue ;;
  esac

  if is_action_step "$STEP" && [ "$ALLOW_ACTIONS" != "1" ]; then
    refuse "step changes state; restart the station with --allow-actions to permit it" \
           "'$STEP'${ENVLINE:+ with env '$ENVLINE'} changes state, and this station is read-only (the default)"
    sleep "$INTERVAL"; continue
  fi

  if [ "$REQUIRE_PIN" = "1" ]; then
    if ! UNPINNED="$(pin_check "$(step_file "$STEP")")"; then
      refuse "'$UNPINNED' is not approved in $APPROVED - the operator runs ./station.sh --pin to approve it" \
             "'$STEP' is not approved: $UNPINNED is new or has changed since the last --pin"
      sleep "$INTERVAL"; continue
    fi
  fi

  # WHO SIGNED THE REQUEST, if the transport could establish it. Written by
  # `heliograph-seal open --author-out`, read here, and carried into the run so
  # the log itself says who asked - see cap_header. An archive that can only say
  # "the estate asked" cannot answer the first question anybody puts to it
  # during an incident.
  REQUEST_BY=""
  if [ -n "$TRUST_SET" ] && [ -r "$REPO_ROOT/.station-request-author" ]; then
    REQUEST_BY="$(tr -d '\n\r' < "$REPO_ROOT/.station-request-author" 2>/dev/null)"
  fi
  export HELIOGRAPH_REQUEST_BY="$REQUEST_BY"

  publish_status "running" "$ID" "$STEP" "${REQUEST_BY:+by:       $REQUEST_BY}"
  RUNNING=1
  START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # CLEARED BEFORE THE RUN, so its ABSENCE means something.
  #
  # run.sh writes this at the end to say whether the log got out. Left over from
  # the previous run it is worse than useless: a runner that exits before
  # delivery - refused as root, an unknown step, killed - would leave the last
  # run's verdict in place and this loop would publish it as if it described
  # this one. Publishing `undelivered` for a run that produced no log at all,
  # or `idle` for one that produced a log nobody received, are both lies told to
  # somebody who cannot check.
  rm -f "$REPO_ROOT/.station-delivery"
  # RECORDED BEFORE THE RUN, NOT AFTER, and the difference is a duplicate
  # execution. If the station is killed mid-step - the machine reboots, somebody
  # closes the terminal - the id written after `wait` was never written, so on
  # restart the same request is new again and a state-changing step runs a
  # second time. An id is used once, and "once" has to include the attempt.
  remember_id "$ID"
  # run.sh owns the log, the timestamps and the log push. The station only decides
  # WHEN it runs - that separation is the same one steps and runners already have.
  #
  # THE STEP RUNS IN ITS OWN SESSION, IN THE BACKGROUND, so this loop stays
  # responsive while it works. Before this, a step that took an hour made the
  # station deaf for an hour: `cancel` could not be heard, and every later request
  # queued behind a run nobody wanted any more. run_detached (above) gives the
  # step its own process group, so the whole tree - run.sh, the step, and
  # whatever those invoke - can be signalled together; killing just the child
  # would orphan whatever it spawned.
  if [ -n "$ENVLINE" ]; then
    # `env: CONFIRM=yes FOO=bar` has to split into separate assignments, so this
    # cannot simply be quoted. Plain word-splitting cannot be the whole answer
    # either: `env: HOSTS="a b" PORTS=443` then reaches env as four words, the
    # first assignment and three commands, and the step dies with
    #     env: 'b': No such file or directory        exit 127
    # which reads as a broken step rather than as a malformed request. A value
    # with a space in it is not exotic - HOSTS is the toolkit's own documented
    # example of one.
    #
    # So: split the line the way a shell would, honouring quotes, but refuse
    # anything that could DO something rather than assign something. The
    # request file is already a trusted control channel - it names the step to
    # run - but "trusted" is not a reason to hand it a subshell, and a refusal
    # naming the character costs one round trip less than a surprise.
    case "$ENVLINE" in
      *'$'* | *'`'* | *';'* | *'&'* | *'|'* | *'<'* | *'>'* | *'('* )
        say "REFUSED: env line contains a shell metacharacter, which this does not evaluate"
        say "  env: $ENVLINE"
        say "  Use plain NAME=value pairs; quote a value that contains spaces."
        publish_status "refused" "$ID" "$STEP" "reason:   env line contains a shell metacharacter"
        LAST_ID="$ID"; echo "$ID" > "$STATE_FILE"
        [ "$ONCE" = "1" ] && cleanup
        continue ;;
    esac
    eval "ENVARR=($ENVLINE)" 2>/dev/null || {
      say "REFUSED: env line is not parseable as NAME=value pairs"
      say "  env: $ENVLINE"
      publish_status "refused" "$ID" "$STEP" "reason:   env line is not parseable"
      LAST_ID="$ID"; echo "$ID" > "$STATE_FILE"
      [ "$ONCE" = "1" ] && cleanup
      continue
    }

    # A REQUEST MAY NOT SET ANYTHING THAT CONFIGURES CAPTURE, DELIVERY,
    # REDACTION OR IDENTITY. Those are settled when the station is started.
    #
    # The env line reaches run.sh through `env`, so every name in it becomes a
    # variable the runner reads - and `cap_need` in caplib.sh reads its value
    # straight out of the environment (`eval "val=\${$name:-}"`). That is how
    # every transport is configured, which makes the whole of a transport's
    # configuration settable by a request unless it is reserved here.
    #
    # THIS USED TO BE A LIST OF FOUR NAMES AND THAT WAS THE BUG. TRANSPORT,
    # PUSH, REDACT and LOG_DIR were reserved; RELAY_URL, RELAY_PEER, SHARE_DIR
    # and the rest were not, and each of those reaches the same end by another
    # road:
    #
    #   TRANSPORT       redirects where the log is delivered, or names a file
    #                   that gets sourced. The operator chose the channel
    #   PUSH            PUSH=0 captures and delivers NOTHING while the run still
    #                   looks clean from here - the exact defect tp_put_log
    #                   exists to remove, handed to whoever can write a request
    #   REDACT          REDACT=0 turns off secret masking on a log that is about
    #                   to be committed and cannot be unpublished
    #   LOG_DIR         moves the log somewhere this loop will not find it
    #   RELAY_URL       delivers the log to somebody else's relay
    #   RELAY_PEER      seals the log to a public key the requester chose:
    #                   relay.sh passes it to BOTH `seal open` and `seal seal`
    #   SHARE_DIR       the same redirection on a share station
    #   PIGEONHOLE_*    and on a blob station
    #   TRUST_SET       names the file that decides WHO MAY COMMAND THIS
    #                   STATION. A request that could set it would point the
    #                   station at a set the requester wrote, which is the
    #                   trust-root bypass the set exists to close, reintroduced
    #                   one variable lower down. It is reserved by the TRUST_
    #                   prefix, the same way and for the same reason as the
    #                   transports
    #
    # SO IT IS RESERVED BY PREFIX, NOT BY NAME. A new transport that introduces
    # a new prefix must add it here, and tests/test-station-gate.sh fails if it
    # does not: it reads this pattern and checks every `cap_need` name in
    # station/bash/transports/ against it. A denylist that has to be remembered
    # is a denylist that will be forgotten.
    #
    # CHECKED AFTER THE eval, ON THE PARSED ARRAY, and that is the whole point.
    # An earlier version matched ` TRANSPORT=` against the raw line, and
    # quoting walked straight through it: `FOO=1 "TRANSPORT=relay"` and
    # `T"RANSPORT"=relay` both fail that test and both come out of the eval as a
    # plain TRANSPORT assignment. A guard applied before the parser is a guard
    # against the spelling rather than against the meaning.
    for _assign in ${ENVARR[@]+"${ENVARR[@]}"}; do
      # RESERVED_ENV_PATTERN - read by tests/test-station-gate.sh. Keep on one line.
      case "${_assign%%=*}" in
        TRANSPORT|PUSH|REDACT|LOG_DIR|ALLOW_ROOT|ALLOW_ACTIONS|CAP_*|RELAY_*|SHARE_*|PIGEONHOLE_*|OBJSTORE_*|BLOB_*|BUNDLE_*|TRUST_*)
          say "REFUSED: the env line sets ${_assign%%=*}, which the request may not choose"
          say "  env: $ENVLINE"
          say "  Capture, delivery, redaction and identity are settled when the"
          say "  station is started, not per request. That covers TRANSPORT, PUSH,"
          say "  REDACT, LOG_DIR, the gates, and every transport's own variables."
          publish_status "refused" "$ID" "$STEP" \
            "reason:   the env line sets ${_assign%%=*}, which configures capture, delivery, redaction or identity and is settled at station start, not per request"
          LAST_ID="$ID"; echo "$ID" > "$STATE_FILE"
          [ "$ONCE" = "1" ] && cleanup
          continue 2 ;;
      esac
    done
    run_detached env "${ENVARR[@]}" ./run.sh "$STEP"
  else
    run_detached ./run.sh "$STEP"
  fi
  CHILD=$!
  CANCELLED=0
  # What `cancel:` said when this run started. A cancel that was ALREADY in the
  # file cannot have been meant for a run that had not begun, and acting on it
  # would reap the next request the moment it starts: seen in testing as a step
  # that finished cleanly and was still published as cancelled, because the
  # `cancel: yes` that stopped its predecessor was still sitting in the file.
  # Only a CHANGE is an instruction.
  CANCEL_AT_START="$(field cancel)"

  LAST_PROGRESS=0
  while kill -0 "$CHILD" 2>/dev/null; do
    sleep "$INTERVAL"

    # Publish the partial log on a slower clock than the poll: every INTERVAL
    # would be a commit every five seconds and an unreadable history.
    if [ "$PROGRESS_EVERY" != "0" ]; then
      NOW="$(date +%s)"
      if [ $((NOW - LAST_PROGRESS)) -ge "$PROGRESS_EVERY" ]; then
        # step_log, NOT a glob on $STEP. See step_log: globbing on the raw step
        # published no snapshot at all for every step sent by path, silently.
        publish_progress "$ID" "$STEP" "$START" "$(step_log "$STEP")"
        LAST_PROGRESS="$NOW"
      fi
    fi

    # Read the request from the REMOTE ref, never by pulling: the step is writing
    # to this working tree right now, and a rebase underneath a running step is
    # how you corrupt a run you were only trying to observe.
    # A mid-run read is optional. Without it a cancel waits for the step to
    # finish or for the next poll, which is a real cost and a smaller one than
    # a transport billing per operation being polled every few seconds.
    case "$TP_CAPS" in
      *" live "*) : ;;
      *) sleep "$INTERVAL"; continue ;;
    esac
    REMOTE_REQ="$(tp_fetch_request_live)" || continue
    [ -n "$REMOTE_REQ" ] || continue
    WANT_CANCEL="$(printf '%s\n' "$REMOTE_REQ" | sed -n 's/^cancel:[[:space:]]*//p' | head -1)"
    NEW_ID="$(printf '%s\n' "$REMOTE_REQ" | sed -n 's/^id:[[:space:]]*//p' | head -1)"

    # `cancel: yes` stops whatever is running. `cancel: <id>` stops it only if
    # that is the id running - so a stale cancel left in the file cannot kill a
    # later, wanted run. An unchanged value is stale by definition: it was in the
    # file before this step started, so it was not asking for this one to stop.
    if [ "$WANT_CANCEL" = "$CANCEL_AT_START" ]; then
      DO_CANCEL=0
    else
      case "$WANT_CANCEL" in
        yes|YES|true) DO_CANCEL=1 ;;
        "")           DO_CANCEL=0; CANCEL_AT_START="" ;;   # cleared: a later `yes` is a fresh instruction
        "$ID")        DO_CANCEL=1 ;;
        *)            DO_CANCEL=0 ;;
      esac
    fi

    if [ "$DO_CANCEL" = "1" ]; then
      say "CANCEL requested for '$STEP' ($ID) - signalling the process group"
      # TERM first so the step can finish its current line and flush; KILL only
      # if it ignores that. A log that stops mid-sentence is still evidence.
      kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
      for _ in 1 2 3 4 5; do
        kill -0 "$CHILD" 2>/dev/null || break
        sleep 1
      done
      kill -KILL -- "-$CHILD" 2>/dev/null || kill -KILL "$CHILD" 2>/dev/null
      CANCELLED=1
      break
    fi

    # A NEW id while this one runs does NOT cancel: an in-flight step may be
    # halfway through changing something, and inferring "they want this dead"
    # from a queued request would be guessing. It waits its turn.
    [ -n "$NEW_ID" ] && [ "$NEW_ID" != "$ID" ] && [ "$NEW_ID" != "$LAST_ID" ] &&
      say "note: request $NEW_ID is queued behind the running step"
  done

  wait "$CHILD" 2>/dev/null
  RC=$?
  [ "$CANCELLED" = "1" ] && RC=130
  CHILD=""
  RUNNING=0
  # BOTH of these, and this is not belt-and-braces. LAST_ID is what the loop
  # compares against; STATE_FILE is only read at startup. Writing the file alone
  # left LAST_ID at its startup value, so the same request matched "new" on every
  # poll and the station re-ran it every few seconds until it was stopped.
  LAST_ID="$ID"
  echo "$ID" > "$STATE_FILE"

  # WHICH LOG THIS RUN PRODUCED. Asked of the runner rather than guessed.
  #
  # This was `ls -t ops-logs/"${STEP}"-*.txt`, and a step given as a PATH - which
  # is the documented way to send one, `heliograph send steps/probe.sh` - made
  # that glob `ops-logs/steps/probe.sh-*.txt`, which matches nothing. So the
  # published status said `log: <none>` for every step sent by path, on every
  # transport, while the log sat in ops-logs under the name run.sh gave it.
  #
  # On git that was survivable because the control side lists the directory. On
  # a relay it is not survivable at all: a relay is a queue, so the name in the
  # status is the only name the log will ever have.
  #
  # cap_record_delivery writes the path it actually delivered, so that is the
  # authority. step_log stays as the fallback for a run that never reached
  # delivery - a cancelled step, most often. The derivation it does lives there
  # rather than here because the progress call site needs the same answer, had
  # the same glob, and was still wrong long after this line was fixed.
  LOGFILE="$(sed -n 's/^log:[[:space:]]*//p' "$REPO_ROOT/.station-delivery" 2>/dev/null | head -1)"
  # RELATIVE TO THE PAYLOAD, because that is what the published status has
  # always carried and what the control side reads. run.sh records the path it
  # wrote, which may be absolute; publishing that would leak the station's
  # directory layout into a document the control side matches names against.
  case "$LOGFILE" in
    "$REPO_ROOT"/*) LOGFILE="${LOGFILE#"$REPO_ROOT"/}" ;;
  esac
  if [ -z "$LOGFILE" ] || [ ! -f "$LOGFILE" ]; then
    LOGFILE="$(step_log "$STEP")"
  fi
  if [ "$CANCELLED" = "1" ]; then
    say "step '$STEP' CANCELLED${LOGFILE:+  (partial log: $LOGFILE)}"
    # The log goes in this commit too: the step was killed, so run.sh's cap_push
    # never ran, and this is the only thing that will carry the partial evidence
    # out - as well as what leaves the tree clean enough to keep polling.
    publish_status "cancelled" "$ID" "$STEP" "$(printf 'started:  %s\ncancelled:%s\nexit:     %s\nlog:      %s\nnote:     partial - the step was signalled, so the log stops where it stopped' \
        "$START" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RC" "${LOGFILE:-<none>}")" "$LOGFILE"
  else
    # Did the log actually get out? run.sh delivers it, in its own process, so
    # this cannot be inferred from $RC - that belongs to the STEP and may not be
    # borrowed to report on the transport.
    #
    # "The log exists and could not be shipped" and "the step is still running"
    # are indistinguishable from the far side unless one of them is published,
    # and only one of them is worth waiting on. pigeonhole.sh published
    # `undelivered` for this reason; porting the loop onto the transport
    # interface dropped it along with the delivery it reported.
    DELIVERED="$(sed -n 's/^delivered:[[:space:]]*//p' "$REPO_ROOT/.station-delivery" 2>/dev/null | head -1)"
    say "step '$STEP' finished exit=$RC${LOGFILE:+  ($LOGFILE)}"
    # `idle` MEANS THE LOG ARRIVED. Only `yes` earns it, and everything else is
    # published as `undelivered` with the reason.
    #
    # This was inverted - anything that was not literally `no` became `idle` -
    # and the hole was not small. An absent marker means the runner exited
    # before it ever reached delivery (refused as root, an unknown step, a sudo
    # pre-cache that failed, killed), and that was reported as a clean run with
    # a log nobody would ever receive. `unknown` says cap_push ran as a fallback
    # and its result was not established. Both are the failure this whole change
    # exists to remove, reinstated by a default.
    case "$DELIVERED" in
      yes)
        publish_status "idle" "$ID" "$STEP" "$(printf 'started:  %s\nfinished: %s\nexit:     %s\nlog:      %s%s' \
            "$START" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RC" "${LOGFILE:-<none>}" "${REQUEST_BY:+$(printf '\nby:       %s' "$REQUEST_BY")}")" ;;
      *)
        case "$DELIVERED" in
          no)      WHY="the transport would not take it" ;;
          skipped) WHY="delivery was skipped (PUSH=0), so the log is on the station only" ;;
          unknown) WHY="delivery fell back to a direct push and its result was not established" ;;
          "")      WHY="the runner exited before it reached delivery, so no log was sent" ;;
          *)       WHY="the runner reported delivery state '$DELIVERED', which this loop does not know" ;;
        esac
        say "NOT DELIVERED over '$TRANSPORT': $WHY"
        publish_status "undelivered" "$ID" "$STEP" "$(printf 'started:  %s\nfinished: %s\nexit:     %s\nlog:      %s\nnote:     %s' \
            "$START" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RC" "${LOGFILE:-<none>}" "$WHY")" ;;
    esac
  fi

  [ "$ONCE" = "1" ] && cleanup
  sleep "$INTERVAL"
done

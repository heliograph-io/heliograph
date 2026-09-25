#!/usr/bin/env bash
# =============================================================================
#  service.sh - make the loop outlive the session that started it
# =============================================================================
#     ./service.sh install                      # survive logout, and start now
#     ./service.sh install --branch task/foo    # ...on a task branch
#     ./service.sh install -- --once            # ...args after -- go to station.sh
#     ./service.sh status      # is it running, and where are the logs
#     ./service.sh logs        # follow them
#     ./service.sh stop
#     ./service.sh uninstall
#
#  WHY THIS EXISTS. station.sh says "run this ONCE on the control node and walk
#  away" and that was not true. sshd sends SIGHUP to the session's process group
#  when the connection closes, station.sh traps INT and TERM but not HUP, and the
#  default action for HUP is to die. Measured: the shell reports
#
#      Hangup    PUSH=0 ./station.sh --interval 3
#
#  and the loop is gone. Every host added since - the container, the Azure four,
#  AKS, the pipelines - gets this free from a restart policy, which is exactly
#  why it went unnoticed for so long. The plainest case, somebody with a shell on
#  a box who wants to close the laptop, was the one still broken.
#
#  THE DIVISION OF LABOUR is unchanged. start.sh decides WHERE, station.sh decides
#  WHEN, run.sh owns the log. This decides only HOW THE LOOP OUTLIVES THE
#  SESSION, and it starts start.sh rather than station.sh so the preflight still
#  runs. It reimplements none of them.
#
#  TWO MECHANISMS, and the first is much better:
#
#    systemd --user plus lingering. No root, restarts on failure, survives
#    reboot, and journalctl already knows how to show you the logs.
#
#    setsid + nohup. Works anywhere, survives logout, and does NOT survive a
#    reboot. Used only when there is no user systemd to talk to, and it says so
#    rather than pretending the two are equivalent.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1

# The unit name is overridable, and that is not only for the tests. Two
# transport repos on one control node is an ordinary situation - one per
# investigation - and a fixed name would mean the second install silently
# replaced the first. It also stops ./tests/run-tests.sh from uninstalling a
# real service somebody is relying on.
SERVICE_NAME="${HELIOGRAPH_SERVICE_NAME:-heliograph}"
UNIT_NAME="$SERVICE_NAME.service"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# --- launchd, for macOS -------------------------------------------------------
# There is no systemd here and the setsid fallback, while it works, does not
# survive a reboot. A LaunchAgent does, restarts on failure, and needs no root -
# the same three properties the systemd path was chosen for.
#
# The label is reverse-DNS because launchd requires it, and it carries
# HELIOGRAPH_SERVICE_NAME for the same reason the unit name does: one transport
# repo per investigation is ordinary, and a fixed label would mean the second
# install silently replaced the first.
LAUNCH_LABEL="uk.dbhq.heliograph.${SERVICE_NAME}"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
LAUNCH_PATH="$LAUNCH_DIR/${LAUNCH_LABEL}.plist"

# A repo path can contain & or < - rare, but a plist with one in it is invalid
# and launchd's complaint about it names the file, not the character.
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# sh_quote - one argument, safe to paste into a shell command line.
#
# Needed because two of the three mechanisms now build a `bash -c` string: the
# LaunchAgent and the setsid fallback both have to source the env file before
# exec'ing start.sh, and a repo path with a space or a quote in it would
# otherwise split into two arguments or end the string early.
sh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# env_wrapped_prefix - the shell that loads the env file before exec'ing.
#
# `set -a` IS THE WHOLE POINT, and leaving it out was a defect that looked like
# working code. `. file` with `KEY=value` in it sets a SHELL variable, and the
# very next thing this does is `exec bash start.sh` - a new process, which
# inherits environment variables and not shell ones. So the file was read,
# every value discarded, and a relay station started as a git one and failed its
# preflight. systemd was unaffected because EnvironmentFile exports for you,
# which is exactly how a defect ends up in two mechanisms out of three.
#
# One definition, used by the LaunchAgent and the setsid fallback both, so they
# cannot drift apart again.
env_wrapped_prefix() {
  printf 'set -a; [ -r %s ] && . %s; set +a; ' \
    "$(sh_quote "$STATION_ENV")" "$(sh_quote "$STATION_ENV")"
}

launchd_ok() {
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 1
  command -v launchctl >/dev/null 2>&1
}

# pick_bash - an ABSOLUTE path to a bash 4 or newer, printed, or nothing.
#
# THIS IS WHY A MAC STATION CRASH-LOOPED, and the failure was invisible for
# four CI runs because it looks exactly like a flaky test.
#
# macOS still ships bash 3.2 at /bin/bash - the last GPLv2 release, from 2007 -
# and start.sh's preflight refuses it, correctly: the station uses `declare -A`
# and `${var^^}`, neither of which 3.2 has. Anybody running a station on a Mac
# therefore has a newer bash from Homebrew or MacPorts, and their interactive
# PATH finds it first, so `./service.sh install` runs under bash 5 and every
# check it makes passes.
#
# launchd does NOT inherit that PATH. A LaunchAgent gets the bare
# /usr/bin:/bin:/usr/sbin:/sbin, where the only bash is 3.2. So the install
# reported success, launchd started the LaunchAgent, preflight found bash 3.2,
# refused to start, and exited 1 - which under KeepAlive/SuccessfulExit=false
# is a restart, correctly. The station never ran a single step, and the plist
# was blameless.
#
# So the bash is resolved HERE, at install time, to an absolute path, and both
# written into ProgramArguments and put on the LaunchAgent's PATH. An absolute
# path in the plist is not a style choice: it is the only part of the environment
# launchd cannot take away.
pick_bash() {
  local c v abs
  # The running shell first. Whoever ran service.sh reached it somehow, and it
  # is by definition the one their PATH resolves - so it is the least
  # surprising answer when it qualifies.
  for c in "${BASH:-}" "$(command -v bash 2>/dev/null)" \
    /opt/homebrew/bin/bash /usr/local/bin/bash /opt/local/bin/bash /bin/bash; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    # MADE ABSOLUTE FIRST, and the version asked of the absolute path.
    #
    # `$BASH` is whatever argv[0] was, `command -v` echoes a relative path back
    # unchanged, and a PATH entry may itself be relative - so `./bin/bash` and
    # `bash` both reach here looking usable. launchd resolves ProgramArguments
    # against its own context, not the installing shell's, so a relative path
    # in the plist names a different file or none at all. `cd -P` also resolves
    # the symlink, which is what makes /usr/local/bin/bash on a Mac come out as
    # the Cellar path it actually is.
    abs="$(cd -P "$(dirname "$c")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$c")")"
    case "$abs" in
    /*) ;;
    *) continue ;;
    esac
    [ -x "$abs" ] || continue
    v="$("$abs" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null)"
    case "$v" in
    '' | *[!0-9]*) continue ;;
    esac
    if [ "$v" -ge 4 ]; then
      printf '%s' "$abs"
      return 0
    fi
  done
  return 1
}
UNIT_PATH="$UNIT_DIR/$UNIT_NAME"
PID_FILE="$REPO_ROOT/.agent-service.pid"
LOG_FILE="$REPO_ROOT/.station-service.log"

START_ARGS=()

say()  { printf '%s\n' "$*"; }
warn() { printf 'warn  %s\n' "$*" >&2; }
die()  { printf 'error %s\n' "$*" >&2; exit 1; }

# --- systemd, and the variable that decides whether you can reach it ----------
# `systemctl --user` talks to a per-user bus under XDG_RUNTIME_DIR. That variable
# is set for a login shell and is routinely UNSET in the shells this toolkit
# actually runs in: `ssh host command`, a sudo session, a cron job. Without it
# systemctl fails with
#
#     Failed to connect to bus: No medium found
#
# which names neither systemd nor the variable, and sends the reader looking for
# a broken unit that was never written. The directory is there regardless, so
# point at it rather than give up.
ensure_xdg() {
  [ -n "${XDG_RUNTIME_DIR:-}" ] && return 0
  local d
  d="/run/user/$(id -u)"
  [ -d "$d" ] || return 1
  export XDG_RUNTIME_DIR="$d"
  return 0
}

systemd_user_ok() {
  command -v systemctl >/dev/null 2>&1 || return 1
  ensure_xdg || return 1
  systemctl --user show-environment >/dev/null 2>&1
}

# --- the credential, which is where an unattended loop actually fails ---------
# A detached process does not inherit the shell's environment. GIT_TOKEN typed
# before ./station.sh reaches station.sh; GIT_TOKEN typed before ./service.sh install
# does NOT reach the service. The loop then starts perfectly, polls happily, and
# cannot push a single log - which is the expensive failure this toolkit exists
# to prevent, discovered hours later by somebody waiting on the far side.
#
# So it is checked BEFORE anything is installed, and named precisely. caplib owns
# the credential chain and this only asks it what it found: no second resolver,
# per the spec.
#
# WHICH credential is even relevant is decided by the remote's scheme, and the
# same three-way split start.sh uses is repeated here rather than a new rule of
# its own. An earlier version checked only for ssh and let everything else fall
# through to the token chain, which refused to install against a local path
# remote - a remote that needs no credential at all. Its own test caught it.
# WHERE A NON-GIT STATION'S CONFIGURATION LIVES.
#
# The whole point of this file's credential check is that a detached process
# inherits nothing from the shell that installed it. That is exactly as true of
# RELAY_TOKEN and SHARE_DIR as it is of GIT_TOKEN - more so, because a relay
# station has no fallback file the way caplib reads ~/.git-token.
#
# So the unit reads an env file, and this is the one place its name is written.
# Mode 600, gitignored, beside the payload: an EnvironmentFile is systemd's own
# answer, launchd's plist has no equivalent and sources it from the wrapper, and
# putting the secret in the unit itself would put it in `systemctl cat`.
STATION_ENV="$REPO_ROOT/.station-env"

# --- the env file, checked in ONE place ---------------------------------------
#
# station-env.sh owns every rule about $STATION_ENV: the format both systemd and
# a shell have to agree on, the transport name, and whether that transport will
# initialise from what is in there. This file calls it and reports.
#
# IT USED TO BE HERE, AND ALSO IN service.ps1, and that was the mistake. An
# adversarial read of the two found six ways they classified the same file
# differently - PowerShell regexes are case-insensitive, so `transport=relay`
# passed there and set nothing in bash; Get-Content eats a UTF-8 BOM that bash
# does not; an empty file passed one and failed the other. A station that
# installs on Windows and is refused on Linux, from one file, is worse than
# either answer alone.
STATION_ENV="$REPO_ROOT/.station-env"
STATION_ENV_CHECK="$REPO_ROOT/station-env.sh"

station_transport() {
  if [ -x "$STATION_ENV_CHECK" ]; then
    STATION_ENV="$STATION_ENV" bash "$STATION_ENV_CHECK" --transport 2>/dev/null
    return
  fi
  printf '%s' "${TRANSPORT:-git}"
}

credential_check() {
  local src url scheme t out rc
  # CHECKED BEFORE THE TRANSPORT IS DECIDED, whenever the file exists at all.
  #
  # A malformed line is not a non-git problem: launchd and the setsid fallback
  # source this file for a git station too. And it is circular the other way -
  # `export TRANSPORT='relay'` is exactly the malformed line an operator writes,
  # and reading the transport out of it first gives 'git', runs the git checks,
  # and reports a missing origin remote to somebody whose real problem is one
  # word at the start of one line.
  if [ -x "$STATION_ENV_CHECK" ]; then
    out="$(STATION_ENV="$STATION_ENV" bash "$STATION_ENV_CHECK" 2>&1)"; rc=$?
    [ -n "$out" ] && printf '%s\n' "$out" | while IFS= read -r _l; do say "$_l"; done
    [ "$rc" = "0" ] || return 1
  fi
  t="$(station_transport)"
  # A non-git transport is settled entirely by station-env.sh above: its
  # credential IS those variables, and it just proved the transport initialises
  # from them. Everything below is git's credential chain.
  [ "$t" = "git" ] || return 0
  # shellcheck source=caplib.sh disable=SC1091
  . "$REPO_ROOT/caplib.sh" 2>/dev/null || { warn "could not read caplib.sh, skipping the credential check"; return 0; }
  src="$(_cap_token_source 2>/dev/null)"
  url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"

  case "$url" in
    git@*|ssh://*)      scheme=ssh ;;
    https://*|http://*) scheme=https ;;
    "")                 scheme=none ;;
    *)                  scheme=other ;;
  esac

  case "$scheme" in
    none)
      warn "there is no origin remote. Git is the transport, so there is nowhere to push a log."
      return 1 ;;
    ssh)
      # NO KEY RESOLUTION HERE, deliberately. ssh's own config resolution is
      # richer than anything reimplemented in this file, and a second resolver
      # that disagreed with it would report a key git never uses. The spec is
      # explicit about that. So this reports the situation and points at the one
      # thing that actually settles it, which is start.sh's write check.
      if [ -n "${SSH_AUTH_SOCK:-}" ]; then
        warn "origin is an SSH remote and this shell has an ssh-agent, which the service will NOT inherit."
        warn "  An agent key lasts only as long as your session, and the whole point of a service is"
        warn "  to outlive it. Give the service a key it can read without an ssh agent: put one at"
        warn "  ~/.ssh/id_ed25519, or name it in ~/.ssh/config for this host."
        warn "  Verify before installing:  ./start.sh --check"
      else
        say "note: origin is an SSH remote and there is no agent in this shell, so the service will"
        say "      depend on a key ssh can find by itself. './start.sh --check' proves it in one step,"
        say "      and the service's own preflight will refuse to start the station if it cannot push."
      fi
      return 0 ;;
    other)
      # A local path or a filesystem URL. git needs no credential for one, and
      # refusing here would block a perfectly good setup: bootstrap.sh's own
      # tests, a bind-mounted repo in a container, a bare repo on a share.
      return 0 ;;
  esac

  case "$src" in
    env:*|header:*)
      warn "the credential is ${src%%:*}:${src#*:}, which lives in THIS shell and will not reach the service."
      warn "  A detached process inherits no environment, so the loop would run and never push."
      warn "  Write it to a file the service can read instead:"
      warn "      printf '%%s' \"\$GIT_TOKEN\" > ~/.git-token && chmod 600 ~/.git-token"
      warn "  caplib reads ~/.git-token already, so nothing else has to change."
      return 1 ;;
    none)
      warn "no credential found at all. The loop will start and be unable to push."
      warn "  See https://docs.heliograph.io/transports#the-credential, then re-run this."
      return 1 ;;
    unreadable:*)
      warn "a credential exists at ${src#unreadable:} but is not readable by $(id -un)."
      return 1 ;;
  esac
  return 0
}

# --- install -----------------------------------------------------------------
write_unit() {
  mkdir -p "$UNIT_DIR"
  # systemd splits ExecStart on whitespace and honours double quotes, so each
  # argument is quoted individually rather than pasted in as one string. A
  # branch name with a space in it is unusual but a step name with one is not.
  local EXEC_TAIL="" a
  for a in ${START_ARGS+"${START_ARGS[@]}"}; do
    EXEC_TAIL="$EXEC_TAIL \"$a\""
  done
  # StartLimit* sit in [Unit], not [Service], on systemd 229 and newer.
  #
  # Restart=on-failure, NOT always, and this was learned the hard way.
  #
  # `stop: yes` in station/request is how the far side ends a loop it can no longer
  # reach, and station.sh honours it by exiting 0. Under Restart=always systemd then
  # started it straight back up, it read the same stop flag, exited 0 again, and
  # round it went: measured at four "station: stopped" commits in eighty seconds,
  # each one PUSHED TO THE TRANSPORT REPO, until StartLimitBurst tripped and left
  # the unit `failed` - which reads like a breakage when the station had in fact
  # done exactly what it was told.
  #
  # station.sh runs forever unless it is deliberately stopped, so exit 0 means "I
  # was told to stop" and must stick. A crash, or a preflight that refuses a bad
  # credential, is non-zero and still restarts, which is the case Restart existed
  # for. The limit stays so a genuinely broken start does not retry forever.
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=heliograph station loop ($REPO_ROOT)
Documentation=https://docs.heliograph.io/service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=$REPO_ROOT
# OPTIONAL, hence the leading dash: a git station that keeps its token in
# ~/.git-token needs no such file, and systemd refuses to start a unit whose
# EnvironmentFile is missing unless it is marked optional.
#
# This is how a relay, share or blob station gets its variables at all. A
# detached process inherits nothing from the shell that installed it - the same
# fact this file has always warned about for GIT_TOKEN, and the reason those
# stations could not be run as a service before.
EnvironmentFile=-$STATION_ENV
ExecStart=/usr/bin/env bash $REPO_ROOT/start.sh$EXEC_TAIL
Restart=on-failure
RestartSec=10

# The loop is a diagnostic tool, not a service worth pre-empting real work for.
Nice=5

[Install]
WantedBy=default.target
EOF
}

# EVERYTHING EXCEPT --force IS FORWARDED TO start.sh, VERBATIM.
#
# The first version of this hardcoded `start.sh` with no arguments, which meant a
# service-managed loop could not be put on a task branch - and branch per task is
# how this whole skill works. It also ruled out --interval and anything after --.
# Found by running a real investigation through it rather than by review.
#
# --force is consumed here because it is this script's own escape hatch for the
# credential check. Anything else belongs to start.sh, which already knows how to
# forward its own tail to station.sh.
cmd_install() {
  [ -f "$REPO_ROOT/start.sh" ] || die "no start.sh beside this script. Run it from inside a transport repo."

  local force=0
  START_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      *)       START_ARGS+=("$1") ;;
    esac
    shift
  done

  if ! credential_check; then
    warn ""
    warn "Refusing to install a loop that cannot push. Fix the above, or pass --force"
    warn "if you know better than this check."
    [ "$force" = "1" ] || exit 1
    warn "--force given, installing anyway."
  fi

  if systemd_user_ok; then
    # LINGERING IS THE WHOLE TRICK. Without it the user manager is torn down at
    # logout and takes every --user unit with it, so the service would look
    # perfectly installed and still die exactly when it was supposed to survive.
    local linger
    linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)"
    if [ "$linger" != "yes" ]; then
      say "enabling lingering so the unit survives logout"
      if ! loginctl enable-linger "$(id -un)" 2>/dev/null; then
        sudo -n loginctl enable-linger "$(id -un)" 2>/dev/null || true
      fi
      linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)"
    fi

    write_unit
    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT_NAME" >/dev/null 2>&1 || {
      systemctl --user status "$UNIT_NAME" --no-pager 2>&1 | head -20
      die "the unit was written to $UNIT_PATH but would not start. Its status is above."
    }

    say ""
    say "installed: $UNIT_PATH"
    [ "${#START_ARGS[@]}" -gt 0 ] && say "arguments: ${START_ARGS[*]}"
    say "mechanism: systemd --user, restarts on failure, survives reboot"
    if [ "$linger" = "yes" ]; then
      say "lingering: enabled, so it survives logout"
    else
      warn "lingering: NOT enabled, and this is the one thing that matters here."
      warn "  The unit will run until you log out and then die with the user manager,"
      warn "  which is exactly what this was meant to prevent. Ask an administrator for:"
      warn "      sudo loginctl enable-linger $(id -un)"
    fi
    say ""
    say "  ./service.sh status     what it is doing"
    say "  ./service.sh logs       follow the journal"
    return 0
  fi

  # --- launchd, on macOS ------------------------------------------------------
  if launchd_ok; then
    mkdir -p "$LAUNCH_DIR"
    # THE ENV FILE IS SOURCED, NOT INLINED INTO THE PLIST.
    #
    # launchd has an EnvironmentVariables dict and it is the wrong place for
    # this: a LaunchAgent plist is world-readable by default, and a station's
    # RELAY_TOKEN would sit in it in cleartext for anybody on the machine, and
    # in every backup of ~/Library. The env file is mode 600 and stays the one
    # copy - so the LaunchAgent runs a shell that sources it and then execs start.sh.
    #
    # `[ -r ... ] &&` rather than a bare source: a git station keeping its token
    # in ~/.git-token has no such file, and a launchd job that failed because a
    # file it never needed was absent would be a poor trade for the tidiness.
    local args_xml="" a cmd sh bindir
    sh="$(pick_bash)" || die "no bash 4 or newer on this Mac, and /bin/bash is 3.2.
      A LaunchAgent gets PATH=/usr/bin:/bin:/usr/sbin:/sbin, so it would find only
      3.2 and the station would refuse to start on every restart for ever.
      Install one - brew install bash - and run this again."
    bindir="$(dirname "$sh")"
    # PATH first, and PREPENDED, so that everything start.sh goes on to spawn as
    # plain 'bash' gets the same one the plist execs. The rest is launchd's own
    # default, kept, because the station calls git, sed and date and dropping
    # /usr/bin would break all three.
    cmd="PATH=$(sh_quote "$bindir"):\"\${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}\"; export PATH; "
    cmd="$cmd$(env_wrapped_prefix)exec $(sh_quote "$sh") $(sh_quote "$REPO_ROOT/start.sh")"
    for a in ${START_ARGS+"${START_ARGS[@]}"}; do
      cmd="$cmd $(sh_quote "$a")"
    done
    args_xml="        <string>-c</string>
        <string>$(xml_escape "$cmd")</string>
"
    cat > "$LAUNCH_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>${LAUNCH_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml_escape "$sh")</string>
${args_xml}    </array>
    <key>WorkingDirectory</key><string>$(xml_escape "$REPO_ROOT")</string>
    <key>RunAtLoad</key><true/>
    <!-- KeepAlive on a NON-ZERO exit only, never unconditionally.

         \`stop: yes\` in station/request is how the far side ends a loop it can
         no longer reach, and station.sh honours it by exiting 0. Under a plain
         <true/> launchd would restart it, it would read the same stop flag,
         exit again, and round it would go - every cycle a commit pushed to the
         transport repo. The systemd unit uses Restart=on-failure for exactly
         this reason, learned by running one. -->
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardOutPath</key><string>$(xml_escape "$LOG_FILE")</string>
    <key>StandardErrorPath</key><string>$(xml_escape "$LOG_FILE")</string>
    <key>ProcessType</key><string>Background</string>
  </dict>
</plist>
PLIST

    launchctl unload "$LAUNCH_PATH" >/dev/null 2>&1
    if ! launchctl load "$LAUNCH_PATH" 2>/dev/null; then
      die "launchctl load failed for $LAUNCH_PATH"
    fi
    say "installed: $LAUNCH_PATH"
    say "mechanism: launchd LaunchAgent, restarts on failure, survives reboot"
    say ""
    say "  ./service.sh status     what it is doing"
    say "  ./service.sh logs       follow $LOG_FILE"
    return 0
  fi

  # --- fallback ---------------------------------------------------------------
  say "no user systemd here, falling back to setsid + nohup"
  if [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    die "already running as pid $(cat "$PID_FILE"). Stop it first: ./service.sh stop"
  fi
  # setsid detaches from the controlling terminal so SIGHUP never arrives, and
  # the redirects matter as much: a process whose stdout is a closed pty gets
  # EIO on the next write and dies anyway, having survived the signal.
  # The env file, here too. This path DOES inherit the installing shell, so a
  # git station with GIT_TOKEN exported has always worked - but a station
  # configured through the env file must behave the same under all three
  # mechanisms, or "it works as a service" depends on which one the machine
  # happened to have.
  if [ -r "$STATION_ENV" ]; then
    local fallback_cmd
    fallback_cmd="$(env_wrapped_prefix)exec bash $(sh_quote "$REPO_ROOT/start.sh")"
    for a in ${START_ARGS+"${START_ARGS[@]}"}; do
      fallback_cmd="$fallback_cmd $(sh_quote "$a")"
    done
    setsid nohup bash -c "$fallback_cmd" >>"$LOG_FILE" 2>&1 </dev/null &
  else
    setsid nohup bash "$REPO_ROOT/start.sh" ${START_ARGS+"${START_ARGS[@]}"} >>"$LOG_FILE" 2>&1 </dev/null &
  fi
  local pid=$!
  sleep 2
  if ! kill -0 "$pid" 2>/dev/null; then
    say "--- last of $LOG_FILE ---"
    tail -20 "$LOG_FILE" 2>/dev/null
    die "it exited immediately. Its output is above."
  fi
  printf '%s\n' "$pid" > "$PID_FILE"
  say ""
  say "running  : pid $pid"
  [ "${#START_ARGS[@]}" -gt 0 ] && say "arguments: ${START_ARGS[*]}"
  say "log      : $LOG_FILE"
  say "mechanism: setsid + nohup. Survives logout. Does NOT survive a reboot -"
  say "           after one, run this again."
}

# --- the others ---------------------------------------------------------------
cmd_status() {
  if launchd_ok && [ -f "$LAUNCH_PATH" ]; then
    say "mechanism: launchd ($LAUNCH_PATH)"
    say "branch   : $(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    say "log      : $LOG_FILE"
    launchctl list "$LAUNCH_LABEL" 2>&1 | head -15
    return 0
  fi
  if systemd_user_ok && [ -f "$UNIT_PATH" ]; then
    say "mechanism: systemd --user ($UNIT_PATH)"
    say "lingering: $(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)"
    say "command  : $(grep -m1 '^ExecStart=' "$UNIT_PATH" | cut -d= -f2-)"
    say "branch   : $(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    systemctl --user status "$UNIT_NAME" --no-pager 2>&1 | head -15
    return 0
  fi
  if launchd_ok && [ -f "$LAUNCH_PATH" ]; then
    # unload, not `launchctl stop`: with KeepAlive set, stop is followed by
    # launchd starting it straight back up, which looks exactly like a stop
    # that did not work.
    launchctl unload "$LAUNCH_PATH" 2>/dev/null && { say "unloaded the LaunchAgent"; stopped=1; }
  fi
  if [ -s "$PID_FILE" ]; then
    local pid; pid="$(cat "$PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      say "mechanism: setsid + nohup"
      say "running  : pid $pid"
      say "log      : $LOG_FILE"
    else
      say "not running. A stale pid file says $pid; the process is gone."
      say "log      : $LOG_FILE"
    fi
    return 0
  fi
  say "not installed. Run: ./service.sh install"
}

cmd_logs() {
  if systemd_user_ok && [ -f "$UNIT_PATH" ]; then
    exec journalctl --user -u "$UNIT_NAME" -f -n 50
  fi
  # A LaunchAgent writes to LOG_FILE by StandardOutPath, so the tail below is
  # already right for it and needs no branch of its own.
  [ -f "$LOG_FILE" ] || die "no log yet at $LOG_FILE, and no service installed."
  exec tail -f -n 50 "$LOG_FILE"
}

cmd_stop() {
  local stopped=0
  if systemd_user_ok && [ -f "$UNIT_PATH" ]; then
    systemctl --user stop "$UNIT_NAME" 2>/dev/null && { say "stopped the unit"; stopped=1; }
  fi
  if launchd_ok && [ -f "$LAUNCH_PATH" ]; then
    say "mechanism: launchd ($LAUNCH_PATH)"
    say "branch   : $(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    say "log      : $LOG_FILE"
    launchctl list "$LAUNCH_LABEL" 2>&1 | head -15
    return 0
  fi
  if [ -s "$PID_FILE" ]; then
    local pid; pid="$(cat "$PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      # TERM the whole process group: setsid gave it its own, and station.sh's own
      # cleanup trap handles the rest.
      kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      say "stopped pid $pid"
      stopped=1
    fi
    rm -f "$PID_FILE"
  fi
  [ "$stopped" = "1" ] || say "nothing was running"
}

cmd_uninstall() {
  cmd_stop
  if [ -f "$UNIT_PATH" ]; then
    systemd_user_ok && systemctl --user disable "$UNIT_NAME" >/dev/null 2>&1
    rm -f "$UNIT_PATH"
    systemd_user_ok && systemctl --user daemon-reload
    say "removed $UNIT_PATH"
  fi
  if [ -f "$LAUNCH_PATH" ]; then
    launchd_ok && launchctl unload "$LAUNCH_PATH" >/dev/null 2>&1
    rm -f "$LAUNCH_PATH"
    say "removed $LAUNCH_PATH"
  fi
  rm -f "$PID_FILE"
  say "uninstalled. Lingering is left enabled: it is a property of the user, not"
  say "of this repo, and other things may rely on it."
}

case "${1:-}" in
  install)   shift; cmd_install "$@" ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  stop)      cmd_stop ;;
  uninstall) cmd_uninstall ;;
  *)
    sed -n '2,9p' "$0" | sed 's/^#\{1,\} \{0,2\}//'
    exit 2 ;;
esac

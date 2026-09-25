#!/usr/bin/env bash
# =============================================================================
#  transports/git.sh - the git transport, under the station's transport contract
# =============================================================================
# Sourced by station.sh. Implements tp_* and nothing else. Every git command
# the loop issues lives in this file, so the loop itself no longer knows what
# it is talking to.
#
# THE CONTRACT
#
#   tp_capabilities            which optional verbs this transport offers
#   tp_check                   can this station reach the transport at all
#   tp_describe                the credential in force, by mechanism, never value
#   tp_fetch_request           emit the request document, or fail
#   tp_fetch_request_live      the same, DURING a run, without touching the tree
#   tp_fetch_self              bring a newer payload, if this transport can
#   tp_put_status              publish a status document, plus an optional file
#   tp_put_progress            publish a partial-log snapshot
#   tp_put_log                 publish the FINISHED log
#
# AND TWO THAT ONLY start.sh CALLS, both optional:
#
#   tp_preflight               checks worth more than "can I reach it"
#   tp_sync                    bring the payload up to date before handing over
#
# WHY tp_preflight EXISTS
#
# start.sh used to check a git remote, a git credential and a git push
# unconditionally, and one FAIL there stops before station.sh ever runs. So a
# relay or blob station could not be started by `./start.sh` - the one command
# every host, every container entrypoint and every page tells the operator to
# type. The documented answer was "by hand", which meant setting eight variables
# and skipping the only preflight there is, on a machine nobody can log into.
#
# tp_check answers "can I reach it" for every transport and that is what start.sh
# asks by default. It is not enough HERE, and the gap is specific: read access is
# not write access, so `ls-remote` says nothing about whether an hour-long step
# can deliver its log. tp_preflight is where a transport puts the checks only it
# knows to make.
#
# TWO SEAMS IT DEPENDS ON, both supplied by start.sh and documented here so
# nothing has to be inferred from a call site:
#
#   report <ok|warn|FAIL> <label> <detail...>   how it speaks. A FAIL counts,
#                                               and always names a remedy
#   TP_WANT_SCOPE                               the scope the operator asked for
#                                               on the command line, or empty.
#                                               `--branch` here; a lane or a
#                                               station name elsewhere
#
# WHY tp_put_log IS A CONTRACT VERB AND NOT run.sh's BUSINESS
#
# It was run.sh's business, and only git worked. `cap_push` is git
# unconditionally, and it was the sole delivery path there had ever been, so a
# station on the relay or the blob transport captured a perfect log and
# delivered nothing: no footer, no exit code, no RESULT line, and with
# PROGRESS_EVERY=0 not a single byte. AGENTS.md constraint 2 says a failed run
# still ships and a failed push never loses a log; two of three transports were
# quietly failing the first half of that.
#
# It is a regression rather than an omission, which is the part worth
# remembering. pigeonhole.sh delivered the finished log correctly before this
# interface existed. Porting the loop onto the interface deleted the duplicated
# 500 lines and this behaviour with them, and nothing noticed, because the log
# is written correctly to local disk every single time and the defect is only
# visible from the side of the gap nobody here can reach.
#
# WHY tp_fetch_request_live IS SEPARATE
#
# During a run the step is appending to its log through an open descriptor.
# Reading the request by pulling would rewrite the working tree underneath it
# and the appends would carry on at a stale offset, corrupting the evidence the
# run exists to produce. So the live read goes to the remote ref and never
# touches the tree. Two verbs rather than a flag, because the difference is not
# a detail: getting it wrong destroys a run while only trying to observe it.
#
# WHY tp_fetch_self EXISTS AT ALL
#
# The loop re-executes itself when a newer station.sh arrives, which is what
# lets a fix take effect without telling the operator to restart - the whole
# point of them starting it once and walking away. git gives that away free,
# because a pull replaces the file. Nothing else does, so it is a declared
# capability rather than an assumption.
# =============================================================================

# What this transport can do. A loop reads this at START, so it can say what it
# will not be able to do later, while somebody is still listening.
tp_capabilities() { printf 'request status progress self live\n'; }

# Validate what this transport needs locally, and fail with a remedy rather
# than a symptom. Called once, before anything else.
tp_init() {
  # Asked FIRST, and separately from `rev-parse`. Without git on PATH every
  # check below fails as "this is not a git repository", which sends the
  # operator looking for a clone that is sitting right there.
  command -v git >/dev/null 2>&1 || {
    echo "station: git is the transport and it is not on PATH." >&2
    echo "         Install git and put it first on PATH." >&2
    return 1
  }
  git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "station: this is not a git repository, and the git transport needs one." >&2
    echo "         clone the transport repo and run ./start.sh from inside it." >&2
    return 1
  }
  local b
  b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$b" ] && [ "$b" != "HEAD" ] || {
    # "detached HEAD" in those words, because that is the phrase the operator
    # will search for and the phrase git itself used to get them here.
    echo "station: detached HEAD, and station.sh refuses to start on one." >&2
    echo "         The branch is which machine this station answers for." >&2
    echo "         Check out the task branch first." >&2
    return 1
  }
  BRANCH="$b"
  return 0
}

# What a run is bound to. A branch here; a lane in the blob transport.
tp_scope() { printf '%s' "$BRANCH"; }

# A one-line description of what was just fetched, for the log.
tp_revision() { git log --oneline -1 2>/dev/null; }

tp_check() {
  git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "not a git repository" >&2
    return 1
  }
  cap_git ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1
}

# MASKED, because this one is printed. station.sh says `transport: $(tp_describe)`
# at start, straight to the terminal and to whatever journal is capturing it, and
# a token-in-URL remote put the token there in full. cap_redact never saw it: that
# is a stream filter on the capture path, and this line does not go down it.
#
# `https://ci-user:glpat-...@host/repo` is a shape transport.md tells people they
# will meet, so this is not a hypothetical.
tp_describe() {
  local url
  url="$(git remote get-url origin 2>/dev/null)"
  printf 'git %s on %s' "$(cap_mask_url "${url:-<no origin>}")" "${BRANCH:-<no branch>}"
}

# The ordinary poll: bring the branch up to date and read the request from the
# working tree. Returns 1 on a fetch failure, which the loop treats as a blip.
tp_fetch_request() {
  cap_git fetch --quiet origin "$BRANCH" 2>/dev/null || return 1
  cat "$REQUEST" 2>/dev/null
}

# The live read, used while a step is running. Never pulls, never rebases,
# never touches the working tree - see the header.
tp_fetch_request_live() {
  cap_git fetch --quiet origin "$BRANCH" 2>/dev/null || return 1
  git show "origin/$BRANCH:$REQUEST" 2>/dev/null
}

# Bring a newer payload into the working tree.
#
# Exits 0 when something changed, 1 when nothing did, 2 when it could not be
# done. The loop uses that to decide whether to re-execute, and a 2 is not
# fatal: a station that cannot update itself is still a working station.
tp_fetch_self() {
  local before after
  before="$(git rev-parse HEAD 2>/dev/null)"
  after="$(git rev-parse "origin/$BRANCH" 2>/dev/null)"
  [ "$before" = "$after" ] && return 1

  if cap_git pull --rebase --quiet 2>/dev/null; then
    return 0
  fi
  # Bare git: abort touches no network, so cap_git would put the auth header
  # into this process's argv for nothing.
  git rebase --abort >/dev/null 2>&1
  return 2
}

# Publish a status document, and optionally a file alongside it.
#
# The extra file is not decoration. A killed step leaves its log modified in the
# working tree, and progress pushes have made that file TRACKED, so unless it is
# committed here every later `pull --rebase` refuses on a dirty tree and the
# station wedges with the cancellation never reaching the far side. Found by
# cancelling a run that had been publishing progress.
tp_put_status() {
  local body="$1" msg="$2" alsofile="${3:-}"
  mkdir -p "$(dirname "$STATUS")"
  [ -n "$alsofile" ] && [ -f "$alsofile" ] || alsofile=""
  printf '%s' "$body" > "$STATUS"

  git add -f "$STATUS" ${alsofile:+"$alsofile"} >/dev/null 2>&1
  git diff --cached --quiet -- "$STATUS" ${alsofile:+"$alsofile"} >/dev/null 2>&1 && return 0
  git -c user.name="${GIT_AUTHOR_NAME:-station}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-station@$(hostname)}" \
      commit -q -m "$msg" -- "$STATUS" ${alsofile:+"$alsofile"} 2>/dev/null
  cap_git pull --rebase --quiet >/dev/null 2>&1
  # EXPLICIT, naming origin and this branch. A bare `git push` resolves through
  # upstream configuration, and once the branch is which MACHINE this station
  # is, resolving it anywhere but here is too implicit. The control side has
  # always pushed `origin HEAD:<branch>`; this side had not.
  cap_git push --quiet origin "HEAD:$BRANCH" >/dev/null 2>&1 || return 1
  return 0
}

# Publish a snapshot of a running step's log.
#
# PUSHES BUT NEVER PULLS OR REBASES, deliberately. The step is appending to that
# log through an open descriptor; a rebase would rewrite the file underneath it
# and the appends would continue at a stale offset. A rejected push is simply
# retried next cycle, and run.sh's own cap_push reconciles properly at the end.
tp_put_progress() {
  local body="$1" msg="$2" logfile="$3"
  mkdir -p "$(dirname "$STATUS")"
  printf '%s' "$body" > "$STATUS"

  git add -f "$STATUS" "$logfile" >/dev/null 2>&1
  git diff --cached --quiet -- "$STATUS" "$logfile" >/dev/null 2>&1 && return 0
  git -c user.name="${GIT_AUTHOR_NAME:-station}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-station@$(hostname)}" \
      commit -q -m "$msg" -- "$STATUS" "$logfile" 2>/dev/null
  cap_git push --quiet origin "HEAD:$BRANCH" >/dev/null 2>&1 || return 1
  return 0
}

# Deliver the finished log.
#
# This is cap_push, unchanged and still in caplib, because its behaviour was
# argued for line by line: it stages only that file, rebases so the push cannot
# be rejected for being behind, aborts a half-applied rebase rather than leaving
# the operator mid-rebase on a machine nobody can investigate, sets an upstream
# on a new branch, and on total failure prints the local path and the credential
# hints instead of exiting. None of that is re-litigated here; the verb just
# names git's implementation of it so that the other transports can have one too.
tp_put_log() { cap_push "$1" "$2"; }

# =============================================================================
#  The preflight - what start.sh asks before it hands over to the loop
# =============================================================================
# Everything below runs ONCE, from start.sh, and never from the loop. It lives
# here rather than in start.sh because of this file's own first rule: every git
# command the station issues is in this file, so nothing else has to know what
# it is talking to. Three of them were not - `git remote get-url`, an
# `ls-remote` and a `push --dry-run` - and keeping them in start.sh is what made
# start.sh refuse to run a station that does not use git at all.
#
# Moved unchanged, comments included. None of it is re-argued here.
# =============================================================================

# git_detail <combined-output> - the line(s) of a git failure that name the cause
#
# `tail -1` was wrong here, and wrong in the two places most likely to fire on a
# new machine. git's transport failures end on a wrapped continuation, so the
# operator got the fragment and a double full stop:
#
#   FAIL  git read  ls-remote failed: and the repository exists.. Check the ...
#
# while "Permission denied (publickey)" or "Could not resolve hostname ..." - the
# line that actually said what was wrong - was thrown away. `head -1` on its own
# is not right either: the generic "fatal: Could not read from remote repository"
# is emitted after the specific line, so it has to be dropped rather than ordered
# around. Keep the lines that name a cause, in git's own order, drop that trailer
# whenever something more specific was printed, and say so when there are more
# than three rather than truncating silently.
#
# CRs are stripped because ssh writes its diagnostics with a trailing CR, which
# inside a printf'd table redraws the line over itself.
#
# The match is CASE-INSENSITIVE, and that is not tidiness. GitHub writes its cause
# in uppercase and without a `remote: ` prefix:
#
#   ERROR: The key you are authenticating with has been marked as read only.
#   fatal: Could not read from remote repository.
#
# A case-sensitive pattern misses the first line, matches the trailer, and hands
# the operator the trailer - which is the whole defect this function exists to fix,
# in the single highest-value case for the write check. A read-only deploy key on
# GitHub is precisely what that check is for. `ERROR: Repository not found.` and
# the SAML SSO line are the same shape. The `grep -v` stays case-sensitive: that
# trailer is git's own text and git always spells it exactly that way.
GIT_CAUSE_RE='^(fatal|error|warning|remote|ssh|hint: Updates):|^ ! \[|Permission denied|Could not resolve|Connection refused|Connection timed out'
git_detail() {
  local clean specific trimmed joined="" line total=0 shown=0
  clean="$(printf '%s\n' "$1" | tr -d '\r')"
  specific="$(printf '%s\n' "$clean" | grep -iE "$GIT_CAUSE_RE" \
                | grep -v 'Could not read from remote repository')"
  [ -n "$specific" ] || specific="$(printf '%s\n' "$clean" | grep -iE "$GIT_CAUSE_RE")"
  [ -n "$specific" ] || specific="$(printf '%s\n' "$clean" | grep -v '^[[:space:]]*$')"
  # A GitLab-style refusal is mostly furniture: a bare `remote:` above and below
  # the message, and `remote: =========` rules around it. Those lines match the
  # cause pattern (they start `remote:`) but carry nothing, and they ate the
  # three-line budget, so the operator got
  #
  #   remote:; remote: ====================================; remote: (+4 more...)
  #
  # and not one word of why the push was refused. Discard them BEFORE the budget
  # is applied, so the budget is spent on sentences.
  #
  # The "(+N more)" count below is taken after this, and therefore means: lines
  # that carried a cause and were withheld for LENGTH. Furniture is not in it,
  # deliberately - "there are also six blank banner lines" is not a reason to go
  # back to a machine nobody can log into.
  #
  # Guarded, because a remote whose whole output is furniture would otherwise be
  # reported as "git printed no diagnostic", which would be a lie about a remote
  # that printed plenty. In that case the furniture is all there is, so show it.
  trimmed="$(printf '%s\n' "$specific" | grep -vE '^[[:space:]]*remote:[-=*[:space:]]*$')"
  [ -n "$trimmed" ] && specific="$trimmed"
  total="$(printf '%s\n' "$specific" | grep -c .)"
  while IFS= read -r line; do
    [ "$shown" -ge 3 ] && break
    line="${line%"${line##*[![:space:]]}"}"   # right-trim
    line="${line%.}"                          # the caller supplies the full stop
    [ -n "$line" ] || continue
    joined="${joined:+$joined; }$line"
    shown=$((shown + 1))
  done <<< "$specific"
  [ "$total" -gt "$shown" ] && joined="$joined (+$((total - shown)) more line(s): run the command by hand to see them)"
  # Never hand back an empty string: the caller interpolates this mid-sentence and
  # "ls-remote failed: . Check ..." tells the reader nothing at all.
  [ -n "$joined" ] || joined="git printed no diagnostic"
  printf '%s' "$joined"
}

# --- the network underneath the credential -----------------------------------
# A CONNECTION FAILURE IS NOT A CREDENTIAL FAILURE, and the read check used to
# end every one of them on "Check the remote URL and the credential reported
# above". Both are usually right, and the operator - the one person who cannot
# debug this - is sent at the two things that are not the problem:
#
#   FAIL  git read   ls-remote failed: ssh: connect to host github.com port 22:
#                    Connection timed out. Check the remote URL and the
#                    credential reported above
#
# An estate that blocks outbound 22 is ordinary, and it is exactly the estate
# this tool is for. So classify first, and blame the credential only when the
# failure is not a statement about the network. The write check already does
# this for a fast-forward refusal; this is the same move on the read side.
#
# THE HOST AND PORT COME OUT OF THE ERROR, not out of the remote URL. ssh says
# "connect to host <h> port <n>" and curl says "Failed to connect to <h> port
# <n>", and that host is the one that actually timed out - which after an
# insteadOf rewrite, a redirect or a proxy is not always the one in the URL.
# It also means these can be tested against canned output.
_git_dial() {  # <output> - "host port", or empty
  printf '%s\n' "$1" \
    | sed -nE 's/.*connect to (host )?([A-Za-z0-9._-]+)[ :]+port ([0-9]+).*/\2 \3/p' \
    | head -1
}

# What a proxy variable says about this machine, credentials removed. "Check the
# proxy variables" is not a remedy when the reader cannot see them from where
# they are standing, and whether one is set changes which answer is right.
_git_proxy_state() {
  local seen="" n v
  for n in https_proxy HTTPS_PROXY http_proxy HTTP_PROXY; do
    v="${!n:-}"
    [ -n "$v" ] || continue
    seen="${seen:+$seen, }$n=$(printf '%s' "$v" | sed -E 's#://[^/@]*@#://***@#')"
  done
  if [ -n "$seen" ]; then
    printf 'A proxy IS set here (%s), so it is on the path and its own rules apply' "$seen"
  else
    printf 'No proxy variable is set here (http_proxy, https_proxy), so nothing is being routed through one'
  fi
}

# _git_network_cause <combined-output> - the remedy, or empty when this failure
# is not the network's. Empty is the signal to fall through to the credential
# text, so a pattern that does not fire costs nothing.
_git_network_cause() {
  local out="$1" dial host port alt ep
  dial="$(_git_dial "$out")"
  host="${dial% *}"; port="${dial#* }"
  [ "$dial" = "$host" ] && { host=""; port=""; }

  # Both major hosts publish an SSH endpoint on 443 for precisely this case, and
  # neither is discoverable from the failure. Nothing here changes: it is
  # ~/.ssh/config or the remote URL, and no part of heliograph touches ports.
  # Matched exactly rather than by substring: a self-hosted gitlab.corp.example
  # is NOT altssh.gitlab.com, and naming an endpoint that host does not run is
  # the same defect as naming the wrong cause.
  case "$host" in
    github.com|*.github.com) alt="GitHub publishes SSH on 443 at ssh.github.com"; ep=ssh.github.com ;;
    gitlab.com|*.gitlab.com) alt="GitLab publishes SSH on 443 at altssh.gitlab.com"; ep=altssh.gitlab.com ;;
    *)                       alt=""; ep="" ;;
  esac

  # Ordered by how specific each pattern is, because a proxy failure also says
  # "connect" and a TLS failure through a proxy also mentions the proxy.
  if printf '%s\n' "$out" | grep -qiE 'could not resolve|name or service not known|nodename nor servname|temporary failure in name resolution'; then
    # A name that did not resolve never got as far as a connection, so it is not
    # in "connect to host ... port ..." and has to be read out of its own line.
    # ssh writes "Could not resolve hostname <h>" and curl "Could not resolve
    # host: <h>".
    host="$(printf '%s\n' "$out" \
              | sed -nE 's/.*[Cc]ould not resolve host(name)?:? ([A-Za-z0-9._-]+).*/\2/p' | head -1)"
    printf 'That is DNS and not the credential: the name never resolved, so nothing was ever sent. Check the spelling in the remote URL, then resolution on this machine with "getent hosts %s". On a split-horizon estate this station may need the internal resolver' \
      "${host:-<the host in the remote URL>}"
  elif printf '%s\n' "$out" | grep -qiE 'received http code 40[37] from proxy|proxy connect aborted|connect tunnel failed|proxy authentication'; then
    printf 'The PROXY refused the tunnel, so nothing reached the git host and the git credential was never offered. That is the proxy'"'"'s own authentication. %s' \
      "$(_git_proxy_state)"
  elif printf '%s\n' "$out" | grep -qiE 'ssl certificate problem|unable to get local issuer|self.signed certificate|certificate verif|sslv3|tlsv1|certificate has expired'; then
    printf 'TLS was refused before any credential was sent, so this is not the token. A proxy that inspects TLS presents its own CA and looks exactly like this. Point git at the estate'"'"'s CA bundle - GIT_SSL_CAINFO=/path/to/ca.pem, or "git config --global http.sslCAInfo /path/to/ca.pem" - and do not turn verification off. %s' \
      "$(_git_proxy_state)"
  elif printf '%s\n' "$out" | grep -qiE 'connection timed out|operation timed out|timed out after'; then
    if [ "$port" = "22" ] && [ -n "$ep" ]; then
      printf 'That is the network and not the credential: nothing answered on port 22, which is what an estate that blocks outbound SSH looks like. %s: put "Host %s / Hostname %s / Port 443" in ~/.ssh/config, then prove it with "ssh -T -p 443 git@%s". If 443 is blocked too, use an https remote or a transport that is not git' \
        "$alt" "$host" "$ep" "$ep"
    elif [ "$port" = "22" ]; then
      printf 'That is the network and not the credential: nothing answered on port 22, which is what an estate that blocks outbound SSH looks like. Ask whether %s answers SSH on 443 as well - GitHub does, at ssh.github.com, and GitLab at altssh.gitlab.com - and point ~/.ssh/config at it with Hostname and Port 443. If 443 is blocked too, use an https remote or a transport that is not git' \
        "${host:-this host}"
    else
      printf 'That is the network and not the credential: nothing answered on %s, so no credential was ever sent. Check egress from this machine to that port. %s' \
        "${port:+port $port}${port:+ }${host:+at $host}" "$(_git_proxy_state)"
    fi
  elif printf '%s\n' "$out" | grep -qiE 'connection refused'; then
    printf 'That is the network and not the credential: the connection to %s was refused outright, so no credential was ever sent. Something is listening and saying no, or an egress firewall is answering for it. %s' \
      "${host:-the remote}${port:+ port $port}" "$(_git_proxy_state)"
  elif printf '%s\n' "$out" | grep -qiE 'network is unreachable|no route to host'; then
    printf 'That is routing and not the credential: this machine has no path to %s at all. Check the route and the egress rules before looking at the token' \
      "${host:-the remote}"
  fi
}

# --- the credential ----------------------------------------------------------
# WHICH credential is even relevant is decided by the remote's scheme: an SSH
# key is useless against an https:// remote and a token useless against git@.
# So branch on the scheme, then report the mechanism without its value.
_git_credential() {
  local url pw_masked masked scheme fps rc desc st
  url="$(git remote get-url origin 2>/dev/null)"
  if [ -z "$url" ]; then
    report FAIL remote "no remote named 'origin'. Git is the transport, so there is nowhere to push a log. Add one: git remote add origin <url>"
    return 0
  fi
  case "$url" in
    git@*|ssh://*)      scheme=ssh ;;
    https://*|http://*) scheme=https ;;
    *)                  scheme=other ;;
  esac
  # People really do arrive with the token-in-URL form (transport.md says so), and
  # git redacts userinfo in its own messages while this did not: the whole
  # https://ci-user:glpat-...@host/... went to stdout, which in PR 3 and PR 4 is
  # container stdout. cap_redact cannot help here - it filters what passes through
  # cap_run, and this table is printed directly - so mask it on the way out.
  #
  # Two rules, in this order, mirroring cap_redact and for the same reasons:
  #   1. `user:password@` between `://` and the first `/`.
  #   2. the BARE `https://TOKEN@host/...` form, which rule 1 misses because rule
  #      1 requires a colon, and which is the commonest GitHub PAT clone URL
  #      there is. Rule 2 cannot re-mask rule 1's output: rule 1 leaves a colon
  #      between `://` and the `@`, and rule 2's class excludes `:`. (Each rule
  #      does still match its OWN output, but `***` is a fixed point of the
  #      substitution, so that pass is a no-op. Two mechanisms, one result;
  #      caplib.sh spells them out.)
  # Rule 2 masks a legitimate `https://username@host/...` username as well. That
  # is deliberate: nothing can tell a username from a token in that position, and
  # a leaked PAT costs incomparably more than a hidden username. It is confined to
  # http/https because a bare userinfo on ssh:// is a login name carrying no
  # secret. `?`, `#` and `,` are excluded from its class so that it stops at the
  # end of the authority rather than masking the HOST out of a line like
  # `https://host?email=foo@bar.com`; `%` is its delimiter so the `#` in that class
  # needs no escaping, which inside a bracket expression would wrongly exclude
  # backslash too. git@host:path, ssh://git@host:2222/... and a local filesystem
  # path all still pass through unaltered.
  #
  # The INTERMEDIATE result is kept, not just the final one. "Did masking change
  # anything" is how the token line below knows the URL carries a credential, and
  # WHICH rule changed it is the difference between "there is a password in here"
  # and "there is a bare userinfo and it may be a username with nothing behind it".
  # Asserting the first for the second is a false diagnosis, and the operator
  # cannot check it against the remote line because that is masked too.
  #
  # The rules live in caplib beside cap_redact's, spelled once each, so a URL a
  # script PRINTS and a URL that passes through the capture can never disagree
  # about what a credential looks like.
  pw_masked="$(cap_mask_url_password "$url")"
  masked="$(cap_mask_url_userinfo "$pw_masked")"
  report ok remote "$masked  ($scheme)"

  case "$scheme" in
    ssh)
      # ssh-add's EXIT STATUS is the answer here, not its stdout. With a live
      # agent holding no keys it prints "The station has no identities." and exits
      # 1, and piping that through `awk '{print $2}'` produced
      # `ok  ssh key  agent offers: agent` - an ok line for the transport this
      # skill recommends, in the state where the key is missing.
      #
      # 0 keys present, 1 agent reachable but empty, 2 no agent at all. The
      # operator's next move differs between the last two, so all three are told
      # apart rather than collapsed into "no key".
      fps="$(ssh-add -l 2>/dev/null)"; rc=$?
      # The ${x% } trims the separator tr leaves on the end: this line gets pasted
      # back into tickets, and trailing whitespace there is noise nobody can see.
      fps="$(printf '%s\n' "$fps" | awk '{print $2}' | tr '\n' ' ')"
      case "$rc" in
        0) report ok "ssh key" "agent offers: ${fps% }" ;;
        1) report warn "ssh key" "an ssh agent is reachable but holds no keys, so nothing can authenticate through it. Run 'ssh-add <path-to-key>'. A key in ~/.ssh may still work: the read and write checks below settle it" ;;
        2) report warn "ssh key" "no ssh agent is reachable (SSH_AUTH_SOCK is ${SSH_AUTH_SOCK:-unset}). Forward one with 'ssh -A', or start one here with 'eval \$(ssh-agent)' then 'ssh-add'. A key in ~/.ssh may still work: the read and write checks below settle it" ;;
        *) report warn "ssh key" "ssh-add exited $rc, so which key is offered is unknown - it may not be installed. Install openssh-client to see the fingerprint; the read and write checks below are what settle it" ;;
      esac
      ;;
    https)
      # cap_auth_describe cannot see the remote, so it names what it looked for
      # and opines on nothing. This DOES know the scheme, so the advice belongs
      # here - and the status is derived from the description rather than
      # asserted over it. "none" on an https remote is not an ok: it is the
      # commonest single reason the read check below fails.
      desc="$(cap_auth_describe)"
      st=ok
      case "$desc" in
        none*)
          st=warn
          # THREE states, not two, and the difference is which masking rule fired.
          #
          # A `user:password@` URL really does carry a credential and git really
          # will use it: a bare "none" there reads as "you have nothing
          # configured" while git is about to authenticate perfectly well.
          #
          # A BARE userinfo is genuinely ambiguous, and saying "carries its own
          # credential" for it is a false diagnosis. `https://ci-user@host/x` has
          # a username and nothing to authenticate with; `https://ghp_...@host/x`
          # is the commonest GitHub PAT clone URL there is. Nothing here can tell
          # them apart - that is the same limit the masking trade-off is built on -
          # so this names both rather than picking one, and the operator, who can
          # see their own remote, settles it in a second. They cannot settle it
          # from the line above, because that userinfo is masked too.
          #
          # The remedial advice is the same in all three states, so it is the
          # diagnosis that has to be honest, not the instruction.
          if [ "$pw_masked" != "$url" ]; then
            desc="$desc. The remote URL carries its own credential, so git will use that instead of a header. Several hosts reject the token-in-URL form outright, so if the read check below fails, set GIT_TOKEN or re-point origin at ssh:// rather than suspecting the token"
          elif [ "$masked" != "$url" ]; then
            desc="$desc. The remote URL carries a bare userinfo and no password. If that is a token, git will authenticate with it; if it is a plain username, there is nothing there to authenticate with and this remote has no credential at all. Set GIT_TOKEN, or re-point origin at ssh:// and use an agent key, which https://docs.heliograph.io/transports#the-credential recommends"
          else
            desc="$desc. An https remote needs one of those. Set GIT_TOKEN, or re-point origin at ssh:// and use an agent key, which https://docs.heliograph.io/transports#the-credential recommends"
          fi ;;
        *"no header is sent"*)
          st=warn ;;
      esac
      report "$st" token "$desc"
      ;;
    other) report warn remote "unrecognised scheme, so the checks below are what settle it" ;;
  esac
}

# --- measure it, rather than assume it ---------------------------------------
# transport.md records the trap this answers: a token that authenticates against
# a host's REST API tells you nothing about whether GIT can authenticate.
# Different credential, different path. So test the path we depend on.
#
# The write check dry-runs against a ref that DOES NOT EXIST on the remote, and
# the choice is load-bearing rather than arbitrary.
#
# `push --dry-run origin HEAD:refs/heads/<current-branch>` is refused LOCALLY as
# a non-fast-forward the moment origin holds a commit this checkout lacks, which
# is the ordinary state every time this script runs: after a reboot, after the
# SSH session died, or any time a step or a request was pushed since the clone.
# The credential is fine and the message blamed it, and the `pull --rebase` that
# would have resolved it is below and never ran. As a container entrypoint that
# is a container that refuses to start after any push.
#
# A ref that does not exist cannot be a non-fast-forward, and --dry-run creates
# nothing, so nothing is left behind on the remote. The push still negotiates
# with git-receive-pack, which is the service write access is granted on, so this
# proves write rather than merely read - which is the whole point of the check.
#
# The name is fixed rather than generated: it is greppable in a git host's audit
# log, it carries the tool's name so nobody mistakes it for someone's work, and a
# deterministic check is one an operator can reproduce by hand. It sits in
# refs/heads/ because that is the namespace station.sh actually pushes to, and some
# hosts refuse a namespace they do not recognise - testing the path we depend on
# is the point.
#
# TWO THINGS THIS CHECK DELIBERATELY DOES NOT CATCH. Both are recorded here so
# the next reader does not take either for an oversight and "fix" it.
#
# 1. A local filesystem remote whose directory is not writable. --dry-run never
#    writes, so it cannot possibly know. Closed as a non-goal rather than fixed:
#    a local path remote appears only in this repo's test fixtures, and the real
#    transport is always a git host. The only way to catch it is to make the
#    check actually write, which would put a real object into a real remote on
#    every single preflight - a worse trade than the case it would cover. Do not
#    "fix" it that way.
#
# 2. A pre-receive hook, or a host ruleset on which branch names may be created.
#    Measured, not assumed: --dry-run negotiates with git-receive-pack and stops
#    there. It sends no pack, so pre-receive and update hooks never run, and a
#    push those would decline is reported here as accepted. The check therefore
#    proves the CREDENTIAL may write, not that this particular ref would survive
#    a hook. For a preflight that is the right side to be wrong on, and it is why
#    the FAIL text below names only things the check can actually see.
WRITE_CHECK_REF="refs/heads/heliograph-write-check"

_git_verify() {
  local out why
  if out="$(cap_git ls-remote --heads origin 2>&1)"; then
    report ok "git read" "ls-remote returned $(printf '%s\n' "$out" | grep -c .) ref(s)"
  else
    # Classify the network before blaming the credential. See _git_network_cause:
    # a timeout, a refusal and a DNS failure are statements about the estate, and
    # each has a different remedy. Empty means it was not one of those, and the
    # credential text below is then the right answer rather than the default one.
    why="$(_git_network_cause "$out")"
    report FAIL "git read" "ls-remote failed: $(git_detail "$out"). ${why:-Check the remote URL and the credential reported above}"
    return 0
  fi

  # Read access is not write access, and the expensive failure is an hour-long
  # step that captures a perfect log and cannot deliver it.
  if out="$(cap_git push --dry-run origin "HEAD:$WRITE_CHECK_REF" 2>&1)"; then
    report ok "git write" "push --dry-run was accepted"
  elif printf '%s\n' "$out" | grep -qiE 'fast-forward|fetch first|behind'; then
    # Classify rather than blaming the credential for every refusal. A
    # fast-forward refusal is a statement about history, not about authorisation.
    report warn "git write" "the remote refused a fast-forward, so write access is unproven rather than denied. That is history, not the credential: the sync below pulls, and station.sh keeps retrying. If it persists, run 'git pull --rebase' by hand"
  elif why="$(_git_network_cause "$out")" && [ -n "$why" ]; then
    # The credential paragraph below asserts that the network is ruled out
    # because the read check passed. When the push itself could not reach the
    # host, that sentence is false - and stating it would be the same defect
    # this classifier exists to remove, one check further down the table.
    report FAIL "git write" "push --dry-run of HEAD:$WRITE_CHECK_REF was refused: $(git_detail "$out"). $why. The read check above did reach the host, so this is the network failing intermittently rather than a standing block"
  else
    # Every clause here has to name something this check can actually detect. It
    # used to end on "a remote that restricts which branch names may be created
    # refuses this check too", which --dry-run never reaches (see the note above
    # WRITE_CHECK_REF), so on a hook- or ruleset-based host it pointed the
    # operator at a red herring in the one message they read when they cannot
    # push. The read check above passed with the same credential, so the URL, the
    # host and the network are already ruled out and the message says so.
    report FAIL "git write" "push --dry-run of HEAD:$WRITE_CHECK_REF was refused: $(git_detail "$out"). The station would capture logs it could not deliver. The read check above passed with this same credential, so the remote URL and the network are not the problem: it is git-receive-pack refusing the write. Check the credential reported above has write access and not just read - a read-only deploy key and a token missing the write scope both look exactly like this - and, on a host that requires it separately, that the token has been authorised for the organisation"
  fi
}

# The branch the operator asked for is NOT necessarily the one checked out:
# `--check --branch station/db-a` exits before anything is checked out, so the
# question can only be answered against the REMOTE. Without this, `--check
# --branch station/db-a` reported on whatever happened to be checked out and
# said nothing at all about db-a - which is the one thing being asked about.
_git_want_scope() {
  local want="$1"
  [ -n "$want" ] || return 0
  if [ "${BRANCH:-}" = "$want" ]; then
    report ok "branch wanted" "$want, already checked out"
  elif cap_git ls-remote --exit-code --heads origin "refs/heads/$want" >/dev/null 2>&1; then
    report ok "branch wanted" "$want exists on origin and would be checked out"
  elif git rev-parse --verify --quiet "refs/heads/$want" >/dev/null 2>&1; then
    report warn "branch wanted" "$want is here but NOT on origin, so this station would publish where nobody is reading. Push it with 'git push -u origin $want'"
  elif [ "${CHECK_ONLY:-0}" = "1" ]; then
    # --check is being asked "will this work here", and it will not. Nothing
    # further will run to say so, because --check exits before the checkout.
    report FAIL "branch wanted" "$want is neither here nor on origin. Create it on the control side with 'heliograph station add <name>', or check the name"
  else
    # A real run WILL reach the checkout, and that stage is the authority on
    # its own failure. Failing here instead would pre-empt a better message
    # with a worse one - it cannot tell a missing branch from a dirty tree,
    # and the container asserts that the checkout's own text reaches the
    # operator through the entrypoint. Say what the remote looks like and
    # leave the verdict to the stage that can give a full one.
    report warn "branch wanted" "$want is neither here nor on origin, so the checkout below will fail. Create it on the control side with 'heliograph station add <name>', or check the name"
  fi
}

# CALLED EVEN WHEN tp_init FAILED, so every `${BRANCH:-}` here is guarded and
# nothing assumes a branch. That is the contract start.sh documents, and it is
# what keeps one trip naming every blocker: a detached HEAD fails tp_init, and a
# read-only deploy key on the same machine has to be reported in the same table
# rather than on the operator's second visit.
#
# Everything below still works detached. `ls-remote` needs no branch, and the
# write check pushes `HEAD:refs/heads/heliograph-write-check`, which is a commit
# on either kind of HEAD.
tp_preflight() {
  if command -v git >/dev/null 2>&1; then
    report ok git "$(git --version)"
  else
    # tp_init has already failed and said so. Repeat it as a check rather than
    # leaving a git preflight with no git line in it at all.
    report FAIL git "git is this station's transport and it is not on PATH. Install git and put it first on PATH"
    return 0
  fi

  # base64 builds the HTTPS auth header, in cap_git, and nowhere else in this
  # toolkit. It was a universal machine check, which refused a relay station -
  # which has no auth header to build - for the absence of a tool it never uses.
  # caplib no longer asks for `-w0`: `base64 | tr -d '\n'` is the same thing and
  # is universal, so this now only fails where there is no base64 at all.
  if printf 'x' | base64 | tr -d '\n' >/dev/null 2>&1; then
    report ok base64 "an HTTPS auth header can be built"
  else
    report FAIL base64 "no usable base64 on PATH, so cap_git cannot build an auth header for an HTTPS remote"
  fi

  [ -n "${BRANCH:-}" ] && report ok branch "$BRANCH"
  _git_want_scope "${TP_WANT_SCOPE:-}"
  _git_credential
  _git_verify
}

# Bring the payload up to date before the loop starts.
#
# NEVER resolves a conflict, never forces and never discards the operator's
# work, for the same reason station.sh does not: their local state may be the
# evidence, and destroying it to make a poll succeed is never the right trade.
#
# Not tp_fetch_self, which is the loop's verb and deliberately does not fetch -
# the loop has just fetched, and paying for a second round trip every poll to
# re-establish something it already knows would be waste. Here nothing has
# fetched yet, so this one has to.
tp_sync() {
  if cap_git pull --rebase --quiet >/dev/null 2>&1; then
    report ok pull "up to date with origin"
    return 0
  fi
  # Bare git, not cap_git: abort touches no network, and cap_git would put the
  # auth header in this process's argv for nothing - visible to anyone else on
  # the box via ps. Do not "helpfully" wrap it back up.
  git rebase --abort >/dev/null 2>&1
  report warn pull "pull --rebase did not succeed, so the tree is being left alone. station.sh will keep retrying"
}

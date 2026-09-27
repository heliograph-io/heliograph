#!/usr/bin/env bash
# =============================================================================
#  test-start.sh - start.sh refuses a machine that cannot capture properly
# =============================================================================
# Be honest about the limit of these: they exercise the checks and the exit
# codes against a local bare repo, and prove nothing about whether a real
# token authenticates against a real git host. That is the one thing that
# matters most and no test here asserts it.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
ROOT="$(cd "$HERE/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GIT="git -c user.email=ci@example.com -c user.name=ci"

# A transport repo with a real, pushable origin. A bare repo on disk is enough
# to exercise ls-remote and push --dry-run for real.
make_repo() {
  local d="$1"
  "$ROOT/station/bootstrap.sh" "$d" >/dev/null 2>&1
  git init -q --bare "$d.origin.git"
  ( cd "$d" \
      && git init -q \
      && git remote add origin "$d.origin.git" \
      && $GIT add -A \
      && $GIT commit -qm init \
      && $GIT push -q -u origin HEAD ) >/dev/null 2>&1
}

run_start() {  # run_start <repodir> [args...] - prints output, sets RC
  local d="$1"; shift
  RC=0
  OUT="$( cd "$d" && ./start.sh "$@" 2>&1 )" || RC=$?
}

# --- the happy path ----------------------------------------------------------
make_repo "$TMP/good"
run_start "$TMP/good" --check
assert_eq "--check exits 0 on a sound machine" "0" "$RC"
assert_contains "--check says the preflight is clear" "preflight: clear" "$OUT"
assert_contains "it reports the sed -u result" "sed -u" "$OUT"
assert_contains "it reports the base64 result" "base64" "$OUT"
assert_contains "it proves read access rather than assuming it" "git read" "$OUT"
assert_contains "it proves write access rather than assuming it" "git write" "$OUT"

# --check must not touch the working tree: it is what an operator runs to answer
# "will this work here", often on a node where they are not allowed to change
# anything yet.
before="$( cd "$TMP/good" && git status --porcelain && git rev-parse HEAD )"
run_start "$TMP/good" --check
after="$( cd "$TMP/good" && git status --porcelain && git rev-parse HEAD )"
assert_eq "--check leaves the working tree and HEAD alone" "$before" "$after"

# --- usage -------------------------------------------------------------------
run_start "$TMP/good" --nonsense
assert_eq "an unknown option exits 2" "2" "$RC"

run_start "$TMP/good" --help
assert_eq "--help exits 0" "0" "$RC"
assert_contains "--help shows the usage" "start.sh" "$OUT"

# --- a sed without -u no longer blocks, and that is a deliberate change -------
# It used to, and the reason was sound at the time: the timestamp was applied
# AFTER sed, so a buffered sed gave every line in a block the same time and a
# hang became invisible while the log still read perfectly.
#
# cap_run now stamps each line before any sed runs, so the timestamps are honest
# whatever sed does. What is left is real but much smaller: redaction is still a
# sed stage and cannot be skipped, so a run killed mid-flight loses whatever sed
# was holding. That is a warning with the trade named, not a refusal - refusing
# would keep Alpine and busybox stations off a toolkit that now works on them.
mkdir -p "$TMP/badbin"
real_sed="$(command -v sed)"
cat > "$TMP/badbin/sed" <<EOF
#!/bin/sh
for a in "\$@"; do
  [ "\$a" = "-u" ] && { echo "sed: unrecognized option: u" >&2; exit 1; }
done
exec "$real_sed" "\$@"
EOF
chmod +x "$TMP/badbin/sed"

make_repo "$TMP/badsed"
RC=0
OUT="$( cd "$TMP/badsed" && PATH="$TMP/badbin:$PATH" ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a sed without -u does not block, because the timestamps survive it" "0" "$RC"
assert_contains "it is reported as a warning" "warn  sed -u" "$OUT"
assert_contains "and says the timestamps are unaffected, which is the load-bearing part" \
  "Timestamps are unaffected" "$OUT"
assert_contains "and names what IS given up" "CANCELLED run will lose its partial log" "$OUT"
assert_contains "and says how to get it back" "GNU sed" "$OUT"

# The claim above is worth more than the warning text, so it is measured rather
# than trusted: capture through the busybox-like sed and check the stamps really
# do differ.
cat > "$TMP/badsed/steps/slow3.sh" <<'EOS'
#!/usr/bin/env bash
# heliograph-mode: read-only
echo one; sleep 1.2; echo two; sleep 1.2; echo three
EOS
chmod +x "$TMP/badsed/steps/slow3.sh"
( cd "$TMP/badsed" && PATH="$TMP/badbin:$PATH" PUSH=0 ./run.sh steps/slow3.sh ) >/dev/null 2>&1
distinct="$(grep ' | ' "$TMP"/badsed/ops-logs/*.txt 2>/dev/null | sed 's/ | .*//' | sort -u | wc -l | tr -d ' ')"
assert_eq "and through that sed the stamps really are distinct" "3" "$distinct"

# --- detached HEAD -----------------------------------------------------------
make_repo "$TMP/detached"
( cd "$TMP/detached" && git checkout -q --detach HEAD ) >/dev/null 2>&1
run_start "$TMP/detached" --check
assert_eq "a detached HEAD blocks, because station.sh would refuse to start" "1" "$RC"
assert_contains "and it says so in those terms" "detached HEAD" "$OUT"

# --- no origin ---------------------------------------------------------------
make_repo "$TMP/noremote"
( cd "$TMP/noremote" && git remote remove origin ) >/dev/null 2>&1
run_start "$TMP/noremote" --check
assert_eq "no origin blocks: git is the transport" "1" "$RC"
assert_contains "and it says which remote is missing" "origin" "$OUT"

# --- a checkout that is merely behind origin is not a credential failure -------
# This is the modal state every time start.sh runs and the agent is not already
# going: after a reboot, after the SSH session died, or any time a step or a
# request was pushed since the clone. `push --dry-run HEAD:refs/heads/<current>`
# is refused LOCALLY as a non-fast-forward in exactly that state, and reporting
# that as an auth problem made a container entrypoint that refuses to start after
# any push, while blaming a credential that was perfect. The write check therefore
# dry-runs against a ref that cannot conflict.
make_repo "$TMP/behind"
br="$( cd "$TMP/behind" && git rev-parse --abbrev-ref HEAD )"
( cd "$TMP/behind" \
    && date > pushed-since-the-clone.txt \
    && $GIT add -A && $GIT commit -qm "the author pushes a step" \
    && $GIT push -q origin HEAD \
    && git reset -q --hard HEAD~1 ) >/dev/null 2>&1
assert_eq "the fixture really is behind origin by one" "1" \
  "$( cd "$TMP/behind" && git rev-list --count "HEAD..origin/$br" )"
run_start "$TMP/behind" --check
assert_eq "a checkout behind origin still passes the preflight" "0" "$RC"
assert_contains "and the write check is accepted, not blamed on the credential" \
  "ok    git write" "$OUT"

# --dry-run must leave nothing behind: a preflight that created a branch on the
# operator's remote every time it ran would be a defect of its own.
assert_eq "the write check creates no ref on the remote" "" \
  "$( cd "$TMP/behind" && git ls-remote --heads origin | grep -o heliograph-write-check )"

# --- and write genuinely refused still blocks ---------------------------------
# Read succeeds, git-receive-pack refuses: what a read-only credential looks like.
# The check above would be worthless if it had become an unconditional pass.
make_repo "$TMP/readonly"
cat > "$TMP/denypack" <<'EOF'
#!/bin/sh
echo "remote: You are not allowed to push code to this project." >&2
exit 1
EOF
chmod +x "$TMP/denypack"
( cd "$TMP/readonly" && git config remote.origin.receivepack "$TMP/denypack" ) >/dev/null 2>&1
run_start "$TMP/readonly" --check
assert_eq "a remote that refuses receive-pack blocks" "1" "$RC"
assert_contains "read having passed is still reported, so the two are told apart" \
  "ok    git read" "$OUT"
assert_contains "and the write failure says what to check" "write access" "$OUT"
# Every clause in that FAIL has to name something this check can actually detect.
# It used to end "a remote that restricts which branch names may be created
# refuses this check too" - which --dry-run never reaches, because it sends no
# pack and pre-receive never runs. On a hook- or ruleset-based host that pointed
# the operator at a red herring in the one message they read when they cannot
# push. The block below measures the reachability rather than asserting it.
assert_eq "and it names no cause a dry-run cannot reach" "" \
  "$(printf '%s' "$OUT" | grep -o 'which branch names may be created')"
assert_contains "and it rules out what the read check already proved" \
  "the remote URL and the network are not the problem" "$OUT"
# `tail -1` handed over git's wrapped continuation instead. The remote's own words
# are the diagnostic, and this is the FAIL most likely to fire on a new machine.
assert_contains "and the remote's own refusal survives into the line" \
  "not allowed to push code" "$OUT"

# --- the documented limitation, pinned so it stays a KNOWN one ----------------
# start.sh records that --dry-run never reaches a pre-receive hook, so a host
# whose ruleset would decline this ref still reports `ok git write`. That is a
# deliberate non-goal, not an oversight. Asserting it means that if some future
# git changes the behaviour, this fails and the comment gets corrected rather
# than quietly becoming false.
make_repo "$TMP/prereceive"
cat > "$TMP/prereceive.origin.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
echo "remote: only refs/heads/release/* may be created here" >&2
exit 1
EOF
chmod +x "$TMP/prereceive.origin.git/hooks/pre-receive"
run_start "$TMP/prereceive" --check
assert_eq "a pre-receive hook does not fail the preflight, as documented" "0" "$RC"
assert_contains "the write check accepts, because --dry-run sends no pack" \
  "ok    git write" "$OUT"

# --- GitHub writes its cause in UPPERCASE, without a remote: prefix -----------
# The single highest-value case for the whole write check: a read-only deploy key
# on GitHub is what that check exists to catch. GitHub's own words are
#
#   ERROR: The key you are authenticating with has been marked as read only.
#   fatal: Could not read from remote repository.
#
# and a case-sensitive cause pattern misses the first line, matches the trailer,
# and hands the operator the trailer - Finding 5's exact defect surviving where it
# costs most. `ERROR: Repository not found.` and the SAML SSO line are identical in
# shape. The CR is in the fixture because that is how it really arrives.
make_repo "$TMP/deploykey"
cat > "$TMP/ghdeploykey" <<'EOF'
#!/bin/sh
printf 'ERROR: The key you are authenticating with has been marked as read only.\r\n' >&2
exit 1
EOF
chmod +x "$TMP/ghdeploykey"
( cd "$TMP/deploykey" && git config remote.origin.receivepack "$TMP/ghdeploykey" ) >/dev/null 2>&1
run_start "$TMP/deploykey" --check
assert_eq "a read-only deploy key blocks" "1" "$RC"
assert_contains "GitHub's uppercase ERROR: line survives into the table" \
  "ERROR: The key you are authenticating with has been marked as read only" "$OUT"
assert_eq "and the generic trailer does not stand in for it" "" \
  "$(printf '%s' "$OUT" | grep -o 'refused: fatal: Could not read from remote repository')"

# --- a GitLab-style banner is furniture, and it ate the whole budget ----------
# GitLab wraps its refusal in bare `remote:` lines and `remote: =====` rules.
# They start with `remote:`, so they match the cause pattern, and they spent all
# three lines of git_detail's budget: the operator got
#   remote:; remote: ==============================; remote: (+6 more line(s)...)
# and the sentence saying WHY was counted among the "more". The budget has to be
# spent on sentences.
make_repo "$TMP/gitlabbanner"
cat > "$TMP/glbanner" <<'EOF'
#!/bin/sh
printf 'remote: \n' >&2
printf 'remote: ========================================================\n' >&2
printf 'remote: \n' >&2
printf 'remote: GitLab: You are not allowed to push code to protected branches on this project.\n' >&2
printf 'remote: \n' >&2
printf 'remote: ========================================================\n' >&2
printf 'remote: \n' >&2
exit 1
EOF
chmod +x "$TMP/glbanner"
( cd "$TMP/gitlabbanner" && git config remote.origin.receivepack "$TMP/glbanner" ) >/dev/null 2>&1
run_start "$TMP/gitlabbanner" --check
assert_eq "a banner-wrapped refusal still blocks" "1" "$RC"
assert_contains "the sentence that says why survives the budget" \
  "You are not allowed to push code to protected branches" "$OUT"
assert_eq "a separator rule never spends a line of it" "" \
  "$(printf '%s' "$OUT" | grep -o 'remote: ====')"
assert_eq "nor does a bare remote: line" "" \
  "$(printf '%s' "$OUT" | grep -oE 'remote:(;| \(\+)')"

# --- the diagnostic must survive, and tail -1 threw it away -------------------
# git's transport failures end on a wrapped continuation ("...and the repository
# exists."), so the operator got a fragment plus a double full stop while the line
# that said what was wrong was discarded.
make_repo "$TMP/badhost"
( cd "$TMP/badhost" && git remote set-url origin git@nonexistent.invalid:x/y.git ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/badhost" \
        && GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' ./start.sh --check 2>&1 )" || RC=$?
assert_eq "an unreachable ssh host blocks" "1" "$RC"
assert_contains "the line that named the cause survives" "Could not resolve hostname" "$OUT"
assert_eq "the wrapped fragment no longer stands in for it" "" \
  "$(printf '%s' "$OUT" | grep -o 'failed: and the repository exists')"
assert_eq "and the double full stop is gone" "" \
  "$(printf '%s' "$OUT" | grep -o '\.\. Check')"
# ssh writes its diagnostics with a trailing CR, which inside a printf'd table
# redraws the line over itself.
assert_eq "no carriage return reaches the table" "" \
  "$(printf '%s' "$OUT" | tr -dc '\r')"
# A NAME THAT DOES NOT RESOLVE IS NOT A CREDENTIAL PROBLEM, and this check used
# to end on "Check the remote URL and the credential reported above" - half of
# which is the wrong half.
assert_contains "a DNS failure is called DNS" "That is DNS and not the credential" "$OUT"
assert_contains "and it names the host it could not resolve" \
  "getent hosts nonexistent.invalid" "$OUT"
assert_eq "and it stops sending the operator at the credential" "" \
  "$(printf '%s' "$OUT" | grep -o 'the credential reported above')"

# --- a blocked port is diagnosed as a blocked port ---------------------------
# An estate that blocks outbound 22 is ordinary, and it is exactly the estate
# this tool is for. The operator saw the right URL and the right credential
# named as the two things to check, and 443 was nowhere in the repository.
#
# `remote.origin.uploadpack` is the read-side twin of the `receivepack`
# override used above: git runs it and the failure arrives through the real
# transport, so these are the station's own words about git's own text rather
# than a message injected into the middle of the check.
fake_read() {  # fake_read <name> <stderr-line>... - ls-remote fails with these
  local name="$1"; shift
  make_repo "$TMP/$name"
  {
    printf '#!/bin/sh\n'
    printf "cat >&2 <<'FAKEEOF'\n"
    printf '%s\n' "$@"
    printf 'FAKEEOF\nexit 128\n'
  } > "$TMP/$name.upload"
  chmod +x "$TMP/$name.upload"
  ( cd "$TMP/$name" && git config remote.origin.uploadpack "$TMP/$name.upload" ) >/dev/null 2>&1
  run_start "$TMP/$name" --check
}

fake_read blocked22 \
  "$(printf 'ssh: connect to host github.com port 22: Connection timed out\r')" \
  'fatal: Could not read from remote repository.'
assert_eq "a blocked port still blocks the start" "1" "$RC"
assert_contains "git's own line still survives into the table" \
  "connect to host github.com port 22: Connection timed out" "$OUT"
assert_contains "the timeout is called the network" \
  "That is the network and not the credential" "$OUT"
assert_contains "and the remedy names the endpoint that would work" \
  "ssh.github.com" "$OUT"
assert_contains "with the ssh config that reaches it" "Port 443" "$OUT"
assert_contains "and a command to prove it by hand" \
  "ssh -T -p 443 git@ssh.github.com" "$OUT"
assert_eq "the credential is no longer blamed for a blocked port" "" \
  "$(printf '%s' "$OUT" | grep -o 'the credential reported above')"

fake_read blocked22gl \
  'ssh: connect to host gitlab.com port 22: Connection timed out'
assert_contains "GitLab gets GitLab's endpoint" "altssh.gitlab.com" "$OUT"

# A host nobody here knows gets a question, not an answer.
fake_read blocked22self \
  'ssh: connect to host gitlab.corp.example port 22: Connection timed out'
assert_contains "an unknown host is asked about rather than assumed" \
  "Ask whether gitlab.corp.example answers SSH on 443" "$OUT"

# AND THE MATCH IS EXACT, not a substring. This fixture is chosen to be the one
# a `*gitlab.com` glob gets wrong: it ends in gitlab.com and is not GitLab. The
# first version of this check used gitlab.corp.example, which no glob of that
# shape matches either - so it passed with the bug in place and proved nothing.
# Sending this operator to altssh.gitlab.com would point their station at
# somebody else's server, which is a worse answer than the one being fixed.
#
# ONE FIXTURE PER PATTERN, because a single one proves only the pattern it
# happens to hit: with the GitLab match loosened and only a GitLab look-alike
# here, the GitHub half could go the same way unwatched.
for lookalike in ourgitlab.com mygithub.com; do
  fake_read "blocked22-$lookalike" \
    "ssh: connect to host $lookalike port 22: Connection timed out"
  assert_contains "a look-alike host is treated as unknown ($lookalike)" \
    "Ask whether $lookalike answers SSH on 443" "$OUT"
  assert_eq "and no endpoint belonging to someone else is invented for it ($lookalike)" "" \
    "$(printf '%s' "$OUT" | grep -oE 'Hostname (ssh\.github\.com|altssh\.gitlab\.com)')"
done

# --- refused, and inspected: the two other shapes an estate produces ---------
fake_read refused \
  "fatal: unable to access 'https://git.corp.example/x.git/': Failed to connect to git.corp.example port 443 after 12 ms: Connection refused"
assert_contains "a refusal names the host and port that refused" \
  "connection to git.corp.example port 443 was refused" "$OUT"
assert_eq "and does not blame the credential either" "" \
  "$(printf '%s' "$OUT" | grep -o 'the credential reported above')"

# A corporate proxy with its own CA is the ordinary way an https remote fails in
# these estates, and it reads exactly like a bad token.
fake_read tlsmitm \
  "fatal: unable to access 'https://git.corp.example/x.git/': SSL certificate problem: unable to get local issuer certificate"
assert_contains "an untrusted CA is called TLS, not the token" \
  "TLS was refused before any credential was sent" "$OUT"
assert_contains "and the remedy is the estate's CA bundle" "GIT_SSL_CAINFO" "$OUT"
assert_contains "and it says not to turn verification off" \
  "do not turn verification off" "$OUT"

# WHETHER A PROXY IS SET IS PART OF THE DIAGNOSIS. "Check the proxy variables"
# is not a remedy for someone who cannot see them from where they are standing,
# and the answer differs depending on which way it goes.
assert_contains "with no proxy set, the table says so" \
  "No proxy variable is set here" "$OUT"
RC=0
OUT="$( cd "$TMP/tlsmitm" \
        && https_proxy='http://ci:hunter2@proxy.corp:8080' ./start.sh --check 2>&1 )" || RC=$?
assert_contains "with one set, it is named" "A proxy IS set here" "$OUT"
assert_contains "and its address is reported" "proxy.corp:8080" "$OUT"
assert_eq "and its password never is" "" "$(printf '%s' "$OUT" | grep -o hunter2)"

# --- TEETH: the classifier must not swallow a real credential failure --------
# A pattern that fires on everything would replace one wrong answer with
# another. A refused key is the credential, and the message has to keep saying
# so.
fake_read publickey \
  'git@github.com: Permission denied (publickey).' \
  'fatal: Could not read from remote repository.'
assert_contains "a refused key is still sent at the credential" \
  "the credential reported above" "$OUT"
assert_eq "and is not miscalled a network failure" "" \
  "$(printf '%s' "$OUT" | grep -o 'That is the network')"

# --- an unreachable https remote exercises the token branch ------------------
make_repo "$TMP/https"
( cd "$TMP/https" && git remote set-url origin https://example.invalid/x.git ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/https" && GIT_TOKEN=abcd ./start.sh --check 2>&1 )" || RC=$?
assert_eq "an unreachable remote blocks rather than starting the agent" "1" "$RC"
assert_contains "the token mechanism is named" "GIT_TOKEN" "$OUT"
assert_contains "the token length is reported" "4 chars" "$OUT"
assert_eq "the token value is never printed" "" "$(printf '%s' "$OUT" | grep -o abcd)"

# --- https with no credential at all: the commonest first-run state ------------
# The read check FAILs with "check the credential reported above"; the token line
# above it used to read `ok  token  none, so git is used unmodified - correct for
# an SSH remote` on an https remote. Two contradictory lines, neither actionable.
make_repo "$TMP/notoken"
( cd "$TMP/notoken" && git remote set-url origin https://example.invalid/x.git ) >/dev/null 2>&1
bare_env=( env -u GIT_AUTH_HEADER -u GIT_TOKEN -u GIT_TOKEN_FILE HOME="$TMP/notoken" )
RC=0
OUT="$( cd "$TMP/notoken" && "${bare_env[@]}" ./start.sh --check 2>&1 )" || RC=$?
assert_contains "no credential on an https remote is a warn, not an ok" "warn  token" "$OUT"
assert_eq "and it no longer calls that correct for an SSH remote" "" \
  "$(printf '%s' "$OUT" | grep -o 'correct for an SSH remote')"
assert_contains "and it names what was looked for" \
  "no readable GIT_AUTH_HEADER, GIT_TOKEN, GIT_TOKEN_FILE or .git-token" "$OUT"
assert_contains "and says what to do about it on an https remote" "ssh://" "$OUT"

# The status must be DERIVED from the description, not asserted over it: describe
# reports "so no header is sent" for a token file that is unreadable or whose
# first line is empty, and git then runs with no credential at all.
: > "$TMP/notoken/.git-token"
RC=0
OUT="$( cd "$TMP/notoken" && "${bare_env[@]}" ./start.sh --check 2>&1 )" || RC=$?
assert_contains "an empty token file is a warn, not an ok" "warn  token" "$OUT"
assert_contains "and the line says no header is sent" "no header is sent" "$OUT"

# --- a GIT_TOKEN_FILE that is there but cannot be read ------------------------
# Docker and Kubernetes mount a secret root-owned and hand it to a non-root
# process, so PRs 3 and 4 make this shape ordinary. The preflight used to list
# GIT_TOKEN_FILE among the things that were not set, which denies a variable the
# operator did set and sends them looking for something they already provided.
# The path and the permissions are the actionable facts.
#
# Skipped under root, where mode 000 is still readable and the state cannot be
# built - PR 3's container runs as root, so someone will run this suite there.
if [ "$(id -u)" != "0" ]; then
  make_repo "$TMP/unreadtok"
  ( cd "$TMP/unreadtok" && git remote set-url origin https://example.invalid/x.git ) >/dev/null 2>&1
  printf 'a-real-token\n' > "$TMP/unreadable-secret"
  chmod 000 "$TMP/unreadable-secret"
  RC=0
  OUT="$( cd "$TMP/unreadtok" \
          && env -u GIT_AUTH_HEADER -u GIT_TOKEN HOME="$TMP/unreadtok" \
                 GIT_TOKEN_FILE="$TMP/unreadable-secret" ./start.sh --check 2>&1 )" || RC=$?
  assert_contains "an unreadable token file is a warn, not an ok" "warn  token" "$OUT"
  assert_contains "and the preflight names the file rather than denying it" \
    "$TMP/unreadable-secret" "$OUT"
  assert_contains "and says which user cannot read it" "is not readable by" "$OUT"
  assert_eq "and it no longer reports the file as simply absent" "" \
    "$(printf '%s' "$OUT" | grep -o 'no readable GIT_AUTH_HEADER')"
  assert_eq "and the token it could not read is still never printed" "" \
    "$(printf '%s' "$OUT" | grep -o a-real-token)"
  chmod 644 "$TMP/unreadable-secret"
else
  t_skip 'the unreadable GIT_TOKEN_FILE preflight test: running as root, where mode 000 is still readable'
fi

# --- a token embedded in the remote URL is a credential too --------------------
# transport.md records that people arrive with this form, git redacts userinfo in
# its own messages, and cap_redact does not catch this shape. The remote line
# printed it verbatim, which in PRs 3 and 4 is container stdout.
make_repo "$TMP/urltoken"
( cd "$TMP/urltoken" \
    && git remote set-url origin https://ci-user:glpat-SUPERSECRET@git.invalid/p/t.git \
  ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/urltoken" && ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a token in the remote URL is never printed" "" \
  "$(printf '%s' "$OUT" | grep -o glpat-SUPERSECRET)"
# BOTH SIDES OF THE COLON, and the username is not spared.
# `https://<token>:x-oauth-basic@github.com/org/repo.git` is a documented git
# form in which the SECRET is the username, so masking only the password prints
# the credential in full in the shape most likely to carry a real one. The
# station's own remote is the only URL this masker is ever given, and that form
# lives exactly there. cap_redact keeps the username for arbitrary log text, for
# the opposite reason, and caplib says why.
assert_contains "the rest of the URL still is, or the line diagnoses nothing" \
  "https://***:***@git.invalid/p/t.git" "$OUT"
assert_eq "and the userinfo USERNAME is masked too, because that position carries the token in the x-oauth-basic form" \
  "" "$(printf '%s' "$OUT" | grep -o 'ci-user:\*\*\*')"
# A bare "none" would read as "you have nothing configured" while git is about to
# authenticate perfectly well with what the URL carries. This is the ONE state in
# which that sentence is true, and it is true because the colon rule fired.
assert_contains "and the token line says the URL carries its own credential" \
  "The remote URL carries its own credential" "$OUT"

# --- and so is a BARE token in the remote URL, which has no colon at all --------
# `https://ghp_...@github.com/org/repo.git` is the commonest GitHub PAT clone URL
# there is, and the mask above requires a colon, so this form was printed verbatim
# AND reported as "none" - the preflight telling an operator no credential is
# configured while git was about to authenticate with the one in the URL.
make_repo "$TMP/urlbaretoken"
( cd "$TMP/urlbaretoken" \
    && git remote set-url origin https://ghp_SUPERSECRETPAT@github.invalid/p/t.git \
  ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/urlbaretoken" \
        && env -u GIT_AUTH_HEADER -u GIT_TOKEN -u GIT_TOKEN_FILE \
               HOME="$TMP/urlbaretoken" ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a bare token in the remote URL is never printed" "" \
  "$(printf '%s' "$OUT" | grep -o ghp_SUPERSECRETPAT)"
assert_contains "the host and path still are, or the line diagnoses nothing" \
  "https://***@github.invalid/p/t.git" "$OUT"
# Deliberately NOT "carries its own credential". That sentence is true of a
# user:password URL and merely PLAUSIBLE here: a bare userinfo is a token on
# GitHub and a bare username everywhere else, and nothing in start.sh can tell
# which - the same limit the masking trade-off is built on. So the line names both
# readings rather than asserting one.
assert_contains "a bare userinfo is reported as the ambiguity it is" \
  "The remote URL carries a bare userinfo and no password" "$OUT"
assert_contains "and it says a token in that position does authenticate" \
  "If that is a token, git will authenticate with it" "$OUT"

# --- the same shape with a plain username, which carries nothing ---------------
# The false diagnosis this distinction exists to prevent: masking the bare form
# made `https://ci-user@host/x` compare unequal to the original, so the preflight
# asserted "the remote URL carries its own credential, so git will use that
# instead of a header" about a URL with nothing in it to authenticate with. Base
# printed the correct advice here, so this was a regression against base.
#
# The operator cannot check that claim against the remote line either, because the
# username is masked out of it. Which RULE fired is the only thing that separates
# the two, and it is what start.sh now branches on.
make_repo "$TMP/urlusername"
( cd "$TMP/urlusername" \
    && git remote set-url origin https://ci-user@git.invalid/p/t.git ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/urlusername" \
        && env -u GIT_AUTH_HEADER -u GIT_TOKEN -u GIT_TOKEN_FILE \
               HOME="$TMP/urlusername" ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a username-only remote is never told it carries a credential" "" \
  "$(printf '%s' "$OUT" | grep -o 'carries its own credential')"
assert_contains "it is told the truth: userinfo, and no password" \
  "The remote URL carries a bare userinfo and no password" "$OUT"
assert_contains "and that a plain username authenticates with nothing" \
  "there is nothing there to authenticate with" "$OUT"
# The remedial advice is right in every state, so it must survive the branching.
assert_contains "and the remedy base printed is still there" \
  "Set GIT_TOKEN, or re-point origin at ssh://" "$OUT"

# The three states must be genuinely distinct, or the branch is decoration. This
# needs its OWN fixture: $TMP/notoken has an empty ./.git-token by now, so its
# describe returns "no header is sent" and never reaches the none* branch where
# these sentences are appended - an assertion there could not fail either way.
make_repo "$TMP/urlnouserinfo"
( cd "$TMP/urlnouserinfo" \
    && git remote set-url origin https://git.invalid/p/t.git ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/urlnouserinfo" \
        && env -u GIT_AUTH_HEADER -u GIT_TOKEN -u GIT_TOKEN_FILE \
               HOME="$TMP/urlnouserinfo" ./start.sh --check 2>&1 )" || RC=$?
assert_contains "a no-userinfo remote still reaches the none branch" \
  "none: no readable GIT_AUTH_HEADER" "$OUT"
assert_eq "and gets neither of the two URL sentences" "" \
  "$(printf '%s' "$OUT" | grep -o 'The remote URL carries')"
assert_contains "just the plain requirement" \
  "An https remote needs one of those" "$OUT"

# ssh and local remotes must come through untouched: masking a colon in
# git@host:path would make the line useless for the transport we recommend.
make_repo "$TMP/urlssh"
( cd "$TMP/urlssh" && git remote set-url origin git@git.invalid:p/t.git ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/urlssh" && ./start.sh --check 2>&1 )" || RC=$?
assert_contains "an scp-form ssh remote is printed unaltered" \
  "git@git.invalid:p/t.git" "$OUT"
assert_contains "and a local path remote is too" \
  "$TMP/good.origin.git" "$( cd "$TMP/good" && ./start.sh --check 2>&1 )"

# --- ssh-add's exit status, not its stdout ------------------------------------
# With a live agent holding no keys, ssh-add prints "The agent has no identities."
# on stdout and exits 1, so `awk '{print $2}'` produced
# `ok  ssh key  agent offers: agent`: an ok line for the transport this skill
# recommends, in the state where the key is missing. 0 with identities, 1 for
# agent-but-empty, 2 for no agent, and the operator's next move differs between
# the last two, so all three are told apart.
make_repo "$TMP/sshkey"
( cd "$TMP/sshkey" && git remote set-url origin git@example.invalid:x/y.git ) >/dev/null 2>&1
mkdir -p "$TMP/sshbin"
fake_ssh_add() {  # fake_ssh_add <exit-status> <stdout-line>
  cat > "$TMP/sshbin/ssh-add" <<EOF
#!/bin/sh
echo "$2"
exit $1
EOF
  chmod +x "$TMP/sshbin/ssh-add"
}
ssh_out() {
  ( cd "$TMP/sshkey" && PATH="$TMP/sshbin:$PATH" \
      GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' ./start.sh --check 2>&1 )
}

fake_ssh_add 0 "256 SHA256:AAAA0000 the-key (ED25519)"
OUT="$(ssh_out)"
assert_contains "ssh-add exit 0: the fingerprint is what gets reported" \
  "ok    ssh key       agent offers: SHA256:AAAA0000" "$OUT"

fake_ssh_add 1 "The agent has no identities."
OUT="$(ssh_out)"
assert_contains "ssh-add exit 1: an empty agent is a warn, not an ok" "warn  ssh key" "$OUT"
assert_eq "ssh-add exit 1: 'agent' is never mistaken for a fingerprint" "" \
  "$(printf '%s' "$OUT" | grep -o 'agent offers: agent')"
assert_contains "ssh-add exit 1: and it says to add a key" "ssh-add <path-to-key>" "$OUT"

fake_ssh_add 2 "Could not open a connection to your authentication agent."
OUT="$(ssh_out)"
assert_contains "ssh-add exit 2: no agent at all is a warn" "warn  ssh key" "$OUT"
assert_contains "ssh-add exit 2: and the action is a different one" "ssh -A" "$OUT"
assert_contains "ssh-add exit 2: naming the variable that decides it" "SSH_AUTH_SOCK" "$OUT"

fake_ssh_add 127 "ssh-add: not found"
OUT="$(ssh_out)"
assert_contains "an unexpected ssh-add status says so rather than guessing" \
  "ssh-add exited 127" "$OUT"

# --- the handover ------------------------------------------------------------
# start.sh must exec station.sh rather than run it as a child, so that the
# operator's Ctrl-C reaches the agent and its cleanup trap fires. A stub agent
# that reports its own pid is how that gets proved.
make_repo "$TMP/handover"
cat > "$TMP/handover/station.sh" <<'EOF'
#!/usr/bin/env bash
echo "STUB AGENT pid=$$ args=$*"
EOF
chmod +x "$TMP/handover/station.sh"

RC=0
OUT="$( cd "$TMP/handover" && ./start.sh 2>&1 )" || RC=$?
assert_eq "without --check it runs the agent" "0" "$RC"
assert_contains "and the agent actually ran" "STUB AGENT" "$OUT"

RC=0
OUT="$( cd "$TMP/handover" && ./start.sh -- --once --interval 15 2>&1 )" || RC=$?
assert_contains "args after -- reach station.sh" "args=--once --interval 15" "$OUT"

# exec, not a subshell: the agent must end up with start.sh's own pid.
RC=0
OUT="$( cd "$TMP/handover" && bash -c 'echo "SHELL pid=$$"; exec ./start.sh' 2>&1 )" || RC=$?
shell_pid="$(printf '%s\n' "$OUT" | sed -n 's/^SHELL pid=//p')"
agent_pid="$(printf '%s\n' "$OUT" | sed -n 's/.*STUB AGENT pid=\([0-9]*\).*/\1/p')"
assert_eq "station.sh is exec'd, so Ctrl-C reaches it" "$shell_pid" "$agent_pid"

# --check must still not reach the agent.
RC=0
OUT="$( cd "$TMP/handover" && ./start.sh --check 2>&1 )" || RC=$?
assert_eq "--check does not run the agent" "" "$(printf '%s' "$OUT" | grep -o 'STUB AGENT')"

# --- --branch ----------------------------------------------------------------
make_repo "$TMP/branchy"
cp "$TMP/handover/station.sh" "$TMP/branchy/station.sh"
( cd "$TMP/branchy" && $GIT checkout -q -b task/probe && $GIT push -q -u origin task/probe \
    && git checkout -q - ) >/dev/null 2>&1
RC=0
OUT="$( cd "$TMP/branchy" && ./start.sh --branch task/probe 2>&1 )" || RC=$?
assert_eq "--branch checks the branch out" "task/probe" \
  "$( cd "$TMP/branchy" && git rev-parse --abbrev-ref HEAD )"
assert_contains "and says it did" "task/probe" "$OUT"

RC=0
OUT="$( cd "$TMP/branchy" && ./start.sh --branch task/nope 2>&1 )" || RC=$?
assert_eq "a branch that does not exist blocks" "1" "$RC"
assert_contains "and names it" "task/nope" "$OUT"

# --- --branch validation -------------------------------------------------------
# Harmless while WANT_BRANCH was inert; once the sync acts on it, a missing or
# empty value must not silently become a no-op checkout.
RC=0
OUT="$( cd "$TMP/good" && ./start.sh --branch 2>&1 )" || RC=$?
assert_eq "--branch with no value is a usage error" "2" "$RC"
assert_contains "and it names the problem" "--branch" "$OUT"

# =============================================================================
#  A station whose transport is not git
# =============================================================================
# THE DEFECT THESE EXIST FOR. start.sh checked a git remote, a git credential
# and a git push unconditionally, and one FAIL stops before station.sh runs. So
# `./start.sh` - the one command every host, every container entrypoint and
# every page tells the operator to type - could not start a relay or blob
# station at all. /hosts said "by hand", meaning: set eight variables and skip
# the only preflight there is, on a machine nobody can log into.
#
# The fixture is deliberately NOT a git repository. That is the whole point: it
# is the state a relay station is actually in, and the state in which every
# assertion below used to fail.
FAKE="$TMP/fake"; mkdir -p "$FAKE"
cat > "$FAKE/curl" <<'EOS'
#!/usr/bin/env bash
# Health, then the authenticated poll. Both answer 200, which is what a
# reachable relay with an accepted token looks like.
printf '%s\n' "$*" >> "${FAKE_CALLS:-/dev/null}"
printf '200'
EOS
chmod +x "$FAKE/curl"
cat > "$FAKE/seal" <<'EOS'
#!/usr/bin/env bash
[ "${1:-}" = "fingerprint" ] && { printf 'SHA256:fake\n'; exit 0; }
exit 0
EOS
chmod +x "$FAKE/seal"

make_payload() {  # a bootstrapped payload with NO git repository in it
  "$ROOT/station/bootstrap.sh" "$1" >/dev/null 2>&1
  cat > "$1/station.sh" <<'EOF'
#!/usr/bin/env bash
echo "STUB AGENT pid=$$ args=$*"
EOF
  chmod +x "$1/station.sh"
}

relay_env() {
  export TRANSPORT=relay
  export RELAY_URL=https://relay.invalid RELAY_ESTATE=e1 RELAY_STATION=s1 \
         RELAY_TOKEN=tok RELAY_IDENTITY="$FAKE/id" RELAY_PEER="$FAKE/peer" \
         RELAY_SEAL="$FAKE/seal" RELAY_SEAL_SHA256="$SEAL_SHA"
  export PATH="$FAKE:$PATH"
}
: > "$FAKE/id"; : > "$FAKE/peer"
SEAL_SHA="$(sha256sum "$FAKE/seal" | cut -d' ' -f1)"

make_payload "$TMP/relaystation"
RC=0
OUT="$( cd "$TMP/relaystation" && relay_env && ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a relay station passes the preflight, in a directory that is not a git repository" \
  "0" "$RC"
assert_contains "and says so" "preflight: clear" "$OUT"
assert_contains "the transport is named, not assumed" "ok    transport     relay" "$OUT"
assert_contains "and it is reported reachable, which is what tp_check answered" \
  "relay reach" "$OUT"

# THE STATION'S OWN FINGERPRINT, which it did not print until this was added.
#
# The PowerShell station has printed both since it was written
# (`station/powershell/transports/relay.psm1:539-547`). This one printed only
# the peer's, so an operator standing at a bash station had nothing of their own
# to read out - and reading twelve characters back over a channel they already
# trust is the whole of what closes enrolment's residual risk
# (`internal/seal/seal.go:76-86`). A ceremony whose input is hard to obtain is
# a ceremony people skip, and nothing detects that they skipped it.
#
# Asserted as the WHOLE ROW rather than by searching for the value, because the
# peer row carries the same value from the same fake and a bare grep for it
# passed with the identity row missing entirely.
assert_contains "the station prints its own fingerprint, for the operator to read out" \
  "ok    identity      SHA256:fake  <- read this to the control side" "$OUT"
assert_contains "and the peer's, to check against" \
  "ok    peer          SHA256:fake  <- and check this against theirs" "$OUT"

# Both fingerprints are printed BEFORE the network is touched, so an operator
# with no route out still leaves with the value they were asked for. Ordered by
# line number rather than by eye.
IDENTITY_LINE="$(printf '%s\n' "$OUT" | grep -n '^ok    identity' | cut -d: -f1)"
REACH_LINE="$(printf '%s\n' "$OUT" | grep -n 'relay reach' | cut -d: -f1)"
assert_eq "the fingerprints come before the reach check, not after it" "yes" \
  "$( [ -n "$IDENTITY_LINE" ] && [ -n "$REACH_LINE" ] && [ "$IDENTITY_LINE" -lt "$REACH_LINE" ] && echo yes || echo no )"

# A key file that will not parse is caught here rather than on the first request
# that never runs, and the line names WHICH key: the identity is made on this
# machine, the peer arrives from the control side, and they are set by different
# people at different times.
cat > "$FAKE/badseal" <<'EOS'
#!/usr/bin/env bash
[ "${1:-}" = "fingerprint" ] && exit 1
exit 0
EOS
chmod +x "$FAKE/badseal"
BADSEAL_SHA="$(sha256sum "$FAKE/badseal" | cut -d' ' -f1)"
RC=0
OUT="$( cd "$TMP/relaystation" && relay_env \
        && export RELAY_SEAL="$FAKE/badseal" RELAY_SEAL_SHA256="$BADSEAL_SHA" \
        && ./start.sh --check 2>&1 )" || RC=$?
assert_contains "a key that will not parse names the station's own key file" \
  "FAIL  identity" "$OUT"
assert_contains "and says where it is made, because the operator makes it here" \
  "heliograph-seal keygen" "$OUT"
assert_contains "a peer that will not parse is named separately" "FAIL  peer" "$OUT"
assert_eq "and the preflight blocks rather than starting a station that verifies nothing" "1" "$RC"
# EVERY git row, not just the write check. Asserting on `git write` alone proved
# nothing: the old code never reached it in a directory with no repository,
# because `git read` failed first and returned early. It would have passed
# against the very code this change exists to replace.
assert_eq "not one git check runs: there is no git here to check" "0" \
  "$(printf '%s\n' "$OUT" | grep -cE '^(ok|warn|FAIL) +(git|branch|remote|token|ssh key)\b')"
assert_eq "and it never asks for an origin remote that this station has no use for" "" \
  "$(printf '%s\n' "$OUT" | grep -o "no remote named 'origin'")"

# base64 was a universal blocking check, and its only caller is cap_git building
# an HTTPS auth header. A relay station has no auth header to build, so it was
# being refused for the absence of a tool it never uses - and told the reason
# was a git remote it does not have.
#
# SHADOWED, not assumed absent. The machine running this has base64, so
# asserting "no FAIL base64 appeared" would have passed whatever the code did.
mkdir -p "$FAKE/nob64"
printf '#!/usr/bin/env bash\nexit 127\n' > "$FAKE/nob64/base64"
chmod +x "$FAKE/nob64/base64"
cp "$FAKE/curl" "$FAKE/nob64/curl"; cp "$FAKE/seal" "$FAKE/nob64/seal"
RC=0
OUT="$( cd "$TMP/relaystation" && relay_env && export PATH="$FAKE/nob64:$PATH" \
        && ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a relay station with no usable base64 still passes: it never builds an auth header" \
  "0" "$RC"
assert_eq "and is not told to install one for a git remote it does not have" "" \
  "$(printf '%s\n' "$OUT" | grep -o 'FAIL  base64')"

# The same shadowing on the git transport must still block, or the check has
# been dropped rather than moved.
RC=0
OUT="$( cd "$TMP/good" && PATH="$FAKE/nob64:$PATH" ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a git station with no usable base64 still blocks" "1" "$RC"
assert_contains "and the check moved rather than vanished" "FAIL  base64" "$OUT"

# --- a tp_preflight that fails without saying so ------------------------------
# FAIL CLOSED. A tp_preflight is expected to speak through `report`, but one
# that simply returns non-zero - a future transport, a half-written one - left
# FAILED untouched, and start.sh reported the preflight clear on a channel that
# had just said it was not usable.
make_payload "$TMP/silentfail"
cat > "$TMP/silentfail/transports/probe.sh" <<'EOF'
#!/usr/bin/env bash
tp_capabilities() { printf 'request status progress\n'; }
tp_init() { return 0; }
tp_scope() { printf 'probe'; }
tp_revision() { printf 'probe'; }
tp_describe() { printf 'a transport that fails quietly'; }
tp_check() { return 0; }
tp_fetch_request() { printf ''; }
tp_put_status() { return 0; }
tp_put_progress() { return 0; }
tp_put_log() { return 0; }
tp_preflight() { return 1; }
EOF
RC=0
OUT="$( cd "$TMP/silentfail" && TRANSPORT=probe ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a tp_preflight that returns non-zero blocks even if it reported nothing" "1" "$RC"
assert_contains "and the missing explanation is called what it is" \
  "that is a defect in transports/probe.sh" "$OUT"

# The handover, not just the checks: a preflight that passes and then refuses to
# hand over would be the same wasted trip in a different place.
RC=0
OUT="$( cd "$TMP/relaystation" && relay_env && ./start.sh 2>&1 )" || RC=$?
assert_eq "and without --check it hands over to station.sh" "0" "$RC"
assert_contains "which actually ran" "STUB AGENT" "$OUT"
assert_eq "no git pull is attempted on a transport that cannot sync" "" \
  "$(printf '%s\n' "$OUT" | grep -o 'ok    pull')"

# --- a relay that is misconfigured says WHICH variable -------------------------
# tp_init's own words, folded into the table. Without this the operator gets
# either silence or a git message about a remote they were never going to have.
make_payload "$TMP/relaybad"
RC=0
OUT="$( cd "$TMP/relaybad" && export TRANSPORT=relay PATH="$FAKE:$PATH" && ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a relay station with nothing configured blocks" "1" "$RC"
assert_contains "and the failure is the transport's, named as such" \
  "FAIL  transport" "$OUT"
assert_contains "and it names the variable that is missing" "RELAY_URL" "$OUT"
assert_eq "rather than blaming a git remote it was never going to have" "" \
  "$(printf '%s\n' "$OUT" | grep -o "no remote named 'origin'")"

# --- a relay that cannot be reached ------------------------------------------
# tp_check's answer, which is the generic question every transport can answer.
# A curl that never returns 200 is a relay that is down or a token that is wrong.
mkdir -p "$FAKE/down"
cat > "$FAKE/down/curl" <<'EOS'
#!/usr/bin/env bash
printf '503'
EOS
chmod +x "$FAKE/down/curl"
cp "$FAKE/seal" "$FAKE/down/seal"
make_payload "$TMP/relaydown"
RC=0
OUT="$( cd "$TMP/relaydown" && relay_env && export PATH="$FAKE/down:$PATH" && ./start.sh --check 2>&1 )" || RC=$?
assert_eq "an unreachable relay blocks rather than starting the station" "1" "$RC"
assert_contains "and it is reported as the transport failing to answer" \
  "FAIL  relay reach" "$OUT"
assert_contains "and it says where to look for the variables" \
  "transports/relay.sh" "$OUT"

# --- --branch is refused where a branch means nothing --------------------------
# REFUSED, NOT IGNORED. Accepting it silently would let somebody believe they
# had pointed a relay station somewhere it is not pointed, and being wrong about
# which machine a station answers for is the failure this design exists to stop.
RC=0
OUT="$( cd "$TMP/relaystation" && relay_env && ./start.sh --check --branch station/db-a 2>&1 )" || RC=$?
assert_eq "--branch on a non-git transport blocks" "1" "$RC"
assert_contains "and says whose flag it is" "the git transport's" "$OUT"
assert_contains "and names the transport that was actually selected" "relay" "$OUT"

# --- a transport name that is not one -----------------------------------------
# The name becomes a filename that gets SOURCED. `TRANSPORT=../station` resolves
# to $REPO_ROOT/transports/../station.sh, which is the LOOP, sourced into the
# middle of the preflight. caplib refuses anything but lowercase, digits and
# hyphens, and this is that check reaching the operator.
#
# THE FIXTURE'S station.sh IS A STUB THAT ANNOUNCES ITSELF. Asserting the
# absence of a marker no file in the fixture ever prints is asserting nothing,
# and the first version of this test did exactly that.
make_repo "$TMP/traversal"
cat > "$TMP/traversal/station.sh" <<'EOF'
#!/usr/bin/env bash
echo "SOURCED THE LOOP"
EOF
chmod +x "$TMP/traversal/station.sh"
RC=0
OUT="$( cd "$TMP/traversal" && TRANSPORT=../station ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a transport name that is a path blocks" "1" "$RC"
assert_contains "and says why the name itself is the problem" \
  "sourced" "$OUT"
assert_eq "and the loop is never sourced into the preflight" "" \
  "$(printf '%s\n' "$OUT" | grep -o 'SOURCED THE LOOP')"

RC=0
OUT="$( cd "$TMP/good" && TRANSPORT=carrierpigeon ./start.sh --check 2>&1 )" || RC=$?
assert_eq "an unknown transport blocks" "1" "$RC"
assert_contains "and lists what this payload actually ships, rather than saying 'a valid one'" \
  "git" "$OUT"
assert_contains "including the ones that are not the default" "relay" "$OUT"

# --- the git transport is unchanged -------------------------------------------
# Everything moved, so this pins that nothing was lost on the way: the git
# station still gets its own credential diagnosis and its own write check, which
# tp_check alone would never have made.
run_start "$TMP/good" --check
assert_contains "git still reports the transport it selected" "ok    transport     git" "$OUT"
assert_contains "git still proves write, which no generic tp_check does" "git write" "$OUT"
assert_contains "and still reports the branch it is on" "ok    branch" "$OUT"

# --- a token in the remote URL never reaches the TRANSPORT line ---------------
# tp_describe prints the remote, and station.sh says it at start straight to the
# terminal and the journal. cap_redact cannot help: that is a stream filter on
# the capture path and this line does not go down it.
#
# PINNED TO THAT ONE LINE, not to the whole output. `credential()` has masked
# the `remote` row since long before this change, so asserting "the token is
# absent from $OUT" passes against the old code and proves nothing about
# tp_describe. Isolating the row makes it fail there twice over: the token is
# present, and the row does not exist at all.
make_repo "$TMP/tokenurl"
( cd "$TMP/tokenurl" && git remote set-url origin \
    'https://ci-user:glpat-SECRETVALUE@git.invalid/org/repo.git' ) >/dev/null 2>&1
run_start "$TMP/tokenurl" --check
tline="$(printf '%s\n' "$OUT" | grep '^ok    transport')"
assert_contains "there IS a transport line to inspect" "git" "$tline"
assert_eq "and it never prints the token the remote URL carries" "" \
  "$(printf '%s\n' "$tline" | grep -o 'glpat-SECRETVALUE')"
assert_contains "while the host and path survive, or the line identifies nothing" \
  "git.invalid/org/repo.git" "$tline"

# --- one trip names every blocker it can see ----------------------------------
# A REGRESSION THIS CHANGE NEARLY SHIPPED. git's tp_init refuses a detached
# HEAD, and stopping there reported only that - so an operator with a detached
# HEAD and a broken remote fixed the branch, ran it again, and only then learnt
# about the remote. Two trips to a machine nobody can log into, where the old
# preflight named both at once. tp_preflight is contracted to be callable after
# a failed tp_init for exactly this.
make_repo "$TMP/detachedandbroken"
( cd "$TMP/detachedandbroken" \
    && git remote set-url origin https://nonexistent.invalid/p/t.git \
    && git checkout -q --detach HEAD ) >/dev/null 2>&1
run_start "$TMP/detachedandbroken" --check
assert_eq "a detached HEAD still blocks" "1" "$RC"
assert_contains "and it is still named in those words" "detached HEAD" "$OUT"
assert_contains "and the remote is diagnosed in the SAME trip, not the next one" \
  "git read" "$OUT"
assert_contains "including which credential was in force for it" "remote" "$OUT"

# =============================================================================
#  The blob transport gets the same treatment
# =============================================================================
# Relay alone would leave an implementation that handles relay and still refuses
# every blob station passing this file green.
BLOBFAKE="$TMP/blobfake"; mkdir -p "$BLOBFAKE"
cat > "$BLOBFAKE/curl" <<'EOS'
#!/usr/bin/env bash
# A PUT is what tp_check now makes: 201 is Azure's "created".
case " $* " in *' -X PUT '*) printf '201' ;; *) printf '404' ;; esac
EOS
chmod +x "$BLOBFAKE/curl"

make_payload "$TMP/blobstation"
RC=0
OUT="$( cd "$TMP/blobstation" && export TRANSPORT=blob PATH="$BLOBFAKE:$PATH" \
        PIGEONHOLE_ACCOUNT=acct PIGEONHOLE_LANE=lane1 PIGEONHOLE_SAS='sv=x&sig=y' \
        && ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a blob station passes the preflight, in a directory that is not a git repository" \
  "0" "$RC"
assert_contains "and the transport is named" "ok    transport     blob" "$OUT"
assert_contains "and the lane is in the description, because that is its scope" \
  "lane1" "$OUT"
assert_eq "and no git row appears" "0" \
  "$(printf '%s\n' "$OUT" | grep -cE '^(ok|warn|FAIL) +(git|branch|remote|token)\b')"

# A SAS that can read and not write is the failure this check exists for: it
# answers 200 to every read it will ever be asked for, and fails on the first
# status upload an hour later with nobody left to tell.
mkdir -p "$BLOBFAKE/ro"
cat > "$BLOBFAKE/ro/curl" <<'EOS'
#!/usr/bin/env bash
case " $* " in *' -X PUT '*) printf '403' ;; *) printf '200' ;; esac
EOS
chmod +x "$BLOBFAKE/ro/curl"
RC=0
OUT="$( cd "$TMP/blobstation" && export TRANSPORT=blob PATH="$BLOBFAKE/ro:$PATH" \
        PIGEONHOLE_ACCOUNT=acct PIGEONHOLE_LANE=lane1 PIGEONHOLE_SAS='sv=x&sig=y' \
        && ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a read-only SAS blocks, because reading is not what a station needs" "1" "$RC"
assert_contains "and it is reported as the transport failing" "FAIL  blob reach" "$OUT"

# --- a relay whose peer key is missing -----------------------------------------
# Readable was never checked for RELAY_PEER, only for RELAY_IDENTITY. A station
# with no peer key started perfectly, then failed every verification and every
# seal, for a reason the preflight had already been told and swallowed.
make_payload "$TMP/relaynopeer"
RC=0
OUT="$( cd "$TMP/relaynopeer" && relay_env && export RELAY_PEER="$TMP/does-not-exist" \
        && ./start.sh --check 2>&1 )" || RC=$?
assert_eq "a relay station with no peer key blocks" "1" "$RC"
assert_contains "and names the file it cannot read" "does-not-exist" "$OUT"
assert_contains "and says what would have failed" "verified against" "$OUT"

t_summary

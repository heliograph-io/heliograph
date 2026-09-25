#!/usr/bin/env bash
# =============================================================================
#  test-doc-coherence.sh - the skill says what the toolkit does
# =============================================================================
# SKILL.md is read by an agent that will act on it without checking. So a number
# in it is not prose, it is an assertion about code that lives in another file
# and changes on its own schedule.
#
# The failure this prevents has a particular shape. Someone changes a default in
# station.sh for a good reason. Nothing breaks, every test passes, and the skill
# now tells an agent something that used to be true. The agent waits 60 seconds
# for a progress snapshot that is never coming, on a machine nobody can reach,
# and the round trip is spent finding out that the documentation lied.
#
# So every fact SKILL.md states about the toolkit is checked against the
# toolkit. If you change a default, this fails, and the fix is to change the
# sentence as well. That is the entire point: it is not here to be passed, it is
# here to make the two files move together.
#
# Near-side facts - CLI flags, MCP tool names - used to belong to another
# repository. Since the 2026-09-08 merge the binary is built from this tree, so
# the few flags SKILL.md does pass are checked against the verb's own --help
# below, rather than against a copy of them typed into this file.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"

SKILL_DIR="$HERE/../skills/heliograph"
SKILL="$SKILL_DIR/SKILL.md"
TOOLKIT="$HERE/../station/bash"
STATION="$TOOLKIT/station.sh"

# --- the file has to exist before anything below means anything --------------
# Without this the greps below all find nothing and every assertion "passes" by
# looking at an empty string.
if [ ! -f "$SKILL" ] || [ ! -f "$STATION" ]; then
  t_no "SKILL.md and station/bash/station.sh are both present"
  t_summary
  exit 1
fi
t_ok "SKILL.md and station/bash/station.sh are both present"

# --- defaults ----------------------------------------------------------------
# Pulled OUT of the code rather than compared to a literal written twice. A
# constant repeated in the test is a third copy to drift.
progress_default="$(sed -n 's/^PROGRESS_EVERY="\${PROGRESS_EVERY:-\([0-9]*\)}".*/\1/p' "$STATION" | head -1)"
actions_default="$(sed -n 's/^ALLOW_ACTIONS="\${ALLOW_ACTIONS:-\([0-9]*\)}".*/\1/p' "$STATION" | head -1)"

assert_eq "station.sh has a PROGRESS_EVERY default the test can read" \
  "60" "$progress_default"

# SKILL.md states the interval in prose, twice. Both have to agree with the code.
skill_progress_claims="$(grep -c "every $progress_default seconds" "$SKILL")"
if [ "$skill_progress_claims" -ge 1 ]; then
  t_ok "SKILL.md's progress interval matches PROGRESS_EVERY=$progress_default"
else
  t_no "SKILL.md's progress interval matches PROGRESS_EVERY=$progress_default"
  printf '     station.sh defaults to %ss; SKILL.md does not say "every %s seconds" anywhere\n' \
    "$progress_default" "$progress_default"
  printf '     it currently says: %s\n' "$(grep -o "every [0-9]* seconds" "$SKILL" | sort -u | tr '\n' ' ')"
fi

# --- read-only by default ----------------------------------------------------
# The single most important claim in the file. An agent that believes the loop
# is read-only when it is not will propose a step it would not otherwise
# propose, and the operator has already agreed to run whatever arrives.
assert_eq "station.sh is read-only by default" "0" "$actions_default"
if grep -q "read-only by default" "$SKILL"; then
  t_ok "SKILL.md says the loop is read-only by default"
else
  t_no "SKILL.md says the loop is read-only by default"
fi

# --- the flag that opens the gate --------------------------------------------
for flag in --allow-actions --no-actions; do
  if grep -q -- "$flag)" "$STATION"; then
    t_ok "station.sh accepts $flag"
  else
    t_no "station.sh accepts $flag"
  fi
done
if grep -q -- "--allow-actions" "$SKILL"; then
  t_ok "SKILL.md names --allow-actions as the flag that permits an action"
else
  t_no "SKILL.md names --allow-actions as the flag that permits an action"
fi

# --- the confirmation string -------------------------------------------------
# SKILL.md tells the reader to put CONFIRM=yes in the request. If the station
# ever looked for a different string, the request would be refused and the
# reason would point at a spelling nobody could see from the near side.
if grep -q "CONFIRM=yes" "$SKILL" && grep -rq "CONFIRM" "$TOOLKIT/run.sh"; then
  t_ok "CONFIRM=yes appears in both SKILL.md and run.sh"
else
  t_no "CONFIRM=yes appears in both SKILL.md and run.sh"
fi

# --- what the far side needs -------------------------------------------------
# SKILL.md used to say the far side needs "bash 4+, git and GNU coreutils,
# nothing else", and that nothing done on the control side ever adds a
# requirement there. Both stopped being true: choosing the relay or starting a
# trusted set puts heliograph-seal on a bash station, which refuses to start
# without it. An agent that trusted the old sentence promised an operator
# something the station then refused.
#
# The list of compiled things a station may need is station/FAR-SIDE-BINARIES,
# which CI already holds to what the station references. So SKILL.md has to
# name every entry in it - read from the file, not typed here, so a second
# entry fails this until the skill says so.
FAR_SIDE="$HERE/../station/FAR-SIDE-BINARIES"
far_bins="$(grep -vE '^[[:space:]]*(#|$)' "$FAR_SIDE" 2>/dev/null | awk '{print $1}' | sort -u)"
if [ -z "$far_bins" ]; then
  t_no "station/FAR-SIDE-BINARIES lists at least one binary the test can read"
fi
for bin in $far_bins; do
  if grep -qF -- "$bin" "$SKILL"; then
    t_ok "SKILL.md names $bin, which station/FAR-SIDE-BINARIES allows on the far side"
  else
    t_no "SKILL.md names $bin, which station/FAR-SIDE-BINARIES allows on the far side"
    printf '     a station may need it, and an agent will not tell the operator\n'
  fi
done

# And the two choices that bring it in, named beside it. The relay is named
# without its flag, which the check further down keeps off this page.
seal_para="$(awk '/heliograph-seal/ { p = 1 } p { print } /^$/ { if (p) exit }' "$SKILL")"
for choice in "relay" "trust init"; do
  assert_contains "SKILL.md names $choice beside heliograph-seal" "$choice" "$seal_para"
done

# The busybox sed is a warning in start.sh now, not a refusal, so GNU
# coreutils cannot be described as a requirement.
if grep -q 'report warn "sed -u"' "$TOOLKIT/start.sh"; then
  claims="$(grep -n 'GNU coreutils' "$SKILL" | grep -v 'not required' || true)"
  if [ -z "$claims" ]; then
    t_ok "SKILL.md does not call GNU coreutils a requirement"
  else
    t_no "SKILL.md does not call GNU coreutils a requirement"
    printf '     start.sh only warns about a sed without -u:\n     %s\n' "$claims"
  fi
else
  t_no "start.sh still treats a sed without -u as a warning, as SKILL.md says"
fi

# --- the paths ---------------------------------------------------------------
# SKILL.md names these as the files the two sides write. They are the contract
# with the near-side CLI as well, which writes station/request by the same
# rules, so a rename here is a rename in two repositories.
for path in station/request station/status ops-logs; do
  in_skill=no; in_toolkit=no
  grep -q "$path" "$SKILL" && in_skill=yes
  grep -rq "$path" "$STATION" && in_toolkit=yes
  if [ "$in_skill" = yes ] && [ "$in_toolkit" = yes ]; then
    t_ok "$path is named in both SKILL.md and station.sh"
  else
    t_no "$path is named in both SKILL.md and station.sh"
    printf '     in SKILL.md: %s, in station.sh: %s\n' "$in_skill" "$in_toolkit"
  fi
done

# --- every script SKILL.md tells you to run has to be there ------------------
# A command in a skill is an instruction an agent will follow verbatim. One that
# points at a path that does not exist fails in front of the operator, which is
# the audience this repository most needs to keep.
while IFS= read -r rel; do
  if [ -e "$SKILL_DIR/$rel" ]; then
    t_ok "SKILL.md points at \${CLAUDE_SKILL_DIR}/$rel, which exists"
  else
    t_no "SKILL.md points at \${CLAUDE_SKILL_DIR}/$rel, which does not exist"
  fi
done < <(grep -o '\${CLAUDE_SKILL_DIR}/[A-Za-z0-9_./-]*' "$SKILL" \
           | sed 's|\${CLAUDE_SKILL_DIR}/||' | sort -u)

# --- links resolve, and nothing is orphaned ----------------------------------
# Two directions, because they fail differently. A dead link wastes a read. An
# orphan is worse: a reference nobody is routed to is one nobody maintains, and
# it goes stale silently while still looking authoritative when finally opened.
linked="$(grep -o '(references/[a-z-]*\.md)' "$SKILL" | tr -d '()' | sort -u)"
for rel in $linked; do
  if [ -f "$SKILL_DIR/$rel" ]; then
    t_ok "SKILL.md links $rel, which exists"
  else
    t_no "SKILL.md links $rel, which does not exist"
  fi
done

for f in "$SKILL_DIR"/references/*.md; do
  [ -f "$f" ] || continue
  rel="references/$(basename "$f")"
  case "$linked" in
    *"$rel"*) t_ok "$rel is reachable from SKILL.md" ;;
    *) t_no "$rel is reachable from SKILL.md"
       printf '     it exists but nothing links to it, so nobody will read it\n' ;;
  esac
done

# --- the near side is described, but not restated ----------------------------
# The skill has to say the CLI exists: an agent that does not know will
# hand-edit a request file when a command would have done it correctly.
#
# It must NOT restate the CLI's flags. Those live on the site, next to the
# binary that implements them. This asserts the boundary is where it was put:
# the site is linked, and the flag tables are not copied back in.
if grep -q "heliograph.dbhq.uk" "$SKILL"; then
  t_ok "SKILL.md links the site for near-side reference"
else
  t_no "SKILL.md links the site for near-side reference"
fi

# `--interval` and `--min` are CLI-only flags with no station-side meaning.
# Finding one here means a flag table was copied in, which is the exact
# duplication the split between the two repositories exists to prevent.
#
# `--timeout` WAS on this list and came off it on purpose. `watch` without it
# waits indefinitely, and an agent's shell call has a time limit, so the call
# was killed mid-watch and the agent lost track of the request. The list was
# what kept the fix out: the one flag an agent must pass was the one the skill
# was forbidden to name. It is required below instead.
copied=""
for f in --interval --min --transport; do
  grep -q -- "$f" "$SKILL" && copied="$copied $f"
done
if [ -z "$copied" ]; then
  t_ok "SKILL.md does not restate CLI-only flags"
else
  t_no "SKILL.md does not restate CLI-only flags"
  printf '     found:%s - these belong on the site, next to the binary\n' "$copied"
fi

# --- what binds a request ----------------------------------------------------
# The station refuses a request whose declared mode no longer matches the step,
# and one past its expiry, and `doctor` tells the reader to start a trusted set.
# SKILL.md said none of it, so an agent could not explain any of those three
# refusals, or the doctor line, to the person waiting on them. These are the
# flags the skill does name, on purpose, because an agent has to choose them.
for term in "--mode" "--expires" "trust init"; do
  if grep -q -- "$term" "$SKILL"; then
    t_ok "SKILL.md covers $term"
  else
    t_no "SKILL.md covers $term"
  fi
done

# The default is a number in prose, so it is read from the code like the
# progress interval above.
expiry_hours="$(sed -n 's/^const defaultExpiry = \([0-9]*\) \* time\.Hour$/\1/p' "$HERE/../cmd/heliograph/main.go")"
if [ -n "$expiry_hours" ] && grep -q "valid for $expiry_hours hours by default" "$SKILL"; then
  t_ok "SKILL.md's request expiry matches defaultExpiry=${expiry_hours}h"
else
  t_no "SKILL.md's request expiry matches defaultExpiry=${expiry_hours:-<unreadable>}h"
fi

# --- every flag SKILL.md passes to a verb, that verb accepts ------------------
# A flag in the skill is typed verbatim by an agent. One the verb does not
# accept stops the command with a usage error in front of somebody who asked
# for a run. So every `heliograph <verb> ... --flag` in SKILL.md, in a code
# block or an inline span, is checked against that verb's own --help, from a
# binary built from this tree. The station moved into this repository on
# 2026-09-08, so the binary is here to ask.
cli_uses() {  # "verb<TAB>--flag" for every flag SKILL.md passes to a verb
  { awk '/^```/ { inb = !inb; next } inb' "$SKILL"
    grep -o '`heliograph [^`]*`' "$SKILL" | tr -d '`'
  } | sed 's/[[:space:]]#.*$//' | grep -E '^[[:space:]]*heliograph [a-z]' \
    | while read -r _ verb rest; do
        case "$verb" in
          trust|station|relay)
            sub="${rest%% *}"
            case "$sub" in -*|"") ;; *) verb="$verb $sub"; rest="${rest#"$sub"}" ;; esac ;;
        esac
        for f in $(printf '%s\n' "$rest" | grep -oE '(^|[[:space:]])--[a-z][a-z-]*'); do
          printf '%s\t%s\n' "$verb" "$f"
        done
      done | sort -u
}
if command -v go >/dev/null 2>&1; then
  cli_bin="$(mktemp -d)/heliograph"
  if (cd "$HERE/.." && go build -o "$cli_bin" ./cmd/heliograph) 2>/dev/null; then
    uses="$(cli_uses)"
    [ -n "$uses" ] || t_no "SKILL.md passes at least one flag to a verb (none found, so this checked nothing)"
    while IFS="$(printf '\t')" read -r verb flag; do
      [ -n "$verb" ] || continue
      # shellcheck disable=SC2086
      help="$("$cli_bin" $verb --help 2>&1)"
      if printf '%s\n' "$help" | grep -qE "^[[:space:]]+-${flag#--}( |$)"; then
        t_ok "heliograph $verb accepts $flag, as SKILL.md passes it"
      else
        t_no "heliograph $verb accepts $flag, as SKILL.md passes it"
      fi
    done <<< "$uses"
    for flag in --mode --expires; do
      if "$cli_bin" send --help 2>&1 | grep -qE "^[[:space:]]+-${flag#--}( |$)"; then
        t_ok "heliograph send accepts $flag, which SKILL.md names"
      else
        t_no "heliograph send accepts $flag, which SKILL.md names"
      fi
    done
    rm -rf "$(dirname "$cli_bin")"
  else
    t_no "the CLI builds, so SKILL.md's flags can be checked against it"
  fi
else
  t_skip "no Go toolchain, so SKILL.md's flags were NOT checked against the CLI"
fi

# --- every watch is bounded -------------------------------------------------
# Every `heliograph watch` an agent could copy, in a code block or an inline
# span, carries --timeout. A diagram line that merely mentions watch does not
# start with the command, so it is not read as one.
watch_cmds="$( { awk '/^```/ { inb = !inb; next } inb' "$SKILL"
                 grep -o '`heliograph watch[^`]*`' "$SKILL" | tr -d '`'
               } | grep -E '^[[:space:]]*heliograph watch( |$)' || true)"
if [ -z "$watch_cmds" ]; then
  t_no "SKILL.md shows how to watch a request (no heliograph watch command found)"
else
  unbounded="$(printf '%s\n' "$watch_cmds" | grep -v -- '--timeout' || true)"
  if [ -z "$unbounded" ]; then
    t_ok "every heliograph watch in SKILL.md is bounded with --timeout ($(printf '%s\n' "$watch_cmds" | grep -c .))"
  else
    t_no "every heliograph watch in SKILL.md is bounded with --timeout"
    printf '%s\n' "$unbounded" | sed 's/^/     unbounded: /'
  fi
fi
# That watch accepts --timeout at all is asked of the binary above, with
# every other flag SKILL.md passes.

# --- the MCP tools are preferred, and named ----------------------------------
# SKILL.md named the MCP server only in its links table, so an agent with the
# tools loaded shelled out to the CLI anyway. It now says to use them, and it
# has to name every one: read from the tool list, so a new tool fails this until
# the skill says when to use it.
mcp_tools="$(grep -oE 'Name:[[:space:]]*"heliograph_[a-z_]+"' "$HERE/../cmd/heliograph/mcptools.go" \
               | sed 's/.*"\(heliograph_[a-z_]*\)"/\1/' | sort -u)"
if [ -z "$mcp_tools" ]; then
  t_no "cmd/heliograph/mcptools.go defines tools the test can read"
fi
for tool in $mcp_tools; do
  if grep -q -- "$tool" "$SKILL"; then
    t_ok "SKILL.md names the MCP tool $tool"
  else
    t_no "SKILL.md names the MCP tool $tool"
  fi
done
if grep -qi 'MCP tools are loaded, use them' "$SKILL"; then
  t_ok "SKILL.md tells an agent to prefer loaded MCP tools over the CLI"
else
  t_no "SKILL.md tells an agent to prefer loaded MCP tools over the CLI"
fi

# --- the term that was retired -----------------------------------------------
# `agent` retired as a heliograph term for the far-side loop. That loop is a
# station. The word itself is not banned and cannot be: this skill is read by an
# AI agent, is driven by one over MCP, and a forwarded ssh agent is a third
# thing entirely. All three keep the name.
#
# What is banned is the loop being called one, because the document is read in
# the one context where that ambiguity is most expensive - by an agent, about
# something that is not it.
#
# The senses are told apart by what else is on the line. That is a heuristic
# rather than a parser, and it is the right trade: it catches the copy-paste
# from an older draft, which is how the word actually comes back.
stray="$(grep -n '\bagent\b' "$SKILL" | grep -viE 'ssh|mcp|\bAI\b|agent key|coding agent' || true)"
if [ -z "$stray" ]; then
  t_ok "SKILL.md does not call the far-side loop an agent"
else
  t_no "SKILL.md does not call the far-side loop an agent"
  printf '     %s\n' "$stray"
fi

# --- the same rule, applied to the toolkit -----------------------------------
# The rename reached SKILL.md and references/ first; the toolkit's own comments
# came last, and this is what stops them drifting back.
#
# THE EXCLUSIONS ARE THE INTERESTING PART, and they are reasons rather than a
# mute list. Every one of these is `agent` meaning something that genuinely is
# an agent, or a name that cannot change without breaking a machine:
#
#   agent/request, agent/status, .agent-state, .agent-approved, .agent.lock,
#   .agent-service.pid
#       read by the compat shim for stations bootstrapped before the rename.
#       Those machines cannot be reached to be upgraded - that is the entire
#       premise of this tool - so renaming them breaks precisely the estates
#       the shim exists for.
#
#   the sentence in station.sh explaining the rename
#       it has to say the old word or it stops explaining anything.
#
#   blob_up agent, "requests, logs, status and agent"
#       a literal storage container name on accounts that already exist.
#
#   a forwarded ssh agent, an Azure DevOps build agent
#       that is what those things are called.
stray_toolkit="$(grep -rn '\bagents\?\b' "$TOOLKIT" --include='*.sh' --include='*.ps1' 2>/dev/null \
  | grep -viE 'ssh|forwarded|build agent|user-agent|blob_up agent|status and agent|/agent/|agent/request|agent/status|\.agent[-.]|agent-service|called the .agent.|vocabulary changed|agent key|agent holding|agent reachable|agent at all|agent will not be usable' \
  || true)"
if [ -z "$stray_toolkit" ]; then
  t_ok "the toolkit does not call the far-side loop an agent"
else
  t_no "the toolkit does not call the far-side loop an agent"
  printf '%s\n' "$stray_toolkit" | sed 's/^/     /'
fi

# And the compat shim's paths must still be there, because an over-eager rename
# of the kind above is exactly what would remove them - silently, and only
# visibly on a machine nobody can reach.
missing=""
for path in "agent/request" "agent/status" ".agent-state" ".agent-approved" ".agent.lock"; do
  grep -q -- "$path" "$STATION" || missing="$missing $path"
done
if [ -z "$missing" ]; then
  t_ok "the compat shim still reads every pre-rename path"
else
  t_no "the compat shim has lost:$missing"
  printf '     A station bootstrapped before the rename would go silently deaf.\n'
fi

# =============================================================================
#  The two payloads' ignore files must agree, exactly, about what never ships
# =============================================================================
# THE RULES THAT KEEP A CREDENTIAL OUT OF A REPOSITORY MAY NOT DEPEND ON WHICH
# PAYLOAD SOMEBODY PLANTED FIRST.
#
# Both payloads can be planted into the same transport repo with `--flavour
# both`, and nothing is ever overwritten - so whichever went first supplies the
# .gitignore that then governs the other. A rule present in only one of them is
# therefore present or absent depending on the order two commands were typed
# in, and the rules in question are the ones that stop `.station-env` - which
# holds a token - being committed to a repo that gets cloned onto a control
# node.
#
# So the block is duplicated on purpose and this refuses a change to one that
# was not made to the other. Byte for byte, because "covers the same things" is
# a judgement and this has to be a test.
BASH_IGNORE="$(dirname "$STATION")/gitignore"
PS_IGNORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../station/powershell" 2>/dev/null && pwd)/gitignore"

extract_shared() {  # extract_shared <file> - the marked block, or nothing
  sed -n '/^#  BEGIN SHARED BLOCK/,/^#  END SHARED BLOCK/p' "$1" 2>/dev/null
}

if [ ! -f "$BASH_IGNORE" ] || [ ! -f "$PS_IGNORE" ]; then
  t_skip "one of the two payload gitignore files is missing, so they were NOT compared"
else
  shared_a="$(extract_shared "$BASH_IGNORE")"
  shared_b="$(extract_shared "$PS_IGNORE")"
  if [ -z "$shared_a" ] || [ -z "$shared_b" ]; then
    # AN EMPTY BLOCK MUST FAIL, not pass. Two absences comparing equal is the
    # oldest way a guard like this goes quiet: delete the markers from both
    # files and a byte comparison of nothing against nothing succeeds.
    t_no "one of the payload gitignore files has no BEGIN/END SHARED BLOCK markers"
    printf '     bash block: %s bytes, powershell block: %s bytes\n' "${#shared_a}" "${#shared_b}"
  elif [ "$shared_a" = "$shared_b" ]; then
    t_ok "both payloads' gitignore files carry an identical shared block ($(printf '%s' "$shared_a" | grep -c .) lines)"
  else
    t_no "the two payloads' gitignore shared blocks have drifted"
    diff <(printf '%s\n' "$shared_a") <(printf '%s\n' "$shared_b") | head -20 | sed 's/^/     /'
  fi

  # AND IT HAS TO ACTUALLY CONTAIN THE RULES. A shared block that matched
  # perfectly and listed nothing would pass everything above.
  missing=""
  for rule in ".station-env" ".station-approved" ".station-approved-ps" \
              ".station-delivery" ".station.lock" "*.pem" "*.key" ".git-token"; do
    printf '%s\n' "$shared_a" | grep -qxF "$rule" || missing="$missing $rule"
  done
  if [ -z "$missing" ]; then
    t_ok "the shared block still ignores every file that holds or reveals a credential"
  else
    t_no "the shared block has lost:$missing"
    printf '     A transport repo could commit one of those. .station-env holds a token.\n'
  fi
fi

t_summary

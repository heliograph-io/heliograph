#!/usr/bin/env bash
# =============================================================================
#  transports/blob.sh - Azure Blob Storage, under the station's contract
# =============================================================================
# Sourced by station.sh. For a control node that cannot reach a git host at all:
# a locked-down subnet whose default route goes to a firewall with no policy for
# it has no outbound path, and git stops being a transport and becomes a
# dependency that cannot be met. A private endpoint is VNet-local, so that
# traffic never touches the route that is blocking everything else.
#
# The primitives here - set_auth, drop_get, drop_put - are pigeonhole.sh's,
# unchanged, because they were paid for by deploying them. What has gone is the
# 450 lines of loop that sat on top and duplicated station.sh.
#
# WHAT THIS TRANSPORT CANNOT DO
#
# It cannot self-update: there is no repository to pull and no working tree to
# replace, so a station on this transport is changed by re-planting it. That is
# declared rather than discovered, and station.sh says so at start.
#
# WHY curl AND REST, NOT THE SDK OR az
#
# A SAS is validated by the storage service itself with no token round trip.
# Every Entra path needs a network call first, and a host with no egress has
# none: on a VNet-injected Container Instance there is no IMDS at all. And an
# image minimal enough to be worth deploying may have no `az` and no Python,
# with nothing installable at runtime. See https://docs.heliograph.io/flare.
# =============================================================================

# No `self`: see the header. No `live` either - a mid-run read costs two blob
# operations per poll against a store that bills per operation, and the cancel
# it exists to deliver can wait for the next cycle.
tp_capabilities() { printf 'request status progress\n'; }

BLOB_API_VERSION="${PIGEONHOLE_API_VERSION:-2021-08-06}"

tp_init() {
  command -v curl >/dev/null 2>&1 || {
    echo "station: the blob transport needs curl, which is not on PATH." >&2
    return 1
  }
  # cap_need rather than `${VAR:?}`, which exits the SHELL rather than failing
  # this function. See cap_need in caplib.sh for what that cost.
  cap_need PIGEONHOLE_ACCOUNT "the storage account the lane lives in" || return 1
  cap_need PIGEONHOLE_LANE    "the lane, which is what a run is bound to" || return 1

  BLOB_BASE="https://${PIGEONHOLE_ACCOUNT}.blob.core.windows.net"
  BLOB_PREFIX="${PIGEONHOLE_CONTAINER:-heliograph}"

  if [ -n "${PIGEONHOLE_SAS:-}" ]; then
    BLOB_AUTH="sas"
    BLOB_SAS="${PIGEONHOLE_SAS#\?}"
  elif [ -n "${IDENTITY_ENDPOINT:-}" ]; then
    BLOB_AUTH="identity"
  else
    echo "station: the blob transport needs PIGEONHOLE_SAS, or a managed identity" >&2
    echo "         (IDENTITY_ENDPOINT) that this host can actually reach." >&2
    return 1
  fi
  return 0
}

# A lane, not a branch. There is no checkout here, so what a run is bound to has
# to be named rather than inferred.
tp_scope() { printf '%s' "${PIGEONHOLE_LANE}"; }

tp_revision() { printf 'lane %s' "${PIGEONHOLE_LANE}"; }

tp_describe() {
  printf 'azure blob %s/%s, lane %s, auth %s' \
    "$PIGEONHOLE_ACCOUNT" "$BLOB_PREFIX" "$PIGEONHOLE_LANE" "$BLOB_AUTH"
}

_blob_identity_token() {
  if [ -n "${PIGEONHOLE_IDENTITY_CMD:-}" ]; then
    # A seam for the tests. Nothing in production sets this.
    "$PIGEONHOLE_IDENTITY_CMD"
    return
  fi
  curl -sS -H "X-IDENTITY-HEADER: ${IDENTITY_HEADER:-}" \
    "${IDENTITY_ENDPOINT}?resource=https%3A%2F%2Fstorage.azure.com%2F&api-version=2019-08-01" \
    2>/dev/null
}

# The auth for one call. In SAS mode the credential is in the query string and
# in identity mode it must NOT be: a request carrying both leaves nobody able to
# say which credential was accepted.
_blob_args=()
_blob_url=""
_blob_auth() {
  local path="$1"
  if [ "$BLOB_AUTH" = "identity" ]; then
    local tok
    tok="$(_blob_identity_token | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$tok" ] || { say "identity: no access_token returned by the token endpoint"; return 1; }
    _blob_args=(-H "Authorization: Bearer ${tok}")
    _blob_url="${BLOB_BASE}/${path}"
  else
    _blob_args=()
    _blob_url="${BLOB_BASE}/${path}?${BLOB_SAS}"
  fi
}

# 0 found, 1 absent, 2 error. Absent is not an error: a lane with no request in
# it yet is the ordinary state of a station that has just started.
_blob_get() {
  local path="$1" out="${2:-/dev/stdout}" code
  _blob_auth "$path" || return 2
  code="$(curl -sS -o "$out" -w '%{http_code}' \
            -H "x-ms-version: ${BLOB_API_VERSION}" \
            "${_blob_args[@]}" "$_blob_url" 2>/dev/null)" || return 2
  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    *)   say "blob get ${path}: HTTP ${code}"; return 2 ;;
  esac
}

_blob_put() {
  local path="$1" file="$2" code
  _blob_auth "$path" || return 1
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
            -H "x-ms-version: ${BLOB_API_VERSION}" \
            -H "x-ms-blob-type: BlockBlob" \
            -H "Content-Type: text/plain; charset=utf-8" \
            "${_blob_args[@]}" --data-binary "@${file}" \
            "$_blob_url" 2>/dev/null)" || return 1
  [ "$code" = "201" ] && return 0
  say "blob put ${path}: HTTP ${code}"
  return 1
}

_lane() { printf '%s/%s/%s' "$BLOB_PREFIX" "$PIGEONHOLE_LANE" "$1"; }

# PROVE THE WRITE, not merely the read.
#
# This used to be a GET, and a 404 was counted as success on the argument that
# an absent request proves the account, the container and the credential. It
# does not prove enough. A misspelt PIGEONHOLE_CONTAINER answers 404, and so
# does a nonexistent account path; a SAS with `r` and no `w` answers 200 to
# every read it will ever be asked for. All three cleared the preflight and
# then failed on the first status upload, which is an hour later with nobody
# left to tell - the exact failure a preflight exists to move forward in time.
#
# A PUT to a fixed probe blob, and NO delete. Deleting would need `d` on the
# SAS, which a correctly scoped station credential need not have, so a check
# that deleted would fail on a credential that is perfectly good. The probe is
# one small blob with a name that says what it is, overwritten by the next
# preflight rather than accumulating.
tp_check() {
  local tmp rc
  tmp="$(mktemp)" || return 1
  printf 'heliograph write check\n' > "$tmp"
  _blob_put "$(_lane "heliograph-write-check")" "$tmp"; rc=$?
  rm -f "$tmp"
  [ "$rc" = "0" ] || {
    say "the blob transport could not write to $BLOB_PREFIX/$PIGEONHOLE_LANE."
    say "  A read-only SAS, a misspelt container and a wrong account all look"
    say "  exactly like this. The station would capture logs it could not ship."
    return 1
  }
  return 0
}

tp_fetch_request() {
  local tmp
  tmp="$(mktemp)" || return 1
  if _blob_get "$(_lane request)" "$tmp"; then
    cat "$tmp"; rm -f "$tmp"; return 0
  fi
  local rc=$?
  rm -f "$tmp"
  # 1 is "nothing queued yet", which is not a fetch failure and must not be
  # counted as one: a station in a quiet lane would otherwise report a flapping
  # link forever.
  [ "$rc" = "1" ] && { printf ''; return 0; }
  return 1
}

# Not offered. Declared in tp_capabilities so the loop never calls it.
tp_fetch_request_live() { return 1; }

# Cannot self-update: no repository, no working tree. Declared, not discovered.
tp_fetch_self() { return 1; }

tp_put_status() {
  local body="$1" _msg="$2" alsofile="${3:-}" tmp rc
  tmp="$(mktemp)" || return 1
  printf '%s' "$body" > "$tmp"
  _blob_put "$(_lane status)" "$tmp"
  rc=$?
  rm -f "$tmp"
  [ "$rc" = "0" ] || return "$rc"

  # THE THIRD ARGUMENT IS A CANCELLED RUN'S PARTIAL LOG, and this transport
  # dropped it on the floor for as long as it has existed. It was not even
  # named in the signature, so nothing read here said it was being ignored.
  #
  # Under the SAME name and lane a finished log goes to, so a reader listing
  # logs finds it where they find every other one. A cancelled run's output is
  # the evidence somebody cancelled it for, and it is the last thing the far
  # side will ever see of that run.
  if [ -n "$alsofile" ] && [ -f "$alsofile" ]; then
    _blob_put "$(_lane "logs/$(basename -- "$alsofile")")" "$alsofile" || return 1
  fi
  return 0
}

tp_put_progress() {
  local body="$1" _msg="$2" logfile="$3" tmp rc
  tmp="$(mktemp)" || return 1
  printf '%s' "$body" > "$tmp"
  _blob_put "$(_lane status)" "$tmp"; rc=$?
  rm -f "$tmp"
  [ "$rc" = "0" ] || return "$rc"
  # The partial log, under its own name, so a reader can pull it while the step
  # is still running.
  _blob_put "$(_lane "log")" "$logfile"
}

# Deliver the finished log, under its own name.
#
# UNDER ITS OWN NAME, not over `log`, and the difference matters. The progress
# snapshot above overwrites a single fixed blob because there is only ever one
# run in flight and a reader wants the latest. A finished log is evidence, and
# the next run's progress must not scribble over the last run's conclusion:
# pigeonhole.sh named finished logs `logs/<step>-<UTC>.txt` for that reason and
# this keeps the property.
#
# The message is ignored. It is a git commit subject; there is no history here.
tp_put_log() {
  local logfile="$1"
  [ -f "$logfile" ] || return 1
  _blob_put "$(_lane "logs/$(basename "$logfile")")" "$logfile"
}

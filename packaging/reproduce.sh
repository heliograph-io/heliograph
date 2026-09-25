#!/usr/bin/env bash
# =============================================================================
#  reproduce.sh - build the released artefacts, byte for byte
# =============================================================================
#     packaging/reproduce.sh v0.4.3             # into dist/
#     packaging/reproduce.sh v0.4.3 /tmp/out    # somewhere else
#
#  THE RELEASE WORKFLOW RUNS THIS FILE. That is the whole point of it being a
#  file. The build loop used to live inline in release.yml, so the command the
#  documentation gave a stranger was written separately from the one that
#  produced the artefact - and a single flag apart, the hashes disagree with no
#  error anywhere to say why. One script, two callers, one set of flags.
#
#  WHAT MAKES THE OUTPUT DETERMINISTIC, each line paid for by a build that was
#  not:
#
#    -trimpath        the source path is otherwise baked into the binary, so
#                     /home/you/heliograph and /src produce different bytes
#    -buildvcs=false  Go stamps the git commit, commit time and dirty flag into
#                     the binary by default. Measured on 2026-09-12: the same
#                     source built in a git checkout and in a tarball of that
#                     checkout differed - 475be520... against 7a1ac692... -
#                     purely because one had a .git and the other did not, and
#                     `-buildvcs=auto` omits the stamp silently rather than
#                     failing. Anybody verifying from the release tarball would
#                     have got a mismatch and concluded we had published
#                     something other than the source. The tag identifies the
#                     build; -X main.version carries it
#    CGO_ENABLED=0    no host libc, no host linker
#    GOTOOLCHAIN      pinned to go.mod's `go` directive, in full. A Go PATCH
#                     release changes the compiler and so changes the bytes, so
#                     "1.27" is not a pin. Go 1.21 and newer will FETCH the
#                     pinned toolchain, verified against the checksum database,
#                     which is what makes this runnable by a stranger who has
#                     some other Go installed
#    GOFLAGS=         cleared, along with GOEXPERIMENT and GOAMD64, because all
#                     three change code generation and all three can be set in
#                     an environment or by `go env -w` without anybody
#                     remembering
#    LC_ALL=C         SHA256SUMS is sorted, and collation is a locale setting
#
#  WHAT IS NOT CLAIMED. The .mcpb bundles are zips, and zip carries whatever
#  the local zlib produces: same file list, same order, same fixed timestamps
#  here, but a zlib-ng build of python3 compresses differently from stock zlib.
#  The BINARIES are the reproducible artefact, and they are what the checksum
#  in a station's RELAY_SEAL_SHA256 and in an installer refers to.
#
#  Verify against a release:
#
#    packaging/reproduce.sh v0.4.3
#    gh release download v0.4.3 -R heliograph-io/heliograph -p SHA256SUMS -O /tmp/published
#    cd dist && sha256sum --ignore-missing -c /tmp/published
#
#  Full account: https://docs.heliograph.io/provenance
# =============================================================================
set -euo pipefail

tag="${1:?usage: reproduce.sh <tag, e.g. v0.4.3> [outdir]}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${2:-$root/dist}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
cd "$root"

# The pin, read from the one place that holds it. A two-part `go` directive is
# refused rather than accepted loosely: it would admit every future patch
# release, which is the drift this file exists to stop.
pinned="$(sed -n 's/^go \([0-9]*\.[0-9]*\.[0-9]*\)$/\1/p' go.mod)"
if [ -z "$pinned" ]; then
  echo "reproduce.sh: go.mod's \`go\` directive is not a full major.minor.patch version." >&2
  echo "              A two-part version admits every patch release, and a Go patch" >&2
  echo "              release changes the bytes the compiler emits." >&2
  exit 2
fi

export GOTOOLCHAIN="go${pinned}"
export CGO_ENABLED=0
export GOFLAGS=""
export GOEXPERIMENT=""
export GOAMD64=v1
export LC_ALL=C

got="$(go version | awk '{print $3}')"
if [ "$got" != "go${pinned}" ]; then
  echo "reproduce.sh: the toolchain is $got and this build is pinned to go${pinned}." >&2
  echo "              GOTOOLCHAIN should have fetched it. With no network, install" >&2
  echo "              go${pinned} yourself, or build in the pinned container:" >&2
  echo "                docker run --rm -v \"\$PWD:/src\" -w /src golang:${pinned} \\" >&2
  echo "                  packaging/reproduce.sh ${tag}" >&2
  exit 2
fi
echo "toolchain: $got (pinned by go.mod)"
echo "tag:       $tag"
echo "output:    $out"

targets="linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64 windows/arm64"

for target in $targets; do
  os="${target%/*}"; arch="${target#*/}"
  exe=""; [ "$os" = windows ] && exe=".exe"

  GOOS="$os" GOARCH="$arch" go build \
    -trimpath -buildvcs=false \
    -ldflags "-s -w -X main.version=${tag}" \
    -o "$out/heliograph-${os}-${arch}${exe}" ./cmd/heliograph

  # heliograph-seal, the ONE binary a bash station is ever given, and the
  # reason the checksums are published at all: transports/relay.sh refuses to
  # start unless RELAY_SEAL_SHA256 matches, and that check is only worth
  # anything if the operator gets the number from somewhere other than the
  # machine holding the binary.
  #
  # No version stamp: it has none to print, and a byte-identical binary across
  # releases is a feature for something a station verifies by hash.
  GOOS="$os" GOARCH="$arch" go build \
    -trimpath -buildvcs=false -ldflags "-s -w" \
    -o "$out/heliograph-seal-${os}-${arch}${exe}" ./cmd/heliograph-seal

  echo "built ${os}/${arch}"
done

# The bundles, if python3 is here. A stranger checking a binary's hash should
# not need one; the release runner has it and builds the full set.
if command -v python3 >/dev/null 2>&1; then
  "$here/mcpb/build.sh" "${tag#v}" "$out"
else
  echo "no python3, so the .mcpb bundles were not built - the binaries above are complete"
fi

# Sorted, and by name rather than by whatever order the loop or the glob
# produced, so two runs on two machines write the same file and `diff` is a
# usable answer.
(
  cd "$out"
  names=()
  for f in heliograph-*; do
    [ -f "$f" ] && names+=("$f")
  done
  printf '%s\n' "${names[@]}" | sort | tr '\n' '\0' | xargs -0 sha256sum > SHA256SUMS
  echo
  cat SHA256SUMS
)

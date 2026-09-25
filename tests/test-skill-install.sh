#!/usr/bin/env bash
# =============================================================================
#  test-skill-install.sh - the install command in SKILL.md installs what runs
# =============================================================================
# SKILL.md tells an agent that finds no `heliograph` on PATH to install it, and
# not to improvise. So the install command is not an example. It is run
# verbatim, on whatever machine the agent happens to be on.
#
# It used to fetch heliograph-linux-amd64 into /usr/local/bin on every machine
# and check nothing. On an Apple Silicon Mac or an arm64 Linux box that is a
# binary the kernel will not load ("exec format error"), /usr/local/bin often
# needs root, and the download was never compared with the SHA256SUMS every
# release publishes. Nothing noticed, because nothing ran it.
#
# So this runs it. The snippet is EXTRACTED from SKILL.md rather than copied
# here, because a copy would pass while the file an agent reads went wrong.
#
#   default    shellcheck, then the snippet against local fixtures, with a
#              fake `uname` for every platform a release is built for, and
#              with checksums that do and do not match. Offline, so it runs
#              in the ordinary suite.
#   --live     the snippet exactly as written, against the real latest
#              release, then the installed binary is run. CI does this on a
#              Linux, an arm64 Linux, a macOS and a Windows runner, because a
#              binary for the wrong platform only fails on the right one.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"

SKILL="$HERE/../skills/heliograph/SKILL.md"
RELEASES="https://github.com/heliograph-io/heliograph/releases/latest/download"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The one ```bash block in SKILL.md that checks SHA256SUMS. Exactly one: two
# would mean an agent could pick the wrong one, and none means the check is
# gone.
extract_snippet() {
  awk '
    /^```bash[[:space:]]*$/ { inb = 1; buf = ""; next }
    /^```[[:space:]]*$/ && inb {
      inb = 0
      if (buf ~ /SHA256SUMS/) { printf "%s", buf; n++ }
      next
    }
    inb { buf = buf $0 "\n" }
    END { if (n != 1) exit 1 }
  ' "$SKILL"
}

snippet="$TMP/install.sh"
if extract_snippet > "$snippet"; then
  t_ok "SKILL.md has exactly one install block, and it checks SHA256SUMS"
else
  t_no "SKILL.md has exactly one install block, and it checks SHA256SUMS"
  printf '     no ```bash block in SKILL.md mentions SHA256SUMS, or more than one does\n'
  t_summary
  exit 1
fi

# -----------------------------------------------------------------------------
#  --live: the real release, on the machine this runs on
# -----------------------------------------------------------------------------
if [ "${1:-}" = "--live" ]; then
  home="$TMP/home"; mkdir -p "$home"
  RC=0
  OUT="$(HOME="$home" bash "$snippet" 2>&1)" || RC=$?
  printf '%s\n' "$OUT" | sed 's/^/     /'
  assert_eq "the install command succeeds on $(uname -s) $(uname -m)" "0" "$RC"

  bin="$home/.local/bin/heliograph"
  [ -f "$bin.exe" ] && bin="$bin.exe"
  if [ -x "$bin" ]; then
    t_ok "it installed an executable into ~/.local/bin"
  else
    t_no "it installed an executable into ~/.local/bin"
  fi

  # The assertion the whole file exists for. A binary for another platform
  # downloads, installs and chmods perfectly, and fails only here.
  RC=0
  VOUT="$("$bin" version 2>&1)" || RC=$?
  printf '     %s\n' "$VOUT"
  assert_eq "the installed binary runs on this machine" "0" "$RC"
  assert_contains "and it says it is heliograph" "heliograph" "$VOUT"
  t_summary
  exit $?
fi

# -----------------------------------------------------------------------------
#  lint: the snippet is POSIX, so it runs under zsh and dash as well
# -----------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  for dialect in sh bash; do
    if out="$(shellcheck -s "$dialect" -S warning "$snippet" 2>&1)"; then
      t_ok "the install block passes shellcheck as $dialect"
    else
      t_no "the install block passes shellcheck as $dialect"
      printf '%s\n' "$out" | sed 's/^/     /'
    fi
  done
else
  t_skip "shellcheck is not installed, so the install block was NOT linted"
fi

# -----------------------------------------------------------------------------
#  offline: every platform, against fixtures
# -----------------------------------------------------------------------------
# The URL is rewritten to a local directory. If it is not there to rewrite,
# the snippet would go to the network from an offline test, so that is a
# failure rather than a quiet fall-through.
fix="$TMP/release"; mkdir -p "$fix"
if [ "$(grep -c "$RELEASES" "$snippet")" = "1" ]; then
  t_ok "the install block downloads from the latest release"
else
  t_no "the install block downloads from the latest release"
  printf '     expected %s exactly once\n' "$RELEASES"
fi
offline="$TMP/install-offline.sh"
sed "s|$RELEASES|file://$fix|" "$snippet" > "$offline"
if grep -q 'https://' "$offline"; then
  t_no "the offline copy of the install block reaches no network"
  t_summary
  exit 1
fi

sha() { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; }

# One fake binary per release asset, each with different bytes, so the test
# can tell WHICH one was installed, not just that something was.
assets="heliograph-linux-amd64 heliograph-linux-arm64 heliograph-darwin-amd64
heliograph-darwin-arm64 heliograph-windows-amd64.exe heliograph-windows-arm64.exe"
for a in $assets; do
  printf '#!/bin/sh\necho "fake %s"\n' "$a" > "$fix/$a"
done
good_sums() {
  ( cd "$fix" && for a in $assets; do sha "$a"; done ) > "$fix/SHA256SUMS"
}
good_sums

# `uname` answers for the platform under test; everything else is real.
real_uname="$(command -v uname)"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/uname" <<EOF
#!/bin/sh
case "\$1" in
  -s) echo "\$FAKE_OS" ;;
  -m) echo "\$FAKE_ARCH" ;;
  *) exec "$real_uname" "\$@" ;;
esac
EOF
chmod +x "$TMP/bin/uname"

run_install() {  # run_install <shell> <uname -s> <uname -m> - sets RC, OUT, HOME_DIR
  HOME_DIR="$TMP/home-$RANDOM$RANDOM"; mkdir -p "$HOME_DIR"
  RC=0
  OUT="$(PATH="$TMP/bin:$PATH" HOME="$HOME_DIR" FAKE_OS="$2" FAKE_ARCH="$3" \
           "$1" "$offline" 2>&1)" || RC=$?
}

# dash is what `sh` is on Debian and Ubuntu, and it is the strictest POSIX
# shell likely to be handed this. Where `sh` is bash, this is the same run
# twice, which costs nothing.
for shell in bash sh; do
  while read -r os arch want installed; do
    [ -n "$os" ] || continue
    run_install "$shell" "$os" "$arch"
    if [ "$RC" = "0" ] && [ -x "$HOME_DIR/.local/bin/$installed" ] \
       && cmp -s "$fix/$want" "$HOME_DIR/.local/bin/$installed"; then
      t_ok "$shell: $os $arch installs $want as ~/.local/bin/$installed"
    else
      t_no "$shell: $os $arch installs $want as ~/.local/bin/$installed"
      printf '     exit %s, installed: %s\n' "$RC" "$(ls "$HOME_DIR/.local/bin" 2>/dev/null | tr '\n' ' ')"
      printf '%s\n' "$OUT" | sed 's/^/     /'
    fi
  done <<'EOF'
Linux x86_64 heliograph-linux-amd64 heliograph
Linux aarch64 heliograph-linux-arm64 heliograph
Darwin arm64 heliograph-darwin-arm64 heliograph
Darwin x86_64 heliograph-darwin-amd64 heliograph
MINGW64_NT-10.0-26100 x86_64 heliograph-windows-amd64.exe heliograph.exe
EOF
done

# A platform with no release refuses, and says what to do instead.
run_install bash Linux armv7l
if [ "$RC" != "0" ] && [ ! -e "$HOME_DIR/.local/bin/heliograph" ]; then
  t_ok "a CPU with no release binary installs nothing"
else
  t_no "a CPU with no release binary installs nothing"
fi
assert_contains "and the refusal points at go install" "go install" "$OUT"

# -----------------------------------------------------------------------------
#  the checksum is a gate, not a formality
# -----------------------------------------------------------------------------
# A file whose hash disagrees with SHA256SUMS: a tampered download, a truncated
# one, or a release whose assets were replaced after the sums were published.
printf 'tampered\n' >> "$fix/heliograph-linux-amd64"
run_install bash Linux x86_64
if [ "$RC" != "0" ] && [ ! -e "$HOME_DIR/.local/bin/heliograph" ]; then
  t_ok "a download that does not match SHA256SUMS is not installed"
else
  t_no "a download that does not match SHA256SUMS is not installed"
  printf '     exit %s\n' "$RC"
fi
assert_contains "and the refusal names SHA256SUMS" "SHA256SUMS" "$OUT"
printf '#!/bin/sh\necho "fake heliograph-linux-amd64"\n' > "$fix/heliograph-linux-amd64"

# An asset missing from SHA256SUMS altogether. An empty expected hash must
# never compare equal to anything, including an empty computed one.
good_sums
grep -v ' heliograph-linux-arm64$' "$fix/SHA256SUMS" > "$fix/SHA256SUMS.new"
mv "$fix/SHA256SUMS.new" "$fix/SHA256SUMS"
run_install bash Linux aarch64
if [ "$RC" != "0" ] && [ ! -e "$HOME_DIR/.local/bin/heliograph" ]; then
  t_ok "a download SHA256SUMS does not list is not installed"
else
  t_no "a download SHA256SUMS does not list is not installed"
fi
good_sums

# No SHA256SUMS at all: the download of it fails, and so does the install.
rm "$fix/SHA256SUMS"
run_install bash Linux x86_64
if [ "$RC" != "0" ] && [ ! -e "$HOME_DIR/.local/bin/heliograph" ]; then
  t_ok "a release with no SHA256SUMS installs nothing"
else
  t_no "a release with no SHA256SUMS installs nothing"
fi
good_sums

t_summary

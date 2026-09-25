# =============================================================================
#  Dockerfile - somewhere the loop can live that is not somebody's laptop
# =============================================================================
# This image supplies only what start.sh's own preflight refuses to run
# without, plus git, openssh-client and sudo. Its ENTRYPOINT is entrypoint.sh
# (declared at the foot of this file): it clones a transport repo and hands
# over to that repo's own start.sh, which bootstrap.sh copies into every
# transport repo and which already owns the preflight, the credential
# resolution, the branch checkout and the handover to station.sh. Duplicating
# any of that here would leave no answer to "which copy of the preflight is
# authoritative", so neither this file nor the entrypoint tries.
#
# Measured, not guessed - see task-1-report.md for the full method and for
# TWO DIFFERENT NUMBERS this daemon reports, which disagree by a wide
# margin and are both honest:
#   `docker image inspect --format '{{.Size}}'` (compressed layer size -
#   close to what a `docker pull` actually transfers, confirmed by diffing
#   against `docker save | gzip`):
#     debian:bookworm-slim                                       28.2 MB
#     + ca-certificates                                           3.5 MB
#     + git (pulls in perl, libcurl3-gnutls and their libraries) +30.1 MB
#     + openssh-client (pulls in libfido2, libcbor, krb5 libs)    +2.3 MB
#     + sudo                                                      +1.0 MB
#     finished image                                             ~65.2 MB
#
#   `docker images` / `docker system df -v` (unpacked, on-disk footprint
#   under this daemon's containerd snapshotter - what the image actually
#   occupies once built or pulled, no compression):
#     debian:bookworm-slim                                        116 MB
#     finished image                                               261 MB
#
# Which of these to quote depends entirely on the question being asked -
# "what does a pull cost" or "what does this take up once it is here" - so
# quote the one that answers the actual question and say which it is,
# rather than picking whichever number is smaller.
#
# bash (5.2), GNU sed (4.9, so -u is honoured), GNU coreutils (9.1, so
# base64 -w0 is genuinely unwrapped and not merely accepted), sha256sum, date
# and setsid all ship with debian:bookworm-slim already. Nothing is installed
# for any of them.
#
# WHY NOT ALPINE. It is smaller, but its sed is busybox's, and busybox sed
# REJECTS -u outright ("invalid option -- 'u'", exit 1) rather than silently
# ignoring it - so on Alpine as shipped, start.sh's preflight would correctly
# refuse to run at all. That refusal is the point: a sed that ignored -u
# instead of rejecting it would run buffered without complaint, producing a
# log where every captured line carries the same timestamp, which is worse
# than no timestamp because it looks like one. Reaching for musl's git
# instead of GNU sed does not even buy the size back: Alpine's own git
# package pulls in perl for the same reason Debian's does, so the ~30 MB cost
# below is not a saving Alpine actually offers.
# --- heliograph-seal, the one binary the far side is ever given -----------------
# THE RELAY IS THE ONLY TRANSPORT THAT NEEDS ONE, and it is argued for explicitly
# in the relay spec rather than smuggled in: `openssl enc` refuses AEAD ciphers
# outright, so a shell implementation would have to hand-assemble
# encrypt-then-MAC and X25519 key agreement across two openssl generations. That
# is where crypto bugs live, and a crypto bug here is silent. git, blob, share
# and bundle remain pure bash and always will.
#
# Without it in the image, a relay station could not run in a container at all -
# transports/relay.sh refuses to start when heliograph-seal is missing, and it is
# right to. Everything else about a relay station already worked.
#
# BUILT FROM THIS COMMIT, not fetched. `go install ...@main` would have needed no
# build context and would have built a DIFFERENT commit from the one under test,
# which is precisely the drift the payload is planted from source to avoid.
#
# GOARCH FROM TARGETARCH, because buildx sets it and a cross-built image that
# silently carried an amd64 binary on arm64 would fail at the first seal with
# "exec format error" - on a machine nobody can log into.
#
# --platform=$BUILDPLATFORM pins this STAGE to the machine doing the building,
# so the Go toolchain runs natively and cross-compiles. Without it the whole
# stage is emulated under QEMU for every non-native target, which turns a
# two-second compile into minutes for nothing: Go cross-compiles perfectly well.
# FULLY QUALIFIED, and that is not pedantry. podman has no unqualified-search
# registry configured by default, so a bare `golang:1.27-alpine` fails with
# "short-name did not resolve to an alias" before a single layer is pulled -
# and this repository's own container suite builds with podman as well as
# docker. `debian:bookworm-slim` below resolves on this host through an alias
# and is left alone; a new line has no such history to rely on.
#
# PINNED TO THE PATCH, and here it is load-bearing rather than tidy. A station
# verifies this binary against RELAY_SEAL_SHA256, which the operator takes from
# the release's SHA256SUMS. A floating `1.27` tag builds a seal that is correct,
# works, and does not match the published checksum - so the operator is told
# their binary has been tampered with. With the pin, and with the same flags
# packaging/reproduce.sh uses, the seal in this image is the released one.
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.27.1-alpine AS seal
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/heliograph-seal ./cmd/heliograph-seal
COPY internal ./internal
ARG TARGETARCH
RUN CGO_ENABLED=0 GOARCH="${TARGETARCH:-amd64}" GOAMD64=v1 go build \
      -trimpath -buildvcs=false -ldflags "-s -w" \
      -o /heliograph-seal ./cmd/heliograph-seal

FROM debian:bookworm-slim

# --- pinned by tag, not by digest ----------------------------------------------
# A digest pin buys byte-for-byte reproducibility at the cost of freezing out
# every security update Debian ships for bookworm from this point on, until
# someone notices the pin is stale and bumps it by hand. Nothing this image
# depends on - a bash new enough to have arrays, GNU sed, GNU coreutils - is
# something a bookworm point release would remove; what a point release
# WOULD change is exactly the security patching this image should keep
# getting. It carries no baked-in secret and nothing about it is sensitive to
# which day's point release it was built from, so the tag is the safer
# default here: every build picks up whatever bookworm-slim currently is.
# Reproducibility in the sense that actually matters for this PR - "the
# published image is what this file produces, not what version of this file
# was current on the day someone ran a push" - is what task 4's publish
# workflow exists to guarantee, by building from this repo rather than by
# freezing this line.
ENV DEBIAN_FRONTEND=noninteractive

# openssh-client is here because the transports page's own stated
# preference is SSH with a forwarded agent key ("nothing is stored on the
# control node and the push needs no credentials of its own"), over HTTPS
# with a token, which that document treats as the fallback. Shipping an
# image with no `ssh` binary at all would silently take that preferred path
# off the table and force every user onto the fallback - a capability gap
# the documentation would then be wrong about.
#
# Including the binary does not make SSH auth WORK everywhere it is
# present, and the next two things are true regardless of what task 2 or 3
# decide:
#   - SSH from inside this container needs an agent socket forwarded in
#     (bind-mounting $SSH_AUTH_SOCK, typically), which is task 3's wrapper's
#     job to offer, not this Dockerfile's;
#   - PR 4's Azure Container Instances path has nobody to forward an agent
#     FROM - there is no host session on the far side of an ACI deployment -
#     so that path is token-based over HTTPS regardless of what ships here.
# `openssh-client` only makes SSH possible where an agent exists to forward;
# it does not make it universal.
# curl is here because THREE transports are HTTP and refuse without it.
# transports/relay.sh and transports/blob.sh both check `command -v curl` in
# tp_init and return 1, so a container told TRANSPORT=blob failed at the first
# line of the preflight - while this file installed libcurl through git and no
# curl BINARY at all, which is the shape of that mistake that looks fine.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         ca-certificates \
         curl \
         git \
         openssh-client \
         sudo \
    && rm -rf /var/lib/apt/lists/*

# --- an unprivileged user, with passwordless sudo -------------------------------
# NOT a security boundary, and nothing written about this image, here or
# later, should be read as claiming otherwise. Passwordless sudo inside a
# container is functionally equivalent to root: anyone who can run a command
# in here can become root at will with one `sudo`.
#
# What it buys instead:
#   - processes stay unprivileged unless they explicitly ask to escalate,
#     rather than starting privileged by default;
#   - a file written into a bind-mounted repo belongs to this user, not to
#     root - which is what would otherwise break the operator's own host-side
#     checkout the next time they touched it;
#   - the toolkit's own escalation path is exercised rather than degenerating.
#     caplib.sh's cap_sudo_precache probes `sudo -n true` and only prompts if
#     that fails; under root there is nothing to prompt for, so the check
#     means nothing. steps/env-snapshot.sh's "sudo (non-interactive)" probe is
#     the same shape: under root it always reports "available WITHOUT a
#     password", which is technically true and tells the operator nothing
#     about the machine this container is meant to simulate. A root container
#     is therefore a WORSE simulator of the far side, not a more convenient
#     one.
#
# The honest limit: passwordless sudo still does not exercise the case
# cap_sudo_precache was actually written for, which is sudo needing a
# password with none cached. No posture available inside a container covers
# that - it would need a real password prompt, which nothing here supplies -
# so this buys a better simulator, not a complete one.
#
# uid 1000 because it is the first normal uid on most Linux distributions and
# therefore the uid a bind-mounted host directory's own first user is likely
# to already have, which is what keeps files this container writes owned by
# the operator rather than landing as a stray numeric uid in `ls -l`.
#
# The username is "heliograph", not "operator": debian:bookworm-slim already
# defines a SYSTEM GROUP called operator (gid 37, the traditional Unix
# operator group), and useradd refuses to create a same-named user group
# alongside it (exit 9, "group operator exists"). Measured by actually
# running useradd, not assumed - see task-1-report.md.
ARG HELIOGRAPH_UID=1000
RUN useradd --create-home --uid "${HELIOGRAPH_UID}" --shell /bin/bash heliograph \
    && printf 'heliograph ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/heliograph \
    && chmod 0440 /etc/sudoers.d/heliograph \
    && visudo -cf /etc/sudoers.d/heliograph

# --- the entrypoint --------------------------------------------------------------
# Copied and made executable while still root, so it works regardless of
# whatever mode the file carried when it entered the build context (git
# preserves the executable bit through a clone, but a build context that
# arrived some other way - `docker build` from a tarball, a CI checkout with
# core.fileMode off - might not). entrypoint.sh: clone the
# transport repo the container is given, then hand over to that repo's own
# start.sh. It owns none of start.sh's job - the preflight, the credential
# table, the branch checkout, the handover to station.sh - only the clone that
# has to happen before start.sh (and caplib.sh with it) exists to be run.
COPY station/bash/docker/entrypoint.sh /usr/local/bin/entrypoint.sh

# The status server. Perl is already here - git pulls it in - so this adds no
# package and no measurable size. It only runs when HELIOGRAPH_STATUS_PORT is
# set, which is off unless a host needs it. Azure Web App for Containers does:
# it probes a port and stops the site after 230s if nothing answers.
COPY station/bash/docker/status-server.pl /usr/local/bin/status-server.pl
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# --- the station payload, for the transports with nothing to clone --------------
# THE BUILD CONTEXT IS THE REPOSITORY ROOT, and this is why.
#
# For git, this image clones a transport repo and that clone is the one
# authoritative copy of start.sh. Nothing here competes with it and the payload
# below is never looked at.
#
# For the relay, the file share and the blob transport there is no repository to
# clone - the request and the log travel over the transport itself. Until this
# existed, that was the single reason a container could not run one of those
# stations: station.sh has taken TRANSPORT since A3 and start.sh asks the
# transport rather than assuming git, but the entrypoint had nothing to put at
# $WORKDIR.
#
# It was station/ until heliograph-seal had to be built from source as well, and
# the Go module is at the root. The root Dockerfile - the CONTROL side's image -
# has always built from there, so this is the same context, not a new one.
#
# PLANTED BY bootstrap.sh, not by a COPY, so the image's payload is exactly what
# a transport repo gets - the same file list, the same gitignore rename, and CI
# already asserts that `heliograph bootstrap` and this script agree. "Which
# station is this image running" then has the same answer as "which image is
# this".
#
# Owned by root and mode 0755: the entrypoint COPIES it into $WORKDIR rather
# than running from it, because the station writes into its own payload
# directory - ops-logs, the delivery record, the relay's sequence state - and a
# container that consumed the image's copy would work exactly once.
COPY station/bootstrap.sh /tmp/heliograph/bootstrap.sh
COPY station/bash /tmp/heliograph/bash
RUN bash /tmp/heliograph/bootstrap.sh /opt/heliograph/payload >/dev/null \
    && rm -rf /tmp/heliograph \
    && chmod -R a+rX /opt/heliograph/payload \
    && test -x /opt/heliograph/payload/start.sh

# --- the seal binary, and a record of what it was ------------------------------
# The checksum is written down at build time, and the entrypoint offers it as
# RELAY_SEAL_SHA256 when the operator has not set one of their own.
#
# BE CLEAR ABOUT WHAT THAT IS WORTH. A checksum recorded beside the binary it
# describes proves the binary has not changed SINCE THE IMAGE WAS BUILT - a
# mangled volume mount, a tampered running container, a corrupt layer. It proves
# nothing at all about whether the right binary was built, because anyone who
# could replace one could replace both.
#
# The pin that is worth something is the operator's: RELAY_SEAL_SHA256 set from
# the checksum published beside the release, compared against a binary they did
# not build. That one always wins over this, and the entrypoint says which it
# used.
COPY --from=seal /heliograph-seal /usr/local/bin/heliograph-seal
# `bash -o pipefail` is not decoration here, and the default shell is dash,
# which has no pipefail at all. `sha256sum ... | cut` reports the
# exit status of `cut`, so a failing sha256sum wrote an EMPTY checksum file and
# the build succeeded - and an empty RELAY_SEAL_SHA256 is treated as unset by
# relay.sh, which warns and starts UNVERIFIED. The check is confirmed to be 64
# hex characters before the layer is allowed to exist.
#
# The version call is not a smoke test either: on a cross-built image it is the
# one thing that would catch a binary for the wrong architecture, which
# otherwise fails at the first seal on a machine nobody can log into. It only
# runs when the target is the build platform; buildx skips the RUN's execution
# on an emulated stage only if QEMU is absent, and the publish workflow installs
# it precisely so this executes.
RUN bash -o pipefail -c '\
      chmod 0755 /usr/local/bin/heliograph-seal \
      && /usr/local/bin/heliograph-seal version >/dev/null \
      && sha256sum /usr/local/bin/heliograph-seal | cut -d" " -f1 \
           > /opt/heliograph/heliograph-seal.sha256 \
      && grep -qE "^[0-9a-f]{64}$" /opt/heliograph/heliograph-seal.sha256'


USER heliograph
WORKDIR /home/heliograph

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

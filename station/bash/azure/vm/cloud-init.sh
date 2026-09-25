#!/usr/bin/env bash
# =============================================================================
#  cloud-init.sh - first-boot script for the heliograph VM host
# =============================================================================
#  Runs once, as root, via cloud-init's userdata handling (any cloud-init
#  image executes a customData payload starting with a #! shebang directly -
#  no cloud-config YAML needed). It is the ONLY thing this host installs:
#
#    1. git, ca-certificates - nothing else. bash, GNU sed, GNU coreutils and
#       setsid already ship on Ubuntu 24.04, so nothing else start.sh's own
#       preflight needs is missing.
#    2. an unprivileged "heliograph" user to run the station as - never root,
#       for the same reason the Dockerfile does not run the container as
#       root: a captured log ends up owned by this user, not by root.
#    3. the clone itself, using the SAME env-based credential trick
#       toolkit/docker/entrypoint.sh uses (git_clone_with_header there) -
#       GIT_CONFIG_COUNT/KEY_0/VALUE_0 rather than `git -c
#       http.extraHeader=...`, so the token never appears in this process's
#       argv, which is exactly as readable via /proc/<pid>/cmdline on a bare
#       VM as it is inside a container.
#    4. a systemd unit so the station survives a reboot and gets restarted if
#       it crashes - the VM's equivalent of ACI's `restartPolicy: OnFailure`.
#
#  THE CREDENTIAL ARRIVES THROUGH AZURE'S CUSTOM DATA, which is not a place
#  to put a secret you cannot rotate: anyone who can read this VM's own
#  resource definition (`az vm show`, `az vm get-instance-view`) can read the
#  base64 blob straight back out, in the same way ACI's plain environment
#  variable and the Web App's app setting can both be read back by anyone
#  who can read THOSE resources. The right fix - a managed identity reading
#  the token from Key Vault at boot, never putting it in custom data at all
#  - needs a Key Vault as a further piece of bring-your-own estate
#  infrastructure this template does not assume exists. Documented as a real
#  limitation, not fixed here: see https://docs.heliograph.io/azure.
#
#  THE CHECKOUT IS TRANSIENT precisely once: this script clones once, at
#  first boot. There is no persistent DATA DISK here and none is created -
#  the OS disk is the only disk, and re-running this template against the
#  same name recreates the VM (and the OS disk) from nothing. Git is still
#  the only thing that survives a rebuild, exactly as everywhere else in
#  this PR.
# =============================================================================
set -uo pipefail

# Templated in by bicep/terraform before this file is base64-encoded into
# customData - see main.bicep/main.tf. Left as plain shell variables (not
# environment variables set by the caller) because customData has no
# mechanism to pass a separate environment; the substitution happens on the
# CONTROL SIDE, before this script ever reaches the VM, so what lands in
# customData is already a complete, self-contained script.
REPO_URL="__REPO_URL__"
GIT_TOKEN="__GIT_TOKEN__"
GIT_TOKEN_USER="__GIT_TOKEN_USER__"
START_ARGS="__START_ARGS__"
# The transport, and its own variables as EnvironmentFile lines.
#
# ON A VM THE CLONE IS HOW THE PAYLOAD ARRIVES, and that is a different question
# from which channel carries the requests. A container image ships the station,
# so its entrypoint refuses a repository URL beside a non-git transport - there
# is genuinely nothing to clone. A bare VM has no such image: `git clone` is the
# only way the toolkit gets here, so repoUrl stays required whatever TRANSPORT
# says, and it names where the PAYLOAD comes from rather than where logs go.
#
# That is worth being plain about: a relay station on a VM still needs a git
# host reachable ONCE, at first boot. A public or internal payload mirror is a
# very different ask from a private repository a station pushes evidence to, but
# it is not nothing.
TRANSPORT="__TRANSPORT__"
# BASE64, NOT THE LINES THEMSELVES. Everything above is substituted straight
# into a double-quoted shell assignment in a script that runs as root at first
# boot, so a value containing a quote, a `$` or a newline is not a value - it is
# code. That is survivable for repoUrl, which the same person chose, and it is
# not something to add MORE of: a whole environment block is exactly the shape
# that ends up carrying somebody else's string one day.
#
# Encoded on the control side, decoded here, never expanded by the shell. It
# also settles the quoting question the other way: whatever bytes went in come
# out, including the ones systemd would have mangled if this were assembled
# line by line in the template.
EXTRA_ENV_B64="__EXTRA_ENV_B64__"

LOG=/var/log/heliograph-cloud-init.log
exec > >(tee -a "$LOG") 2>&1

echo "$(date -u +%FT%TZ) heliograph cloud-init: starting"

apt-get update -y
# --no-install-recommends for the same reason the Dockerfile uses it: only
# what start.sh's own preflight actually checks for.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ca-certificates

if ! id heliograph >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash heliograph
fi

WORKDIR=/opt/heliograph/repo
mkdir -p /opt/heliograph
chown heliograph:heliograph /opt/heliograph

# git_clone_with_header - same shape as entrypoint.sh's function of the same
# name: the credential travels through GIT_CONFIG_COUNT/KEY_0/VALUE_0 so it
# never lands in this process's own argv. Run as the heliograph user so the
# clone - and everything under it - is owned by the user the systemd unit
# below actually runs as, not by root.
if [ -n "$GIT_TOKEN" ]; then
  AUTH_HEADER="Authorization: Basic $(printf '%s:%s' "$GIT_TOKEN_USER" "$GIT_TOKEN" | base64 -w0)"
  sudo -u heliograph env \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=http.extraHeader \
    GIT_CONFIG_VALUE_0="$AUTH_HEADER" \
    git clone -- "$REPO_URL" "$WORKDIR"
else
  sudo -u heliograph git clone -- "$REPO_URL" "$WORKDIR"
fi

chmod +x "$WORKDIR/start.sh"

# The credential the RUNNING station needs is separate from the one-off clone
# above: start.sh's own preflight and station.sh's later pushes both re-read
# GIT_TOKEN/GIT_TOKEN_USER via caplib.sh's cap_git, the same env-based
# lookup as the clone. An EnvironmentFile, not inline Environment= lines in
# the unit, so the token is not visible in `systemctl cat` or
# `systemctl show` - only in this file, which is root:heliograph 0640.
install -d -m 0750 -o root -g heliograph /etc/heliograph
# CREATED 0640 BEFORE ANYTHING IS WRITTEN INTO IT. A plain `> file` creates it
# at 0644 under the default umask and the chmod came afterwards, so every token
# in it was world-readable for the width of that window - on a machine where
# cloud-init runs as root beside whatever else the image starts.
install -m 0640 -o root -g heliograph /dev/null /etc/heliograph/env
{
  printf 'GIT_TOKEN=%s\n' "$GIT_TOKEN"
  printf 'GIT_TOKEN_USER=%s\n' "$GIT_TOKEN_USER"
  [ -n "$TRANSPORT" ] && [ "$TRANSPORT" != "git" ] && printf 'TRANSPORT=%s\n' "$TRANSPORT"
  # systemd's EnvironmentFile, so systemd's rules: it strips leading and
  # trailing whitespace, honours quotes, and treats a newline as the end of an
  # assignment. A value that needs any of that has to arrive already quoted -
  # the template does not add quotes, because guessing when to would be worse
  # than saying so. A backslash in an unquoted value IS altered by systemd.
  if [ -n "$EXTRA_ENV_B64" ]; then
    printf '%s' "$EXTRA_ENV_B64" | base64 -d
  fi
} >> /etc/heliograph/env

cat > /etc/systemd/system/heliograph.service <<UNIT
[Unit]
Description=heliograph station
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=heliograph
WorkingDirectory=$WORKDIR
EnvironmentFile=/etc/heliograph/env
ExecStart=$WORKDIR/start.sh $START_ARGS
# OnFailure, not always-restart-unconditionally: same reasoning as ACI's
# restartPolicy in aci/main.bicep. A clean exit (stop: yes in station/request,
# or --once finishing) must stay stopped.
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now heliograph.service

echo "$(date -u +%FT%TZ) heliograph cloud-init: done"

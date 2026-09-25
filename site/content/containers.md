# Docker and Kubernetes

Two hosts that need no OS to own. Both are proven: CI builds the image and runs
a real loop in it, and applies the shipped manifest to a real cluster.

## The rule the container follows

**It clones, then gets out of the way. It never re-implements `start.sh`.**

Unless there is nothing to clone. A share or blob station has no repository, so
the image carries the station payload - planted at build time by
the same `bootstrap.sh` that plants a transport repo - and the entrypoint copies
it into place instead of cloning. The git path is unchanged and the clone is
still authoritative there; the baked payload is a fallback for the transports
with no repo, not a second opinion about the ones that have one.

The relay needs one more thing and the image has it: `heliograph-seal`, the one
binary the far side is ever given, built from the same commit as the payload.
The entrypoint points a relay station at it.

**Which checksum it used is printed, because the two are worth different
things.** `RELAY_SEAL_SHA256` set by you - from `SHA256SUMS` in the release,
where `heliograph-seal-linux-amd64` and its arm64 twin are published beside the
CLI - compares a binary you did not build against a number you did not choose.
The image's own record - offered only when you set none - proves the binary
has not changed *since the image was built*, and nothing about whether the
right one was built, since anyone who could replace one could replace both.
Both beat the third state, which is the one that existed until now: no binary,
and a relay station that refused to start.

`entrypoint.sh` resolves the repo URL, clones or reuses a checkout, and
`exec ./start.sh`. Everything past the clone is `start.sh`'s alone. That
boundary is why the container cannot drift from a station started by hand.

## Docker

```bash
docker run --rm \
  -e REPO_URL=https://github.com/your-org/your-transport-repo.git \
  -e GIT_TOKEN_FILE=/run/secrets/token \
  -e GIT_TOKEN_USER=x-access-token \
  -v /path/to/token:/run/secrets/token:ro \
  ghcr.io/heliograph-io/heliograph-toolkit:0.4.3
```

**The tag has no `v`.** Git tag `v0.4.3` publishes image tag
`0.4.3`. This costs somebody twenty minutes roughly every time.

| variable | |
|---|---|
| `REPO_URL` | the transport repo to clone. May also be the first positional argument |
| `BRANCH` | which branch to check out |
| `GIT_TOKEN` / `GIT_TOKEN_FILE` | the credential. Prefer the file |
| `GIT_TOKEN_USER` | `x-access-token` for GitHub, `oauth2` for GitLab, empty for Azure DevOps |
| `HELIOGRAPH_STATUS_PORT` | serve a liveness endpoint. Off unless set |
| everything `station.sh` reads | passed straight through |

Arguments after the image name go to `start.sh`, so `-- --once` works exactly
as it does on a terminal.

### The unprivileged user is not a security boundary

The image runs as uid 1000 because the runners refuse to run as root and
because it is the right default. It is not isolation: anything the container
can reach, the station can reach. The security argument is the [account and the
gates](/security), not the container.

### The status port

`HELIOGRAPH_STATUS_PORT` starts a tiny status server so a platform that
insists on a health check has something to probe. It is **off unless set**,
because ACI, a VM and a plain `docker run` all need nothing, and an open port
nobody asked for is a worse default than a platform-specific setting.

Web App for Containers is the case that forces it: it kills a container with no
listening port every 230 seconds.

## Kubernetes

```bash
kubectl apply -f station/bash/kubernetes/heliograph.yaml
```

A Deployment with one replica, running as uid 1000, with the transport repo URL
and the credential as environment and a mounted secret. Edit the URL and the
secret reference; nothing else has to change.

**One replica, and it matters.** Two stations on one lane both answer the same
request, double-run every step and race on delivery. A heliograph log's whole
value is that it says what *one* machine saw.

The manifest is applied to a real kind cluster in CI and driven through a
complete run, so the thing published is the thing tested.

## Debugging a container that will not start

The failure that wastes the most time is a crash loop, because the logs you
need are the ones the platform will not give you while it is restarting.

Reproduce it locally with the same invocation:

```bash
docker run --rm -e REPO_URL=... ghcr.io/heliograph-io/heliograph-toolkit:0.4.3 -- --check
```

`--check` runs the preflight and changes nothing, and it names every blocking
problem with a remedy. That is almost always faster than reading platform logs.

On Azure specifically, a VNet-injected ACI reports slowly and gives you nothing
while crash-looping - see [Azure](/azure).

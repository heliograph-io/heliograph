# Where a station can run

Sometimes there is no willing human to start `./start.sh` and leave it running.
A station needs very little, so it can run almost anywhere - and this page
publishes the contract first, then says honestly which hosts have actually been
proven.

## The host contract

A station needs seven things and nothing else:

1. a process that can run bash
2. reach to one transport, **outbound only**. Nothing needs to reach *in*,
   and no host here opens a listener
3. a way to see it died: a restart policy, or a person who will notice
4. a non-root account
5. a writable checkout, or somewhere else to write a log it then hands off
6. **a credential that survives the session.** A forwarded ssh agent key dies
   at logout, which is exactly when an unattended loop needs it
7. **an unbuffered stdout.** The capture stamps each line when it is produced.
   A host that buffers gives every line the same timestamp, which reads like a
   working log while destroying the only property that makes it worth having

No VNet, no storage account, no inbound port, no persistent disk. **Git or the
relay is the persistence**: if the compute dies, you run the step again. The
checkout is transient everywhere.

Anything meeting those seven is a viable host, whether or not it appears below.

## Every host, and what it runs

**Proven** means it has run the loop end to end, and something re-checks that.
**Validated** means the file is well-formed and checked in CI, but has never
started a station. **Written** means the file exists and nothing here has run
or checked it. The distinction is kept deliberately: shipping twenty untested
templates would spend the credibility of the ones that work, and the next host
added should be labelled honestly rather than inherit the row above it.

| host | what starts the loop | status | evidence |
|---|---|---|---|
| operator's terminal | `./start.sh` | **proven** | `tests/test-start.sh`, every CI run |
| Docker (`station/bash/docker/`) | `entrypoint.sh`, then `exec ./start.sh` | **proven** | `tests/test-container.sh` builds the image and runs the loop in it, every CI run |
| Kubernetes (`station/bash/kubernetes/`) | the same image, one replica | **proven** | `tests/test-kubernetes.sh` applies the shipped manifest to a kind cluster and drives a run through it, every CI run |
| systemd `--user` + lingering (`service.sh`) | `service.sh install` | **proven** | `tests/test-service.sh` installs a unit and finds a running loop, every CI run |
| launchd (`service.sh`) | `service.sh install` | **proven** | `tests/test-launchd.sh` loads a real LaunchAgent on a macOS runner and proves `stop: yes` sticks, every CI run |
| setsid + nohup (`service.sh`) | `service.sh install`, where neither exists | **proven** | `tests/test-service.sh`, on a machine with no systemd user manager |
| Windows scheduled task (`service.ps1`) | `service.ps1 install`, then `station.ps1` | **proven** | the Windows runner registers the task, reads `ExecutionTimeLimit` back off it, and removes it, every CI run |
| Azure Container Instances (`station/bash/azure/aci/`) | the image | **proven** | deployed live, then torn down |
| Azure Web App for Containers (`station/bash/azure/webapp/`) | the image | **proven** | deployed live, then torn down |
| Azure Container Apps Job (`station/bash/azure/containerappsjob/`) | the image, on a schedule | **proven** | deployed live, then torn down |
| Azure VM (`station/bash/azure/vm/`) | `cloud-init.sh`, then a systemd unit | **proven** | deployed live on `Standard_D2s_v3` in westeurope, ran a step, and the log came back |
| Azure Function App (`station/bash/azure/function/`) | `pigeonhole.sh`, on a timer | **validated** | `terraform validate` and `bicep build` in CI. Never deployed |
| GitHub Actions, Azure Pipelines (`station/bash/pipelines/`) | `./start.sh -- --once` | written | - |
| ECS Fargate, Cloud Run, anything else | your own, against the contract above | recipes, not templates | - |

## Which transport works on which host

The interactive version of this table, with the controllers alongside it, is
[what works with what](/matrix). Pick what you already have and it dims
whatever cannot go with it.

`start.sh` asks the transport rather than assuming git. Set `TRANSPORT` and that
transport's variables and the preflight checks *that* channel - so a relay or
blob station now starts with the same command, and gets the same table.

Most hosts now carry those variables too. The container image plants the station
payload itself, so a transport with nothing to clone has one; the service
installers read an env file, because a detached process inherits nothing from
the shell that installed it.

| host | git | Azure Blob | relay | file share | bundle, object store |
|---|---|---|---|---|---|
| operator's terminal | yes | **yes** | **yes** | **yes** | no station side |
| Docker, Kubernetes | yes | **yes** | **yes** | **yes** | no station side |
| systemd, launchd, setsid | yes | **yes** | **yes** | **yes** | no station side |
| Windows scheduled task | yes | **yes** | **yes** | **yes** | no station side |
| pipelines | yes | not shipped | not shipped | not shipped | no station side |
| Azure ACI, Web App, Apps Job, VM | yes | **yes** | needs the key files | needs the share mounted | no station side |
| Azure Function App | no `git` in the image | **yes** | not plumbed | not plumbed | no station side |

**"yes"** means: export `TRANSPORT` and the transport's variables, then run
`./start.sh` exactly as you would for git. The relay also needs
`heliograph-seal` present and a key exchange completed, and `./start.sh --check`
says so if either is missing.

**The relay in a container needs no extra step.** It is the one transport that
needs a binary - `heliograph-seal`, argued for in [the relay page](/relay) - and
the image carries it, built from the same commit as the payload. The entrypoint
points the station at it and says which checksum it used. Only the two key files
have to be mounted, because those are yours.

**A pipeline is git-only by design.** There, the **git push is the trigger** -
that is what makes the latency *however long an agent takes to start* instead of
*however long until the next cron tick*. A relay or a share has no push to fire
on, so a non-git station in a pipeline would be a cron job costing a wait per
step, every step.

Both definitions say what such a job would need - a schedule with `trigger:
none` on Azure, secret variables mapped explicitly into the environment, the
relay's two key files materialised on disk, and `heliograph-seal` installed -
and neither ships one, because nothing here has ever run it.

**The Azure templates take a transport too**, and they take it the same way in
both languages:

```
transport      = "blob"
extraEnv       = { PIGEONHOLE_ACCOUNT = "...", PIGEONHOLE_LANE = "..." }
extraSecureEnv = { PIGEONHOLE_SAS = "..." }
```

Two maps rather than a parameter per transport, because each transport declares
its own requirements with `cap_need` and the station reads them from the
environment. A template naming `RELAY_URL`, `PIGEONHOLE_SAS` and the rest would
need editing every time a transport gained a variable - and would be five
templates out of date at once.

`extraSecureEnv` goes through whatever secure field the platform has: ACI's
`secureValue`, a Container Apps secret per entry. App Service has none, so there
both maps land in app settings and carry the same caveat the git token already
does.

**Azure Blob is the transport these templates carry outright**, because it needs
nothing but variables. The other two need a file:

- **the relay** reads `RELAY_IDENTITY` and `RELAY_PEER` as *paths*, and none of
  these templates mounts anything, so the two key files have to be put on the
  host and the paths set in `extraEnv`. The image carries `heliograph-seal`; a
  VM does not
- **a file share** needs the share mounted, which is the same job

Both are a volume and two settings rather than a change to the template, and
`./start.sh --check` on the host says exactly which is missing. It is still less
than "yes", which is why the table does not say it.

**The VM is the exception, and for a real reason.** A container image ships the
station payload, so its entrypoint refuses a repository URL beside a non-git
transport - there is genuinely nothing to clone. A bare VM has no image: `git
clone` is how the toolkit arrives, so `repoUrl` stays required whatever
`transport` says, and it names where the **payload** comes from rather than
where logs go. A relay station on a VM still needs a git host reachable once, at
first boot.

**"no station side"** means the CLI implements the transport and the station
has no code to read it, so the combination cannot work at all.

What each still needs is in
[the roadmap](https://github.com/heliograph-io/heliograph/blob/main/docs/plans/2026-09-08-powershell-and-docs-roadmap.md).

### In a container

The image carries the station payload, planted at build time by the same
`bootstrap.sh` that plants a transport repo. So there is nothing to clone and
nothing to mount:

```bash
docker run --rm \
  -e TRANSPORT=share -e SHARE_DIR=/mnt/ops -e SHARE_SCOPE=dns-timeouts \
  -v /mnt/ops:/mnt/ops \
  ghcr.io/dbhq-uk/heliograph-toolkit:1.0.0-rc2
```

`REPO_URL` alongside a non-git `TRANSPORT` is **refused**, not ignored: it means
somebody believes the container is going to clone something, and it is not.

The git path is untouched. It still clones, and that clone is the one
authoritative copy of `start.sh` - the payload in the image is a fallback for
the transports that have no repository, not a second opinion about the ones
that do.

### As a service

A detached process inherits nothing from the shell that installed it. That has
always been true of `GIT_TOKEN`, and `service.sh` has warned about it for as
long as it has existed; for a relay or a share it is worse, because those have
no fallback file the way caplib reads `~/.git-token`.

So write the variables to `.station-env` beside the payload, mode 600:

```
TRANSPORT=relay
RELAY_URL=https://heliograph-relay.dbhq.uk
RELAY_ESTATE=payments
RELAY_STATION=db-a
RELAY_TOKEN=...
RELAY_IDENTITY=/home/ops/.heliograph-identity
RELAY_PEER=/home/ops/.heliograph-peer
```

`RELAY_URL` above is the relay DBHQ hosts, and `RELAY_TOKEN` is the
station-scoped token for one estate on it. Both are issued by hand and free:
[how to ask, and the terms](/relay#the-hosted-relay-and-how-to-ask-for-a-token).
A relay you run yourself takes the same five variables.

`./service.sh install` reads it, tells you which variables that transport wants
if it is missing, and says so if the file is readable by anyone else. systemd
gets an `EnvironmentFile`; launchd and the `setsid` fallback source it before
`exec`, because a LaunchAgent plist is world-readable and a token has no
business being in one.

**Windows works the same way, and needs it more.** There is no
`EnvironmentFile` to reach for and no `~/.git-token` equivalent for a relay, so
`.station-env` is the *only* way a scheduled task can be given a `RELAY_TOKEN`.
`station.ps1` sources it on every start - by hand as well as under the task,
because a station behaving differently in the two would be the surprise.
**The rules for that file are written once**, in `station-env.sh`, and both
installers call it. They were written twice - once in bash, once in PowerShell -
and the two disagreed six ways about the same file: PowerShell's regexes are
case-insensitive, so `transport=relay` passed there and set nothing in bash;
`Get-Content` eats a UTF-8 BOM that bash does not skip when sourcing; an empty
file passed one and failed the other. A station that installs on Windows and is
refused on Linux, from one file, is worse than either answer alone.

**And it asks the transport, rather than checking a list.** `station-env.sh`
loads the file and runs that transport's own `tp_init`, which is local by
contract and touches no network. A list of variable names cannot express that
Azure Blob needs a SAS *or* a managed identity; `tp_init` already does.

## Picking one

**A person's terminal is still the best host** when there is a willing person.
It needs no infrastructure request, and `./start.sh` prints its own preflight
to somebody who can read it. Reach past it when nobody will sit there.

| you want | reach for |
|---|---|
| the simplest thing that survives a logout | [systemd or a scheduled task](/service) |
| an image, and no OS to own | [Docker or Kubernetes](/containers) |
| cloud compute, no VM to patch | [Azure ACI or Container Apps Job](/azure) |
| a shell to debug the station itself | Azure Web App for Containers, or a VM |
| nowhere to keep a process at all | [Azure Function App](/azure) - a timer, not a loop |

## Two things that will waste your time

**The published image tag has no `v`.** Git tag `v1.0.0-rc1` publishes
`ghcr.io/dbhq-uk/heliograph-toolkit:1.0.0-rc1`.

**A GitHub transport repo needs `GIT_TOKEN_USER=x-access-token`**, or git
reports a missing username rather than a wrong one, which sends you looking at
the token.

## Running it in a pipeline

A build agent is a host too, and often the only compute in an estate that can
already reach both the git host and the target. `station/bash/pipelines/` ships
GitHub Actions and Azure Pipelines definitions. See [pipelines](/pipelines) -
including the loop guard that stops a log push re-triggering the pipeline that
produced it.

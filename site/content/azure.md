# Running a station in Azure

Five templates, when there is no willing human to start `./start.sh` and leave
it running. Each ships as Terraform; four also ship as bicep, because estates
are split on which they accept. The Function App is Terraform only - it deploys
a Python function package rather than only compute, and that step has no bicep
equivalent worth maintaining twice.

All of them are **bring-your-own**. You pass in a VNet, a subnet, a plan or an
environment that already exists. The template creates the compute and nothing
else, which keeps the request to *"run this container"* rather than *"let us
build you a network"*.

The checkout is transient everywhere. There is no file share and no storage
account: git is the persistence, and a log sits on local disk only for the
seconds between the capture finishing and the delivery landing.

## Which one

| | good for | watch out for |
|---|---|---|
| **ACI** | one container, cheapest and simplest to explain | you cannot read logs while it is crash-looping |
| **Web App for Containers** | you can get a shell in to debug | built for web servers: a container with no open port is killed and restarted every 230s unless you raise `WEBSITES_CONTAINER_START_TIME_LIMIT`. Always has a public HTTPS front door - VNet integration is outbound only |
| **Container Apps Job** | runs on a schedule, so nothing is long-lived | the image refuses `REPO_URL` and an argument together, so the repo URL travels positionally |
| **VM + systemd** | easiest to debug: SSH in, or `az vm run-command`. No image, no registry | you own an OS and its patching. Pick the region before the SKU |
| **Function App (Flex)** | there is nowhere to keep a process at all | not a loop: a timer answers one request per tick. No `git` in the image |

Four of the five were deployed for real against a test resource group and torn
down again. **Only the Function App has never been deployed.** Everything below
came from watching a real deployment fail or succeed.

## What a real deployment taught

### `SkuNotAvailable` means try another region, not another size

The VM could not be provisioned in `uksouth` at any size. Eleven SKUs were
tried - `Standard_B1s`, `B1ms`, `B2s`, `D2s_v3`, `D2_v5`, `E2s_v5`, `F2s_v2`,
`DS1_v2`, `A1_v2`, `A2_v2`, `B2ats_v2` - and every one returned the same error,
in two regions, while `az vm list-usage` showed 65 vCPUs free the entire time.

The message reads like a per-SKU stock-out and invites exactly the wrong next
move. It deployed first time on `Standard_D2s_v3` in `westeurope`, which had
583 unrestricted SKUs against uksouth's far smaller set. **Query the SKU list
and pick a region**; it settles in one call what eleven deployments could not:

```bash
az rest --method get --url "https://management.azure.com/subscriptions/SUB/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location eq 'westeurope'"
```

### A bring-your-own VNet must have outbound internet

This one presents as a healthy VM with no loop on it. The deployment succeeded,
then cloud-init timed out cloning after 135 seconds and systemd reported
`203/EXEC` on a `start.sh` that had never arrived. Azure removed default
outbound access; a NAT gateway on the subnet fixed it.

### A crash-looping ACI gives you no logs

`az container logs` returns nothing while the group is restarting, which is
precisely when you need it. Reproduce the invocation locally with `docker run`
using the same `command` array and read the error straight away. Web App for
Containers and a VM both let you get a shell, and are better places to debug
the station itself.

### ACI's `command` replaces the entrypoint outright

It does the same job as Kubernetes' `command`, so passing the repo URL there
makes ACI try to execute the URL as a program. Container Apps Jobs have a
genuinely separate `args`, unlike ACI.

### Terraform's `azurerm_container_group` needs a port

Even when nothing listens. The bicep template never mentions `ipAddress` and
Azure is happy to omit the object entirely for a VNet-injected group with no
ports; the Terraform provider is not.

### Managed identity works in a VNet-injected ACI

This document asserted the opposite for a while. A container group with a
user-assigned identity, in a delegated subnet, asked IMDS for a token and got
HTTP 200 back. A measurement beats a confidently asserted negative, and the SAS
was never the only option on ACI.

## The Function host, and the estate that forced it

Reach for this when there is nowhere to keep a process. On one estate every
other option failed outright: App Service quota was zero on all nine SKUs that
allocate a VM, a VNet-injected Container Apps environment could not provision
at all because it had no egress to bootstrap itself, and a container group
deployed but could reach nothing. `FC1` was the only SKU that validated.

**Measure quota with ARM preflight, not by trying to create things.**
`az deployment group validate` returns the quota error and creates nothing.
`az appservice list-locations` describes the region rather than your
subscription and will list a SKU you cannot have.

### It is an invocation, not a loop

`PIGEONHOLE_RESUME=1` and `PIGEONHOLE_ONCE=1`. Neither is optional, and the
first is subtle: the station normally absorbs whatever id is in the drop when
it starts, so a restart does not re-run the last step unwatched. For a runner
invoked fresh every tick, that rule means it answers **nothing, ever** - and it
fails silently, because an unanswered request looks exactly like a slow one.

`functionTimeout` in `host.json` is a hard wall. A step that overruns is killed
with it.

### There is no `git` in the image, and that is the point

So this host uses Azure Blob as its transport, and blob storage behind a
private endpoint needs no egress at all. That is why it works in a subnet with
no route off it, where every other host failed.

The image is Debian bookworm with bash 5.2 and GNU coreutils, which is what the
capture needs - so the station shells out to the bash toolkit rather than
reimplementing the capture in Python.

### It can use its own identity instead of a SAS

An estate can disable shared keys outright (`allowSharedKeyAccess = false`),
and then there is no key to sign a SAS with and the transport's only credential
cannot be created. A Function is handed a **local** token endpoint needing no
egress, so identity auth works in exactly the locked-down subnets the SAS path
was reached for.

It needs a role assignment the template does not make: `Storage Blob Data
Contributor` on the drop account. The templates are bring-your-own and do not
own the account.

## Two things that will waste your time

**The published image tag has no `v`.** Git tag `v0.4.3` publishes
`ghcr.io/heliograph-io/heliograph-toolkit:0.4.3`.

**A GitHub transport repo needs `GIT_TOKEN_USER=x-access-token`**, or git
reports a missing username rather than a wrong one.

## What "validated" is worth

A validated template is a good starting point and not a promise. Both findings
above needed a real deployment to surface, and neither would have been caught
by review. Expect the Function App to have one of its own.

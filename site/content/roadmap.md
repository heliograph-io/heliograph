# What might come next, and what never will

Three questions arrive constantly: *"could it go over X"*, *"could it run on
Y"* and *"could I drive it from Z"*. This page answers all three for every
candidate anyone has raised, with a verdict and the reason, so that an estate
can tell in one read whether it is waiting for something or whether the answer
is no.

Nothing here is a promise of a date. What is **built** is on
[transports](/transports) and [hosts](/hosts), and those two pages state both
sides of every claim. This one is about what is not built.

| verdict | means |
|---|---|
| **do** | next, or near enough free |
| **later** | real value, waiting on something named |
| **maybe** | revisited when an engagement asks for it |
| **never** | decided against, and the reason travels with it |

## Two contracts decide most of it

A candidate that fails either is not a near miss, it is a different product.

**A transport** implements ten functions on the station side, seven of them on
the capture path, and its `tp_check` proves a **write** rather than a read.
Read access is not write access, and the expensive failure is an hour-long step
that captures a perfect log and cannot deliver it.

**A host** needs five things: a process that can run bash, outbound reach to one
transport, a restart policy, a non-root account, and somewhere to write a file
it then hands off. No VNet, no inbound port, no persistent disk.

The constraint that shapes the rest is that **nothing is ever installed on the
far side**. A transport that needs a client library is a transport that needs a
change request, which is the thing this exists to avoid.

## Transports

| candidate | verdict | why |
|---|---|---|
| artifact repository - Artifactory, Nexus raw | **do** | The largest population of any candidate. An estate that refuses a git host and refuses a storage account still has an artifact repository, because that is how software gets into the estate at all - an approved egress path with an owner, a change record and a credential model already attached. It is a plain HTTP `PUT` and `GET` with a token, so the station needs nothing it does not already have |
| Google Cloud Storage | **do** | The object store transport signs SigV4, and GCS accepts SigV4 on its S3-compatible API. This may already work and be documented nowhere. One round trip decides it |
| OCI registry | later | An estate that runs containers permits registry traffic by definition, and a registry has been a general artifact store since ORAS. Three HTTP calls and a sha256, so no new station dependency. It follows the artifact repository because that proves the same HTTP shape first |
| Microsoft Graph - SharePoint, OneDrive | later | The only reach into an estate whose one sanctioned egress is Microsoft 365. A [file share](/transports#file-share) does not cover it, because that needs a mount and this is an API. It costs an OAuth refresh path nothing here has yet, and a second upload route for logs over 4MB |
| ServiceNow or Jira attachments | maybe | In a change-controlled estate the ticket is already where the operator is pasting half a terminal, so the log would land in the audit record rather than beside it. Two problems: a ticket is not a queue, and anyone who can attach a file could queue a request |
| AMQP, MQTT, Kafka | maybe | Real value where an estate already runs a broker. No pure-bash client exists for any of them, so the station would gain its first dependency and stop being readable before it is run |
| animated QR, screen to camera | maybe | The one channel left when removable media is banned and a screen is the only way out - a remote desktop session with the clipboard turned off is the ordinary case. A version 40 QR holds 2953 binary bytes per frame, which makes it three orders of magnitude faster than data over sound. It is **asymmetric**, though: a request is a few hundred bytes and fits in a single static code, while sending a log back needs the station to render animated frames, and that is a package and a display it does not have. The [bundle](/transports#bundle) covers the same population wherever a file can cross |
| data over sound - ggwave and similar | never | **8 to 16 bytes per second.** A 50KB log is 53 minutes of uninterrupted clean audio, and this is a tool whose first rule is that a log is never truncated. It is also a C library needing an audio backend, so it breaks *nothing is ever installed on the far side*, and no container, pod, cloud container group or VM in the [host table](/hosts) has a speaker or a microphone. Ultrasonic egress from an isolated machine is a documented attack technique, which puts it in the same bin as DNS |
| LoRa and Meshtastic | never | 84 bytes per second on the default preset and 2.7KB/s at the fastest, before packet headers, mesh hops and a 10% hourly duty cycle limit in Europe. It also needs a radio, and in most estates an unauthorised transmitter is a larger incident than an unauthorised network connection |
| rclone, Syncthing, croc, magic-wormhole | never | Each is a binary or a daemon on the far side, which is the one thing this refuses. croc and magic-wormhole are also the [relay](/relay) again but worse, because both ends have to be online at the same moment and heliograph is store-and-forward on purpose. The useful version of this is a docs line: an operator who already runs rclone has a file share or an object store, and those transports work through it without heliograph needing to know |
| WebDAV | never | The right protocol for the job, and no population that has WebDAV and not one of the five above |
| Vault, Parameter Store, App Configuration | never | A captured log does not fit in a parameter, and chunking one across secrets is a transport built to be abused by whoever finds it next |
| email | never | It genuinely works in a mail-only air gap. It also carries a large operational burden - size limits at every relay, SPF and DKIM alignment, base64 inflation - for a small population |
| chat - Slack, Teams | never | Captured logs in a chat system is a compliance problem, not a feature |
| DNS | never | A covert channel. Shipping one would get the product banned from exactly the estates it is for |
| raw TCP, reverse tunnel | **superseded** | An unauthenticated, always-on reverse connection stays refused, and for the original reason: it is a C2 channel by any blue team's definition. The **beam** is the answer designed instead - off unless explicitly enabled on both ends, sealed, signed, and torn down when idle. See [security](/security) |

## Stations

| candidate | verdict | why |
|---|---|---|
| AWS ECS Fargate | **do**, with an account to prove it on | The plainest gap in the product. There are five [Azure templates](/azure) and no AWS ones, while [the comparison page](/compared) argues against AWS SSM Run Command - so a reader arriving from that argument finds nothing to deploy. It maps onto the Container Instances template: same image, same environment, same transport selection. The condition is real: every Azure template here has been deployed live and torn down, and shipping an AWS one that has never started a station would be a row that looks authoritative and is not |
| AWS EC2 | **do**, with an account to prove it on | Maps onto the Azure VM template, and its `cloud-init.sh` already exists. Same condition as Fargate |
| GitLab CI | **do** | One file, against the pattern [pipelines](/pipelines) already establishes, loop guard included. GitLab is the git host of choice across a large part of the enterprise git market |
| Kubernetes CronJob | **do** | The same image with `--once`, beside the Deployment [containers](/containers) already ships. It is what an estate that will not run a long-lived pod will accept |
| Arista EOS | **do** | Bash on an Arista switch is documented and supported, in every command mode but EXEC, with `awk` and `egrep` present. That is the host contract met with no new code - a proving exercise and a page. It waits on one of the curl-only transports, because git is usually absent and installing it is out of the question |
| AWS Lambda | later | The timer-not-a-loop pattern the Azure Function App already uses, ported |
| Cisco IOS-XE Guest Shell | later | A Linux container bundled with the image, enabled with `guestshell enable`, surviving a reload once enabled. Cisco's own warning is that a script producing high-volume output exhausts container memory and should redirect to a file, which is [the capture contract](/conformance) doing its job on a device nobody wrote it for |
| NVIDIA Cumulus Linux | later | Debian. It is a server that forwards packets |
| Google Cloud Run and Compute Engine | later | The same shape as the AWS work, behind it because AWS is the larger gap |
| Ansible AWX | later | Not a host but a way to plant one. An ops team runs AWX precisely so that nobody needs SSH, and launching a job template is a permission somebody already has. The honest limit: AWX does not remove SSH, it moves it to the control plane |
| F5 BIG-IP | maybe | Bash beside tmsh, and a narrower population than the switches |
| Jenkins | maybe | A third pipeline definition, once GitLab CI shows the pattern generalises |
| Termux on Android | maybe | Bash, GNU coreutils, a runit service manager and a start-on-boot addon: four of the five host contract points already present. Low commercial value and high evidential value, because a phone in a cabinet on a factory floor is a real station |
| Synology and QNAP | maybe | [Docker](/containers) already covers it. A paragraph in the docs, not a template |
| OpenWrt, ESXi shell, appliances | maybe | These have BusyBox `ash` and no bash, so supporting them means a third station implementation in POSIX `sh` - after bash and the PowerShell one that is not finished. Writing one file twice already produced six disagreements about the same file. A third comes after the second is done |
| z/OS UNIX System Services | maybe | Bash is maintained for it, and a mainframe is exactly the change-controlled, nobody-gets-a-login estate this is for. It is research rather than a plan because the whole capture contract is a byte-for-byte claim about a text file, and EBCDIC is a platform where even git converts encodings underneath you |
| IBM i PASE, AIX, Solaris | maybe | The softer landing of the same family: ASCII throughout, bash from the package manager, and line endings as the documented hazard |
| microcontrollers | never | No process, no shell, no filesystem. Three of the five host contract points are absent, which makes it a different product rather than a port |
| iOS as a station | never | No unattended background execution, and no shell an estate would sanction |

## Control nodes

The near side is the half a person actually touches, and two facts bound what
can be one. The [binary](/install) is already built static for six targets -
Linux, macOS and Windows, on both amd64 and arm64. And **only the git transport
needs anything installed**: the CLI shells out to `git` for that one, while the
relay, the file share, the object store and the bundle are the binary and
nothing else. A machine with no git can still drive an estate.

| candidate | verdict | why |
|---|---|---|
| the near side without the CLI | **do** | It already works and is documented nowhere. A request is a `key: value` text file, so a laptop that permits git and refuses new binaries is a control node today - write the file, push it, read the log back out of the repository. It is the mirror of the [bootstrap without a CLI](/bootstrap) on the far side |
| Android, through Termux | **do** | The arm64 Linux binary is already built and git is a Termux package, so this is a check and a paragraph rather than a port. An on-call phone that can publish a step and read back a timestamped log is worth more than it sounds at 2am |
| ChromeOS | **do** | Crostini is Linux. One line, once somebody has actually checked it |
| Claude Code on the web | **do** | A far better fit than a remote MCP connector, because a cloud sandbox is a real shell - the CLI is a static binary, so it installs and runs with no protocol work at all. What stops it is not architecture: every web session gets a fresh sandbox behind an Anthropic-managed proxy allowlist, so a private git host, an internal artifact repository and the relay's own domain are all refused with `blocked-by-allowlist`, and a GitHub-hosted transport repository is the one combination likely to work today. Then two things the docs must say rather than gloss: the control credential would live in somebody else's cloud, and the estate directory is wiped between sessions |
| Homebrew, winget, scoop | later | Not capability, distribution. [Install](/install) covers a release binary, npm and an MCP bundle; these three are the gap |
| remote MCP, over Streamable HTTP | later | **The only route to a web or mobile control node.** Claude's custom connectors reach a server from Anthropic's cloud even on Desktop, so a connector must be publicly reachable - and that endpoint would hold the transport credential, and on the relay the signing identity as well. A party able to forge a request has code execution inside every estate at once, which is the hazard [the relay](/relay) is built to refuse. It is possible only as a courier, with signing left on a device that holds the key. That is design work, not plumbing |
| a CI job as the control node | later | Send a step on a schedule and fail the build on what the log says: continuous verification of a machine nobody can log into. No new code, one example workflow, and a genuinely new use of the near side |
| FreeBSD | maybe | One line in the target list, and no evidence anybody has asked |
| iOS and iPadOS natively | never | No way to ship a binary or run git. Reachable only through remote MCP, so it is that row rather than its own |
| a hosted web control plane | never | To be useful it must hold every estate's transport credential and signing key, which makes whoever operates it able to run commands inside every connected estate. That is precisely what the relay is architected not to be, and building one beside it would spend the claim |

## Where this is decided

The reasoning behind every row, including the sources and the open questions
each candidate still has, is in
[the survey](https://github.com/heliograph-io/heliograph/blob/main/docs/specs/2026-09-10-new-transports-and-stations-design.md).
What is being built now is in
[ROADMAP.md](https://github.com/heliograph-io/heliograph/blob/main/ROADMAP.md).

If your estate is a **maybe** and you need it, say so in an issue. A named
engagement is exactly what moves a row up this page, and it is more useful than
a vote.

## What changed on 17 September 2026

The project moved to the `heliograph-io` organisation and the licences changed:
heliograph is Apache 2.0, this documentation is CC BY 4.0, and the relay is fair
source under FSL-1.1-ALv2. **Every commit published under MIT is still available
under MIT, permanently.** Old links redirect, and nothing about what the tool
does changed.

The whole statement, including why each licence and what is expressly
permitted, is on [licensing](/licence).

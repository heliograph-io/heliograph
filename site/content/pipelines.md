# Running a station in a pipeline

A build agent is a host too, and often the only compute in an estate that can
already reach both the git host and the target. `station/bash/pipelines/` ships
a GitHub Actions workflow and an Azure Pipelines definition.

## When this is the right answer

- The estate has a build agent inside the network and nothing else you can run on
- Getting a VM approved is a change request; adding a pipeline is not
- You want the run to be someone's audited, logged CI job rather than a process
  on a laptop

## When it is not

A pipeline job has a **time limit**, and a station is a loop. Run it with
`--once` so it answers one request and exits, and accept that the loop is
"whenever the pipeline runs" rather than every five seconds.

If you need a genuine loop, use [a real host](/hosts).

## The loop guard, which is not optional

The station delivers its log by committing to the transport repo. If the
pipeline is triggered by pushes to that same repo, the log push re-triggers the
pipeline, which runs a step, which pushes a log, which re-triggers it.

Every commit the station makes carries **`***NO_CI***`** in its message.

- **GitHub Actions** refuses to trigger a workflow on a push made with
  `GITHUB_TOKEN`, so it needs no help - but the marker travels anyway
- **Azure DevOps** has no equivalent, so the marker in the commit message is
  the only guard, and it is the one that travels with the commit rather than
  living in one host's trigger configuration

If you write your own pipeline, honour it. A runaway loop on somebody else's
build minutes is a bad first impression.

## The credential

The agent's own git credential is usually already there and usually enough. If
not, the same rules as everywhere else apply: `GIT_TOKEN` or `GIT_TOKEN_FILE`,
and `GIT_TOKEN_USER=x-access-token` for GitHub.

Use the pipeline's secret store. Do not put it in the YAML.

## What the first Azure DevOps run cost

Four things, in the order they bite. Each looked like a different problem than
it was, which is what made them expensive.

**A new pipeline is not authorised for the pool or the repo, and the symptom is
indistinguishable from an outage.** The run sits at `notStarted`. It never
appears in the pool's job request list, so no build agent is ever asked for -
and if the pool scales on demand, you will find every agent `offline` and
conclude the pool is dead. It is not. The evidence is in the build's own
timeline:

```
Checkpoint.Authorization   state=inProgress
Job                        (absent - nothing dispatched)
```

Queue the pipeline once from the web UI and click **Authorize** on the banner it
shows, or grant it directly. The `queue` resource is the agent pool; do the
repository too, or the checkout fails next:

```
PATCH https://dev.azure.com/{org}/{projectId}/_apis/pipelines/pipelinePermissions/queue/{queueId}?api-version=7.1-preview.1
PATCH .../pipelinePermissions/repository/{projectId}.{repoId}?api-version=7.1-preview.1
{"pipelines":[{"id":<definitionId>,"authorized":true}]}
```

Once authorised, the wait was seconds, not minutes.

**The build service needs Contribute on the transport repo, and finding its
identity is its own trap.** Without it the run looks clean and no log arrives -
`start.sh`'s preflight catches this as a failing `git write` check. Granting it
needs a *subject descriptor*, and `az devops security permission update` rejects
both the display name and the `Microsoft.TeamFoundation.ServiceIdentity;...`
form with errors that name neither problem. Only the Graph `svc.*` descriptor
works. Read it from the identity itself:

```
GET https://vssps.dev.azure.com/{org}/_apis/identities?searchFilter=DisplayName&filterValue={Project}%20Build%20Service%20({Org})&api-version=7.1-preview.1
```

then pass its `subjectDescriptor` as `--subject`, with `--allow-bit 6` (2 Read +
4 Contribute) on namespace `2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87` and token
`repoV2/{projectId}/{repoId}`.

**The checkout is a detached HEAD.** Azure DevOps checks out a commit, not a
branch, and `station.sh` refuses to start on one - correctly, because a commit
on a detached HEAD goes nowhere and the log would be destroyed with the
workspace. The shipped definition re-attaches with
`git checkout -B "${BUILD_SOURCEBRANCH#refs/heads/}"` before anything else.

**`$(...)` in an inline script is Azure DevOps macro syntax**, expanded before
bash sees the line. Use `${VAR}` for shell variables.

And one that wastes an afternoon otherwise: `az pipelines create` sets a
definition-level default queue, and it may pick a pool retired years ago. That
is **not** what routes the job. The `pool:` in the YAML wins. So if a run will
not start, read the timeline for a checkpoint before touching the queue.

## Do not run it as root

Most container-based agents run as root by default, and the runners refuse
that: this tooling holds no credentials of its own, so the account it runs as
is the whole blast radius, and as root that is the machine.

Add a non-root user in the job, or set `ALLOW_ROOT=1` if the agent image
genuinely has no other and you accept what that means. See
[security](/security).

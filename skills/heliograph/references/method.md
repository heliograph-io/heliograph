# Method - debugging a system you cannot log into

The tooling exists to support a way of working. The tooling is the easy part.

These are the rules that were paid for, mostly by breaking them first.

---

## 1. Measure now, and do not trust the last investigation

Notes, findings files and remembered conclusions describe a system that existed when they were
written. Environments move: someone patched a host, a token expired, a firewall rule landed, a
tool floated a major version.

Start every investigation by measuring the current state - that is what the `env` step is for.
A prior finding is a hypothesis to re-test, never a premise to build on.

Four dead ends in one afternoon have been spent on this exact mistake.

## 2. Keep a control

A measurement with nothing to compare against is an anecdote. Run the same probe against
something known-good **in the same log**: the other node, another host in the same subnet, the
environment where it works.

"It fails" is not a finding. "It fails here and succeeds there, same command, same minute" is.

## 3. Run it in all directions

Reachability, permissions and name resolution are all directional. A→B working tells you
nothing about B→A. Probe both ways before concluding anything about the network - the fault is
routinely in the direction that wasn't tested.

Same for protocols: an all-green TCP matrix does not mean "reachable". ICMP and UDP are
separate questions and have to be asked separately. A Windows cluster will refuse to form with
ICMP filtered while every TCP port it needs is open.

## 4. Never truncate

No `head`, no `tail -20`, no `2>/dev/null` on the thing being diagnosed, no "I'll just grep for
the error". The line you cut is the line you needed, and you won't know that until after you've
cut it. Disk is cheap; a second round-trip through the operator is not.

Corollary: read the whole log, including the parts that worked.

## 5. A gap in the timestamps is a finding

This is why every captured line carries a UTC clock. After the fact, a hang and slow progress
are indistinguishable in an untimed log. With timestamps, a four-minute gap tells you exactly
which operation stalled and for how long.

## 6. Change one thing

Between two runs, change exactly one variable. Two changes and a different result tells you
nothing - you've spent a full round-trip to learn that something in a set of two mattered.

## 7. Symptoms lie about their cause. Match the shape

"Access denied", "RPC server unavailable", "cannot be contacted" are the *same message* for a
credential problem, a name-resolution problem and a firewall problem. Don't read a symptom as a
diagnosis.

Get a healthy baseline of the same operation and **diff it**. The difference is the finding;
the error text is just where you started looking.

In particular, don't conflate credential contexts. A command that works locally and fails
across machines is usually about which credential the second hop is using, not about the
network being broken.

## 8. Beware the guaranteed pass

Before trusting a check, ask what it would look like if the thing were broken. A sudo-password
test run as an account with `NOPASSWD:ALL` passes no matter what - it isn't testing what it
claims to. If a probe cannot fail, it is not a probe.

## 9. Say what you measured, separately from what you concluded

In `TASK.md`, keep those apart. Measurements stay true; conclusions get revised. Mixing them is
how a guess becomes a premise three runs later and takes the whole investigation with it.

## 10. Read-only until you have earned it

Every step is read-only until you can say precisely what the change will do and why. Diagnostic
steps are safe to repeat, safe to run out of order, and safe to run against the wrong host by
accident. Action steps are none of those things, which is why they carry the `CONFIRM=yes`
gate.

---

## 11. A green exit means the probes that ran passed. Not that the work happened

A step that reports `exit 0` has told you one thing: nothing it executed returned
non-zero. It has not told you the intended change landed. A commit step once
reported success having never pushed - the push sat behind a condition that
tested a string against `"1"` and was silently false, so it simply never ran.

Verify the outcome, not the exit code. If a step is supposed to push, have it
print what the remote says afterwards. If it is supposed to apply, read the
resource back. The exit code is the weakest evidence in the log.

## 12. One request, one runner. Bind them to different branches

Two runners on one transport repo will both answer the same request, and there
is no lock that stops them. Each station records the last id it handled in
`.station-state`, which is gitignored because it is a fact about one machine, so
neither can see what the other has done. A build agent makes it worse: a
pipeline that cleans its workspace starts every job with no state file at all,
so it answers whatever id it finds, every time.

The failure looks like success. Two logs for one question, from two machines,
seconds apart, both green - and the whole value of a heliograph log is that it
says what *one* machine saw. You will not notice until two logs disagree and you
cannot tell which one is about the box you care about.

Bind each runner to its own branches, so they read different copies of
`station/request` and have nothing to race on:

```
main, pipeline/*  ->  the build agent   (trigger.branches.include)
vm/*              ->  the VM station    (./start.sh --branch vm/<slug>)
```

Do not bind `task/*` to a runner. It is the branch name this documentation uses
for an investigation, so it is the first thing anyone reaches for when starting
work on the *other* runner - which is exactly how both end up on one request.

The trigger config stops the run being created; add a guard in the job that
refuses a branch outside its set, because queueing a run by hand from a web UI
bypasses trigger evaluation entirely. A loud failure beats a silent double
answer.

---

## When the branch carries a change, not only a question

Sometimes the repo that has to *change* is on the far side of the gap too. A
separate estate often lives on a git server you cannot reach from where you are
authoring: you cannot clone it, grep it, or read its config. Only the machine
the operator reaches can. This is the standing case for production and
pre-production estates kept deliberately separate from the one you develop in.

That does not change the loop. It means the branch carries the change as well
as the question, and five more rules apply.

### 13. Measure the target before you write a line of the change

The temptation is to copy the working definition from the sibling estate and
rename one environment to another. Do not. Resource-group keys, subnet keys,
secret names, module refs and the slice layout are all local conventions, and a
definition built on assumed ones fails at plan time at best, or applies something
subtly wrong at worst.

The first step of this kind of task is always a **discovery** step, and it should
answer *everything* needed to author the change. One round trip is expensive.

A discovery step should:

- **Find the checkout, do not assume its path.** Search a set of roots, then
  identify each candidate by `git remote -v`. A directory named `infra` may be
  the repo you want under a different local name, and the remote is the only
  thing that proves it.
- **Print the wiring, not just the tree.** The config file, the dependency-key
  map, the root configuration, the branch and head commit. Those are what the
  change has to agree with.
- **Prove the toolchain and the module source.** Versions, cloud auth, and
  whether the private registry actually resolves from that machine. A plan that
  cannot fetch modules fails for a reason that has nothing to do with your
  Terraform.
- **Name secrets, never read them.** Listing secret *names* settles "does this
  exist here". The value is never in question and must never reach a log.

### 14. Read the sibling estate's current config before designing

Two decisions have been re-litigated from first principles that another estate
had already made and written down, including a provider-version trap with its
reasoning in a comment. One of them led to cutting a version tag in a shared
module registry to work around a problem that had already been decided against.

`git show origin/main:<path>` costs nothing. Do it before designing, not after
committing.

### 15. Deliver the change as a payload, not as instructions

Put the new file under `payload/` on the task branch and write a step that copies
it into place and runs the plan. Commit both and `heliograph send` the step: the
operator types nothing new.

**Never send them a patch to apply by hand.** An unlogged manual edit is exactly
the divergence these logs exist to rule out.

Sequence it so nothing changes state before the evidence justifies it:

| step | does | gate |
|---|---|---|
| `discover` | reads the target repo and estate | read-only |
| `plan` | copies the payload in, then plans | read-only against the estate; prints a diff of what it copied |
| `apply` | the real change | `action`: `CONFIRM=yes`, `--mode action` on the send, and a station started with `--allow-actions` |

A `plan` step still writes files into the *other* repo, so it must say so at the
top, show the diff it caused, and be re-runnable. Leave the target repo's working
tree obviously dirty rather than committing on the operator's behalf: what gets
committed there is a human decision, and the log is the evidence for making it.

`lib/tfguard.sh` carries two guard rails that exist because the same mistakes
recur, and the reasoning generalises past Terraform:

- **A "refresh the dependency" flag is rarely only that.** `terraform init
  -upgrade` re-resolves *providers* to latest, ignoring the lock file, and the
  resulting errors point at files nobody edited. A changed module ref is
  re-fetched by a plain init anyway.
- **A lock file committed in the target repo is not yours to move.** Restoring
  one something else has modified is undoing damage, not tidying, and it has to
  happen *before* the tool runs.

### 16. A guard that can only skip preserves a broken state

Guards get written to be idempotent: "if the key is already there, skip". That
is right until the thing already there is wrong. An entry inserted without a
required field passed the "is it present?" test on every later run and would
have stayed broken indefinitely.

Make a guard able to repair, not just abstain, and have it report which it did.
"SKIP, already correct" and "repaired the existing entry" are different facts.

### 17. Scope an edit to a shared file by structure, not by name

Key names repeat across sections. An edit matching `^  <key>:` anywhere in a
config file commented out live entries in three different top-level blocks
because the same name existed under each. The output said so, and that was read
as noise rather than as the symptom it was.

Track the block you are in. And print the resulting diff, not a summary line: a
count of what changed cannot show you that it changed the wrong thing.

---

## The loop, in practice

1. Write the question in `TASK.md`. One question.
2. Write the step that answers it - with a control in the same run.
3. Commit it and `heliograph send` it.
4. Read the whole log. Record what was *measured*.
5. Only then form the next hypothesis.

Slower per round-trip than guessing. Far quicker to the end of the investigation.

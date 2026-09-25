# =============================================================================
#  station.ps1 - run this ONCE on the far side and walk away
# =============================================================================
#     .\station.ps1                    # poll, run, deliver, repeat - READ-ONLY
#     .\station.ps1 --once             # do one requested run, then exit
#     .\station.ps1 --interval 15      # seconds between polls (default 5)
#     .\station.ps1 --allow-actions    # also run steps that declare themselves actions
#     .\station.ps1 --allow-root       # permit a privileged account (see SAFETY)
#     .\station.ps1 --pin              # approve the current steps, for REQUIRE_PIN=1
#
#  The PowerShell twin of station.sh, for the estate that has no bash. It
#  watches the transport for a new request, runs the step through run.ps1, and
#  publishes the result - so the loop stops needing a human to relay each run:
#
#     control  writes a request with a new id ──────────────▶ transport
#     station  sees it within seconds, runs .\run.ps1
#              publishes status "running" ──────────────────▶ transport
#              run.ps1 delivers ops-logs\<step>-<UTC>.txt ─▶ transport
#              publishes status "idle exit=N" ──────────────▶ transport
#     control  reads the log, decides the next step ◀───────
#
#  NOT TO BE CONFUSED WITH station\bash\station.ps1, which is a LAUNCHER: it
#  finds the bash that Git for Windows installed and hands over to start.sh.
#  This file is the loop itself, in PowerShell, for a machine with no bash at
#  all. The two never ship in the same payload.
#
#  THE TRIGGER IS `id`, NOT "something changed". Steps and documentation change
#  constantly; if any change triggered a run, the station would fire on all of
#  them. It runs only when the `id:` line in the request changes, so a run is
#  always something somebody asked for on purpose.
#
#  STOPPING: `stop: yes` in the request, or Ctrl-C. The stop flag is honoured
#  from the far side precisely because nobody is sitting at this terminal.
#
#  WATCHING: while a step runs the station publishes the partial log every
#  PROGRESS_EVERY seconds (default 60, 0 disables) with a line count and the
#  last real line, so a long run can be followed instead of waited out.
#
#  CANCELLING: `cancel: yes` kills the step running right now; `cancel: <id>`
#  kills it only if that id is the one running, so a stale cancel cannot reap a
#  later run. The step runs in the background and the loop keeps polling while
#  it works - an hour-long step does not make the station deaf for an hour. A
#  cancelled run publishes state `cancelled` and leaves whatever the log had
#  reached, which is usually the evidence you wanted anyway.
#
#  SAFETY, and this loop's whole posture is in this paragraph.
#
#  READ-ONLY BY DEFAULT. A step says what it is in its own file
#  (`# heliograph-mode: read-only` or `action`); this asks run.ps1 --mode and
#  refuses an action outright unless started with --allow-actions. That is
#  GATE 3, and it lives here because it is a property of how the station was
#  STARTED rather than of the step. The refusal is PUBLISHED within one poll,
#  so the far side learns in seconds rather than waiting out a round trip -
#  which is what makes a safe default affordable. An action that is allowed
#  still has to carry CONFIRM=yes in the request's `env:` and get past run.ps1's
#  own gate. ACTION_ENV catches the case a declaration cannot see: `env: APPLY=1`
#  turning a read-only step into a writing one.
#
#  NOT AS A PRIVILEGED ACCOUNT. The account this runs as IS the blast radius -
#  there are no other credentials in this toolkit - so running it as
#  Administrator or SYSTEM makes that radius the whole machine. Refused unless
#  --allow-root (or ALLOW_ROOT=1) says the estate has no other option.
#
#  REQUIRE_PIN=1 refuses any step whose file hash the operator has not approved
#  with `.\station.ps1 --pin`. Off by default: it makes every new step wait for
#  the operator, which is the relaying this loop exists to remove.
# =============================================================================
# NO param() BLOCK AND NO [CmdletBinding()], for run.ps1's reason: CmdletBinding
# adds the common parameters and binds them before this script sees anything, so
# `--interval` would be at the mercy of prefix matching against -InformationAction
# and friends. The automatic $args gets the words as typed.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $RepoRoot

Import-Module (Join-Path $RepoRoot 'caplib.psm1') -Force -Global
Import-Module (Join-Path $RepoRoot 'lib/transport.psm1') -Force -Global
Import-Module (Join-Path $RepoRoot 'lib/cancel.psm1') -Force -Global
# The trusted set. Imported unconditionally so `--help` and a station with no
# TRUST_SET behave identically to one with it, and so a set that will not parse
# is a startup failure rather than a surprise at the first request.
Import-Module (Join-Path $RepoRoot 'lib/trust.psm1') -Force -Global

$SelfPath = $MyInvocation.MyCommand.Path

# --- the configuration a detached start has no other way to get ---------------
# See lib/stationenv.psm1. Read here as well as in start.ps1, because the loop
# is startable on its own - `.\station.ps1` by hand, and the scheduled task's
# own restart after a self-update exit both reach this file without passing
# through the preflight.
Import-Module (Join-Path $RepoRoot 'lib/stationenv.psm1') -Force -Global
$null = Import-CapStationEnv -Root $RepoRoot

function Get-FileDigest {
    param([string[]] $Paths)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $buf = New-Object System.IO.MemoryStream
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $b = [System.IO.File]::ReadAllBytes($p)
        $buf.Write($b, 0, $b.Length)
    }
    $hash = $sha.ComputeHash($buf.ToArray())
    $buf.Dispose(); $sha.Dispose()
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

# WHICH PAYLOAD IS RUNNING, published so it can be compared without asking.
#
# A transport revision cannot answer this: on git every status commit and every
# log advances HEAD, so two stations on the same payload report different
# revisions within a minute of each other. Branches carry independent copies and
# self-update pulls only its own, so drift between stations is real - and with
# nothing published it is discovered by a step behaving differently on one
# machine, which is the most expensive way to find out.
#
# The loop, the runner and the capture, because those are what a step's
# behaviour actually rests on. NOT the steps: those are SUPPOSED to differ, and
# including them would make the digest change for the ordinary reason and stop
# meaning anything. station.sh digests the same three.
$Payload = (Get-FileDigest -Paths @(
        $SelfPath,
        (Join-Path $RepoRoot 'run.ps1'),
        (Join-Path $RepoRoot 'caplib.psm1'))).Substring(0, 12)
$SelfHash = Get-FileDigest -Paths @($SelfPath)

# --- the knobs ----------------------------------------------------------------
function Get-EnvOr {
    param([string] $Name, [string] $Default)
    $v = [System.Environment]::GetEnvironmentVariable($Name)
    if ($v) { return $v }
    return $Default
}

$Interval = [int](Get-EnvOr 'INTERVAL' '5')
$Once = $false
$PinOnly = $false

# 1 = the station may run steps that change state, when the request asks.
#
# DEFAULT 0. This was 1 on the bash side for a while and the reason was real:
# the flag is typed once at station start, often days before the request it
# gates, and a forgotten one surfaced as a silent "refused" long after the push
# - wasting exactly the round trip this tooling exists to save.
#
# What retired that argument was publishing the refusal: it now reaches the far
# side, with its reason and the flag that would allow it, within one poll. The
# cost of a safe default fell from a wasted day to a few seconds, and an
# unattended loop that can change infrastructure because a file changed is not a
# default anything should ship.
$AllowActions = (Get-EnvOr 'ALLOW_ACTIONS' '0') -ceq '1'
$RequirePin = (Get-EnvOr 'REQUIRE_PIN' '0') -ceq '1'
$ProgressEvery = [int](Get-EnvOr 'PROGRESS_EVERY' '60')

# A substring match against the request's env line, and it stays because a
# DECLARATION CANNOT SEE IT: a step that plans is read-only until `env: APPLY=1`
# makes it apply. Add whatever does that on your branch.
$ActionEnv = (Get-EnvOr 'ACTION_ENV' 'APPLY=1 CONFIRM=yes DESTROY=1 FORCE=1 WRITE=1') -split '\s+' |
    Where-Object { $_ }

# --- the trusted set: who may command this station ---------------------------
#
# OFF UNLESS THE OPERATOR PLANTED ONE, exactly as on the bash side. Every
# station in the field has none, and upgrading one means somebody standing at a
# machine.
#
# UNLIKE THE BASH STATION, THIS ONE NEEDS NOTHING INSTALLED. Ed25519
# verification is already here in managed C# (lib/seal.psm1 over
# vendor/Chaos.NaCl), so there is no TRUST_SEAL and no binary to check. The
# formats are held identical to the Go side by tests/trust-vectors.ps1, which
# compares canonical bytes, digests and whole refusal sentences against
# tests/fixtures/trust-vectors.json.
#
# THE FILE IS LOCAL AND GITIGNORED, for the reason .station-approved-ps is:
# recorded in the transport repo it could be edited from the far side, and the
# far side is the only side a trust root exists to distrust. What is published
# is a read-only COPY.
$TrustSetPath = Get-EnvOr 'TRUST_SET' ''
$TrustPublish = 'station/trusted-set'
$TrustSet = $null

# Every request id this station has ACTED ON. The replay defence, on disk so it
# survives a restart - a station restarts when the machine does, which is
# exactly when nobody is watching. .station-state holds only the LAST id, so a
# request from two days ago, put back, ran again with every gate satisfied.
$SeenIdsFile = Join-Path $RepoRoot '.station-seen-ids'
$SeenIdsKeep = [int](Get-EnvOr 'SEEN_IDS_KEEP' '2000')

$StateFile = Join-Path $RepoRoot '.station-state'
# A FILE OF ITS OWN, not the bash station's .station-approved.
#
# The two payloads pin different files - run.sh/caplib.sh/lib/*.sh against
# run.ps1/caplib.psm1/lib/*.psm1 - and each `--pin` TRUNCATES the file before
# writing. Sharing one would mean each implementation's pin silently unapproved
# the other's, so in a repo carrying both payloads every request would be
# refused by whichever station did not pin last. Separate files, no collision,
# and each pin is complete for the payload that wrote it.
$ApprovedFile = Join-Path $RepoRoot '.station-approved-ps'
$LockFile = Join-Path $RepoRoot '.station.lock'
$DeliveryFile = Join-Path $RepoRoot '.station-delivery'

function Show-Usage {
    # READ OUT OF THIS FILE, so the usage and the behaviour cannot disagree.
    # station.sh prints its own header the same way, with the same sed.
    $n = 0
    foreach ($l in [System.IO.File]::ReadAllLines($SelfPath)) {
        $n++
        if ($n -lt 2) { continue }
        if ($l -cmatch '^# =+$' -and $n -gt 3) { break }
        Write-Output ($l -replace '^#\s?', '')
    }
}

$argv = @($args)
$i = 0
while ($i -lt $argv.Count) {
    # -ceq throughout: station.sh's `case` is case-sensitive, and `--ONCE` is
    # not an option there.
    switch -CaseSensitive ($argv[$i]) {
        '--once' { $Once = $true }
        '--interval' {
            if ($i + 1 -ge $argv.Count) {
                [Console]::Error.WriteLine('--interval needs a number of seconds')
                exit 2
            }
            $i++
            if ("$($argv[$i])" -notmatch '^\d+$') {
                [Console]::Error.WriteLine("--interval wants a whole number of seconds, not '$($argv[$i])'")
                exit 2
            }
            $Interval = [int]$argv[$i]
        }
        '--allow-actions' { $AllowActions = $true }
        '--no-actions' { $AllowActions = $false }   # the default; kept so old invocations still work
        # SET IN THE ENVIRONMENT, not in a variable, because run.ps1 is a
        # SEPARATE PROCESS with a root gate of its own and reads this from the
        # environment it inherits.
        #
        # station.sh got this wrong and shipped it: it set a plain shell
        # variable, so `--allow-root` satisfied the loop's check and reached
        # nothing else, and every step was then refused with exit 5 while the
        # status said only "the runner exited before it reached delivery". The
        # ALLOW_ROOT=1 form worked the whole time because that one is already in
        # the environment - so the variable worked and the flag beside it did
        # not. Fixed there in the same change as this.
        '--allow-root' { $env:ALLOW_ROOT = '1' }
        '--pin' { $PinOnly = $true }
        '-h' { Show-Usage; exit 0 }
        '--help' { Show-Usage; exit 0 }
        default {
            [Console]::Error.WriteLine("unknown option: $($argv[$i])")
            exit 2
        }
    }
    $i++
}

function Write-Say {
    param([string] $Text)
    Write-Host ("{0}  {1}" -f [DateTime]::UtcNow.ToString('HH:mm:ssZ'), $Text)
}

# --- the transport ------------------------------------------------------------
# EXPORTED, because run.ps1 is a separate process and loads a transport of its
# own in order to deliver. Left unexported, every station would hand its runner
# the git default - so a share station would capture perfect logs and deliver
# them into a git repo that may not even exist. That is the exact defect
# Send-TpLog exists to fix, reintroduced one variable lower down.
if (-not $env:TRANSPORT) { $env:TRANSPORT = 'git' }

if (-not (Import-Tp)) { exit 2 }

# Read at START, so a station can say what it will NOT be able to do later,
# while there is still somebody listening. A station that cannot self-update is
# a working station; one that discovers it when an update is needed and nobody
# is there has cost a round trip.
$CanSelf = Test-TpCapability -Name 'self'
$CanLive = Test-TpCapability -Name 'live'

$Scope = Get-TpScope
if (-not $Scope) {
    [Console]::Error.WriteLine('station: the transport reported no scope')
    exit 2
}

# --- one station per checkout -------------------------------------------------
# Two would double-run every request and race on publication.
#
# --pin takes no lock, deliberately: approving a new step is exactly the thing an
# operator does WHILE the loop is running, and a pin that refused because the
# station was up would be useless at the only moment it is wanted.
$HoldsLock = $false
if (-not $PinOnly) {
    if (Test-Path -LiteralPath $LockFile -PathType Leaf) {
        $held = ''
        try { $held = ([System.IO.File]::ReadAllText($LockFile)).Trim() } catch { $held = '' }
        # ONE LINE, THE PID, AND NOTHING ELSE - the same format station.sh
        # writes and reads, so a bash station and a PowerShell station in one
        # payload directory still lock each other out.
        #
        # A RECYCLED PID READS AS A LIVE STATION, and this does not try to tell
        # them apart. Recording a start time as well would fix it and would make
        # this file unreadable to station.sh, which cats it and passes the whole
        # thing to `kill -0`. The shared format is worth more: the case it
        # protects against - two stations double-running every request - is
        # common, and a recycled pid holding a lock presents as a refusal to
        # start with the pid named, which an operator can check in seconds.
        if ($held -match '^\d+$' -and (Test-CapAlive -ProcessId ([int]$held))) {
            [Console]::Error.WriteLine("station: already running here as pid $held (remove $LockFile if that is wrong)")
            exit 3
        }
        Write-Say "clearing a stale lock from pid $(if ($held) { $held } else { '?' })"
    }
    [System.IO.File]::WriteAllText($LockFile, "$PID")
    $HoldsLock = $true
}

# --- pinning: run only what the operator approved ------------------------------
# The hashes live in a LOCAL file that is not published. Recorded in the
# transport they could be edited from the far side, which is the only side a pin
# exists to distrust - the approval would then travel with the change it is
# supposed to catch.
#
# The pinned set is everything a request can cause to execute: the step itself,
# the runner, the capture library and the modules a step loads. Hashing rather
# than listing names is the point - an edit to an approved step is a different
# step, and the pin notices.
#
# It does NOT cover station.ps1, which self-updates. Said out loud rather than
# implying a boundary that is not there.
function Get-PinSet {
    $out = @()
    foreach ($rel in 'run.ps1', 'caplib.psm1') {
        $p = Join-Path $RepoRoot $rel
        if (Test-Path -LiteralPath $p -PathType Leaf) { $out += $rel }
    }
    $libDir = Join-Path $RepoRoot 'lib'
    if (Test-Path -LiteralPath $libDir -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $libDir -Filter '*.psm1' -File | Sort-Object Name)) {
            $out += "lib/$($f.Name)"
        }
    }
    return $out
}

function Get-PinLine {
    param([string] $Relative)
    $p = Join-Path $RepoRoot $Relative
    # LOWERCASE HEX, because sha256sum writes lowercase and this file is meant
    # to be readable beside the bash station's. Get-FileHash writes uppercase.
    return "$(Get-FileDigest -Paths @($p))  $Relative"
}

function Write-Pin {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($rel in (Get-PinSet)) { $lines.Add((Get-PinLine -Relative $rel)) }
    $stepsDir = Join-Path $RepoRoot 'steps'
    if (Test-Path -LiteralPath $stepsDir -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $stepsDir -File | Sort-Object Name)) {
            $lines.Add((Get-PinLine -Relative "steps/$($f.Name)"))
        }
    }
    [System.IO.File]::WriteAllLines($ApprovedFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
    Write-Say "approved $($lines.Count) file(s) into $ApprovedFile"
    Write-Say "re-run .\station.ps1 --pin after any step changes, or the loop will refuse them"
}

function Test-Pin {
    <#
      .SYNOPSIS
      '' when every file a request would execute is approved; otherwise the
      first path that is not.
    #>
    param([string] $StepFile)
    $approved = @()
    if (Test-Path -LiteralPath $ApprovedFile -PathType Leaf) {
        $approved = [System.IO.File]::ReadAllLines($ApprovedFile)
    }
    $want = @(Get-PinSet)
    if ($StepFile) {
        # THE SAME SPELLING THE PIN WROTE. run.ps1 --file answers with an
        # absolute path; the approval is matched as a whole line and Write-Pin
        # writes `steps/x.ps1`. Two spellings of one file hash identically and
        # never match, which would refuse every step with pinning on.
        $rel = $StepFile
        if ($rel.StartsWith($RepoRoot)) {
            $rel = $rel.Substring($RepoRoot.Length).TrimStart('\', '/')
        }
        $want += ($rel -replace '\\', '/')
    }
    foreach ($rel in $want) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $rel) -PathType Leaf)) { continue }
        if ($approved -cnotcontains (Get-PinLine -Relative $rel)) { return $rel }
    }
    return ''
}

if ($PinOnly) {
    Write-Pin
    exit 0
}

# The account is the blast radius, and an unattended loop is the worst place to
# find that out afterwards. Checked once at startup rather than per run: this
# process does not change identity, and a loop that would refuse every request
# should say so before the operator walks away rather than a day later in a
# status document.
if (-not (Test-CapPrivilegedAllowed)) {
    [Console]::Error.WriteLine('station: refusing to run as a privileged account.')
    [Console]::Error.WriteLine('  This toolkit has no credentials of its own, so the account it runs as is')
    [Console]::Error.WriteLine('  the whole blast radius. As Administrator or SYSTEM that is the machine.')
    [Console]::Error.WriteLine('  Run it as an ordinary user, or set ALLOW_ROOT=1 if this image has no other.')
    if ($HoldsLock) { Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue }
    exit 5
}

# EVERYTHING THIS STARTS DIES WITH IT. On Windows that is a Job Object with
# KILL_ON_JOB_CLOSE, falling back to taskkill where Add-Type is blocked; on Unix
# it is nothing, because the caller is expected to have a process group. An
# operator who kills the station expects the run to stop, not to carry on
# detached and publish a log afterwards with nothing watching it.
$KillStrategy = Enter-CapKillGroup

# --- request parsing ----------------------------------------------------------
# Deliberately dumb `key: value`. No YAML parser, nothing to install, and the
# document stays readable by whoever opens it next.
function Get-Field {
    <#
      .SYNOPSIS
      The first `<Name>: value` line of a request body, or ''.
      .DESCRIPTION
      CASE-SENSITIVE, because station.sh reads these with a case-sensitive sed
      and a request that means one thing to one station and another to its twin
      has not said anything.
    #>
    param([string] $Body, [string] $Name)
    if (-not $Body) { return '' }
    $re = "^$([regex]::Escape($Name)):\s*(.*)$"
    foreach ($l in ($Body -split "`r?`n")) {
        if ($l -cmatch $re) { return $Matches[1] }
    }
    return ''
}

# --- run.ps1 is the authority on what a step is ------------------------------
# Asked through `--mode` and `--file` rather than by reading the step table
# here. That mapping belongs to run.ps1, and a second copy of it would drift the
# first time somebody registered a step that takes arguments - drift that shows
# up as a WRITING step being waved through.
$Shell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$Runner = Join-Path $RepoRoot 'run.ps1'

# THE EXIT CODE IS KEPT, in $script:RunnerExit, because run.ps1 answers two
# different questions with it: 2 is "there is no such step", 3 is "the step
# declares no mode". Reading only the printed line made an unknown step look
# like a step with no mode, and the refusal told the reader to add a header to
# a file that does not exist. station.sh keeps the same code the same way.
$script:RunnerExit = 0

function Invoke-Runner {
    <#
      .SYNOPSIS
      Run run.ps1 with these arguments and return its first line of output.
      Its exit code is left in $script:RunnerExit.
    #>
    param([string[]] $RunArgs)
    # CONTINUE, IN THIS SCOPE ONLY. Windows PowerShell 5.1 turns a line on a
    # redirected native stderr into a terminating error under Stop, and run.ps1
    # writes one for exactly the case the exit code has to report.
    $ErrorActionPreference = 'Continue'
    # THE WHOLE OUTPUT FIRST, then the first line. A pipeline that
    # Select-Object stops early never sets $LASTEXITCODE, so the code read after
    # it belongs to whatever native command ran before.
    $out = @(& $Shell -NoProfile -File $Runner @RunArgs 2>$null)
    $script:RunnerExit = $LASTEXITCODE
    if ($out.Count -eq 0 -or $null -eq $out[0]) { return '' }
    return "$($out[0])".Trim()
}

function Get-StepMode { param([string] $Step) return (Invoke-Runner -RunArgs @('--mode', $Step)) }
function Get-StepFile { param([string] $Step) return (Invoke-Runner -RunArgs @('--file', $Step)) }

function Get-DefaultStep {
    <#
      .SYNOPSIS
      The step run.ps1 runs when a request names none.
      .DESCRIPTION
      READ OUT OF run.ps1's SOURCE, which is what station.sh does with a sed on
      run.sh's DEFAULT_STEP line. It is not elegant and the alternative is
      worse: a `--default-step` option here would be a fourth query verb that
      run.sh does not have, so the two runners would answer a different set of
      questions and the twin comparison would have nothing to compare.
    #>
    try {
        foreach ($l in [System.IO.File]::ReadAllLines($Runner)) {
            if ($l -cmatch "^\`$DefaultStep\s*=\s*'([^']*)'") { return $Matches[1] }
        }
    } catch { }
    return ''
}

# Every refusal takes the same shape: say it locally, PUBLISH it with a reason
# the far side can act on, and record the id so the same request is not
# re-refused on every poll. The publishing is the part that matters - a refusal
# nobody can see is indistinguishable from a station that died.
function Deny {
    param([string] $Id, [string] $Step, [string] $Reason, [string] $Local)
    Write-Say "REFUSED: $Local"
    Publish-Status -State 'refused' -Id $Id -Step $Step -Extra "reason:   $Reason"
    $script:LastId = $Id
    [System.IO.File]::WriteAllText($StateFile, $Id)
}

function Test-ActionStep {
    param([string] $Step, [string] $EnvLine)
    if ((Get-StepMode -Step $Step) -ceq 'action') { return $true }
    foreach ($a in $ActionEnv) {
        if ($EnvLine -and $EnvLine.Contains($a)) { return $true }
    }
    return $false
}

# --- the env line -------------------------------------------------------------
# `env: CONFIRM=yes HOSTS="a b"` has to become separate assignments, so it cannot
# simply be passed through as one string. Plain splitting on whitespace cannot be
# the whole answer either: a value with a space in it is not exotic - HOSTS is
# the toolkit's own documented example of one.
#
# So: split it the way a shell would, honouring quotes, but refuse anything that
# could DO something rather than assign something.
#
# WHAT THIS GUARD IS AND IS NOT, stated plainly because the obvious reading is
# wrong here. On the bash side the line reaches an `eval`, so refusing these
# characters is what stops a request executing something. NOTHING IS EVALUATED
# HERE - Split-EnvLine is a parser and the values go into a child's environment
# - so this is not what stops evaluation on this station. What it does is keep
# the two implementations refusing the SAME SET OF REQUESTS.
#
# Without it they diverge on the ordinary case rather than the exotic one:
# `env: FOO=a;DANGER=1` is a perfectly valid NAME=value assignment to this
# parser and would be accepted, while station.sh refuses it on the semicolon. A
# request that is legal on one station and refused on its twin is a control side
# that works against one machine and not another, which is worse than either
# rule on its own.
#
# The request is already a trusted control channel - it names the step to run -
# but "trusted" is not a reason to relax a rule its twin enforces, and a refusal
# naming the character costs one round trip less than a surprise.
$EnvMetaChars = '$', '`', ';', '&', '|', '<', '>', '('

function Split-EnvLine {
    <#
      .SYNOPSIS
      Shell-style word splitting, honouring quotes. Returns $null if unbalanced.

      .DESCRIPTION
      MATCHES WHAT station.sh's `eval` DOES for the character set that survives
      the metacharacter refusal above, which is the only set that reaches here:

        outside quotes   whitespace splits; \X yields X; ' and " open a quote
        inside '...'     everything is literal, including backslash
        inside "..."     \" and \\ are escapes, everything else literal

      The backslash rules are the ones that matter on Windows, where a value is
      usually a path, and they were MEASURED against bash's own `eval` rather
      than reasoned about:

        FOO=C:\tmp      ->  FOO=C:tmp     unquoted, a shell eats the backslash
        FOO='C:\tmp'    ->  FOO=C:\tmp    single quotes: everything is literal
        FOO="C:\tmp"    ->  FOO=C:\tmp    double quotes: \ before t is no escape
        FOO=a\\b        ->  FOO=a\b       \\ is an escaped backslash

      A splitter that "helpfully" kept the backslash in the first case would
      make the twins disagree about the value a step RECEIVES, from the same
      request - and nothing would fail. The step would simply look in the wrong
      directory and report honestly about it. Agreeing on an awkward rule is
      much better than that, and tests/test-station-loop-ps1.sh compares the two
      implementations on every one of these.
    #>
    param([string] $Line)
    $out = New-Object System.Collections.Generic.List[string]
    $cur = New-Object System.Text.StringBuilder
    $has = $false
    $quote = ''
    $i = 0
    while ($i -lt $Line.Length) {
        $c = $Line[$i]
        if ($quote -eq "'") {
            if ($c -eq "'") { $quote = '' } else { [void]$cur.Append($c) }
        } elseif ($quote -eq '"') {
            if ($c -eq '"') {
                $quote = ''
            } elseif ($c -eq '\' -and $i + 1 -lt $Line.Length -and
                      ($Line[$i + 1] -eq '"' -or $Line[$i + 1] -eq '\')) {
                $i++; [void]$cur.Append($Line[$i])
            } else {
                [void]$cur.Append($c)
            }
        } elseif ($c -eq "'" -or $c -eq '"') {
            $quote = "$c"; $has = $true
        } elseif ($c -eq '\' -and $i + 1 -lt $Line.Length) {
            $i++; [void]$cur.Append($Line[$i]); $has = $true
        } elseif ($c -eq ' ' -or $c -eq "`t") {
            if ($has) { $out.Add($cur.ToString()); [void]$cur.Clear(); $has = $false }
        } else {
            [void]$cur.Append($c); $has = $true
        }
        $i++
    }
    # AN UNBALANCED QUOTE IS REFUSED, not silently closed at end of line. `eval`
    # on the bash side fails outright on one, and a splitter that closed it here
    # would run a step with a value neither side intended.
    if ($quote) { return $null }
    if ($has) { $out.Add($cur.ToString()) }
    return , $out.ToArray()
}

# A REQUEST MAY NOT SET THE VARIABLES THAT CONTROL DELIVERY OR THE GATES.
#
#   TRANSPORT  redirects where the log is delivered, or names a module that
#              gets imported. The operator chose the channel at start
#   PUSH       PUSH=0 captures and delivers NOTHING, while the run still looks
#              clean from here. That is the exact defect Send-TpLog exists to
#              remove, handed to whoever can write a request
#   REDACT     turns off secret masking on a log that is about to be published
#              and cannot be unpublished
#   LOG_DIR    moves the log somewhere this loop will not find to report it
#
# AND EVERY TRANSPORT'S OWN CONFIGURATION, which those four names do not cover.
#
# Get-TpNeed reads variables STRAIGHT OUT OF THE ENVIRONMENT - that is how every
# transport is configured - so reserving four names left the whole of a
# transport's configuration settable by whoever can write a request:
#
#   RELAY_URL    the captured log is delivered to a relay of the author's choice
#   RELAY_PEER   what a request is verified against AND who the log is sealed
#                to. relay.psm1 uses it for both
#   SHARE_DIR    the same redirection on a share station
#   OBJSTORE_*   and on an object store
#
# A `read-only` step does it and NO GATE FIRES - not --allow-actions, not
# CONFIRM, not the root refusal. It needs somebody who can publish a request,
# and the premise of this whole tool is that the request author is not the
# estate owner.
#
# SO IT IS RESERVED BY PREFIX, NOT BY NAME, matching station.sh line for line. A
# new transport that introduces a new prefix must add it in BOTH, and
# tests/test-station-gate.sh fails if either is missed: it reads both patterns
# and checks every Test-TpNeed and cap_need name against them.
#
# THE TWO STATIONS MUST AGREE, and this is the reason that is stated rather than
# assumed. A control side cannot tell which implementation answered a request,
# so a security gate that differs between them means the same request is refused
# on one machine and honoured on another. These twins have diverged on a gate
# before - three case-sensitivity differences in run.ps1, two of them in a
# security check - which is why the suite now compares them rather than reading
# both and hoping.
#
# CHECKED AFTER THE SPLIT, ON THE PARSED NAMES, and that is the whole point. The
# bash side once matched ` TRANSPORT=` against the raw line and quoting walked
# straight through it: `FOO=1 "TRANSPORT=relay"` and `T"RANSPORT"=relay` both
# fail that test and both come out of the parser as a plain TRANSPORT
# assignment. A guard applied before the parser is a guard against the spelling
# rather than against the meaning.
#
# RESERVED_ENV_PATTERN - read by tests/test-station-gate.sh. Keep on one line.
$ReservedEnvPattern = '^(TRANSPORT|PUSH|REDACT|LOG_DIR|ALLOW_ROOT|ALLOW_ACTIONS|CAP_.*|RELAY_.*|SHARE_.*|PIGEONHOLE_.*|OBJSTORE_.*|BLOB_.*|BUNDLE_.*|TRUST_.*)$'

# --- the trusted set ----------------------------------------------------------
#
# VALIDATED AT STARTUP, WHILE SOMEBODY IS STILL LISTENING. A station configured
# with a set it cannot read would refuse every request afterwards, on a machine
# nobody can log into, for a reason nothing had said out loud. That is the shape
# of the defect RELAY_PEER had on the bash side: readable was checked, usable
# was not, and every verification failed silently.
function Initialize-TrustSet {
    if (-not $TrustSetPath) { return }
    if (-not (Test-Path -LiteralPath $TrustSetPath -PathType Leaf)) {
        Write-Error@"
station: cannot read the trusted set at $TrustSetPath.
         Plant it here, on this machine. Unlike the bash station this one needs
         no extra binary: the verification is managed code already in the
         payload. Create the set with the control side's public identity as the
         anchor and restart with TRUST_SET pointing at it.
"@
        exit 2
    }
    try { $script:TrustSet = Import-TrustSetFile $TrustSetPath }
    catch {
        Write-Error @"
station: the trusted set at $TrustSetPath will not parse: $($_.Exception.Message)
         Every request would be refused. Re-plant it.
"@
        exit 2
    }
}

# Publish-TrustSet writes the auditable copy the estate owner reads.
#
# A COPY, never the authority. The authoritative set is the gitignored local
# file; this one lives in the transport where the far side can edit it, and
# editing it changes nothing at all. Publishing it is what lets an owner see a
# key appearing that nobody authorised, without asking us.
function Publish-TrustSet {
    if (-not $script:TrustSet) { return }
    try {
        $dir = Split-Path -Parent $TrustPublish
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $header = @(
            '# Published by the station. The authority is a local file this repo'
            '# cannot reach; editing this copy changes nothing. Compare it against'
            "# your own with 'heliograph doctor'."
        ) -join "`n"
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($TrustPublish, $header + "`n" + (Export-TrustSet $script:TrustSet), $utf8)
    } catch { }
}

# --- the replay ledger: an id is used once, and that survives a restart -------
#
# .station-state records the LAST id, which stops the same request firing on
# every poll and is not replay protection: a request from two days ago, put
# back, has an id that is not the last one. THE LEDGER IS A FILE, because an
# in-memory window forgets when the station restarts, and a station restarts
# when the machine does.
function Test-SeenId {
    param([string] $Id)
    if (-not (Test-Path -LiteralPath $SeenIdsFile -PathType Leaf)) { return $false }
    foreach ($line in [System.IO.File]::ReadAllLines($SeenIdsFile)) {
        if ($line -ceq $Id) { return $true }
    }
    return $false
}

function Add-SeenId {
    param([string] $Id)
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($SeenIdsFile, $Id + "`n", $utf8)
    } catch {
        # A LEDGER THAT COULD NOT BE WRITTEN IS NOT A LEDGER. Said out loud
        # rather than swallowed: a full disk would otherwise leave replay
        # protection off with nothing to say so.
        Write-Say "warn: could not record request id in $SeenIdsFile - replay protection is not being written down"
        return
    }
    try {
        $lines = [System.IO.File]::ReadAllLines($SeenIdsFile)
        if ($lines.Count -gt ($SeenIdsKeep * 2)) {
            $keep = $lines[($lines.Count - $SeenIdsKeep)..($lines.Count - 1)]
            $tmp = "$SeenIdsFile.$PID.tmp"
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($tmp, (($keep -join "`n") + "`n"), $utf8)
            Move-Item -LiteralPath $tmp -Destination $SeenIdsFile -Force
        }
    } catch { }
}

# --- the action mode, published rather than inferred --------------------------
# Whether this station will run a state-changing step is decided by
# --allow-actions at startup and holds for the whole process. It is on no
# request and it was in no published document, so the far side's only way to
# answer "can this station make changes" was to infer it from the logs already
# delivered - and that is wrong in both directions. A station restarted without
# the flag still has action logs behind it, and one started with the flag may
# never have been asked. Getting that answer wrong is not cosmetic: it is the
# field somebody reads to decide whether an estate is safe to point at.
#
# A FUNCTION RATHER THAN A SCRIPT VARIABLE, because $AllowActions is set from
# the environment before the argument loop and again inside it, and a value
# captured at the wrong moment would report the environment's answer while the
# gate at GATE 3 enforced the flag's. Read at publish time, there is one answer.
function Get-ActionMode { if ($AllowActions) { 'allowed' } else { 'refused' } }

# --- status, published so the far side can see what is happening --------------
function Publish-Status {
    param(
        [string] $State,
        [string] $Id,
        [string] $Step,
        [string] $Extra = '',
        [string] $AlsoFile = ''
    )
    $lines = @(
        "state:    $State"
        "id:       $Id"
        "step:     $Step"
        "host:     $(Get-CapHostname)"
        # `branch:` RATHER THAN `scope:`, because the control side reads that key
        # and a station in the field must stay readable by a control that
        # predates the vocabulary change. station.sh publishes the same key.
        "branch:   $Scope"
        "utc:      $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        "actions:  $(Get-ActionMode)"
        "payload:  $Payload"
    )
    # WHO MAY COMMAND THIS STATION, published on every transition, exactly as
    # station.sh publishes it. This is what lets an estate owner audit the set
    # from their own transport without asking us, so a key appearing that
    # nobody authorised is independently detectable.
    if ($script:TrustSet) {
        $lines += "trust:    $(Get-TrustSetDigest $script:TrustSet)"
        $lines += "trust-serial: $($script:TrustSet.Serial)"
        $lines += "trust-members: $(Get-TrustMembersLine $script:TrustSet)"
    }
    if ($Extra) { $lines += $Extra }
    $body = ($lines -join "`n") + "`n"
    if (-not (Send-TpStatus -Body $body -Message "station: $State ($Id) ***NO_CI***" -AlsoFile $AlsoFile)) {
        Write-Say 'status publish failed (will retry on the next transition)'
    }
}

# --- progress, published WHILE a step runs ------------------------------------
# A long step used to be a black box: nothing reached the far side until it
# finished, so "running for forty minutes" and "wedged" looked identical. This
# publishes the partial log periodically so the run can be watched as it goes.
#
# The runner still owns the log. This publishes a SNAPSHOT and never writes to
# it, so the ownership rule the whole toolkit rests on is intact.
function Publish-Progress {
    param([string] $Id, [string] $Step, [string] $Started, [string] $LogPath)
    if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return }
    $count = 0
    $last = ''
    try {
        # Read-CapSharedLines, NOT ReadAllLines. The capture holds this file
        # open for writing, and on Windows a reader that does not declare
        # FileShare.ReadWrite gets a sharing violation - so this whole function
        # threw, was swallowed by the catch below, and progress NEVER published
        # on Windows. Nothing errored; a long run was simply a black box.
        foreach ($l in (Read-CapSharedLines -Path $LogPath)) {
            $count++
            # The last non-blank, non-divider line says more about where a step
            # is than a line count does - it is usually the probe in flight.
            if ($l -match '^\s*$' -or $l -match '^-{5,}' -or $l -match '^={5,}') { continue }
            $last = $l
        }
    } catch {
        # The step is writing to this file right now. A read that loses a race
        # is not a reason to stop publishing progress.
        return
    }
    if ($last.Length -gt 160) { $last = $last.Substring(0, 160) }
    $lines = @(
        'state:    running'
        "id:       $Id"
        "step:     $Step"
        "host:     $(Get-CapHostname)"
        "branch:   $Scope"
        "utc:      $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        # Published here too, not only on transitions. A station mid-run is
        # exactly when a fleet view is being looked at, and a column that
        # empties for the duration of a long step is a column nobody trusts.
        "actions:  $(Get-ActionMode)"
        "started:  $Started"
        "progress: $count lines"
        "log:      $LogPath"
    )
    if ($last) { $lines += "last:     $last" }
    $body = ($lines -join "`n") + "`n"
    if (-not (Send-TpProgress -Body $body -Message "station: progress ($Id) $count lines ***NO_CI***" -LogPath $LogPath)) {
        Write-Say 'progress publish rejected (the far side moved) - will retry; the final delivery reconciles'
    }
}

function Find-StepLog {
    <#
      .SYNOPSIS
      The newest log this step could have written, as an absolute path, or ''.

      .DESCRIPTION
      THE LABEL, NOT THE STEP NAME. run.ps1 names a log for the step file's base
      name without its extension, so a step sent as a PATH - which is the
      documented way, `heliograph send steps/probe.ps1` - writes
      `ops-logs/probe-<stamp>.txt` and not `ops-logs/steps/probe.ps1-<stamp>`.

      station.sh globbed on the raw step for a while and every step sent by path
      published `log: <none>`, on every transport. On git that was survivable
      because the control side lists the directory; on a relay it is not, because
      a relay is a queue and the name in the status is the only name the log will
      ever have.

      This is the FALLBACK and the guess. run.ps1 records the path it actually
      delivered, and that record is the authority wherever it exists.
    #>
    param([string] $Step)
    $label = [System.IO.Path]::GetFileNameWithoutExtension($Step)
    if (-not $label) { return '' }
    $logDir = Join-Path $RepoRoot 'ops-logs'
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) { return '' }
    $newest = Get-ChildItem -LiteralPath $logDir -Filter "$label-*.txt" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc | Select-Object -Last 1
    if ($newest) { return $newest.FullName }
    return ''
}

# --- starting a step ----------------------------------------------------------
function Start-Step {
    <#
      .SYNOPSIS
      Start run.ps1 in the background. Returns the Process, or $null.
      .DESCRIPTION
      ProcessStartInfo rather than Start-Process, for the environment: the
      request's `env:` assignments have to reach the child and only the child,
      and Start-Process offers no way to say that. `.Arguments` rather than
      `.ArgumentList` because ArgumentList does not exist on .NET Framework,
      which is what Windows PowerShell 5.1 runs on - the floor this station
      targets.
    #>
    param([string] $Step, [string[]] $Assignments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo

    # --- ON UNIX, GIVE THE STEP ITS OWN PROCESS GROUP ------------------------
    # Or a cancel reaches run.ps1 and stops there, leaving the step running.
    #
    # `Process.Start` gives the child this station's process group, so
    # Stop-CapTree - which refuses to signal a group the caller is in, for the
    # very good reason that it would kill the station - can only signal the one
    # pid. run.ps1 dies, the capture stops, the log stops growing, and the
    # assertion that the cancel worked passes. The STEP carries on changing the
    # estate, with the operator told it was cancelled. Measured: the step
    # survived by minutes.
    #
    # `setsid` is what station.sh uses for exactly this. Windows needs none of
    # it: there are no process groups, and taskkill /T walks the tree.
    #
    # IT IS SAFE WHEN setsid MISBEHAVES. setsid forks instead of exec'ing when
    # it is already a group leader, which would make the pid below the wrong
    # one - but Stop-CapTree MEASURES the group rather than assuming it, so a
    # wrong pid falls back to signalling one process, which is where this
    # started. Nothing is worse than before, and usually it is right.
    $useSetsid = $false
    if (-not (Test-CapWindows) -and (Get-Command setsid -CommandType Application -ErrorAction SilentlyContinue)) {
        $useSetsid = $true
    }
    if ($useSetsid) {
        $psi.FileName = 'setsid'
        $psi.Arguments = ConvertTo-CapArgumentString -Argv @(
            $Shell, '-NoProfile', '-File', $Runner, $Step)
    } else {
        $psi.FileName = $Shell
        $psi.Arguments = ConvertTo-CapArgumentString -Argv @('-NoProfile', '-File', $Runner, $Step)
    }
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $RepoRoot
    # NOT REDIRECTED. The child inherits this station's console, so an operator
    # watching the loop sees the run as it happens, and a service manager's log
    # gets it. Redirecting would mean draining two pipes while also polling for
    # a cancel, and a pipe nobody drains is a step that blocks on its own
    # output - the capture already learned that lesson in caplib.psm1.
    foreach ($a in $Assignments) {
        $eq = $a.IndexOf('=')
        $psi.EnvironmentVariables[$a.Substring(0, $eq)] = $a.Substring($eq + 1)
    }
    try {
        return [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Say "could not start the runner: $($_.Exception.Message)"
        return $null
    }
}

# --- the banner ---------------------------------------------------------------
Write-Say "station up on $Scope at $(Get-CapHostname), polling every ${Interval}s"
Write-Say "transport: $(Get-TpDescribe)"
Write-Say "payload:   $Payload"
Write-Say "cancel:    $KillStrategy$(if ((Get-CapKillGroupReason)) { " (a Job Object was not available: $(Get-CapKillGroupReason))" })"
if (-not $CanSelf) {
    Write-Say 'note: this transport cannot update the station. To change it, re-plant.'
}
if (-not $CanLive) {
    Write-Say 'note: this transport has no live read, so a cancel is only seen once the step finishes.'
}
if ($AllowActions) {
    Write-Say 'state-changing steps: ALLOWED - started with --allow-actions, still gated by CONFIRM in the request'
} else {
    Write-Say 'state-changing steps: BLOCKED (the default) - a step declaring "action" is refused'
}
if ($RequirePin) {
    if (Test-Path -LiteralPath $ApprovedFile -PathType Leaf) {
        Write-Say "pinning: ON - only the $(@([System.IO.File]::ReadAllLines($ApprovedFile)).Count) file(s) approved in $ApprovedFile will run"
    } else {
        Write-Say "pinning: ON, nothing approved yet - every request is refused until .\station.ps1 --pin"
    }
}
Write-Say 'request "stop: yes" or Ctrl-C to finish, "cancel: yes" to kill a running step'

Initialize-TrustSet
if ($script:TrustSet) {
    Write-Say "trusted set: serial $($script:TrustSet.Serial), $(Get-TrustMembersLine $script:TrustSet)"
    Write-Say "  the anchor changes only here, on this machine"
    Publish-TrustSet
    # PUBLISHED AT STARTUP WHEN IT HAS CHANGED, and only then. station.sh does
    # the identical thing at the identical point.
    #
    # A change that ARRIVED as a request publishes its own outcome. One made
    # HERE does not, and that is the recovery path: the estate owner rotates the
    # anchor at the machine precisely when the keys that could have sent a
    # request are the problem. With nothing published, `heliograph doctor` would
    # go on reporting a match against a digest from before the rotation.
    #
    # ONLY WHEN IT HAS CHANGED, because publishing on every start would
    # overwrite the last run's exit and log with a `starting` that carries
    # neither, and a station restarts for ordinary reasons.
    $trustPublishedFile = Join-Path $RepoRoot '.station-trust-published'
    $nowDigest = Get-TrustSetDigest $script:TrustSet
    $lastDigest = ''
    if (Test-Path -LiteralPath $trustPublishedFile -PathType Leaf) {
        try { $lastDigest = ([System.IO.File]::ReadAllText($trustPublishedFile)).Trim() } catch { $lastDigest = '' }
    }
    if ($nowDigest -cne $lastDigest) {
        $lastIdAtStart = ''
        if (Test-Path -LiteralPath $StateFile -PathType Leaf) {
            try { $lastIdAtStart = ([System.IO.File]::ReadAllText($StateFile)).Trim() } catch { $lastIdAtStart = '' }
        }
        if ($lastDigest) { Write-Say 'the trusted set changed while this station was down - publishing it' }
        Publish-Status -State 'starting' -Id $lastIdAtStart -Step ''
        try {
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($trustPublishedFile, $nowDigest + "`n", $utf8)
        } catch { }
    }
} else {
    Write-Say 'trusted set: none configured - this station accepts whatever its transport verifies'
}

$LastId = ''
if (Test-Path -LiteralPath $StateFile -PathType Leaf) {
    try { $LastId = ([System.IO.File]::ReadAllText($StateFile)).Trim() } catch { $LastId = '' }
}
if ($LastId) { Write-Say "last request handled here: $LastId" }

$script:Running = $null

function Stop-Station {
    param([int] $Code = 0)
    if ($HoldsLock) { Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue }
    if ($script:Running -and -not $script:Running.HasExited) {
        Write-Say 'interrupted mid-run - signalling the step, the log may not have been delivered'
        [void](Stop-CapTree -ProcessId $script:Running.Id)
    }
    Write-Say 'stopped'
    exit $Code
}

# Ctrl-C, and anything else that unwinds this script. PowerShell has no trap for
# SIGINT that survives into a finally reliably across both editions, so the
# whole loop is wrapped: an operator who interrupts the station gets the lock
# released and the step signalled, rather than a lock file that refuses the next
# start and a step that carries on detached.
try {

$Fails = 0
while ($true) {
    $body = Receive-TpRequest
    # $null MEANS FAILED and '' means nothing is queued. Collapsing them is how
    # a station goes permanently deaf without anybody being told - see the
    # receive half of the transports. A fetch failure is a blip, not a reason to
    # die: this loop is meant to outlive a flapping link.
    if ($null -eq $body) {
        $Fails++
        if ($Fails % 12 -eq 1) { Write-Say "fetch failed (${Fails}x) - still trying" }
        Start-Sleep -Seconds $Interval
        continue
    }
    if ($Fails -ne 0) { Write-Say 'fetch recovered'; $Fails = 0 }

    # Bring a newer payload in, if this transport can. run.ps1, caplib.psm1 and
    # the steps take effect on the NEXT RUN with no restart at all, because each
    # run is a fresh process that loads them again. Only this file needs the
    # restart below.
    if ($CanSelf) {
        $sync = Sync-TpSelf
        if ($sync -eq 2) {
            Write-Say 'the payload could not be brought forward - the working tree may be dirty; leaving it alone'
            Start-Sleep -Seconds $Interval
            continue
        }
        if ($sync -eq 0) {
            Write-Say "updated: $(Get-TpRevision)"
            if ((Get-FileDigest -Paths @($SelfPath)) -cne $SelfHash) {
                # NO RE-EXEC, BECAUSE POWERSHELL HAS NONE, AND NO RESPAWN EITHER.
                #
                # station.sh execs itself here, keeping its pid. The obvious
                # translation - start a replacement and exit - is a trap on the
                # platform this station is FOR: on Windows the loop has put
                # itself in a Job Object with KILL_ON_JOB_CLOSE, a child is in
                # the same job, and the moment this process exits the last
                # handle closes and the kernel terminates the replacement it
                # just started. The station would appear to update itself and
                # then be gone, with the lock released and nothing running.
                #
                # Breaking out of the job needs CREATE_BREAKAWAY_FROM_JOB, which
                # needs the job to permit it, which needs another P/Invoke on
                # the path that exists because P/Invoke is blocked.
                #
                # So: exit, and let whatever started this start it again. A
                # non-zero code, because that is what a Windows scheduled task
                # and a systemd unit both treat as "restart me" - service.ps1
                # configures exactly that. Started by hand, the operator gets
                # the command to type.
                Write-Say 'station.ps1 itself changed. PowerShell cannot replace a running script in place,'
                Write-Say 'so this station is exiting for its supervisor to restart it into the new version.'
                Write-Say "If nothing supervises it, start it again:  .\station.ps1$(if ($argv.Count) { ' ' + ($argv -join ' ') })"
                Stop-Station -Code 75
            }
        }
    }

    if (-not $body) { Start-Sleep -Seconds $Interval; continue }

    if ((Get-Field -Body $body -Name 'stop') -ceq 'yes') {
        Write-Say 'stop requested by the far side'
        Publish-Status -State 'stopped' -Id (Get-Field -Body $body -Name 'id') -Step ''
        Stop-Station
    }

    $id = Get-Field -Body $body -Name 'id'
    if (-not $id) { Start-Sleep -Seconds $Interval; continue }
    if ($id -ceq $LastId) { Start-Sleep -Seconds $Interval; continue }

    # --- a trusted-set change, which is an act and not a step ----------------
    #
    # IT RIDES IN THE REQUEST DOCUMENT, so it costs no new transport verb, and
    # it is verified INDEPENDENTLY of however the request arrived: the signature
    # is over the change, by a key in the set. THE STEP PATH IS NOT REACHED - a
    # change is one signed act, and the control side refuses to write a request
    # carrying both.
    $incoming = $null
    try { $incoming = Import-TrustChange -Text $body } catch { $incoming = $null }
    if ($incoming) {
        if (-not $script:TrustSet) {
            Deny -Id $id -Step '' `
                 -Reason 'this station has no trusted set, so there is nothing for a trusted-set change to change. The operator plants one on the machine' `
                 -Local 'a trusted-set change arrived and this station has no trusted set'
            Add-SeenId $id
            if ($Once) { Stop-Station }
            Start-Sleep -Seconds $Interval; continue
        }
        $applied = $null
        $refusal = $null
        try { $applied = Invoke-TrustApply $script:TrustSet $incoming ([DateTime]::UtcNow) }
        catch { $refusal = $_.Exception.Message }
        if ($applied) {
            Save-TrustSet -Path $TrustSetPath -Set $applied
            $script:TrustSet = $applied
            Write-Say "TRUSTED SET: $($incoming.Op) $($incoming.Name) by $($incoming.Author), serial $($applied.Serial)"
            Publish-TrustSet
            Publish-Status -State 'idle' -Id $id -Step '' `
                -Extra "reason:   trusted set updated: $($incoming.Op) $($incoming.Name) by $($incoming.Author) serial $($applied.Serial)"
            $script:LastId = $id
            [System.IO.File]::WriteAllText($StateFile, $id)
            Add-SeenId $id
        } else {
            # EVERY REFUSAL IS PUBLISHED WITH THE VERIFIER'S OWN SENTENCE, which
            # names the key and says what was wrong with it. It is word for word
            # the Go side's, and tests/trust-vectors.ps1 compares the whole
            # sentence rather than a substring.
            Deny -Id $id -Step '' -Reason $refusal -Local "trusted-set change refused: $refusal"
            Add-SeenId $id
        }
        if ($Once) { Stop-Station }
        Start-Sleep -Seconds $Interval; continue
    }

    $step = Get-Field -Body $body -Name 'step'
    $envLine = Get-Field -Body $body -Name 'env'
    if (-not $step) { $step = Get-DefaultStep }

    Write-Say "request $id -> step '$step'$(if ($envLine) { "  env: $envLine" })"

    # --- the signed scope: target, expiry, mode and id -----------------------
    #
    # A signature over "run this" is not enough, and each of these closes one
    # gap a signature alone left open. All four are fields of the request
    # document, so on a sealed transport they are inside the signature already;
    # enforcing them here is what turns that into scope. station.sh applies the
    # identical four, in the identical order.

    # TARGET: a request written for one station, replayed at another.
    $target = Get-Field -Body $body -Name 'target'
    if ($target -and $target -cne $Scope) {
        Deny -Id $id -Step $step `
             -Reason "this request names target '$target' and this station is '$Scope'" `
             -Local "request $id was written for '$target', not for this station"
        if ($Once) { Stop-Station }
        Start-Sleep -Seconds $Interval; continue
    }

    # EXPIRY: a captured request stops being valid. Without it, one taken out of
    # a transport is good for ever - and --allow-actions and CONFIRM=yes were
    # decided days before it.
    #
    # COMPARED AS A STRING, deliberately, exactly as station.sh does. A
    # fixed-width Z-suffixed RFC3339 stamp sorts lexicographically in the same
    # order it sorts chronologically, and comparing strings cannot disagree with
    # the bash side about a time zone or a locale.
    $expires = Get-Field -Body $body -Name 'expires'
    if ($expires) {
        $nowUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        if ([string]::CompareOrdinal($nowUtc, $expires) -gt 0) {
            Deny -Id $id -Step $step `
                 -Reason "this request expired at $expires and it is now $nowUtc" `
                 -Local "request $id expired at $expires"
            if ($Once) { Stop-Station }
            Start-Sleep -Seconds $Interval; continue
        }
    }

    # REPLAY: an id this station has already acted on, remembered across a
    # restart because the ledger is a file.
    if (Test-SeenId $id) {
        Deny -Id $id -Step $step `
             -Reason "request id '$id' has already been acted on here, and an id is used once" `
             -Local "request $id is a replay: this station has already acted on that id"
        if ($Once) { Stop-Station }
        Start-Sleep -Seconds $Interval; continue
    }

    $mode = Get-StepMode -Step $step
    if ($script:RunnerExit -eq 2) {
        Deny -Id $id -Step $step `
             -Reason "unknown step '$step': run.ps1 does not register it and there is no step file at that path. The operator lists the registered steps with .\run.ps1 --list; a step file in the transport repo can be sent by its path, e.g. steps/<name>.ps1" `
             -Local "'$step' is not a registered step or a step file"
        if ($Once) { Stop-Station }
        Start-Sleep -Seconds $Interval; continue
    }

    # MODE: the request says what it expected the step to declare. A step file
    # edited from read-only to action between authoring and running would
    # otherwise carry the earlier decision's authority.
    $wantMode = Get-Field -Body $body -Name 'mode'
    if ($wantMode -and $wantMode -cne $mode) {
        Deny -Id $id -Step $step `
             -Reason "the request was signed for a '$wantMode' step and '$step' declares '$mode'. The step changed after the request was written" `
             -Local "request $id expected '$step' to be $wantMode and it declares $mode"
        if ($Once) { Stop-Station }
        Start-Sleep -Seconds $Interval; continue
    }
    if ($mode -cne 'read-only' -and $mode -cne 'action') {
        # run.ps1 would refuse this too, and its message is better. Catching it
        # here means the far side gets a status rather than an exit code buried
        # in a log it has to go and find.
        # THE REMEDY IS FOR THE SIDE THAT READS THIS. "see run.ps1 --mode" sends
        # the reader to a command on the machine they cannot log into, which is
        # the whole reason there is a status document at all. The person reading
        # it is the person who wrote the step, and what they need is the line to
        # add. station.sh publishes the same sentence.
        Deny -Id $id -Step $step `
             -Reason "step '$step' declares no mode ($mode), so it will not run. Add '# heliograph-mode: read-only' (measures, changes nothing) or '# heliograph-mode: action' (changes state, needs CONFIRM=yes) in its first 30 lines" `
             -Local "'$step' does not declare 'heliograph-mode: read-only' or 'action', so it will not run"
        if ($Once) { Stop-Station }
        Start-Sleep -Seconds $Interval; continue
    }

    # --- GATE 3: the station must have been STARTED with --allow-actions ------
    # The gate this file exists to carry. run.ps1 has gates 1, 2 and 4 and
    # cannot have this one: it is a property of how the STATION was started, and
    # a runner invoked by hand has no station behind it to ask.
    if ((Test-ActionStep -Step $step -EnvLine $envLine) -and -not $AllowActions) {
        Deny -Id $id -Step $step `
             -Reason 'step changes state; restart the station with --allow-actions to permit it' `
             -Local "'$step'$(if ($envLine) { " with env '$envLine'" }) changes state, and this station is read-only (the default)"
        if ($Once) { Stop-Station }
        Start-Sleep -Seconds $Interval; continue
    }

    if ($RequirePin) {
        $unpinned = Test-Pin -StepFile (Get-StepFile -Step $step)
        if ($unpinned) {
            Deny -Id $id -Step $step `
                 -Reason "'$unpinned' is not approved in $ApprovedFile - the operator runs .\station.ps1 --pin to approve it" `
                 -Local "'$step' is not approved: $unpinned is new or has changed since the last --pin"
            if ($Once) { Stop-Station }
            Start-Sleep -Seconds $Interval; continue
        }
    }

    # --- the env line, parsed and gated --------------------------------------
    $assignments = @()
    if ($envLine) {
        $bad = ''
        foreach ($m in $EnvMetaChars) {
            if ($envLine.Contains($m)) { $bad = $m; break }
        }
        if ($bad) {
            Write-Say "  env: $envLine"
            Write-Say '  Use plain NAME=value pairs; quote a value that contains spaces.'
            Deny -Id $id -Step $step `
                 -Reason "env line contains the shell metacharacter '$bad', which this does not evaluate" `
                 -Local "env line contains '$bad', and this station evaluates nothing"
            if ($Once) { Stop-Station }
            Start-Sleep -Seconds $Interval; continue
        }

        $assignments = Split-EnvLine -Line $envLine
        if ($null -eq $assignments) {
            Write-Say "  env: $envLine"
            Deny -Id $id -Step $step `
                 -Reason 'env line has an unbalanced quote, so it is not parseable as NAME=value pairs' `
                 -Local 'env line has an unbalanced quote'
            if ($Once) { Stop-Station }
            Start-Sleep -Seconds $Interval; continue
        }

        $reject = ''
        foreach ($a in $assignments) {
            $eq = $a.IndexOf('=')
            # NOT AN ASSIGNMENT AT ALL. station.sh hands the array to `env`,
            # which treats the first non-assignment as a COMMAND - so a stray
            # word there runs something, and a mis-typed one dies with
            # `env: 'b': No such file or directory  exit 127`, which reads as a
            # broken step rather than as a malformed request. Nothing is
            # evaluated here, so it is refused by name instead, which is the
            # same outcome arrived at honestly.
            if ($eq -lt 1) {
                $reject = "'$a' is not a NAME=value assignment"
                break
            }
            $name = $a.Substring(0, $eq)
            if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
                $reject = "'$name' is not a usable variable name"
                break
            }
            # -imatch, CASE-INSENSITIVE, AND THIS IS THE ONE GATE HERE THAT IS.
            #
            # Every other check in this station is case-SENSITIVE, deliberately,
            # because `read-only` and `READ-ONLY` are different declarations and
            # bash's `case` distinguishes them. This one is the opposite, and
            # the reason is the platform rather than the protocol.
            #
            # WINDOWS ENVIRONMENT VARIABLE NAMES ARE CASE-INSENSITIVE. The child
            # environment is a StringDictionary on .NET Framework, so
            # `transport=relay` and `TRANSPORT=relay` are the SAME entry and the
            # second silently overwrites the first. A case-sensitive guard would
            # refuse `TRANSPORT=relay`, allow `transport=relay`, and Windows
            # would honour it - which is the whole defect, spelled in lowercase.
            #
            # Measured, not assumed: on .NET on Linux the same dictionary keeps
            # two distinct keys, so this is over-strict there and necessary
            # here. Being over-strict costs an operator nothing - nothing reads
            # a lowercase `share_dir` - and it makes the two platforms behave
            # alike, which is worth more than the letter of the rule.
            #
            # The bash twin needs no equivalent: `env transport=relay ./run.sh`
            # sets a genuinely different variable, and run.sh reads $TRANSPORT.
            # Same RULE - a request may not influence these - implemented to
            # suit what each platform will actually honour.
            if ($name -imatch $ReservedEnvPattern) {
                $reject = "the env line sets $name, which configures capture, delivery, redaction or identity and is settled at station start, not per request"
                break
            }
        }
        if ($reject) {
            Write-Say "  env: $envLine"
            Deny -Id $id -Step $step -Reason $reject -Local $reject
            if ($Once) { Stop-Station }
            Start-Sleep -Seconds $Interval; continue
        }
    }

    Publish-Status -State 'running' -Id $id -Step $step
    $started = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

    # CLEARED BEFORE THE RUN, so its ABSENCE means something.
    #
    # run.ps1 writes this at the end to say whether the log got out. Left over
    # from the previous run it is worse than useless: a runner that exits before
    # delivery - refused as privileged, an unknown step, killed - would leave the
    # last run's verdict in place and this loop would publish it as though it
    # described this one. Publishing `undelivered` for a run that produced no log
    # at all, or `idle` for one that produced a log nobody received, are both
    # lies told to somebody who cannot check.
    Remove-Item -LiteralPath $DeliveryFile -Force -ErrorAction SilentlyContinue

    # RECORDED BEFORE THE RUN, NOT AFTER, and the difference is a duplicate
    # execution. If the station is killed mid-step - the machine reboots,
    # somebody closes the session - the id written after the wait was never
    # written, so on restart the same request is new again and a state-changing
    # step runs a second time. An id is used once, and "once" includes the
    # attempt. station.sh records it at the identical point.
    Add-SeenId $id

    $child = Start-Step -Step $step -Assignments $assignments
    if ($null -eq $child) {
        Publish-Status -State 'refused' -Id $id -Step $step -Extra 'reason:   the runner could not be started on this station'
        $LastId = $id
        [System.IO.File]::WriteAllText($StateFile, $id)
        if ($Once) { Stop-Station }
        Start-Sleep -Seconds $Interval; continue
    }
    $script:Running = $child

    # What `cancel:` said when this run started. A cancel that was ALREADY in
    # the request cannot have been meant for a run that had not begun, and
    # acting on it would reap the next request the moment it starts: seen in
    # testing as a step that finished cleanly and was still published as
    # cancelled, because the `cancel: yes` that stopped its predecessor was
    # still sitting there. ONLY A CHANGE IS AN INSTRUCTION.
    $cancelAtStart = Get-Field -Body $body -Name 'cancel'
    $cancelled = $false
    $lastProgress = [DateTime]::MinValue

    while (-not $child.HasExited) {
        Start-Sleep -Seconds $Interval

        if ($ProgressEvery -gt 0 -and
            ([DateTime]::UtcNow - $lastProgress).TotalSeconds -ge $ProgressEvery) {
            Publish-Progress -Id $id -Step $step -Started $started `
                             -LogPath (Find-StepLog -Step $step)
            $lastProgress = [DateTime]::UtcNow
        }

        # A mid-run read is OPTIONAL. Without it a cancel waits for the step to
        # finish, which is a real cost and a smaller one than a transport billed
        # per operation being polled every few seconds.
        if (-not $CanLive) { continue }
        $live = Receive-TpRequestLive
        if ($null -eq $live -or -not $live) { continue }

        $want = Get-Field -Body $live -Name 'cancel'
        $newId = Get-Field -Body $live -Name 'id'

        # `cancel: yes` stops whatever is running. `cancel: <id>` stops it only
        # if that is the id running, so a stale cancel cannot kill a later,
        # wanted run. An unchanged value is stale by definition: it was there
        # before this step started, so it was not asking for this one to stop.
        $doCancel = $false
        if ($want -cne $cancelAtStart) {
            if ($want -ceq 'yes' -or $want -ceq 'YES' -or $want -ceq 'true' -or $want -ceq $id) {
                $doCancel = $true
            } elseif (-not $want) {
                # Cleared: a later `yes` is a fresh instruction.
                $cancelAtStart = ''
            }
        }

        if ($doCancel) {
            Write-Say "CANCEL requested for '$step' ($id) - signalling $(Get-CapTreeReach -ProcessId $child.Id)"
            [void](Stop-CapTree -ProcessId $child.Id)
            $cancelled = $true
            break
        }

        # A NEW id while this one runs does NOT cancel: an in-flight step may be
        # halfway through changing something, and inferring "they want this
        # dead" from a queued request would be guessing. It waits its turn.
        if ($newId -and $newId -cne $id -and $newId -cne $LastId) {
            Write-Say "note: request $newId is queued behind the running step"
        }
    }

    $child.WaitForExit()
    $rc = if ($cancelled) { 130 } else { $child.ExitCode }
    $script:Running = $null

    # BOTH of these, and it is not belt-and-braces. $LastId is what the loop
    # compares against; the state file is only read at startup. Writing the file
    # alone left the variable at its startup value, so the same request matched
    # "new" on every poll and the station re-ran it every few seconds until it
    # was stopped.
    $LastId = $id
    [System.IO.File]::WriteAllText($StateFile, $id)

    # WHICH LOG THIS RUN PRODUCED. Asked of the runner rather than guessed.
    #
    # run.ps1 records the path it actually delivered, so that is the authority.
    # The newest-file fallback is for a run that never reached delivery - a
    # cancelled step, most often.
    $logFile = ''
    $delivered = ''
    if (Test-Path -LiteralPath $DeliveryFile -PathType Leaf) {
        try {
            $rec = [System.IO.File]::ReadAllText($DeliveryFile)
            $logFile = Get-Field -Body $rec -Name 'log'
            $delivered = Get-Field -Body $rec -Name 'delivered'
        } catch {
            $logFile = ''
        }
    }
    # RELATIVE TO THE PAYLOAD, because that is what the published status has
    # always carried and what the control side matches names against.
    # Publishing an absolute path would leak this station's directory layout
    # into a document somebody else reads.
    if ($logFile -and $logFile.StartsWith($RepoRoot)) {
        $logFile = ($logFile.Substring($RepoRoot.Length).TrimStart('\', '/')) -replace '\\', '/'
    }
    if (-not $logFile -or -not (Test-Path -LiteralPath (Join-Path $RepoRoot $logFile) -PathType Leaf)) {
        $found = Find-StepLog -Step $step
        $logFile = if ($found) { "ops-logs/$(Split-Path -Leaf $found)" } else { '' }
    }
    $logShown = if ($logFile) { $logFile } else { '<none>' }
    $logAbs = if ($logFile) { Join-Path $RepoRoot $logFile } else { '' }
    $finished = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

    if ($cancelled) {
        Write-Say "step '$step' CANCELLED$(if ($logFile) { "  (partial log: $logFile)" })"
        # The log goes with this publication: the step was killed, so run.ps1
        # never reached delivery, and this is the only thing that will carry the
        # partial evidence out.
        Publish-Status -State 'cancelled' -Id $id -Step $step -Extra (@(
                "started:  $started"
                "cancelled:$finished"
                "exit:     $rc"
                "log:      $logShown"
                'note:     partial - the step was signalled, so the log stops where it stopped'
            ) -join "`n") -AlsoFile $logAbs
    } else {
        Write-Say "step '$step' finished exit=$rc$(if ($logFile) { "  ($logFile)" })"
        # `idle` MEANS THE LOG ARRIVED. Only `yes` earns it, and everything else
        # is published as `undelivered` with the reason.
        #
        # The bash side had this inverted once - anything that was not literally
        # `no` became `idle` - and the hole was not small. An ABSENT record means
        # the runner exited before it ever reached delivery, and that was
        # reported as a clean run with a log nobody would ever receive.
        if ($delivered -ceq 'yes') {
            Publish-Status -State 'idle' -Id $id -Step $step -Extra (@(
                    "started:  $started"
                    "finished: $finished"
                    "exit:     $rc"
                    "log:      $logShown"
                ) -join "`n")
        } else {
            $why = switch -CaseSensitive ($delivered) {
                'no' { 'the transport would not take it' }
                'skipped' { 'delivery was skipped (PUSH=0), so the log is on the station only' }
                'unknown' { 'delivery fell back to a direct push and its result was not established' }
                '' { 'the runner exited before it reached delivery, so no log was sent' }
                default { "the runner reported delivery state '$delivered', which this loop does not know" }
            }
            Write-Say "NOT DELIVERED over '$(Get-TpName)': $why"
            Publish-Status -State 'undelivered' -Id $id -Step $step -Extra (@(
                    "started:  $started"
                    "finished: $finished"
                    "exit:     $rc"
                    "log:      $logShown"
                    "note:     $why"
                ) -join "`n")
        }
    }

    if ($Once) { Stop-Station }
    Start-Sleep -Seconds $Interval
}

} finally {
    # Reached on Ctrl-C and on any unhandled error. Stop-Station calls `exit`,
    # which unwinds through here again, so the work is guarded rather than
    # repeated: the lock is removed if it is still there and the step is
    # signalled if it is still running.
    #
    # NOT REACHED ON SIGTERM, and that is a real limit rather than an oversight.
    # station.sh traps INT and TERM; PowerShell 5.1 has no way to catch a
    # SIGTERM at all, and 7's PosixSignalRegistration does not exist on the
    # edition this station targets as its floor. So `kill` on a PowerShell
    # station leaves the lock file behind.
    #
    # WHAT COVERS IT is the stale-lock check at startup: the next station reads
    # the pid, finds it dead, says so and takes the lock. A killed station
    # therefore costs one line of log on the next start and nothing else, which
    # is why this is documented rather than worked around. What it must NEVER
    # become is a lock that outlives its process AND is trusted - the check that
    # prevents that is the one thing here that has to keep working.
    if ($HoldsLock -and (Test-Path -LiteralPath $LockFile -PathType Leaf)) {
        Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    }
    if ($script:Running -and -not $script:Running.HasExited) {
        [void](Stop-CapTree -ProcessId $script:Running.Id)
    }
}

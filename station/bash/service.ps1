# =============================================================================
#  service.ps1 - make the loop outlive the session, on a Windows control node
# =============================================================================
#     .\service.ps1 install                    # survive logout and reboot
#     .\service.ps1 install --branch task/foo  # ...on a task branch
#     .\service.ps1 install -- --once          # ...args after -- go to station.sh
#     .\service.ps1 status
#     .\service.ps1 logs
#     .\service.ps1 stop
#     .\service.ps1 uninstall
#
#  This is service.sh's counterpart. Same job, same division of labour: it
#  decides only HOW THE LOOP OUTLIVES THE SESSION, and it starts station.ps1 so
#  that the bash discovery and start.sh's preflight both still happen. It
#  reimplements neither.
#
#  IT DOES NOT LOOK FOR BASH. station.ps1 already does that, including the
#  registry lookup that is the only thing which finds bash.exe on a default Git
#  for Windows install. Registering the task against station.ps1 rather than
#  against a bash path keeps one copy of that logic.
#
#  WHY A SCHEDULED TASK rather than a service. A Windows service needs
#  installation rights and a service wrapper for a script; a scheduled task
#  needs neither, runs as the operator, and can be told to run whether that
#  operator is logged on or not, which is the whole requirement.
# =============================================================================

$ErrorActionPreference = 'Stop'

# Overridable for the same reason service.sh's unit name is: one transport repo
# per investigation is ordinary, a fixed name would let the second install
# silently replace the first, and CI must not unregister a task somebody is
# relying on.
$TaskName = if ($env:HELIOGRAPH_SERVICE_NAME) { $env:HELIOGRAPH_SERVICE_NAME } else { 'heliograph' }
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile  = Join-Path $RepoRoot '.station-service.log'

function Assert-Prereqs {
    if (-not (Test-Path (Join-Path $RepoRoot 'station.ps1'))) {
        throw "service.ps1: no station.ps1 beside this script. Run it from inside a transport repo."
    }
    if (-not (Test-Path (Join-Path $RepoRoot 'start.sh'))) {
        throw "service.ps1: no start.sh beside this script. Run it from inside a transport repo."
    }
}

# The credential is where an unattended loop actually fails, and a scheduled task
# inherits nothing from the shell that registered it. GIT_TOKEN typed before
# .\station.ps1 reaches the station; GIT_TOKEN typed before .\service.ps1 install
# does NOT reach the task. The loop then starts, polls happily and cannot push a
# single log, which is discovered hours later by somebody waiting on the far
# side.
#
# caplib owns the credential chain, so this only reports what a detached run
# would find: a file it can read, or nothing.
# NATIVE COMMANDS AND $ErrorActionPreference = 'Stop' DO NOT MIX. git writing to
# stderr becomes a TERMINATING NativeCommandError once its error stream is
# redirected, so `git remote get-url origin` against a repo with no remote threw
# a PowerShell stack trace naming service.ps1 line 55, instead of letting the
# check below report "there is no origin remote" and name the fix.
#
# Found by CI on a real Windows runner. It cannot happen on Linux, and no amount
# of reading the file would have shown it.
function Invoke-GitQuiet {
    param([string[]]$GitArgs)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $out = (& git @GitArgs 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { return $null }
        return $out
    } finally {
        $ErrorActionPreference = $old
    }
}

# --- the env file, checked by the ONE thing that owns those rules -------------
#
# station-env.sh is bash, and that is the point: the file is bash. systemd reads
# it with EnvironmentFile, and launchd, the setsid fallback and station.ps1 all
# SOURCE it, so the authority on what a shell will do with a line is a shell.
#
# THIS FILE USED TO REIMPLEMENT THOSE RULES IN POWERSHELL, and an adversarial
# read found six ways the two classified the same file differently: PowerShell
# regexes are case-insensitive by default, so `transport=relay` passed here and
# set nothing in bash; Get-Content silently eats a UTF-8 BOM that bash does not
# skip when sourcing; an empty file passed one and failed the other. A station
# that installs on Windows and is refused on Linux, from one file, is worse than
# either answer on its own.
#
# IT DOES NOT DISCOVER BASH ITSELF. That is station.ps1's job and this file has
# never duplicated it - it dot-sources lib/Find-GitBash.ps1, which station.ps1
# uses too, so there is one answer to "which bash" as well.
$StationEnv = Join-Path $RepoRoot '.station-env'

function Invoke-StationEnvCheck {
    param([string[]]$CheckArgs = @())
    $script = Join-Path $RepoRoot 'station-env.sh'
    if (-not (Test-Path $script)) { return $null }
    $finder = Join-Path (Join-Path $RepoRoot 'lib') 'Find-GitBash.ps1'
    if (-not (Test-Path $finder)) { return $null }
    . $finder
    $bash = $null
    try { $bash = Find-GitBash } catch { return $null }
    if (-not $bash) { return $null }

    # The path in the form bash understands, exactly as station.ps1 converts it.
    $unix = ($RepoRoot -replace '\\', '/') -replace '^([A-Za-z]):', '/$1'
    $argline = ($CheckArgs | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $out = (& $bash -lc "cd '$unix' && ./station-env.sh $argline" 2>&1 | Out-String)
        return [pscustomobject]@{ Output = $out.TrimEnd(); Code = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $old
    }
}

function Test-Credential {
    # CHECKED BEFORE THE TRANSPORT IS DECIDED, whenever the file exists at all.
    # station.ps1 sources it for a git station too, and reading the transport
    # out of a malformed file first is circular: `export TRANSPORT='relay'` is
    # exactly the bad line somebody writes, it parses as no transport, runs the
    # git checks, and reports a missing origin remote to somebody whose real
    # problem is one word.
    $transport = 'git'
    $check = Invoke-StationEnvCheck
    if ($null -eq $check) {
        if (Test-Path $StationEnv) {
            Write-Warning "there is a $StationEnv but no bash to check it with."
            Write-Warning "  station.ps1 needs Git for Windows anyway - install it, then run this again."
            return $false
        }
    } else {
        if ($check.Output) { Write-Host $check.Output }
        if ($check.Code -ne 0) { return $false }
        $t = Invoke-StationEnvCheck @('--transport')
        if ($t -and $t.Output) { $transport = $t.Output.Trim() }
    }
    # A non-git transport is settled entirely by station-env.sh: its credential
    # IS those variables, and it has just proved the transport initialises from
    # them. Everything below is git's credential chain.
    if ($transport -ne 'git') { return $true }

    $url = Invoke-GitQuiet @('-C', $RepoRoot, 'remote', 'get-url', 'origin')
    if (-not $url) {
        Write-Warning "there is no origin remote. Git is the transport, so there is nowhere to push a log."
        return $false
    }
    # Only an http(s) remote needs a token. ssh uses a key, and a local path
    # needs nothing at all.
    if ($url -notmatch '^https?://') { return $true }

    foreach ($p in @($env:GIT_TOKEN_FILE, (Join-Path $RepoRoot '.git-token'), (Join-Path $HOME '.git-token'))) {
        if ($p -and (Test-Path $p)) { return $true }
    }
    if ($env:GIT_TOKEN -or $env:GIT_AUTH_HEADER) {
        Write-Warning "the credential is in THIS shell's environment, which the scheduled task will not inherit."
        Write-Warning "  A detached task starts with a fresh environment, so the loop would run and never push."
        Write-Warning "  Write it to a file the task can read instead:"
        Write-Warning "      `$env:GIT_TOKEN | Out-File -NoNewline -Encoding ascii `"`$HOME\.git-token`""
        Write-Warning "  caplib reads ~/.git-token already, so nothing else has to change."
        return $false
    }
    Write-Warning "no credential found at all. The loop will start and be unable to push."
    Write-Warning "  See https://docs.heliograph.io/transports#the-credential, then run this again."
    return $false
}

# Everything except -Force is forwarded to station.ps1, which forwards it to
# start.sh. The first version hardcoded no arguments, so a service-managed loop
# could not be put on a task branch - and branch per task is how this skill
# works. Found by running a real investigation through the Linux side.
function Install-Service {
    param([switch]$Force, [string[]]$StartArgs = @())
    Assert-Prereqs
    if (-not (Test-Credential) -and -not $Force) {
        throw "Refusing to install a loop that cannot push. Fix the above, or pass -Force if you know better."
    }

    # Redirect through -Command rather than -File, because a task's output goes
    # nowhere by default and a loop you cannot read is not much better than one
    # that died. 6>&1 catches the information stream too; station.ps1 reports the
    # bash it picked with Write-Host.
    $tail = ''
    if ($StartArgs.Count) { $tail = ' ' + (($StartArgs | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ' ') }
    $inner = "& '$RepoRoot\station.ps1'$tail *>&1 | Out-File -FilePath '$LogFile' -Encoding utf8 -Append"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$inner`"" `
        -WorkingDirectory $RepoRoot

    # AtStartup so it comes back after a reboot without anyone logging in, which
    # is the part setsid+nohup cannot do on the Linux side either.
    $trigger = New-ScheduledTaskTrigger -AtStartup

    # S4U runs the task whether the operator is logged on or not and stores no
    # password. The trade-off is that it gets no network CREDENTIALS, which does
    # not matter here: git authenticates with a token from a file or an ssh key,
    # not with the Windows identity.
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType S4U -RunLevel Limited

    # ExecutionTimeLimit Zero means no limit. THE DEFAULT IS THREE DAYS, after
    # which Windows stops the task, and a loop that quietly stops after three
    # days is precisely the failure this file exists to prevent.
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description "heliograph station loop ($RepoRoot)" | Out-Null

    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3

    Write-Output ""
    Write-Output "installed: scheduled task '$TaskName'"
    if ($StartArgs.Count) { Write-Output "arguments: $($StartArgs -join ' ')" }
    Write-Output "mechanism: scheduled task, runs whether logged on or not, starts at boot"
    Write-Output "log      : $LogFile"
    Write-Output ""
    Write-Output "  .\service.ps1 status     what it is doing"
    Write-Output "  .\service.ps1 logs       follow the log"
    Get-Status
}

function Get-Status {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) {
        Write-Output "not installed. Run: .\service.ps1 install"
        return
    }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Output "task     : $TaskName"
    Write-Output "state    : $($t.State)"
    Write-Output "last run : $($info.LastRunTime)  result=$($info.LastTaskResult)"
    Write-Output "next run : $($info.NextRunTime)"
    Write-Output "log      : $LogFile"
    # LastTaskResult 267009 is "currently running", which reads like an error
    # code to anybody who has not looked it up.
    if ($info.LastTaskResult -eq 267009) {
        Write-Output "           (267009 means it is running now, not a failure)"
    }
}

function Show-Logs {
    if (-not (Test-Path $LogFile)) {
        throw "no log yet at $LogFile. Has it started? Run .\service.ps1 status"
    }
    Get-Content -Path $LogFile -Tail 50 -Wait
}

function Stop-Service_ {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { Write-Output "nothing was running"; return }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Output "stopped '$TaskName'"
}

function Uninstall-Service {
    Stop-Service_
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Output "removed the scheduled task '$TaskName'"
    Write-Output "the log is left at $LogFile"
}

switch ($args[0]) {
    'install'   {
        $rest = @($args | Select-Object -Skip 1 | Where-Object { $_ -ne '-Force' })
        Install-Service -Force:($args -contains '-Force') -StartArgs $rest
    }
    'status'    { Get-Status }
    'logs'      { Show-Logs }
    'stop'      { Stop-Service_ }
    'uninstall' { Uninstall-Service }
    default {
        Write-Output "service.ps1 - make the loop outlive the session"
        Write-Output ""
        Write-Output "  .\service.ps1 install     survive logout and reboot, and start now"
        Write-Output "  .\service.ps1 status"
        Write-Output "  .\service.ps1 logs"
        Write-Output "  .\service.ps1 stop"
        Write-Output "  .\service.ps1 uninstall"
        exit 2
    }
}

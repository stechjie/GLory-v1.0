# Runner that makes a headless check's *engine* errors count.
#
# Why this exists on top of tools/CheckHarness.gd: the harness already owns exit
# codes, treats an empty check set as failure, and keeps an expiring allowlist.
# What it cannot see is anything the engine prints on its own. A GDScript parse
# error, a missing dependency, a resource that would not load -- those never reach
# an assertion, so a scene can print them, then print
# `CHECK_RESULT ... status=PASS`, and exit 0. That is the "red log, green result"
# the V2 review recorded against battle_presentation_director_check.
#
# So the rule here is: the check passes only if ALL of these hold.
#   1. the process exited 0
#   2. it exited before -TimeoutSec
#   3. no engine-level error line appeared on stdout or stderr
#
# PowerShell 5.1 is the target (this machine has no pwsh), which means: no `&&`,
# no ternary, no `??`, and every read/write states its encoding -- 5.1 defaults to
# the ANSI codepage and the repo has ~252 Chinese asset paths that it would mangle.
#
# THIS FILE MUST KEEP ITS UTF-8 BOM. The self-test fixtures below quote real
# Chinese check output on purpose (proving a check's own FAIL text is not misread
# as an engine error). Without the BOM, 5.1 decodes the file as ANSI and the
# script dies with a parse error rather than merely printing garbled text.
#
# Usage:
#   powershell -File tools/run_check.ps1 -Name vfx_warmup
#   powershell -File tools/run_check.ps1 -Name vfx_warmup,export_presets
#   powershell -File tools/run_check.ps1 -All
#   powershell -File tools/run_check.ps1 -SelfTest
#
# Exit codes: 0 all passed; 1 at least one failed; 2 bad invocation.

[CmdletBinding()]
param(
    [string[]]$Name = @(),
    [switch]$All,
    [switch]$SelfTest,
    [string]$GodotConsole = "",
    [string]$ProjectRoot = "",
    [string]$ReportDir = "",
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Engine-level failures that a scene can print while still reporting PASS.
# Matched against stdout and stderr, line by line.
$script:EngineErrorPatterns = @(
    'SCRIPT ERROR',
    'Parse Error',
    'Failed to load script',
    'Failed loading resource',
    'Failed to load resource',
    'Attempt to open script .* resulted in error',
    'Invalid call\. Nonexistent function'
)

# Checks that talk to a live dedicated server. Skipped by -All because a red here
# would mean "no server running", not "the code is broken" -- and a gate that goes
# red for an unrelated reason is a gate people learn to ignore.
# Run them through tools/multiplayer_regression.sh, which starts a server first.
$script:NetworkChecks = @(
    'channel_check',
    'handshake_check',
    'persist_check',
    'reconnect_check',
    'dedicated_server_check',
    'adversarial_client'
)

function Resolve-Godot {
    param([string]$Requested)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        if (Test-Path -LiteralPath $Requested -PathType Leaf) { return [IO.Path]::GetFullPath($Requested) }
        $requestedCommand = Get-Command $Requested -ErrorAction SilentlyContinue
        if ($null -ne $requestedCommand) { return $requestedCommand.Source }
        throw "Godot executable not found: $Requested"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GLORY_GODOT)) {
        if (Test-Path -LiteralPath $env:GLORY_GODOT -PathType Leaf) {
            return [IO.Path]::GetFullPath($env:GLORY_GODOT)
        }
    }
    foreach ($candidate in @('godot4', 'godot')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) { return $command.Source }
    }
    throw "Godot executable not found; pass -GodotConsole <path> or set GLORY_GODOT. Use the *_console.exe build, or headless output never reaches stdout."
}

# Lines the checks themselves print are bracketed by convention ("[vfx_warmup] ...",
# "[PERFLOG] ...", "[WARMUP] ..."). Excluding them keeps a check's own failure text
# from being re-counted as an engine error when it happens to quote one.
function Get-EngineErrorLines {
    param([string]$Text)
    # Returns a plain array and lets PowerShell unroll it; every call site wraps
    # the result in @() so that "no hits" is a 0-length array rather than $null.
    # (Do not "fix" this with `return ,$array` -- combined with the @() at the call
    # site that yields a 1-element array holding an empty array, which reads as one
    # blank error and fails every check.)
    $hits = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Text)) { return $hits.ToArray() }
    foreach ($rawLine in ($Text -split "`r?`n")) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.TrimStart().StartsWith('[')) { continue }
        foreach ($pattern in $script:EngineErrorPatterns) {
            if ($line -match $pattern) {
                $hits.Add($line.Trim()) | Out-Null
                break
            }
        }
    }
    return $hits.ToArray()
}

function Get-CheckResultLine {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    foreach ($rawLine in ($Text -split "`r?`n")) {
        if ($rawLine -match '^\s*CHECK_RESULT\s') { return $rawLine.Trim() }
    }
    return ""
}

function Read-TextUtf8 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Write-JsonUtf8 {
    param([string]$Path, [object]$Value)
    $json = $Value | ConvertTo-Json -Depth 8
    $noBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $json, $noBom)
}

function Invoke-OneCheck {
    param([string]$CheckName, [string]$Godot, [string]$Root, [string]$OutDir)

    # Accept both the scene name (vfx_warmup_check) and the name the check reports
    # itself as in CHECK_RESULT (vfx_warmup) -- the latter is what people read off
    # a log and then try to re-run.
    $sceneName = $CheckName
    $scenePath = Join-Path $Root ("tools/" + $sceneName + ".tscn")
    if (-not (Test-Path -LiteralPath $scenePath -PathType Leaf)) {
        $sceneName = $CheckName + "_check"
        $scenePath = Join-Path $Root ("tools/" + $sceneName + ".tscn")
    }
    if (-not (Test-Path -LiteralPath $scenePath -PathType Leaf)) {
        return [pscustomobject]@{
            name = $CheckName; passed = $false; verdict = "missing_scene"
            exit_code = -1; duration_sec = 0.0; check_result = ""
            engine_errors = @("neither tools/$CheckName.tscn nor tools/${CheckName}_check.tscn exists")
            log = ""
        }
    }

    $stdoutPath = Join-Path $OutDir ($CheckName + ".stdout.log")
    $stderrPath = Join-Path $OutDir ($CheckName + ".stderr.log")

    # One string, quoted by hand: 5.1's -ArgumentList array joining does not
    # reliably re-quote elements containing spaces, and this project root has one.
    $arguments = '--headless --path "' + $Root + '" res://tools/' + $sceneName + '.tscn'

    # System.Diagnostics.Process rather than Start-Process -PassThru: on 5.1 the
    # latter hands back an object whose .ExitCode does not survive the process
    # ending, so a check that exited 0 reads back as nonzero. Doing it directly
    # also lets us state the stream encoding, which matters because check output
    # is full of Chinese.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Godot
    $psi.Arguments = $arguments
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    $started = Get-Date
    $process.Start() | Out-Null
    # Drain both pipes concurrently. Reading one to the end before waiting would
    # deadlock as soon as a chatty check fills the other pipe's 64 KB buffer.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $exited = $process.WaitForExit($TimeoutSec * 1000)
    $timedOut = $false
    if (-not $exited) {
        $timedOut = $true
        try { $process.Kill() } catch { }
        try { $process.WaitForExit(5000) | Out-Null } catch { }
    }
    $duration = [Math]::Round(((Get-Date) - $started).TotalSeconds, 1)

    $stdoutText = ""
    $stderrText = ""
    try { $stdoutText = $stdoutTask.Result } catch { }
    try { $stderrText = $stderrTask.Result } catch { }

    $exitCode = -1
    if (-not $timedOut) { $exitCode = $process.ExitCode }
    $process.Dispose()

    $noBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($stdoutPath, $stdoutText, $noBom)
    [IO.File]::WriteAllText($stderrPath, $stderrText, $noBom)

    $combined = $stdoutText + "`n" + $stderrText
    $engineErrors = @(Get-EngineErrorLines $combined)
    $checkResult = Get-CheckResultLine $combined

    $verdict = "pass"
    $passed = $true
    if ($timedOut) {
        $verdict = "timeout"; $passed = $false
    } elseif ($engineErrors.Count -gt 0) {
        # Deliberately checked before the exit code: this is the whole point.
        $verdict = "engine_error"; $passed = $false
    } elseif ($exitCode -ne 0) {
        $verdict = "nonzero_exit"; $passed = $false
    }

    return [pscustomobject]@{
        name = $CheckName
        passed = $passed
        verdict = $verdict
        exit_code = $exitCode
        duration_sec = $duration
        check_result = $checkResult
        engine_errors = $engineErrors
        log = $stdoutPath
    }
}

# Proves the detector actually fires, without committing a broken script to the
# repo just so something can be red. Fixtures are real Godot output shapes.
function Invoke-SelfTest {
    $mustFlag = @(
        'SCRIPT ERROR: Parse Error: Identifier "BoardReadabilityStyle" not declared in the current scope.',
        'ERROR: Failed to load script "res://scenes/battle/BattleResult.gd" with error "Parse error".',
        'ERROR: Failed loading resource: res://assets/models/missing.tscn. Make sure resources have been imported.',
        '  at: GDScript::reload (modules/gdscript/gdscript.cpp:2996) - Invalid call. Nonexistent function ''foo'' in base ''Node''.'
    )
    $mustIgnore = @(
        'CHECK_RESULT name=vfx_warmup status=PASS checked=93 failures=0 allowed=0 stale=0',
        '[export_presets]   FAIL [template_drifted] res://export_presets.template.cfg 与本机 export_presets.cfg 已漂移',
        '[asset_delivery] 校验进度 500/2632',
        '[client_log]   note: 扫描到 3 处 Failed loading resource 字样的日志文案',
        'ASSET_DELIVERY_RESULT status=PASS entries=2632 missing=0'
    )

    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($line in $mustFlag) {
        if (@(Get-EngineErrorLines $line).Count -eq 0) {
            $failures.Add("should have flagged: $line") | Out-Null
        }
    }
    foreach ($line in $mustIgnore) {
        if (@(Get-EngineErrorLines $line).Count -gt 0) {
            $failures.Add("should have ignored: $line") | Out-Null
        }
    }

    # A PASS line sitting next to an engine error is the exact case this runner
    # exists for: the combined output must still be judged a failure.
    $mixed = @(
        'SCRIPT ERROR: Parse Error: Identifier "Foo" not declared.',
        'CHECK_RESULT name=demo status=PASS checked=93 failures=0 allowed=0 stale=0'
    ) -join "`n"
    if (@(Get-EngineErrorLines $mixed).Count -eq 0) {
        $failures.Add("should have flagged an engine error sitting next to a PASS line") | Out-Null
    }

    foreach ($failure in $failures) { Write-Host "SELFTEST FAIL  $failure" }
    if ($failures.Count -gt 0) {
        Write-Host ""
        Write-Host ("RUN_CHECK_SELFTEST status=FAIL failures=" + $failures.Count)
        return 1
    }
    Write-Host ("SELFTEST ok: " + $mustFlag.Count + " error shapes flagged, " + $mustIgnore.Count + " benign lines ignored, mixed PASS+error flagged")
    Write-Host "RUN_CHECK_SELFTEST status=PASS failures=0"
    return 0
}

# --- main ---------------------------------------------------------------------

if ($SelfTest) { exit (Invoke-SelfTest) }

# Resolved here rather than as a param default: under `powershell -File` on 5.1,
# $PSScriptRoot is not reliably populated while param defaults are being bound.
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDir)) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $ProjectRoot = Split-Path -Parent $scriptDir
}
$root = [IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath (Join-Path $root "project.godot") -PathType Leaf)) {
    throw "Not a Godot project root: $root"
}

$targets = @()
if ($All) {
    $skipped = @()
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $root "tools") -Filter "*_check.tscn" | Sort-Object Name)) {
        $checkName = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($script:NetworkChecks -contains $checkName) { $skipped += $checkName; continue }
        $targets += $checkName
    }
    if ($skipped.Count -gt 0) {
        Write-Host ("[run_check] skipping " + $skipped.Count + " server-dependent checks (run tools/multiplayer_regression.sh for these): " + ($skipped -join ", "))
    }
} else {
    # Split on commas ourselves: invoked as `powershell -File`, every argument
    # arrives as a string, so -Name a,b binds as the single element "a,b".
    $targets = @($Name | ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

if ($targets.Count -eq 0) {
    Write-Host "Nothing to run. Pass -Name <check>[,<check>...], -All, or -SelfTest."
    exit 2
}

$godot = Resolve-Godot $GodotConsole
if ([string]::IsNullOrWhiteSpace($ReportDir)) { $ReportDir = Join-Path $root "reports/checks" }
if (-not (Test-Path -LiteralPath $ReportDir)) {
    New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
}

Write-Host ("[run_check] godot=" + $godot)
Write-Host ("[run_check] running " + $targets.Count + " check(s), timeout " + $TimeoutSec + "s each")
Write-Host ""

$results = @()
foreach ($checkName in $targets) {
    Write-Host ("[run_check] ---- " + $checkName) -NoNewline
    $result = Invoke-OneCheck -CheckName $checkName -Godot $godot -Root $root -OutDir $ReportDir
    $results += $result
    # Persist the verdict per check, not just in summary.json. summary.json describes
    # one invocation, so anything reading it later sees only the checks that happened
    # to be in the last run. And the verdict must be the one this runner computed:
    # re-deriving it from the log's CHECK_RESULT line would read `reconnect_service`
    # and `room_service` as PASS, because their failure is an engine error the harness
    # never saw -- which is the whole thing this runner exists to catch.
    $perCheck = [pscustomobject]@{
        observed_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        result = $result
    }
    Write-JsonUtf8 (Join-Path $ReportDir ($checkName + ".result.json")) $perCheck
    $label = "PASS"
    if (-not $result.passed) { $label = "FAIL (" + $result.verdict + ")" }
    Write-Host ("  " + $label + "  " + $result.duration_sec + "s")
    if (-not [string]::IsNullOrWhiteSpace($result.check_result)) {
        Write-Host ("             " + $result.check_result)
    }
    foreach ($errorLine in $result.engine_errors) {
        Write-Host ("             ENGINE " + $errorLine)
    }
    if (-not $result.passed) {
        Write-Host ("             log: " + $result.log)
    }
}

$failed = @($results | Where-Object { -not $_.passed })
$summary = [pscustomobject]@{
    generated = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    godot = $godot
    project_root = $root
    timeout_sec = $TimeoutSec
    total = $results.Count
    failed = $failed.Count
    results = $results
}
Write-JsonUtf8 (Join-Path $ReportDir "summary.json") $summary

Write-Host ""
Write-Host ("RUN_CHECK_SUMMARY total=" + $results.Count + " failed=" + $failed.Count + " report=" + (Join-Path $ReportDir "summary.json"))
if ($failed.Count -gt 0) {
    Write-Host ("[run_check] failed: " + (($failed | ForEach-Object { $_.name }) -join ", "))
    exit 1
}
exit 0

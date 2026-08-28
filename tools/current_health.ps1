# Aggregate what the gates actually say right now into one file.
#
# Why: README, the V2 list and the V3 list each froze a snapshot of project state
# on the day they were written, and every one of them has since drifted. V2 still
# reports 759 missing assets where the delivery check now reports 0; its export
# drift figure of 273 was down to a single field. A reader cannot tell which
# sentences are current, so all of them lose authority.
#
# So this script does NOT re-run anything and does NOT judge. It reads artefacts
# other tools produced, records when each was produced, and writes one JSON plus a
# generated Markdown block. If a check is not in the last run_check.ps1 summary, it
# is reported as "not in the last run" -- never as passing.
#
# Usage:
#   powershell -File tools/current_health.ps1
#   powershell -File tools/current_health.ps1 -NoReadme
#
# This file is intentionally ASCII-only. Non-ASCII text comes from the data files
# it reads (UTF-8, read explicitly), so the script itself cannot be broken by
# PowerShell 5.1 decoding a BOM-less source as ANSI.

[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [switch]$NoReadme
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$BeginMarker = "<!-- CURRENT_HEALTH:BEGIN -->"
$EndMarker = "<!-- CURRENT_HEALTH:END -->"

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        return $text | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-FileStampUtc {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    return (Get-Item -LiteralPath $Path).LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Invoke-Git {
    param([string]$Root, [string[]]$GitArgs)
    try {
        $out = & git -C $Root @GitArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return "" }
        return ($out | Out-String).Trim()
    } catch {
        return ""
    }
}

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

# --- git ----------------------------------------------------------------------
$commitFull = Invoke-Git $root @("rev-parse", "HEAD")
$commitShort = Invoke-Git $root @("rev-parse", "--short", "HEAD")
$branch = Invoke-Git $root @("rev-parse", "--abbrev-ref", "HEAD")
$porcelain = Invoke-Git $root @("status", "--porcelain")
$dirtyTracked = 0
$untracked = 0
if (-not [string]::IsNullOrWhiteSpace($porcelain)) {
    foreach ($line in ($porcelain -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith("??")) { $untracked++ } else { $dirtyTracked++ }
    }
}

# --- assets -------------------------------------------------------------------
$manifestPath = Join-Path $root "assets.manifest.json"
$manifest = Read-JsonFile $manifestPath
$assetHash = "unknown"
$assetCount = 0
if ($null -ne $manifest) {
    $assetHash = [string]$manifest.inventory_sha256
    $assetCount = [int]$manifest.file_count
}

# --- checks -------------------------------------------------------------------
# summary.json only describes the LAST run_check.ps1 invocation, so after someone
# re-runs two checks the README would claim the project has two gates. The per-check
# stdout logs persist across runs, so they are folded in as well -- each carrying its
# own timestamp and marked from_last_run=false. A stale-but-dated result is useful;
# a result presented as current when it is a week old is not.
$summaryPath = Join-Path $root "reports/checks/summary.json"
$summary = Read-JsonFile $summaryPath
$checks = @()
$checksGeneratedUtc = ""
$seenNames = @{}

function New-CheckRecord {
    param([string]$Name, [bool]$Passed, [string]$Verdict, [string]$ResultLine,
          [int]$EngineErrors, [bool]$FromLastRun, [string]$ObservedUtc)
    $checked = -1
    $failures = -1
    if ($ResultLine -match 'checked=(\d+)\s+failures=(\d+)') {
        $checked = [int]$Matches[1]
        $failures = [int]$Matches[2]
    }
    return [pscustomobject]@{
        name = $Name
        passed = $Passed
        verdict = $Verdict
        checked = $checked
        failures = $failures
        engine_errors = $EngineErrors
        from_last_run = $FromLastRun
        observed_utc = $ObservedUtc
    }
}

# run_check accepts both "vfx_warmup" and "vfx_warmup_check", so the same gate can
# leave results under two names. Everything is keyed on the bare form, or a project
# that has been checked both ways reports more gates than it has.
function Get-BareCheckName {
    param([string]$Name)
    return ($Name -replace '_check$', '')
}

if ($null -ne $summary) {
    $checksGeneratedUtc = [string]$summary.generated
    foreach ($result in @($summary.results)) {
        $name = [string]$result.name
        $seenNames[(Get-BareCheckName $name)] = $true
        $checks += New-CheckRecord -Name $name -Passed ([bool]$result.passed) `
            -Verdict ([string]$result.verdict) -ResultLine ([string]$result.check_result) `
            -EngineErrors (@($result.engine_errors).Count) -FromLastRun $true `
            -ObservedUtc $checksGeneratedUtc
    }
}

# Per-check verdicts written by run_check.ps1. Read the verdict it recorded rather
# than re-deriving one from the log: a check can print CHECK_RESULT status=PASS and
# still have failed on an engine-level error the harness never saw (reconnect_service
# and room_service both do exactly that today). Re-parsing the log would quietly
# report those two as passing.
$checksDir = Join-Path $root "reports/checks"
if (Test-Path -LiteralPath $checksDir) {
    foreach ($file in @(Get-ChildItem -LiteralPath $checksDir -Filter "*.result.json")) {
        $name = $file.Name -replace '\.result\.json$', ''
        $bare = Get-BareCheckName $name
        if ($seenNames.ContainsKey($bare)) { continue }
        $record = Read-JsonFile $file.FullName
        if ($null -eq $record) { continue }
        $seenNames[$bare] = $true
        $checks += New-CheckRecord -Name $name -Passed ([bool]$record.result.passed) `
            -Verdict ([string]$record.result.verdict) `
            -ResultLine ([string]$record.result.check_result) `
            -EngineErrors (@($record.result.engine_errors).Count) -FromLastRun $false `
            -ObservedUtc ([string]$record.observed_utc)
    }
}

# --- model material integrity -------------------------------------------------
$integrityPath = Join-Path $root "reports/model_material_integrity.json"
$integrity = Read-JsonFile $integrityPath
$integrityBlock = $null
if ($null -ne $integrity) {
    $failing = @()
    foreach ($model in @($integrity.models)) {
        if ([string]$model.status -ne "PASS") { $failing += [string]$model.scene_path }
    }
    $integrityBlock = [pscustomobject]@{
        generated_utc = [string]$integrity.generated_utc
        models = [int]$integrity.summary.models
        surfaces = [int]$integrity.summary.surfaces
        white_material_suspect = [int]$integrity.summary.white_material_suspect
        missing_texture = [int]$integrity.summary.missing_texture
        scene_load_failed = [int]$integrity.summary.scene_load_failed
        failing_models = $failing
    }
}

# --- apk content scan ---------------------------------------------------------
$scanPath = Join-Path $root "reports/apk_content_scan.json"
$scan = Read-JsonFile $scanPath
$scanBlock = $null
if ($null -ne $scan) {
    $scanBlock = [pscustomobject]@{
        apk = [string]$scan.apk
        entries = [int]$scan.entries
        passed = [bool]$scan.passed
        violations = @($scan.violations).Count
        generated_utc = (Get-FileStampUtc $scanPath)
    }
}

# --- latest android smoke -----------------------------------------------------
# Lives outside the repo (../build/android) so evidence never lands in the APK.
$smokeBlock = $null
$smokeRoot = [IO.Path]::GetFullPath((Join-Path $root "../build/android"))
if (Test-Path -LiteralPath $smokeRoot) {
    $smokeDirs = @(Get-ChildItem -LiteralPath $smokeRoot -Directory -Filter "smoke_*" |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($smokeDirs.Count -gt 0) {
        $smokeJson = Read-JsonFile (Join-Path $smokeDirs[0].FullName "smoke.json")
        if ($null -ne $smokeJson) {
            $deviceModel = ""
            $apkSha = ""
            $pkg = ""
            if ($smokeJson.PSObject.Properties.Name -contains "device") { $deviceModel = [string]$smokeJson.device.model }
            if ($smokeJson.PSObject.Properties.Name -contains "apk") {
                $apkSha = [string]$smokeJson.apk.sha256
                $pkg = [string]$smokeJson.apk.package
            }
            $smokeBlock = [pscustomobject]@{
                run_dir = $smokeDirs[0].Name
                run_utc = $smokeDirs[0].LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
                passed = [bool]$smokeJson.passed
                device_model = $deviceModel
                package = $pkg
                apk_sha256 = $apkSha
            }
        }
    }
}

# --- known blockers -----------------------------------------------------------
$blockersPath = Join-Path $root "data/qa/known_blockers.json"
$blockersDoc = Read-JsonFile $blockersPath
$blockers = @()
if ($null -ne $blockersDoc) {
    foreach ($item in @($blockersDoc.blockers)) {
        $blockers += [pscustomobject]@{
            id = [string]$item.id
            title = [string]$item.title
            state = [string]$item.state
            owner = [string]$item.owner
            area = [string]$item.area
        }
    }
}

# --- assemble -----------------------------------------------------------------
$failedChecks = @($checks | Where-Object { -not $_.passed })
$health = [pscustomobject]@{
    generated_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    generated_by = "tools/current_health.ps1"
    note = "Reads existing artefacts only. Nothing here is re-run or re-judged; each block carries the timestamp of the artefact it came from."
    git = [pscustomobject]@{
        branch = $branch
        commit = $commitFull
        commit_short = $commitShort
        dirty_tracked_files = $dirtyTracked
        untracked_paths = $untracked
    }
    assets = [pscustomobject]@{
        inventory_sha256 = $assetHash
        file_count = $assetCount
        manifest_utc = (Get-FileStampUtc $manifestPath)
    }
    checks = [pscustomobject]@{
        source = "reports/checks/summary.json"
        generated_utc = $checksGeneratedUtc
        covered = $checks.Count
        failed = $failedChecks.Count
        caveat = "from_last_run=true came from the run named in generated_utc; false means the result was read from that check's persisted log and carries its own observed_utc. A check that has never been run appears nowhere -- absence is unknown, not passing."
        results = $checks
    }
    model_material_integrity = $integrityBlock
    apk_content_scan = $scanBlock
    android_smoke = $smokeBlock
    known_blockers = $blockers
}

$reportDir = Join-Path $root "reports"
if (-not (Test-Path -LiteralPath $reportDir)) {
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
}
$outPath = Join-Path $reportDir "current_health.json"
$noBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($outPath, ($health | ConvertTo-Json -Depth 8), $noBom)

# --- markdown block -----------------------------------------------------------
$md = New-Object System.Collections.Generic.List[string]
$md.Add($BeginMarker)
$md.Add("")
$md.Add("<!-- Generated by tools/current_health.ps1. Do not edit by hand. -->")
$md.Add("")
$md.Add("### Current health (generated " + $health.generated_utc + ")")
$md.Add("")
$md.Add("| Item | Value |")
$md.Add("| --- | --- |")
$md.Add("| Commit | ``" + $commitShort + "`` on ``" + $branch + "`` (" + $dirtyTracked + " dirty tracked, " + $untracked + " untracked) |")
$md.Add("| Asset inventory | ``" + $assetHash.Substring(0, [Math]::Min(16, $assetHash.Length)) + "`` / " + $assetCount + " files |")
if ($checks.Count -gt 0) {
    $fromLastRun = @($checks | Where-Object { $_.from_last_run }).Count
    $md.Add("| Gates | " + $checks.Count + " known, " + $failedChecks.Count + " failing (" + $fromLastRun + " from the run at " + $checksGeneratedUtc + ", rest from earlier runs) |")
} else {
    $md.Add("| Gates | no run_check.ps1 results found |")
}
if ($null -ne $integrityBlock) {
    $md.Add("| Model material integrity | " + $integrityBlock.models + " models, " + $integrityBlock.white_material_suspect + " white-material suspects, " + @($integrityBlock.failing_models).Count + " failing |")
}
if ($null -ne $scanBlock) {
    $scanWord = "clean"
    if (-not $scanBlock.passed) { $scanWord = "VIOLATIONS" }
    $md.Add("| APK content scan | " + $scanBlock.apk + ": " + $scanBlock.entries + " entries, " + $scanWord + " |")
}
if ($null -ne $smokeBlock) {
    $smokeWord = "passed"
    if (-not $smokeBlock.passed) { $smokeWord = "FAILED" }
    $md.Add("| Last device run | " + $smokeBlock.run_utc + " on " + $smokeBlock.device_model + " (" + $smokeWord + ") |")
} else {
    $md.Add("| Last device run | none recorded |")
}
$md.Add("")

if ($failedChecks.Count -gt 0) {
    $md.Add("Failing gates:")
    $md.Add("")
    foreach ($check in $failedChecks) {
        $detail = $check.verdict
        if ($check.failures -ge 0) { $detail = $detail + ", " + $check.failures + " failures of " + $check.checked + " checked" }
        if (-not $check.from_last_run) { $detail = $detail + " (observed " + $check.observed_utc + ")" }
        $md.Add("- ``" + $check.name + "`` - " + $detail)
    }
    $md.Add("")
}

if ($blockers.Count -gt 0) {
    $md.Add("Known blockers (source: ``data/qa/known_blockers.json``):")
    $md.Add("")
    foreach ($blocker in $blockers) {
        $md.Add("- **" + $blocker.state + "** (" + $blocker.owner + ", " + $blocker.area + ") - " + $blocker.title)
    }
    $md.Add("")
}

$md.Add("Full machine-readable detail: ``reports/current_health.json``.")
$md.Add("")
$md.Add($EndMarker)
$blockText = ($md -join "`n")

$readmePath = Join-Path $root "README.md"
$readmeState = "skipped"
if (-not $NoReadme) {
    if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
        $readmeState = "readme_missing"
    } else {
        $readme = [IO.File]::ReadAllText($readmePath, [Text.Encoding]::UTF8)
        $beginAt = $readme.IndexOf($BeginMarker)
        $endAt = $readme.IndexOf($EndMarker)
        if ($beginAt -lt 0 -or $endAt -lt $beginAt) {
            # Refuse to guess where the block belongs. Mangling a 975-line document
            # to save one manual edit is a bad trade.
            $readmeState = "markers_missing"
            Write-Host "[current_health] README has no $BeginMarker / $EndMarker pair; not touching it."
            Write-Host "[current_health] Add the two markers where the block should live, then re-run."
        } else {
            $tail = $readme.Substring($endAt + $EndMarker.Length)
            $updated = $readme.Substring(0, $beginAt) + $blockText + $tail
            [IO.File]::WriteAllText($readmePath, $updated, $noBom)
            $readmeState = "updated"
        }
    }
}

Write-Host ("[current_health] git " + $commitShort + " dirty=" + $dirtyTracked + " untracked=" + $untracked)
Write-Host ("[current_health] gates covered=" + $checks.Count + " failed=" + $failedChecks.Count)
Write-Host ("[current_health] blockers=" + $blockers.Count + " readme=" + $readmeState)
Write-Host ("CURRENT_HEALTH_RESULT report=" + $outPath + " readme=" + $readmeState)
exit 0

# Explicit, opt-in refresh of the trusted asset baselines.
#
# Why this exists as a separate entry point: asset_manifest_check used to rewrite
# assets.manifest.json and docs/ASSET_MANIFEST.md on every run, and
# asset_delivery_check validates against the first of those. Alphabetically
# delivery runs before manifest, so any asset change made the FIRST full suite
# red and the SECOND green. A self-healing false red trains people to "just run
# it again", which is worse in the long run than a false green -- a red at least
# gets looked at once.
#
# So the check is read-only by default and this script is the only sanctioned way
# to move the baseline. It prints what changed and shows the Git diff. It does NOT
# commit -- a baseline update is a decision, not a side effect.
#
# The check keeps its own guard: if the tree has unallowed missing assets or
# dependency failures it refuses to overwrite even here, and prints
# manifest_untrusted=true.
#
# PowerShell 5.1 target (no pwsh on this machine): no &&, no ternary, no ??.
# THIS FILE MUST KEEP ITS UTF-8 BOM -- 5.1 decodes a BOM-less script as ANSI and
# dies with a parse error on the non-ASCII text below.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/update_asset_manifest.ps1

[CmdletBinding()]
param(
    [string]$GodotConsole = "",
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

if ([string]::IsNullOrWhiteSpace($GodotConsole)) {
    $GodotConsole = $env:GLORY_GODOT
}
if ([string]::IsNullOrWhiteSpace($GodotConsole)) {
    $GodotConsole = "C:\Users\Leno\Desktop\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe"
}
if (-not (Test-Path -LiteralPath $GodotConsole -PathType Leaf)) {
    throw "Godot console build not found: $GodotConsole (pass -GodotConsole or set GLORY_GODOT)"
}

$targets = @("assets.manifest.json", "docs/ASSET_MANIFEST.md")

function Get-Sha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "<absent>" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$before = @{}
foreach ($rel in $targets) {
    $before[$rel] = Get-Sha256 (Join-Path $ProjectRoot $rel)
}

Write-Host "[update_asset_manifest] baselines before:"
foreach ($rel in $targets) {
    Write-Host ("[update_asset_manifest]   " + $rel + "  " + $before[$rel].Substring(0, 16))
}
Write-Host ""

# User args go after "--"; the check reads them via OS.get_cmdline_user_args().
$arguments = '--headless --path "' + $ProjectRoot + '" res://tools/asset_manifest_check.tscn -- --update-manifest'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $GodotConsole
$psi.Arguments = $arguments
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [Text.Encoding]::UTF8

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
[void]$process.Start()
# Read both pipes asynchronously: a full buffer on either one deadlocks the child.
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$process.WaitForExit()
$stdout = $stdoutTask.Result
$stderr = $stderrTask.Result
$exitCode = $process.ExitCode

foreach ($line in ($stdout -split "`r?`n")) {
    if ($line -match '^\[asset_manifest\]' -or $line -match '^CHECK_RESULT') {
        Write-Host $line
    }
}
if (-not [string]::IsNullOrWhiteSpace($stderr)) {
    Write-Host "[update_asset_manifest] stderr:"
    Write-Host $stderr
}

Write-Host ""
Write-Host "[update_asset_manifest] baselines after:"
$changed = $false
foreach ($rel in $targets) {
    $after = Get-Sha256 (Join-Path $ProjectRoot $rel)
    $mark = "unchanged"
    if ($after -ne $before[$rel]) { $mark = "UPDATED"; $changed = $true }
    Write-Host ("[update_asset_manifest]   " + $rel + "  " + $after.Substring(0, 16) + "  " + $mark)
}

Write-Host ""
if ($changed) {
    Write-Host "[update_asset_manifest] git diff --stat (NOT committed -- review, then commit yourself):"
    Push-Location -LiteralPath $ProjectRoot
    try {
        & git diff --stat -- assets.manifest.json docs/ASSET_MANIFEST.md
    } finally {
        Pop-Location
    }
} else {
    Write-Host "[update_asset_manifest] nothing changed. Either the tree already matches the baseline,"
    Write-Host "[update_asset_manifest] or the check refused to overwrite (look for manifest_untrusted=true above)."
}

exit $exitCode

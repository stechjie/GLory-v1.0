# Builds the Windows voice bridge (GDExtension) into addons/glory_voice/bin/windows/.
# Spec: the LiveKit voice doc under docs/, section 5.2 (approach "A": the SDK's platform audio).
#
# Needs, all outside the repo:
#   - Visual Studio Build Tools with "Desktop development with C++" (MSVC; SCons finds it itself)
#   - godot-cpp 10.0.0-stable            (-GodotCpp)
#   - LiveKit C++ SDK 1.11.0 for Windows  (-LiveKitSdk; livekit-sdk-windows-x64-1.11.0.zip from the
#     official GitHub release, sha256 d95d677c3ca7348e0af18ede713f7fe825c14a726296ff65524b933f64f965dc)
#   - SCons 4.x                           (-Scons)
# Defaults are where they were set up on the MSI machine (2026-09-19).
#
# Output (all committed, so an export needs nothing but the repo):
#   glory_voice.windows.template_{debug,release}.x86_64.dll   the bridge
#   livekit.dll, livekit_ffi.dll                             copied from the SDK
#   msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll       VC++ runtime from the Build Tools redist folder;
#                                                            livekit.dll needs it and players may not have it
#   glory_voice_desktop_source.sha256                        digest of the sources; tools/voice_check
#                                                            recomputes it, so editing the C++ without
#                                                            rebuilding turns the gate red
#
# Everything is built from a copy under the (ASCII) temp dir: this repo lives under a Chinese-named folder.
#
# Usage (from the repo root):
#   powershell -NoProfile -ExecutionPolicy Bypass -File native/glory_voice_desktop/build_dll.ps1
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

[CmdletBinding()]
param(
    [string]$GodotCpp = "C:\Users\stech\GloryBuild\desktop_voice\third_party\godot-cpp",
    [string]$LiveKitSdk = "C:\Users\stech\GloryBuild\desktop_voice\third_party\livekit-sdk\livekit-sdk-windows-x64-1.11.0",
    [string]$Scons = "C:\Users\stech\GloryBuild\desktop_voice\venv\Scripts\scons.exe"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$SdkVersion = "1.11.0"   # same as GloryVoiceDesktop::LIVEKIT_SDK_VERSION

$here = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($here)) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = [IO.Path]::GetFullPath((Join-Path $here "..\.."))

if (-not (Test-Path -LiteralPath (Join-Path $GodotCpp "SConstruct"))) { throw "no godot-cpp at $GodotCpp (pass -GodotCpp)" }
if (-not (Test-Path -LiteralPath (Join-Path $LiveKitSdk "include\livekit\livekit.h"))) { throw "no LiveKit C++ SDK at $LiveKitSdk (pass -LiveKitSdk)" }
if (-not (Test-Path -LiteralPath $Scons)) { throw "no scons at $Scons (pass -Scons)" }
$buildInfo = Get-Content -Raw -LiteralPath (Join-Path $LiveKitSdk "share\livekit\build-info.json") | ConvertFrom-Json
if ($buildInfo.sdk_version -ne $SdkVersion) { throw "LiveKit SDK is $($buildInfo.sdk_version), expected $SdkVersion" }

# VC++ runtime to ship next to livekit.dll (from the Build Tools redist folder).
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) { throw "Visual Studio Build Tools not installed (no vswhere.exe)" }
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ([string]::IsNullOrWhiteSpace($vsPath)) { throw "no MSVC found - install 'Desktop development with C++' in the Build Tools" }
$crtDir = Get-ChildItem -Path (Join-Path $vsPath "VC\Redist\MSVC") -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName "x64") -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if ($null -eq $crtDir) { throw "no VC++ redist x64 CRT folder under $vsPath\VC\Redist\MSVC" }
$runtimeDlls = @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")
foreach ($dll in $runtimeDlls) {
    if (-not (Test-Path -LiteralPath (Join-Path $crtDir.FullName $dll))) { throw "missing $dll in $($crtDir.FullName)" }
}

# --- 1. copy the sources to an ASCII path --------------------------------------------------
$sourceFiles = @("SConstruct") + @(Get-ChildItem (Join-Path $here "src") -File | Where-Object { $_.Extension -in ".cpp", ".h" } | ForEach-Object { "src/" + $_.Name })
$work = Join-Path ([IO.Path]::GetTempPath()) "glory_voice_dll_build"
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $work "src") | Out-Null
foreach ($rel in $sourceFiles) { Copy-Item -LiteralPath (Join-Path $here $rel) -Destination (Join-Path $work $rel) }

# --- 2. build both targets --------------------------------------------------------------------
$env:GLORY_GODOT_CPP = $GodotCpp
$env:GLORY_LIVEKIT_SDK = $LiveKitSdk
$jobs = [Math]::Max(2, [Environment]::ProcessorCount)
foreach ($target in @("template_debug", "template_release")) {
    & $Scons -C $work "-j$jobs" "target=$target"
    if ($LASTEXITCODE -ne 0) { throw "scons target=$target failed" }
}

# --- 3. source digest ---------------------------------------------------------------------------
# "relative/path:sha256" lines, ordinal-sorted, joined with "\n", then SHA-256.
# tools/voice_check.gd computes exactly the same thing.
$relArray = [string[]]$sourceFiles
[Array]::Sort($relArray, [StringComparer]::Ordinal)
$lines = New-Object System.Collections.Generic.List[string]
foreach ($r in $relArray) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $here $r) -Algorithm SHA256).Hash.ToLowerInvariant()
    $lines.Add($r + ":" + $hash)
}
$sha = [Security.Cryptography.SHA256]::Create()
$digestBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines.ToArray() -join "`n")))
$digest = ($digestBytes | ForEach-Object { $_.ToString("x2") }) -join ""

# --- 4. install into the addon --------------------------------------------------------------
$outDir = Join-Path $root "addons\glory_voice\bin\windows"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
foreach ($target in @("template_debug", "template_release")) {
    $dll = Join-Path $work ("bin\glory_voice.windows.{0}.x86_64.dll" -f $target)
    if (-not (Test-Path -LiteralPath $dll)) { throw "scons did not produce $dll" }
    Copy-Item -LiteralPath $dll -Destination $outDir -Force
}
foreach ($dll in @("livekit.dll", "livekit_ffi.dll")) { Copy-Item -LiteralPath (Join-Path $LiveKitSdk "bin\$dll") -Destination $outDir -Force }
foreach ($dll in $runtimeDlls) { Copy-Item -LiteralPath (Join-Path $crtDir.FullName $dll) -Destination $outDir -Force }
[IO.File]::WriteAllText((Join-Path $outDir "glory_voice_desktop_source.sha256"), $digest, (New-Object Text.UTF8Encoding($false)))

Get-ChildItem -LiteralPath $outDir -File | ForEach-Object { Write-Host ("  {0,-55} {1,12:N0} bytes" -f $_.Name, $_.Length) }
Write-Host ("  VC++ runtime from: {0}" -f $crtDir.FullName)
Write-Host ("  source sha:        {0}" -f $digest)

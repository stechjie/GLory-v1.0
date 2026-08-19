[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$BundlePath = "",
    [string]$ArchivePath = "",
    [string]$GodotConsole = "",
    [switch]$ReplaceMismatchedExternalAssets
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-CanonicalInventorySha256 {
    param([object[]]$Entries)
    $builder = [System.Text.StringBuilder]::new()
    $byPath = @{}
    foreach ($entry in $Entries) {
        $path = [string]$entry.path
        if ($byPath.ContainsKey($path)) { throw "Duplicate manifest path: $path" }
        $byPath[$path] = $entry
    }
    $orderedPaths = [string[]]@($byPath.Keys)
    [Array]::Sort($orderedPaths, [StringComparer]::Ordinal)
    foreach ($path in $orderedPaths) {
        $entry = $byPath[$path]
        [void]$builder.Append([string]$entry.path); [void]$builder.Append("`t")
        [void]$builder.Append([int64]$entry.size); [void]$builder.Append("`t")
        [void]$builder.Append(([string]$entry.sha256).ToLowerInvariant()); [void]$builder.Append("`t")
        [void]$builder.Append([string]$entry.class); [void]$builder.Append("`n")
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($builder.ToString())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PathListSha256 {
    param([string[]]$Paths)
    $ordered = [string[]]$Paths.Clone()
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($ordered -join "`n") + "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-SafeRelativePath {
    param([string]$PathValue)
    $normalized = $PathValue.Replace('\', '/').TrimStart('./')
    if ([string]::IsNullOrWhiteSpace($normalized) -or [IO.Path]::IsPathRooted($PathValue) -or $normalized.Contains(':')) {
        throw "Unsafe archive path: $PathValue"
    }
    if (@($normalized.Split('/') | Where-Object { $_ -eq '..' }).Count -gt 0) { throw "Archive path traversal: $PathValue" }
    return $normalized
}

function Resolve-Godot {
    param([string]$Requested)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        if (Test-Path -LiteralPath $Requested -PathType Leaf) { return [IO.Path]::GetFullPath($Requested) }
        $requestedCommand = Get-Command $Requested -ErrorAction SilentlyContinue
        if ($null -ne $requestedCommand) { return $requestedCommand.Source }
        throw "Godot executable not found: $Requested"
    }
    foreach ($name in @('godot4', 'godot')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) { return $command.Source }
    }
    throw "Godot executable not found; pass -GodotConsole <path>"
}

$project = [IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath (Join-Path $project "project.godot") -PathType Leaf)) { throw "Not a Godot project root: $project" }
if ([string]::IsNullOrWhiteSpace($BundlePath)) { $BundlePath = Join-Path $project "assets.bundle.json" }
$bundleFile = [IO.Path]::GetFullPath($BundlePath)
if (-not (Test-Path -LiteralPath $bundleFile -PathType Leaf)) { throw "Bundle descriptor not found: $bundleFile" }
$manifestFile = Join-Path $project "assets.manifest.json"
if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) { throw "Manifest not found: $manifestFile" }

$manifest = Get-Content -Raw -LiteralPath $manifestFile | ConvertFrom-Json
$bundle = Get-Content -Raw -LiteralPath $bundleFile | ConvertFrom-Json
if ([int]$manifest.schema_version -ne 2) { throw "Unsupported manifest schema_version: $($manifest.schema_version)" }
if ([int]$bundle.schema_version -ne 1) { throw "Unsupported bundle schema_version: $($bundle.schema_version)" }
$entries = @($manifest.entries)
$inventorySha = Get-CanonicalInventorySha256 $entries
if ($inventorySha -ne ([string]$manifest.inventory_sha256).ToLowerInvariant()) { throw "Manifest inventory SHA-256 mismatch" }
if ($inventorySha -ne ([string]$bundle.inventory_sha256).ToLowerInvariant()) { throw "Bundle belongs to a different inventory" }

$expectedPaths = [string[]]@($bundle.artifact.paths | ForEach-Object { Assert-SafeRelativePath ([string]$_) })
[Array]::Sort($expectedPaths, [StringComparer]::Ordinal)
if ($expectedPaths.Count -ne [int]$bundle.artifact.entry_count -or $expectedPaths.Count -ne [int]$bundle.archive.entry_count) {
    throw "Bundle entry count does not match artifact path list"
}
if ((Get-PathListSha256 $expectedPaths) -ne ([string]$bundle.artifact.paths_sha256).ToLowerInvariant()) {
    throw "Bundle artifact path list SHA-256 mismatch"
}

$entryByRelative = @{}
foreach ($entry in $entries) { $entryByRelative[([string]$entry.path).Substring(6).Replace('\', '/')] = $entry }
foreach ($path in $expectedPaths) { if (-not $entryByRelative.ContainsKey($path)) { throw "Bundle path is absent from manifest: $path" } }

if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $besideDescriptor = Join-Path (Split-Path -Parent $bundleFile) ([string]$bundle.archive.file_name)
    $defaultBuild = Join-Path (Split-Path -Parent $project) ("build\assets\" + [string]$bundle.archive.file_name)
    if (Test-Path -LiteralPath $besideDescriptor -PathType Leaf) { $ArchivePath = $besideDescriptor }
    elseif (Test-Path -LiteralPath $defaultBuild -PathType Leaf) { $ArchivePath = $defaultBuild }
    else { throw "Archive not found beside descriptor or in ../build/assets; pass -ArchivePath" }
}
$archiveFile = [IO.Path]::GetFullPath($ArchivePath)
$archiveSha = (Get-FileHash -LiteralPath $archiveFile -Algorithm SHA256).Hash.ToLowerInvariant()
if ($archiveSha -ne ([string]$bundle.archive.sha256).ToLowerInvariant()) { throw "Archive SHA-256 mismatch: expected=$($bundle.archive.sha256) actual=$archiveSha" }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$readZip = [IO.Compression.ZipFile]::OpenRead($archiveFile)
try {
    $archivePaths = [string[]]@($readZip.Entries | ForEach-Object { Assert-SafeRelativePath ([string]$_.FullName) })
    [Array]::Sort($archivePaths, [StringComparer]::Ordinal)
    if (($archivePaths -join "`n") -ne ($expectedPaths -join "`n")) { throw "Archive file list does not match bundle descriptor" }
}
finally { $readZip.Dispose() }

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$temp = Join-Path $tempBase ("GloryAssetRestore-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp | Out-Null

try {
    $extractZip = [IO.Compression.ZipFile]::OpenRead($archiveFile)
    try {
        foreach ($zipEntry in $extractZip.Entries) {
            $relative = Assert-SafeRelativePath ([string]$zipEntry.FullName)
            $destination = [IO.Path]::GetFullPath((Join-Path $temp $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)))
            $tempPrefix = [IO.Path]::GetFullPath($temp).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $destination.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Archive entry escaped temp root: $relative" }
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            $inputStream = $zipEntry.Open()
            $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $inputStream.CopyTo($outputStream) }
            finally { $outputStream.Dispose(); $inputStream.Dispose() }
        }
    }
    finally { $extractZip.Dispose() }

    $conflicts = [System.Collections.Generic.List[string]]::new()
    $copyPaths = [System.Collections.Generic.List[string]]::new()
    $index = 0
    foreach ($relative in $expectedPaths) {
        $index++
        $source = [IO.Path]::GetFullPath((Join-Path $temp $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)))
        $tempPrefix = [IO.Path]::GetFullPath($temp).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $source.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Extracted path escaped temp root: $relative" }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Extracted file missing: $relative" }
        $entry = $entryByRelative[$relative]
        $sourceItem = Get-Item -LiteralPath $source
        if ([int64]$sourceItem.Length -ne [int64]$entry.size) { throw "Extracted size mismatch: $relative" }
        $sourceSha = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sourceSha -ne ([string]$entry.sha256).ToLowerInvariant()) { throw "Extracted SHA-256 mismatch: $relative" }

        $destination = [IO.Path]::GetFullPath((Join-Path $project $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)))
        $projectPrefix = $project.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $destination.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Destination escaped project root: $relative" }
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $destinationSha = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($destinationSha -eq $sourceSha) { continue }
            if (-not $ReplaceMismatchedExternalAssets) { $conflicts.Add($relative); continue }
        }
        $copyPaths.Add($relative)
        if ($index % 250 -eq 0) { Write-Host "[restore_assets] preflight $index/$($expectedPaths.Count)" }
    }
    if ($conflicts.Count -gt 0) {
        throw "Refusing to replace $($conflicts.Count) mismatched destination file(s). First: $($conflicts[0]). Inspect them, then explicitly pass -ReplaceMismatchedExternalAssets if replacement is intended."
    }

    foreach ($relative in $copyPaths) {
        $source = Join-Path $temp $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $destination = Join-Path $project $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $source -Destination $destination -Force:$ReplaceMismatchedExternalAssets
    }

    $godot = Resolve-Godot $GodotConsole
    & $godot --headless --path $project res://tools/asset_delivery_check.tscn -- --full-hash --strict-extras
    if ($LASTEXITCODE -ne 0) { throw "Godot asset delivery gate failed after restore (exit $LASTEXITCODE)" }
    Write-Host ("ASSET_RESTORE_RESULT status=PASS copied={0} already_present={1} inventory_sha256={2}" -f $copyPaths.Count, ($expectedPaths.Count - $copyPaths.Count), $inventorySha)
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($temp)
    if ((Test-Path -LiteralPath $resolvedTemp) -and $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedTemp).StartsWith("GloryAssetRestore-")) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}

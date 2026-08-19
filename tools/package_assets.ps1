[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputDirectory = "",
    [string]$GitExecutable = "git",
    [string]$ManifestPath = ""
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
        [void]$builder.Append([string]$entry.path)
        [void]$builder.Append("`t")
        [void]$builder.Append([int64]$entry.size)
        [void]$builder.Append("`t")
        [void]$builder.Append(([string]$entry.sha256).ToLowerInvariant())
        [void]$builder.Append("`t")
        [void]$builder.Append([string]$entry.class)
        [void]$builder.Append("`n")
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($builder.ToString())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PathListSha256 {
    param([string[]]$Paths)
    $ordered = [string[]]$Paths.Clone()
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    $text = ($ordered -join "`n") + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Resolve-ManifestFile {
    param([string]$Root, [string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return (Join-Path $Root "assets.manifest.json") }
    if ([IO.Path]::IsPathRooted($PathValue)) { return $PathValue }
    return (Join-Path $Root $PathValue)
}

function Convert-ResourcePathToFile {
    param([string]$Root, [string]$ResourcePath)
    if (-not $ResourcePath.StartsWith("res://", [StringComparison]::Ordinal)) {
        throw "Manifest path is not a res:// path: $ResourcePath"
    }
    $relative = $ResourcePath.Substring(6).Replace('/', [IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath((Join-Path $Root $relative))
    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest path escapes project root: $ResourcePath"
    }
    return $full
}

$project = [IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath (Join-Path $project "project.godot") -PathType Leaf)) {
    throw "Not a Godot project root: $project"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Split-Path -Parent $project) "build\assets"
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
$manifestFile = [IO.Path]::GetFullPath((Resolve-ManifestFile $project $ManifestPath))
if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) { throw "Manifest not found: $manifestFile" }

$manifest = Get-Content -Raw -LiteralPath $manifestFile | ConvertFrom-Json
if ([int]$manifest.schema_version -ne 2) { throw "Unsupported manifest schema_version: $($manifest.schema_version)" }
$entries = @($manifest.entries)
if ($entries.Count -eq 0) { throw "Manifest has no entries" }
$inventorySha = Get-CanonicalInventorySha256 $entries
if ($inventorySha -ne ([string]$manifest.inventory_sha256).ToLowerInvariant()) {
    throw "Manifest inventory SHA-256 mismatch: expected=$($manifest.inventory_sha256) actual=$inventorySha"
}

$tracked = @{}
$trackedLines = @(& $GitExecutable -C $project ls-files --)
if ($LASTEXITCODE -ne 0) { throw "git ls-files failed with exit code $LASTEXITCODE" }
foreach ($line in $trackedLines) {
    if (-not [string]::IsNullOrWhiteSpace($line)) {
        $tracked["res://" + ([string]$line).Replace('\', '/')] = $true
    }
}

$artifactEntries = [System.Collections.Generic.List[object]]::new()
$artifactRelativePaths = [System.Collections.Generic.List[string]]::new()
$artifactBytes = [int64]0
$trackedEntryCount = 0
$index = 0
foreach ($entry in $entries) {
    $index++
    $resourcePath = [string]$entry.path
    $file = Convert-ResourcePathToFile $project $resourcePath
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Manifest resource missing: $resourcePath" }
    $item = Get-Item -LiteralPath $file
    if ([int64]$item.Length -ne [int64]$entry.size) {
        throw "Manifest size mismatch: $resourcePath expected=$($entry.size) actual=$($item.Length)"
    }
    $sha = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha -ne ([string]$entry.sha256).ToLowerInvariant()) {
        throw "Manifest SHA-256 mismatch: $resourcePath expected=$($entry.sha256) actual=$sha"
    }
    if ($index % 250 -eq 0) { Write-Host "[package_assets] validation $index/$($entries.Count)" }
    if ($tracked.ContainsKey($resourcePath)) {
        $trackedEntryCount++
        continue
    }
    $relative = $resourcePath.Substring(6).Replace('\', '/')
    $artifactEntries.Add($entry)
    $artifactRelativePaths.Add($relative)
    $artifactBytes += [int64]$entry.size
}
if ($artifactEntries.Count -eq 0) { throw "No manifest resources are external to Git; refusing to create an empty bundle" }

$sortedPaths = [string[]]@($artifactRelativePaths)
[Array]::Sort($sortedPaths, [StringComparer]::Ordinal)
$pathsSha = Get-PathListSha256 $sortedPaths
New-Item -ItemType Directory -Force -Path $output | Out-Null
$work = Join-Path $output (".a2-package-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$tempZip = Join-Path $work "glory-assets.zip"
$listFile = Join-Path $work "files.txt"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllLines($listFile, $sortedPaths, $utf8NoBom)

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipStream = [IO.File]::Open($tempZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $zip = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Create, $false, $utf8NoBom)
    try {
        $zipIndex = 0
        foreach ($relative in $sortedPaths) {
            $zipIndex++
            $source = Join-Path $project $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $zipEntry = $zip.CreateEntry($relative, [IO.Compression.CompressionLevel]::Fastest)
            $zipEntry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $sourceStream = [IO.File]::OpenRead($source)
            $entryStream = $zipEntry.Open()
            try { $sourceStream.CopyTo($entryStream) }
            finally { $entryStream.Dispose(); $sourceStream.Dispose() }
            if ($zipIndex % 250 -eq 0) { Write-Host "[package_assets] archive $zipIndex/$($sortedPaths.Count)" }
        }
    }
    finally { $zip.Dispose(); $zipStream.Dispose() }
    $archiveSha = (Get-FileHash -LiteralPath $tempZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $archiveName = "glory-assets-{0}-{1}.zip" -f $inventorySha.Substring(0, 16), $archiveSha.Substring(0, 16)
    $archiveFile = Join-Path $output $archiveName
    if (Test-Path -LiteralPath $archiveFile -PathType Leaf) {
        $existingSha = (Get-FileHash -LiteralPath $archiveFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingSha -ne $archiveSha) { throw "Content-addressed archive collision: $archiveFile" }
        Remove-Item -LiteralPath $tempZip
    } else {
        Move-Item -LiteralPath $tempZip -Destination $archiveFile
    }

    $bundle = [ordered]@{
        schema_version = 1
        inventory_sha256 = $inventorySha
        manifest_schema_version = 2
        archive = [ordered]@{
            file_name = $archiveName
            sha256 = $archiveSha
            bytes = [int64](Get-Item -LiteralPath $archiveFile).Length
            entry_count = $artifactEntries.Count
        }
        artifact = [ordered]@{
            entry_count = $artifactEntries.Count
            total_bytes = $artifactBytes
            paths_sha256 = $pathsSha
            paths = $sortedPaths
        }
        repo_tracked_entry_count = $trackedEntryCount
        restore_roots = @($manifest.roots)
        storage_uri = ""
    }
    $bundleFile = Join-Path $project "assets.bundle.json"
    [IO.File]::WriteAllText($bundleFile, (($bundle | ConvertTo-Json -Depth 6) + "`n"), $utf8NoBom)
    Write-Host ("ASSET_PACKAGE_RESULT status=PASS artifact_entries={0} tracked_entries={1} archive_bytes={2} inventory_sha256={3} archive_sha256={4} archive={5}" -f $artifactEntries.Count, $trackedEntryCount, ([int64](Get-Item -LiteralPath $archiveFile).Length), $inventorySha, $archiveSha, $archiveFile)
}
finally {
    $resolvedWork = [IO.Path]::GetFullPath($work)
    $resolvedOutput = [IO.Path]::GetFullPath($output).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ((Test-Path -LiteralPath $resolvedWork) -and $resolvedWork.StartsWith($resolvedOutput, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedWork).StartsWith(".a2-package-")) {
        Remove-Item -LiteralPath $resolvedWork -Recurse -Force
    }
}

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$Path,

    [switch]$InPlace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Set-Variable -Name GLB_MAGIC -Value ([uint32]0x46546C67) -Option Constant
Set-Variable -Name GLB_VERSION -Value ([uint32]2) -Option Constant
Set-Variable -Name JSON_CHUNK_TYPE -Value ([uint32]0x4E4F534A) -Option Constant
Set-Variable -Name BIN_CHUNK_TYPE -Value ([uint32]0x004E4942) -Option Constant

function Get-UInt32 {
    param([byte[]]$Bytes, [int]$Offset)
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Get-PaddedBytes {
    param(
        [byte[]]$Bytes,
        [byte]$PaddingByte
    )
    $padding = (4 - ($Bytes.Length % 4)) % 4
    if ($padding -eq 0) {
        return $Bytes
    }
    $result = [byte[]]::new($Bytes.Length + $padding)
    [Array]::Copy($Bytes, 0, $result, 0, $Bytes.Length)
    for ($i = $Bytes.Length; $i -lt $result.Length; $i++) {
        $result[$i] = $PaddingByte
    }
    return $result
}

function Get-ByteSlice {
    param(
        [byte[]]$Bytes,
        [int]$Offset,
        [int]$Length
    )
    if ($Length -eq 0) {
        return [byte[]]::new(0)
    }
    $result = [byte[]]::new($Length)
    [Array]::Copy($Bytes, $Offset, $result, 0, $Length)
    return $result
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Remove-OptionalProperty {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties.Remove($Name)
    }
}

function Remap-BufferViewIndex {
    param(
        [int]$Index,
        [int]$FirstRemoved,
        [int]$LastRemoved,
        [int]$RemovedCount
    )
    if ($Index -ge $FirstRemoved -and $Index -le $LastRemoved) {
        throw "A retained resource references removed bufferView $Index."
    }
    if ($Index -gt $LastRemoved) {
        return $Index - $RemovedCount
    }
    return $Index
}

function Update-AccessorBufferViews {
    param(
        [object]$Document,
        [int]$FirstRemoved,
        [int]$LastRemoved,
        [int]$RemovedCount
    )
    foreach ($accessor in @($Document.accessors)) {
        if ($null -ne $accessor.PSObject.Properties["bufferView"]) {
            $accessor.bufferView = Remap-BufferViewIndex ([int]$accessor.bufferView) $FirstRemoved $LastRemoved $RemovedCount
        }
        if ($null -ne $accessor.PSObject.Properties["sparse"]) {
            foreach ($partName in @("indices", "values")) {
                $part = $accessor.sparse.$partName
                if ($null -ne $part -and $null -ne $part.PSObject.Properties["bufferView"]) {
                    $part.bufferView = Remap-BufferViewIndex ([int]$part.bufferView) $FirstRemoved $LastRemoved $RemovedCount
                }
            }
        }
    }
}

function Convert-Glb {
    param(
        [string]$InputPath,
        [string]$OutputPath
    )

    $fullPath = [IO.Path]::GetFullPath($InputPath)
    if ([IO.Path]::GetExtension($fullPath).ToLowerInvariant() -ne ".glb") {
        throw "Only .glb files are supported: $fullPath"
    }
    [byte[]]$fileBytes = [IO.File]::ReadAllBytes($fullPath)
    if ($fileBytes.Length -lt 28) {
        throw "GLB is too small: $fullPath"
    }
    if ((Get-UInt32 $fileBytes 0) -ne $GLB_MAGIC) {
        throw "Invalid GLB magic: $fullPath"
    }
    if ((Get-UInt32 $fileBytes 4) -ne $GLB_VERSION) {
        throw "Unsupported GLB version: $fullPath"
    }
    if ((Get-UInt32 $fileBytes 8) -ne $fileBytes.Length) {
        throw "GLB header length does not match file length: $fullPath"
    }

    $jsonLength = [int](Get-UInt32 $fileBytes 12)
    if ((Get-UInt32 $fileBytes 16) -ne $JSON_CHUNK_TYPE) {
        throw "First GLB chunk is not JSON: $fullPath"
    }
    $binHeaderOffset = 20 + $jsonLength
    if ($binHeaderOffset + 8 -gt $fileBytes.Length) {
        throw "GLB has no complete BIN chunk header: $fullPath"
    }
    $binLength = [int](Get-UInt32 $fileBytes $binHeaderOffset)
    if ((Get-UInt32 $fileBytes ($binHeaderOffset + 4)) -ne $BIN_CHUNK_TYPE) {
        throw "Second GLB chunk is not BIN: $fullPath"
    }
    $binOffset = $binHeaderOffset + 8
    if ($binOffset + $binLength -ne $fileBytes.Length) {
        throw "Only a single BIN chunk is supported: $fullPath"
    }

    $jsonText = [Text.Encoding]::UTF8.GetString($fileBytes, 20, $jsonLength).TrimEnd([char]0, [char]32)
    $document = $jsonText | ConvertFrom-Json -Depth 100
    if (@($document.buffers).Count -ne 1) {
        throw "Exactly one GLB buffer is required: $fullPath"
    }
    if ($document.buffers[0].byteLength -gt $binLength) {
        throw "Declared buffer length exceeds BIN chunk length: $fullPath"
    }

    $bufferViews = @($document.bufferViews)
    $imageViewIndices = @(
        @($document.images) |
            ForEach-Object {
                if ($null -eq $_.PSObject.Properties["bufferView"]) {
                    throw "External image URIs are not supported by this stripping tool: $fullPath"
                }
                [int]$_.bufferView
            } |
            Sort-Object -Unique
    )
    if ($imageViewIndices.Count -eq 0) {
        throw "No embedded image bufferViews found: $fullPath"
    }

    $firstRemoved = $imageViewIndices[0]
    $lastRemoved = $imageViewIndices[-1]
    $expectedIndices = @($firstRemoved..$lastRemoved)
    if (($expectedIndices -join ",") -ne ($imageViewIndices -join ",")) {
        throw "Embedded image bufferViews must be consecutive: $fullPath"
    }
    if ($firstRemoved -lt 0 -or $lastRemoved -ge $bufferViews.Count) {
        throw "Embedded image bufferView index is out of range: $fullPath"
    }

    $regionStart = [int]($bufferViews[$firstRemoved].byteOffset ?? 0)
    $regionEnd = if ($lastRemoved + 1 -lt $bufferViews.Count) {
        [int]($bufferViews[$lastRemoved + 1].byteOffset ?? 0)
    }
    else {
        $binLength
    }
    if ($regionStart -lt 0 -or $regionEnd -le $regionStart -or $regionEnd -gt $binLength) {
        throw "Invalid embedded image byte region [$regionStart, $regionEnd): $fullPath"
    }

    foreach ($accessor in @($document.accessors)) {
        if ($null -ne $accessor.PSObject.Properties["bufferView"]) {
            $index = [int]$accessor.bufferView
            if ($index -ge $firstRemoved -and $index -le $lastRemoved) {
                throw "Accessor references embedded image bufferView ${index}: $fullPath"
            }
        }
    }

    [byte[]]$binBytes = Get-ByteSlice $fileBytes $binOffset $binLength
    $retainedHashes = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $bufferViews.Count; $i++) {
        if ($i -ge $firstRemoved -and $i -le $lastRemoved) {
            continue
        }
        $view = $bufferViews[$i]
        $offset = [int]($view.byteOffset ?? 0)
        $length = [int]$view.byteLength
        $retainedHashes.Add((Get-Sha256Hex (Get-ByteSlice $binBytes $offset $length)))
    }

    $removedBytes = $regionEnd - $regionStart
    [byte[]]$newBinBytes = [byte[]]::new($binLength - $removedBytes)
    [Array]::Copy($binBytes, 0, $newBinBytes, 0, $regionStart)
    [Array]::Copy($binBytes, $regionEnd, $newBinBytes, $regionStart, $binLength - $regionEnd)

    $newBufferViews = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $bufferViews.Count; $i++) {
        if ($i -ge $firstRemoved -and $i -le $lastRemoved) {
            continue
        }
        $view = $bufferViews[$i]
        $offset = [int]($view.byteOffset ?? 0)
        if ($offset -ge $regionEnd) {
            $view.byteOffset = $offset - $removedBytes
        }
        $newBufferViews.Add($view)
    }
    $document.bufferViews = @($newBufferViews)
    $removedViewCount = $lastRemoved - $firstRemoved + 1
    Update-AccessorBufferViews $document $firstRemoved $lastRemoved $removedViewCount

    foreach ($mesh in @($document.meshes)) {
        foreach ($primitive in @($mesh.primitives)) {
            Remove-OptionalProperty $primitive "material"
        }
    }
    foreach ($propertyName in @("materials", "textures", "images", "samplers")) {
        Remove-OptionalProperty $document $propertyName
    }
    $document.buffers[0].byteLength = $newBinBytes.Length

    $newJsonText = $document | ConvertTo-Json -Depth 100 -Compress
    [byte[]]$newJsonBytes = Get-PaddedBytes ([Text.Encoding]::UTF8.GetBytes($newJsonText)) 0x20
    [byte[]]$paddedBinBytes = Get-PaddedBytes $newBinBytes 0x00
    $totalLength = 12 + 8 + $newJsonBytes.Length + 8 + $paddedBinBytes.Length

    $stream = [IO.MemoryStream]::new($totalLength)
    $writer = [IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([uint32]$GLB_MAGIC)
        $writer.Write([uint32]$GLB_VERSION)
        $writer.Write([uint32]$totalLength)
        $writer.Write([uint32]$newJsonBytes.Length)
        $writer.Write([uint32]$JSON_CHUNK_TYPE)
        $writer.Write($newJsonBytes)
        $writer.Write([uint32]$paddedBinBytes.Length)
        $writer.Write([uint32]$BIN_CHUNK_TYPE)
        $writer.Write($paddedBinBytes)
        $writer.Flush()
        [byte[]]$outputBytes = $stream.ToArray()
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }

    $targetPath = [IO.Path]::GetFullPath($OutputPath)
    [IO.File]::WriteAllBytes($targetPath, $outputBytes)

    [byte[]]$verifyBytes = [IO.File]::ReadAllBytes($targetPath)
    $verifyJsonLength = [int](Get-UInt32 $verifyBytes 12)
    $verifyJson = [Text.Encoding]::UTF8.GetString($verifyBytes, 20, $verifyJsonLength).TrimEnd([char]0, [char]32) | ConvertFrom-Json -Depth 100
    $verifyBinHeaderOffset = 20 + $verifyJsonLength
    $verifyBinLength = [int](Get-UInt32 $verifyBytes $verifyBinHeaderOffset)
    $verifyBinOffset = $verifyBinHeaderOffset + 8
    [byte[]]$verifyBin = Get-ByteSlice $verifyBytes $verifyBinOffset $verifyBinLength

    $verifiedHashes = [Collections.Generic.List[string]]::new()
    foreach ($view in @($verifyJson.bufferViews)) {
        $offset = [int]($view.byteOffset ?? 0)
        $length = [int]$view.byteLength
        $verifiedHashes.Add((Get-Sha256Hex (Get-ByteSlice $verifyBin $offset $length)))
    }
    if (($retainedHashes -join "|") -ne ($verifiedHashes -join "|")) {
        throw "Retained bufferView payload hashes changed: $targetPath"
    }

    return [pscustomobject]@{
        path = $targetPath
        old_bytes = $fileBytes.Length
        new_bytes = $verifyBytes.Length
        removed_file_bytes = $fileBytes.Length - $verifyBytes.Length
        removed_buffer_bytes = $removedBytes
        removed_buffer_views = $removedViewCount
        retained_buffer_views = @($verifyJson.bufferViews).Count
        meshes = @($verifyJson.meshes).Count
        accessors = @($verifyJson.accessors).Count
        skins = @($verifyJson.skins).Count
        animations = @($verifyJson.animations).Count
        nodes = @($verifyJson.nodes).Count
        retained_payloads_verified = $verifiedHashes.Count
        output_sha256 = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$results = @()
foreach ($item in $Path) {
    $inputPath = (Resolve-Path -LiteralPath $item).Path
    if ($InPlace) {
        $temporaryPath = "$inputPath.codex-strip.tmp"
        try {
            $result = Convert-Glb $inputPath $temporaryPath
            Move-Item -LiteralPath $temporaryPath -Destination $inputPath -Force
            $result.path = $inputPath
            $result.output_sha256 = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $results += $result
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }
    }
    else {
        $outputPath = [IO.Path]::Combine(
            [IO.Path]::GetDirectoryName($inputPath),
            ([IO.Path]::GetFileNameWithoutExtension($inputPath) + ".stripped.glb")
        )
        $results += Convert-Glb $inputPath $outputPath
    }
}

$results | ConvertTo-Json -Depth 8

$script:LanFlowPortableWorkspace = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\') + '\'

function Assert-PortablePath([string]$Path, [string]$Workspace = $script:LanFlowPortableWorkspace) {
    $workspacePrefix = [IO.Path]::GetFullPath($Workspace).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($Path)
    if (!$full.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Portable package path must stay inside the workspace: $full"
    }
    $cursor = $full
    while ($cursor.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Portable package paths cannot contain links: $cursor"
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}

function Get-PortableStreamHash([IO.Stream]$Stream) {
    $Stream.Position = 0
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($Stream)).Replace('-', '') }
    finally { $Stream.Position = 0; $hash.Dispose() }
}

function Copy-PortableRelease([string]$Source, [string]$Destination, [string]$SourceWorkspace = $script:LanFlowPortableWorkspace) {
    $ErrorActionPreference = 'Stop'
    $sourceRoot = Assert-PortablePath $Source -Workspace $SourceWorkspace
    $targetRoot = Assert-PortablePath $Destination
    $sourcePrefix = $sourceRoot.TrimEnd('\') + '\'
    $targetPrefix = $targetRoot.TrimEnd('\') + '\'
    if ($sourcePrefix.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $targetPrefix.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Portable source and destination must be separate directories.'
    }
    $records = @()
    $updated = 0
    try {
        # Acquire every existing package file before changing any contents. A
        # running executable or locked asset must not leave a half-updated app.
        foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse | Sort-Object FullName) {
            $sourcePath = Assert-PortablePath $file.FullName -Workspace $SourceWorkspace
            $relative = $sourcePath.Substring($sourcePrefix.Length)
            $destinationPath = Assert-PortablePath (Join-Path $targetRoot $relative)
            if (!$destinationPath.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Portable file escaped its destination.'
            }
            $record = [pscustomobject]@{
                Source = $sourcePath
                Destination = $destinationPath
                Hash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
                Stream = $null
                Changed = $true
            }
            $records += $record
            if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
                $record.Stream = [IO.File]::Open($destinationPath, [IO.FileMode]::Open,
                    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                $record.Changed = (Get-PortableStreamHash $record.Stream) -ne $record.Hash
            }
        }
        foreach ($record in $records) {
            if (!$record.Changed) { continue }
            if (!$record.Stream) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $record.Destination) -Force | Out-Null
                $record.Stream = [IO.File]::Open($record.Destination, [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            }
            $inputStream = [IO.File]::OpenRead($record.Source)
            try {
                $record.Stream.Position = 0
                $inputStream.CopyTo($record.Stream)
                $record.Stream.SetLength($inputStream.Length)
                $record.Stream.Flush($true)
            } finally { $inputStream.Dispose() }
            if ((Get-PortableStreamHash $record.Stream) -ne $record.Hash) {
                throw "Portable file verification failed: $($record.Destination)"
            }
            $updated++
        }
        return [pscustomobject]@{Files = $records.Count; Updated = $updated; Verified = $true}
    } catch {
        throw $_.Exception.GetBaseException()
    } finally {
        foreach ($record in $records) { if ($record.Stream) { $record.Stream.Dispose() } }
    }
}

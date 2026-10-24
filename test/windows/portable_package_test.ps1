$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $workspace 'scripts/portable-package.ps1')
$testParent = [IO.Path]::GetFullPath((Join-Path $workspace 'build/portable-publish-tests')).TrimEnd('\') + '\'
$caseRoot = [IO.Path]::GetFullPath((Join-Path $testParent ([guid]::NewGuid().ToString('N'))))
if (!$caseRoot.StartsWith($testParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test path' }
$source = Join-Path $caseRoot 'source'
$target = Join-Path $caseRoot 'target'
New-Item -ItemType Directory -Path $source,$target -Force | Out-Null
try {
    [IO.File]::WriteAllBytes((Join-Path $source 'a.bin'), [byte[]](1,2,3))
    [IO.File]::WriteAllBytes((Join-Path $source 'b.bin'), [byte[]](4,5,6))
    [IO.File]::WriteAllBytes((Join-Path $target 'a.bin'), [byte[]](9))
    [IO.File]::WriteAllBytes((Join-Path $target 'b.bin'), [byte[]](8))
    [IO.File]::WriteAllBytes((Join-Path $target 'user-extra.bin'), [byte[]](7))
    $locked = [IO.File]::Open((Join-Path $target 'b.bin'), [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $rejected = $false
    try {
        try { Copy-PortableRelease $source $target | Out-Null }
        catch [IO.IOException] { $rejected = $true }
    } finally { $locked.Dispose() }
    if (!$rejected) { throw 'A locked package file must prevent publishing.' }
    if ([IO.File]::ReadAllBytes((Join-Path $target 'a.bin'))[0] -ne 9) {
        throw 'A file was updated before the lock check completed.'
    }
    $result = Copy-PortableRelease $source $target
    if ($result.Updated -ne 2 -or !$result.Verified) { throw 'Unlocked update failed.' }
    if ([IO.File]::ReadAllBytes((Join-Path $target 'user-extra.bin'))[0] -ne 7) {
        throw 'Extra files must be preserved.'
    }
    $result = Copy-PortableRelease $source $target
    if ($result.Updated -ne 0) { throw 'Identical files should not be rewritten.' }
    $overlapRejected = $false
    try { Copy-PortableRelease $source (Join-Path $source 'nested') | Out-Null }
    catch { $overlapRejected = $true }
    if (!$overlapRejected) { throw 'Overlapping directories must be rejected.' }
    Write-Output 'Portable publishing checks passed: locked files, verified updates, extra files, repeat updates, and path isolation.'
} finally {
    $resolved = [IO.Path]::GetFullPath($caseRoot)
    if (!$resolved.StartsWith($testParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility, Microsoft.PowerShell.Archive
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $workspace 'scripts/portable-package.ps1')
$tokens = $null
$parseErrors = $null
$packageAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $workspace 'scripts/package.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0] }
foreach ($name in @('Install-WindowsFlutter', 'Invoke-Package')) {
    $definition = $packageAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

$caseRoot = Assert-PortablePath (Join-Path $workspace ('build/flutter-bootstrap-tests/' + [guid]::NewGuid().ToString('N')))
$toolRoot = Join-Path $caseRoot '.tooling'
$downloads = Join-Path $toolRoot 'downloads'
$flutter = Join-Path $toolRoot 'flutter/bin/flutter.bat'
$sdkRoot = Join-Path $toolRoot 'flutter'
$archive = Join-Path $downloads 'flutter_windows_3.47.7-stable.zip'
$script:downloadCount = 0
$script:extractCount = 0
$script:badDownload = $false
$script:badArchive = $false
$script:initialized = $false

# Exercise setup without fetching an SDK or touching the real project toolchain.
function Initialize-WindowsEnvironment { $script:initialized = $true }
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    if ($Uri -ne 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.7-stable.zip') {
        throw 'Unexpected Flutter download URL.'
    }
    $script:downloadCount++
    $content = if ($script:badDownload) { 'invalid' } else { 'verified' }
    [IO.File]::WriteAllText($OutFile, $content)
}
function Get-FileHash {
    param($LiteralPath, $Algorithm)
    if ($Algorithm -ne 'SHA256') { throw 'SDK archives must use SHA256.' }
    $hash = if ([IO.File]::ReadAllText($LiteralPath) -eq 'verified') {
        'c2c875da25a1a1448d18ee4e8f398b2f6fce888b4775d8f9130538e16d826cb4'
    } else { 'invalid' }
    [pscustomobject]@{Hash = $hash}
}
function Expand-Archive {
    param($LiteralPath, $DestinationPath)
    $script:extractCount++
    if ($script:badArchive) { return }
    $bin = Join-Path $DestinationPath 'flutter/bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $bin 'flutter.bat'), '@echo test-sdk')
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $caught = $false
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        $caught = $true
    }
    if (!$caught) { throw "Expected failure: $Message" }
}
function Remove-TestSdk {
    if (Test-Path -LiteralPath $sdkRoot) {
        Remove-Item -LiteralPath (Assert-PortablePath $sdkRoot) -Recurse -Force
    }
}

try {
    $Target = 'windows'
    $SkipSetup = $true
    Assert-Throws { Invoke-Package } 'run without -SkipSetup'
    if (!$script:initialized -or $script:downloadCount) { throw 'SkipSetup must initialize the environment without downloading.' }

    Install-WindowsFlutter
    if (!(Test-Path -LiteralPath $flutter) -or $script:downloadCount -ne 1 -or $script:extractCount -ne 1) {
        throw 'A fresh workspace did not install the verified SDK.'
    }
    Install-WindowsFlutter
    if ($script:downloadCount -ne 1 -or $script:extractCount -ne 1) { throw 'An existing SDK must be preserved.' }

    Remove-TestSdk
    Install-WindowsFlutter
    if ($script:downloadCount -ne 1 -or $script:extractCount -ne 2) { throw 'A verified cached archive should be reused.' }

    Remove-TestSdk
    [IO.File]::WriteAllText($archive, 'invalid')
    Install-WindowsFlutter
    if ($script:downloadCount -ne 2 -or $script:extractCount -ne 3) { throw 'An invalid cached archive must be replaced.' }

    Remove-TestSdk
    [IO.File]::WriteAllText($archive, 'invalid')
    $script:badDownload = $true
    Assert-Throws { Install-WindowsFlutter } 'checksum verification failed'
    if ((Test-Path -LiteralPath $sdkRoot) -or $script:extractCount -ne 3) { throw 'Unverified archives must never be extracted.' }

    $script:badDownload = $false
    $script:badArchive = $true
    Assert-Throws { Install-WindowsFlutter } 'does not contain the expected SDK'
    if (Test-Path -LiteralPath $sdkRoot) { throw 'A failed extraction must not become the installed SDK.' }
    if (Get-ChildItem -LiteralPath $toolRoot -Directory -Filter 'flutter-setup-*') { throw 'Temporary extraction directories must be removed.' }

    New-Item -ItemType Directory -Path $sdkRoot | Out-Null
    $before = $script:downloadCount
    Assert-Throws { Install-WindowsFlutter } 'SDK is incomplete'
    if ($script:downloadCount -ne $before) { throw 'An incomplete existing SDK must not be overwritten.' }
    Write-Output 'Flutter bootstrap checks passed: fresh setup, SkipSetup, cache reuse, corrupt archives, existing SDK preservation, and extraction cleanup.'
} finally {
    if (Test-Path -LiteralPath $caseRoot) {
        Remove-Item -LiteralPath (Assert-PortablePath $caseRoot) -Recurse -Force
    }
}

$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $workspace 'scripts/portable-package.ps1')
$tokens = $null
$parseErrors = $null
$packageAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $workspace 'scripts/package.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0] }
foreach ($name in @('Invoke-Flutter', 'Set-PluginLinks', 'Invoke-WindowsPubGet')) {
    $definition = $packageAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

$testRoot = Assert-PortablePath (Join-Path $workspace ('build/plugin-bootstrap-tests/' + [guid]::NewGuid().ToString('N')))
$previousCache = $env:PUB_CACHE
$previousTestRoot = $env:LANFLOW_PLUGIN_TEST_ROOT
$previousTestMode = $env:LANFLOW_PLUGIN_TEST_MODE
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$flutter = Join-Path $testRoot 'flutter-fixture.cmd'
$fixture = @'
@echo off
if exist "%LANFLOW_PLUGIN_TEST_ROOT%\first-call" goto retry
echo called>"%LANFLOW_PLUGIN_TEST_ROOT%\first-call"
if "%LANFLOW_PLUGIN_TEST_MODE%"=="dependency" (
    echo Version solving failed. 1>&2
    exit /b 65
)
if "%LANFLOW_PLUGIN_TEST_MODE%"=="missing-metadata" goto symlink
copy /y "%LANFLOW_PLUGIN_TEST_ROOT%\metadata.fixture" "%LANFLOW_PLUGIN_TEST_ROOT%\.flutter-plugins-dependencies" >nul
if "%LANFLOW_PLUGIN_TEST_MODE%"=="success" (
    echo Dependencies resolved.
    exit /b 0
)
:symlink
echo Building with plugins requires symlink support. 1>&2
exit /b 1
:retry
echo called>"%LANFLOW_PLUGIN_TEST_ROOT%\second-call"
if "%LANFLOW_PLUGIN_TEST_MODE%"=="retry-fails" (
    echo Version solving failed on retry. 1>&2
    exit /b 65
)
if not exist "%LANFLOW_PLUGIN_TEST_ROOT%\platforms\windows\flutter\ephemeral\.plugin_symlinks\fixture_plugin\marker" (
    echo Plugin junction missing. 1>&2
    exit /b 2
)
echo Dependencies resolved after plugin junction setup.
exit /b 0
'@
[IO.File]::WriteAllText($flutter, $fixture.Replace("`r`n", "`n").Replace("`n", "`r`n"), [Text.Encoding]::ASCII)
$cases = @('success', 'cold', 'dependency', 'retry-fails', 'missing-metadata')
try {
    foreach ($mode in $cases) {
        $projectRoot = Join-Path $testRoot $mode
        $env:PUB_CACHE = Join-Path $projectRoot '.pub-cache'
        $env:LANFLOW_PLUGIN_TEST_ROOT = $projectRoot
        $env:LANFLOW_PLUGIN_TEST_MODE = $mode
        $pluginRoot = Join-Path $env:PUB_CACHE 'hosted/pub.dev/fixture_plugin-1.0.0'
        New-Item -ItemType Directory -Path $pluginRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $pluginRoot 'marker'), 'test fixture')
        $metadata = @{plugins = @{windows = @(@{name = 'fixture_plugin'; path = $pluginRoot})}} | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $projectRoot 'metadata.fixture'), $metadata)
        $failure = $null
        try { Invoke-WindowsPubGet }
        catch { $failure = $_.Exception.Message }
        $retried = Test-Path -LiteralPath (Join-Path $projectRoot 'second-call')
        if ($mode -in @('dependency', 'retry-fails')) {
            if (!$failure -or !$failure.Contains('failed (65)')) { throw "Dependency failure was not preserved: $mode" }
        } elseif ($mode -eq 'missing-metadata') {
            if (!$failure -or !$failure.Contains('did not generate plugin metadata')) { throw 'Missing metadata must fail clearly.' }
        } elseif ($failure) { throw $failure }
        if ($retried -ne ($mode -in @('cold', 'retry-fails'))) { throw "Unexpected retry count: $mode" }
        if ($mode -in @('success', 'cold')) {
            $link = Get-Item -LiteralPath (Join-Path $projectRoot 'platforms/windows/flutter/ephemeral/.plugin_symlinks/fixture_plugin')
            if ($link.LinkType -ne 'Junction' -or !(Test-Path -LiteralPath (Join-Path $link.FullName 'marker'))) {
                throw "A usable plugin junction was not created: $mode"
            }
        }
        if (!(Test-Path -LiteralPath (Join-Path $pluginRoot 'marker'))) { throw 'Plugin cache contents changed.' }
    }
    Write-Output 'Plugin bootstrap checks passed: clean metadata, NTFS junction fallback, one retry, dependency failures, retry failures, and missing metadata.'
} finally {
    $env:PUB_CACHE = $previousCache
    $env:LANFLOW_PLUGIN_TEST_ROOT = $previousTestRoot
    $env:LANFLOW_PLUGIN_TEST_MODE = $previousTestMode
    foreach ($mode in $cases) {
        $linkPath = Join-Path $testRoot "$mode/platforms/windows/flutter/ephemeral/.plugin_symlinks/fixture_plugin"
        $link = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
        if ($link) {
            if ($link.LinkType -ne 'Junction') { throw 'Unexpected plugin test cleanup path.' }
            [IO.Directory]::Delete($linkPath)
        }
    }
    Remove-Item -LiteralPath (Assert-PortablePath $testRoot) -Recurse -Force
}

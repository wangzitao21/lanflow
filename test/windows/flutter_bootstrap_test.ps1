$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $workspace 'scripts/portable-package.ps1')
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $workspace 'scripts/package.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0] }
foreach ($name in @('Install-WindowsFlutter', 'Install-WindowsTools', 'Build-WindowsCore', 'Invoke-Package')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (!$definition) { throw "Missing function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Find-VisualStudio { return $null }
function Invoke-WebRequest { throw 'Projects must not download private Windows toolchains.' }
$caseRoot = Assert-PortablePath (Join-Path $workspace ('build/flutter-bootstrap-tests/' + [guid]::NewGuid().ToString('N')))
$flutter = Join-Path $caseRoot 'flutter.bat'
try {
    foreach ($action in @({ Install-WindowsFlutter }, { Install-WindowsTools })) {
        $blocked = $false
        try { & $action } catch {
            if (!$_.Exception.Message.Contains('Automatic Windows toolchain installation is disabled')) { throw }
            $blocked = $true
        }
        if (!$blocked) { throw 'Missing shared tools must not trigger a private installation.' }
    }
    New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
    [IO.File]::WriteAllText($flutter, '@echo fixture')
    Install-WindowsFlutter
    function Find-VisualStudio { return 'existing-shared-installation' }
    Install-WindowsTools
    function Initialize-WindowsEnvironment { $script:windowsInitializations++ }
    function Invoke-LinuxBuild([string]$LinuxTarget) { $script:linuxTargets += $LinuxTarget }
    function Initialize-WindowsBuildWorkspace { return $workspace }
    function Set-PlatformLinks { throw 'WINDOWS_UI_PHASE_REACHED' }
    $projectRoot = $workspace
    $sourceRoot = $workspace
    $SkipSetup = $false
    $SkipTests = $false
    foreach ($Target in @('all', 'windows', 'android', 'nas', 'check')) {
        $script:linuxTargets = @()
        $script:windowsInitializations = 0
        $windowsPhase = $false
        try { Invoke-Package } catch {
            if ($_.Exception.Message -ne 'WINDOWS_UI_PHASE_REACHED') { throw }
            $windowsPhase = $true
        }
        $expectedWindows = $Target -in @('all', 'windows')
        if ($windowsPhase -ne $expectedWindows -or $script:windowsInitializations -ne [int]$expectedWindows) { throw "Incorrect platform routing: $Target" }
        $expectedLinux = if ($Target -eq 'all') { 'all,windows-core' } elseif ($Target -eq 'windows') { 'check,windows-core' } else { $Target }
        if (($script:linuxTargets -join ',') -ne $expectedLinux) { throw "Rust/Android/NAS did not route through Debian: $Target" }
    }
    Write-Output 'Shared tool checks passed: reuse existing tools, no automatic private installs, Windows UI on Windows, and all Rust/Android/NAS builds through Debian.'
} finally {
    if (Test-Path -LiteralPath $caseRoot) { Remove-Item -LiteralPath (Assert-PortablePath $caseRoot) -Recurse -Force }
}
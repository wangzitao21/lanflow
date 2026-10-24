param(
    [ValidateSet('all', 'windows', 'android', 'nas', 'check')]
    [string]$Target = 'all',
    [switch]$SkipSetup,
    [switch]$SkipTests,
    [ValidateRange(1, 4)][int]$Jobs = 2,
    [ValidateRange(3, 12)][int]$MemoryGB = 6,
    [switch]$Interactive
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolRoot = Join-Path $projectRoot '.tooling'
$downloads = Join-Path $toolRoot 'downloads'
$flutter = Join-Path $toolRoot 'flutter/bin/flutter.bat'
$platformLinks = [System.Collections.Generic.List[string]]::new()
Set-Location -LiteralPath $projectRoot
. (Join-Path $PSScriptRoot 'portable-package.ps1')

function Set-PlatformLinks {
    # Flutter expects these directories beside pubspec.yaml. Junctions expose the
    # platform sources only while packaging, without creating another source copy.
    foreach ($name in @('android', 'windows')) {
        $source = Join-Path $projectRoot "platforms/$name"
        $link = Join-Path $projectRoot $name
        if (!(Test-Path -LiteralPath $source -PathType Container)) { throw "Missing platform source: $source" }
        $existing = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.LinkType -ne 'Junction' -or
                [IO.Path]::GetFullPath(@($existing.Target)[0]) -ne [IO.Path]::GetFullPath($source)) {
                throw "Cannot create Flutter platform link over an existing path: $link"
            }
        } else {
            New-Item -ItemType Junction -Path $link -Target $source | Out-Null
        }
        $platformLinks.Add($link)
    }
}

function Remove-PlatformLinks {
    foreach ($link in $platformLinks) {
        $existing = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        if (!$existing) { continue }
        $source = Join-Path $projectRoot ('platforms/' + (Split-Path -Leaf $link))
        if ($existing.LinkType -ne 'Junction' -or
            [IO.Path]::GetFullPath(@($existing.Target)[0]) -ne [IO.Path]::GetFullPath($source)) {
            throw "Flutter platform link changed during packaging: $link"
        }
        # Delete the junction itself; never recurse into its source directory.
        [IO.Directory]::Delete($link)
    }
    $platformLinks.Clear()
}

function Initialize-WindowsEnvironment {
    $env:PUB_CACHE = Join-Path $projectRoot '.pub-cache'
    $env:CARGO_BUILD_JOBS = "$Jobs"
    $env:CMAKE_BUILD_PARALLEL_LEVEL = "$Jobs"
    $env:DOTNET_PROCESSOR_COUNT = "$Jobs"
    $env:MSBUILDDISABLENODEREUSE = '1'
    $env:CI = 'true'
    $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $env:DASH__SUPPRESS_ANALYTICS = 'true'
    $env:TEMP = Join-Path $toolRoot 'test-temp'
    $env:TMP = $env:TEMP
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
    [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
}

function Install-WindowsFlutter {
    if (Test-Path -LiteralPath $flutter -PathType Leaf) { return }
    $sdkRoot = Assert-PortablePath (Join-Path $toolRoot 'flutter')
    if (Test-Path -LiteralPath $sdkRoot) {
        throw "The Windows Flutter SDK is incomplete at $sdkRoot. Move that directory aside and run without -SkipSetup."
    }
    New-Item -ItemType Directory -Path $downloads -Force | Out-Null
    $archive = Join-Path $downloads 'flutter_windows_3.47.7-stable.zip'
    # Pinned to the same Flutter release as WSL, using the official release manifest.
    $expectedHash = 'c2c875da25a1a1448d18ee4e8f398b2f6fce888b4775d8f9130538e16d826cb4'
    if (!(Test-Path -LiteralPath $archive -PathType Leaf) -or
        (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expectedHash) {
        Write-Host 'Downloading Flutter 3.47.7 for Windows...'
        $pending = "$archive.pending"
        Invoke-WebRequest -Uri 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.7-stable.zip' -OutFile $pending -UseBasicParsing
        if ((Get-FileHash -LiteralPath $pending -Algorithm SHA256).Hash -ne $expectedHash) {
            throw 'Windows Flutter archive checksum verification failed; the SDK was not installed.'
        }
        Move-Item -LiteralPath $pending -Destination $archive -Force
    }
    $staging = Assert-PortablePath (Join-Path $toolRoot ('flutter-setup-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
    try {
        New-Item -ItemType Directory -Path $staging | Out-Null
        Expand-Archive -LiteralPath $archive -DestinationPath $staging
        $extracted = Join-Path $staging 'flutter'
        if (!(Test-Path -LiteralPath (Join-Path $extracted 'bin/flutter.bat') -PathType Leaf)) {
            throw 'The Windows Flutter archive does not contain the expected SDK.'
        }
        Move-Item -LiteralPath (Assert-PortablePath $extracted) -Destination $sdkRoot
    } finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath (Assert-PortablePath $staging) -Recurse -Force
        }
    }
}

function Build-WindowsCore {
    Invoke-LinuxBuild 'windows-core'
}

function Invoke-Flutter([string[]]$FlutterArguments) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $flutter --suppress-analytics @FlutterArguments
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "Flutter command failed ($code): $($FlutterArguments -join ' ')" }
}

function Set-PluginLinks {
    $metadata = Join-Path $projectRoot '.flutter-plugins-dependencies'
    if (!(Test-Path -LiteralPath $metadata)) { return }
    $plugins = Get-Content -Raw -LiteralPath $metadata | ConvertFrom-Json
    $cacheRoot = [System.IO.Path]::GetFullPath($env:PUB_CACHE) + '\'
    $linkRoot = Join-Path $projectRoot 'platforms\windows\flutter\ephemeral\.plugin_symlinks'
    New-Item -ItemType Directory -Path $linkRoot -Force | Out-Null
    foreach ($plugin in $plugins.plugins.windows) {
        if ($plugin.name -notmatch '^[a-z0-9_]+$') { throw 'Invalid plugin name' }
        $source = [System.IO.Path]::GetFullPath($plugin.path)
        if (!$source.StartsWith($cacheRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Plugin must be inside the project package cache' }
        $destination = Join-Path $linkRoot $plugin.name
        if (!(Test-Path -LiteralPath $destination)) {
            # NTFS directory junctions work for Flutter plugins without changing Developer Mode.
            New-Item -ItemType Junction -Path $destination -Target $source | Out-Null
        }
    }
}

function Invoke-WindowsPubGet {
    Set-PluginLinks
    $messages = [System.Collections.Generic.List[string]]::new()
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $flutter --suppress-analytics pub get --enforce-lockfile 2>&1 | ForEach-Object {
            $message = $_.ToString()
            $messages.Add($message)
            Write-Host $message
        }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) {
        if (!(($messages -join "`n").Contains('Building with plugins requires symlink support.'))) {
            throw "Flutter command failed ($code): pub get --enforce-lockfile"
        }
        if (!(Test-Path -LiteralPath (Join-Path $projectRoot '.flutter-plugins-dependencies') -PathType Leaf)) {
            throw 'Flutter could not create plugin links and did not generate plugin metadata; pub get failed.'
        }
        # On a clean checkout Flutter writes the metadata before attempting links.
        # The retry sees unchanged metadata and preserves these NTFS junctions.
        Write-Host 'Preparing Windows plugin junctions and retrying pub get...'
        Set-PluginLinks
        Invoke-Flutter @('pub', 'get', '--enforce-lockfile')
    }
    Set-PluginLinks
}

function Find-VisualStudio {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (!(Test-Path -LiteralPath $vswhere)) { return $null }
    $found = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath
    if ($LASTEXITCODE -eq 0 -and $found) { return @($found)[0] }
    return $null
}

function Test-WindowsNative {
    $installation = Find-VisualStudio
    if (!$installation) { throw 'Visual Studio C++ tools are required for native checks' }
    $cmakeRoot = Join-Path $installation 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin'
    $cmake = Join-Path $cmakeRoot 'cmake.exe'
    $ctest = Join-Path $cmakeRoot 'ctest.exe'
    $testBuild = Join-Path $projectRoot 'build/windows-native-checks'
    & $cmake -S (Join-Path $projectRoot 'test/windows') -B $testBuild -G 'Visual Studio 17 2022' -A x64
    if ($LASTEXITCODE -ne 0) { throw 'Windows native test configuration failed' }
    & $cmake --build $testBuild --config Release --parallel $Jobs
    if ($LASTEXITCODE -ne 0) { throw 'Windows native test build failed' }
    & $ctest --test-dir $testBuild -C Release --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw 'Windows native checks failed' }
}

function Install-WindowsTools {
    if (Find-VisualStudio) {
        Write-Host 'Windows C++ build tools are available.'
        return
    }
    Write-Host 'Downloading Microsoft Visual Studio 2022 Build Tools...'
    $installer = Join-Path $downloads 'vs_BuildTools.exe'
    Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $installer -UseBasicParsing
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=Microsoft Corporation') {
        throw 'Microsoft installer signature could not be verified'
    }
    $installPath = Join-Path $env:LOCALAPPDATA 'BuildTools/visual-studio'
    $arguments = @('--quiet', '--wait', '--norestart', '--nocache', '--installPath', ('"' + $installPath + '"'), '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--includeRecommended')
    $startOptions = @{
        FilePath = $installer
        ArgumentList = $arguments
        WindowStyle = 'Hidden'
        Wait = $true
        PassThru = $true
    }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $startOptions.Verb = 'RunAs' }
    $process = Start-Process @startOptions
    if ($process.ExitCode -notin @(0, 3010)) { throw "Visual Studio installation failed: $($process.ExitCode)" }
    if (!(Find-VisualStudio)) { throw 'Visual Studio C++ tools are still unavailable after installation' }
    if ($process.ExitCode -eq 3010) { Write-Warning 'The installer reports a pending restart. A build will be attempted without restarting.' }
}

function Invoke-Debian([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    try {
        # WSL startup notices on stderr are not command failures in PowerShell 5.1.
        $ErrorActionPreference = 'Continue'
        & wsl.exe --distribution Debian @Arguments
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "Debian build command failed ($code)" }
}

function Invoke-LinuxBuild([string]$LinuxTarget) {
    $LinuxTarget = $LinuxTarget.ToLowerInvariant()
    $linuxRoot = @(Invoke-Debian @('--exec', 'wslpath', '-a', $projectRoot))[-1].Trim()
    if (!$linuxRoot.StartsWith('/')) { throw 'Unable to resolve the project path in Debian' }
    if (!$SkipSetup) {
        Invoke-Debian @('--user', 'root', '--exec', '/bin/bash', "$linuxRoot/scripts/wsl-setup.sh", '--system')
    }
    $setupArgument = if ($SkipSetup) { 'skip' } else { 'setup' }
    $testArgument = if ($SkipTests) { 'skip' } else { 'test' }
    Write-Host "Debian: $LinuxTarget; at most $Jobs CPU cores, $MemoryGB GiB RAM, low build priority."
    Invoke-Debian @(
        '--exec', 'systemd-run', '--user', '--scope', '--quiet',
        '-p', "CPUQuota=$($Jobs * 100)%", '-p', 'CPUWeight=10', '-p', 'IOWeight=10',
        '-p', "MemoryMax=${MemoryGB}G", '-p', "MemoryHigh=$($MemoryGB - 1)G", '-p', 'MemorySwapMax=1G',
        '--', 'nice', '-n', '10', 'ionice', '-c', '2', '-n', '7',
        '/bin/bash', "$linuxRoot/scripts/wsl-build.sh", $linuxRoot, $LinuxTarget, $setupArgument, $testArgument, "$Jobs"
    )

}

function Invoke-Package {
    $buildWindows = $Target -in @('all', 'windows')
    if ($buildWindows) {
        Initialize-WindowsEnvironment
        if (!$SkipSetup) { Install-WindowsFlutter }
        if (!(Test-Path -LiteralPath $flutter -PathType Leaf)) {
            throw 'The Windows Flutter SDK is missing; run without -SkipSetup.'
        }
    }
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pubspec.yaml')
    $version = [regex]::Match($manifest, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)').Groups[1].Value
    if (!$version) { throw 'Application version is missing' }
    $outputRoot = Join-Path $projectRoot 'artifacts'
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    if ($Target -ne 'windows' -or !$SkipTests) {
        $linuxTarget = if ($Target -eq 'windows') { 'check' } else { $Target }
        Invoke-LinuxBuild $linuxTarget
    }
    if (!$buildWindows) { return }
    if (!$SkipSetup) {
        New-Item -ItemType Directory -Path $downloads -Force | Out-Null
        Install-WindowsTools
    }
    Build-WindowsCore
    Set-PlatformLinks
    Invoke-WindowsPubGet
    Invoke-Flutter @('analyze', '--no-pub')
    if (!$SkipTests) {
        # Validate the actual Windows UI, including native clipboard/window cases.
        Invoke-Flutter @('test', '--no-pub', 'test/widget', "--concurrency=$Jobs", '--reporter', 'expanded', '--timeout', '60s')
        Test-WindowsNative
        & (Join-Path $projectRoot 'test/windows/portable_package_test.ps1')
        & (Join-Path $projectRoot 'test/windows/flutter_bootstrap_test.ps1')
        & (Join-Path $projectRoot 'test/windows/plugin_bootstrap_test.ps1')
    }

    if ($Target -in @('all', 'windows')) {
        $symbols = Join-Path $projectRoot "build/symbols/$version/windows-x64"
        Invoke-Flutter @('build', 'windows', '--release', '--no-pub', "--split-debug-info=$symbols")
        $release = Join-Path $projectRoot 'build\windows\x64\runner\Release'
        $releaseIcons = Join-Path $release 'data/flutter_assets/fonts/MaterialIcons-Regular.otf'
        $previousIconFont = $env:LANFLOW_RELEASE_ICON_FONT
        $previousIconsSource = $env:LANFLOW_MATERIAL_ICONS_SOURCE
        try {
            $env:LANFLOW_RELEASE_ICON_FONT = $releaseIcons
            $env:LANFLOW_MATERIAL_ICONS_SOURCE = Join-Path $toolRoot 'flutter/packages/flutter/lib/src/material/icons.dart'
            # Verify every icon referenced by the UI after tree shaking, plus
            # actual rendering of navigation, menus and recovery actions.
            Invoke-Flutter @('test', '--no-pub', 'test/previews/verify_release_icons.dart', '--reporter', 'expanded')
        } finally {
            $env:LANFLOW_RELEASE_ICON_FONT = $previousIconFont
            $env:LANFLOW_MATERIAL_ICONS_SOURCE = $previousIconsSource
        }
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        $vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($LASTEXITCODE -ne 0 -or !$vsRoot) { throw 'Visual Studio installation could not be located' }
        $vsInstallation = @($vsRoot)[0]
        $redistRoot = Join-Path $vsInstallation 'VC\Redist\MSVC'
        $runtimeDirectories = @(Get-ChildItem -LiteralPath $redistRoot -Directory | Where-Object {
            $_.Name -match '^\d+\.\d+(?:\.\d+){0,2}$'
        } | Sort-Object { [version]$_.Name } -Descending | ForEach-Object {
            Get-ChildItem -LiteralPath (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue
        })
        if (!$runtimeDirectories.Count) { throw 'Visual C++ runtime files are missing' }
        Get-ChildItem -LiteralPath $runtimeDirectories[0].FullName -File -Filter '*.dll' | Copy-Item -Destination $release -Force
        $windowsOutput = Join-Path $outputRoot "LanFlow-$version-windows-x64"
        $zipOutput = "$windowsOutput.zip"
        $pendingZip = "$windowsOutput.pending.zip"
        # Package the fresh build directly, independent of a possibly open portable copy.
        Compress-Archive -Path (Join-Path $release '*') -DestinationPath $pendingZip -Force
        Move-Item -LiteralPath $pendingZip -Destination $zipOutput -Force
        New-Item -ItemType Directory -Path $windowsOutput -Force | Out-Null
        try {
            $published = Copy-PortableRelease $release $windowsOutput
            Write-Host "Portable directory verified: $($published.Files) files; $($published.Updated) updated."
        } catch [System.IO.IOException] {
            if (($_.Exception.HResult -band 0xffff) -notin @(32, 33, 1224)) { throw }
            Write-Warning "Portable files are in use; close LanFlow before updating the directory. The latest complete package is $zipOutput"
        }
        Get-Item -LiteralPath (Join-Path $release 'lanflow.exe'),$zipOutput | Select-Object Name,Length
    }

    Get-ChildItem -LiteralPath $outputRoot -File | Where-Object { $_.Extension -in @('.apk', '.zip') } | Get-FileHash -Algorithm SHA256 | Format-Table -AutoSize

}

$transcriptStarted = $false
$buildExitCode = 0
$packageLock = $null
try {
    New-Item -ItemType Directory -Path (Join-Path $projectRoot 'build') -Force | Out-Null
    try {
        $packageLock = [IO.File]::Open((Join-Path $projectRoot 'build/package.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        throw 'Another package build is already running for this project.'
    }
    if ($Interactive) {
        $logDirectory = Join-Path $projectRoot 'build/logs'
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        $logPath = Join-Path $logDirectory ('package-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID + '.log')
        Start-Transcript -LiteralPath $logPath | Out-Null
        $transcriptStarted = $true
        Write-Host 'LanFlow：正在准备 Windows、安卓和 NAS 构建包。' -ForegroundColor Cyan
        Write-Host 'Rust、安卓与 NAS 在 Debian WSL 编译，Windows 界面在 Windows 编译。'
        Write-Host "默认最多使用 $Jobs 核；WSL 编译内存上限 $MemoryGB GiB。"
    }
    Invoke-Package
    Remove-PlatformLinks
    if ($Interactive) {
        Write-Host '打包成功！最新安装包位于：' -ForegroundColor Green
        Write-Host (Join-Path $projectRoot 'artifacts')
    }
} catch {
    if (!$Interactive) { throw }
    $buildExitCode = 1
    Write-Host '打包未完成，请保留窗口中的错误信息。' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($_.InvocationInfo.PositionMessage) { Write-Host $_.InvocationInfo.PositionMessage }
} finally {
    try {
        Remove-PlatformLinks
    } finally {
        if ($packageLock) { $packageLock.Dispose() }
        if ($transcriptStarted) {
            Stop-Transcript | Out-Null
            Write-Host ('完整日志：' + $logPath)
        }
    }
}
if ($Interactive) { exit $buildExitCode }

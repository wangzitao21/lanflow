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
$sourceRoot = $projectRoot
$toolRoot = if ($env:WINDOWS_BUILD_TOOLS_HOME) {
    [IO.Path]::GetFullPath($env:WINDOWS_BUILD_TOOLS_HOME)
} else {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'BuildTools'
}
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
    $env:WINDOWS_BUILD_TOOLS_HOME = $toolRoot
    $env:FLUTTER_ROOT = Join-Path $toolRoot 'flutter'
    $env:PUB_CACHE = Join-Path $toolRoot 'pub-cache'
    $env:CARGO_BUILD_JOBS = "$Jobs"
    $env:CMAKE_BUILD_PARALLEL_LEVEL = "$Jobs"
    $env:DOTNET_PROCESSOR_COUNT = "$Jobs"
    $env:MSBUILDDISABLENODEREUSE = '1'
    $env:CI = 'true'
    $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $env:DASH__SUPPRESS_ANALYTICS = 'true'
    $env:TEMP = Join-Path $toolRoot 'temp/lanflow'
    $env:TMP = $env:TEMP
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
    [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
}

function Install-WindowsFlutter {
    if (Test-Path -LiteralPath $flutter -PathType Leaf) { return }
    throw 'Shared Windows Flutter is missing. Automatic Windows toolchain installation is disabled; restore the shared BuildTools environment first.'
}

function Build-WindowsCore {
    Invoke-LinuxBuild 'windows-core'
    if ($projectRoot -ne $sourceRoot) {
        $library = Join-Path $sourceRoot 'build/native/lanflow_core.dll'
        $destination = Join-Path $projectRoot 'build/native/lanflow_core.dll'
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        if (!(Test-Path -LiteralPath $destination) -or (Get-FileHash -LiteralPath $library).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) {
            Copy-Item -LiteralPath $library -Destination $destination -Force
        }
    }
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
        if (!$source.StartsWith($cacheRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Plugin must be inside the configured shared package cache' }
        $destination = Join-Path $linkRoot $plugin.name
        $existing = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.LinkType -notin @('Junction', 'SymbolicLink')) {
                throw "Plugin link path contains an ordinary directory: $destination"
            }
            $oldTarget = [IO.Path]::GetFullPath(@($existing.Target)[0]).TrimEnd('\')
            if ($oldTarget -eq $source.TrimEnd('\')) { continue }
            # Remove only the link, preserving the previous package directory.
            [IO.Directory]::Delete($destination)
        }
        New-Item -ItemType Junction -Path $destination -Target $source | Out-Null
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
    if (Find-VisualStudio) { return }
    throw 'Shared Windows C++ build tools are missing. Automatic Windows toolchain installation is disabled; restore the shared MSVC, CMake and desktop SDK first.'
}

function Invoke-Debian([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    try {
        # WSL startup notices on stderr are not command failures in PowerShell 5.1.
        $ErrorActionPreference = 'Continue'
        & wsl.exe --distribution Debian --cd '~' @Arguments
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "Debian build command failed ($code)" }
}

function Invoke-LinuxBuild([string]$LinuxTarget) {
    $LinuxTarget = $LinuxTarget.ToLowerInvariant()
    $linuxRoot = @(Invoke-Debian @('--exec', 'wslpath', '-a', $sourceRoot))[-1].Trim()
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

function Initialize-WindowsBuildWorkspace {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $id = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($sourceRoot.ToLowerInvariant()))).Replace('-', '').Substring(0, 12).ToLowerInvariant() }
    finally { $hasher.Dispose() }
    $sharedPrefix = [IO.Path]::GetFullPath($toolRoot).TrimEnd('\') + '\'
    $buildHome = Join-Path $toolRoot ('projects/lanflow-' + $id)
    $buildSource = [IO.Path]::GetFullPath((Join-Path $buildHome 'source'))
    if (!$buildSource.StartsWith($sharedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Build workspace escaped the shared tool directory.' }
    $cursor = $buildSource
    while ($cursor.StartsWith($sharedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Build workspace contains a link: $cursor" }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    $marker = Join-Path $buildHome '.source-root'
    if (Test-Path -LiteralPath $marker) {
        if ([IO.File]::ReadAllText($marker).Trim() -ne $sourceRoot) { throw 'Build workspace belongs to another project.' }
    } else {
        if ((Test-Path -LiteralPath $buildSource) -and (Get-ChildItem -LiteralPath $buildSource -Force)) { throw 'Refusing to synchronize over an unowned build workspace.' }
        New-Item -ItemType Directory -Path $buildHome -Force | Out-Null
        [IO.File]::WriteAllText($marker, $sourceRoot, [Text.UTF8Encoding]::new($false))
    }
    New-Item -ItemType Directory -Path $buildSource -Force | Out-Null
    foreach ($directory in @('lib', 'native', 'platforms', 'scripts', 'test', 'assets')) {
        $source = Join-Path $sourceRoot $directory
        if (!(Test-Path -LiteralPath $source -PathType Container)) { continue }
        $destination = [IO.Path]::GetFullPath((Join-Path $buildSource $directory))
        if (!$destination.StartsWith($buildSource + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected synchronization destination.' }
        $messages = @(& robocopy.exe $source $destination /MIR /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XD .git build target .gradle .kotlin .cxx ephemeral jniLibs /XF key.properties local.properties '*.jks' '*.keystore')
        if ($LASTEXITCODE -ge 8) { throw "Windows source synchronization failed: $($messages -join ' ')" }
    }
    foreach ($file in @('pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', '.gitignore', '.gitattributes')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination (Join-Path $buildSource $file) -Force
    }
    Write-Host "Shared Windows build workspace: $buildSource"
    return $buildSource
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
        Install-WindowsTools
    }
    $script:projectRoot = Initialize-WindowsBuildWorkspace
    Set-Location -LiteralPath $projectRoot
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
        # Flutter's release asset target can retain an old tree-shaken font when
        # only Dart icon references change. Rebuild this target for every package.
        $assetCache = [IO.Path]::GetFullPath((Join-Path $projectRoot '.dart_tool/flutter_build'))
        $workspacePrefix = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\') + '\'
        if (!$assetCache.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Asset cache escaped the build workspace.' }
        if (Test-Path -LiteralPath $assetCache) {
            foreach ($cache in Get-ChildItem -LiteralPath $assetCache -Directory) {
                if ($cache.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected asset cache link.' }
                foreach ($stamp in Get-ChildItem -LiteralPath $cache.FullName -File -Filter 'release_bundle_windows-*_assets.stamp') {
                    if ($stamp.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected asset stamp link.' }
                    Remove-Item -LiteralPath $stamp.FullName -Force
                }
            }
        }
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
            $published = Copy-PortableRelease $release $windowsOutput -SourceWorkspace $projectRoot
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
        Write-Host 'Rust、安卓与 NAS 使用 Debian 共享工具；Windows 界面使用系统共享工具。'
        Write-Host "默认最多使用 $Jobs 核；WSL 编译内存上限 $MemoryGB GiB。"
    }
    Invoke-Package
    Remove-PlatformLinks
    if ($Interactive) {
        Write-Host '打包成功！最新安装包位于：' -ForegroundColor Green
        Write-Host (Join-Path $sourceRoot 'artifacts')
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

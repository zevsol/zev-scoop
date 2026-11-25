param(
    [ValidateSet('Install', 'Upgrade')]
    [string]$Mode = 'Install',
    [string]$PreviousManifestPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$candidatePath = Join-Path $repoRoot 'bucket\qoder-cli.json'
$candidate = Get-Content -LiteralPath $candidatePath -Raw | ConvertFrom-Json
$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } elseif ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
$runRoot = Join-Path $tempBase ("zev-scoop-qoder-cli-test-{0}" -f [guid]::NewGuid().ToString('N'))
$scoopRoot = Join-Path $runRoot 'scoop'
$sourceBucket = Join-Path $runRoot 'source-bucket'
$isolatedConfigHome = Join-Path $runRoot 'config-home'
$isolatedQoderConfig = Join-Path $runRoot 'qoder-config'
$globalRoot = Join-Path $runRoot 'global'
$cacheRoot = Join-Path $runRoot 'cache'
$bootstrapPath = Join-Path $runRoot 'bootstrap-scoop.ps1'
$previousEnvironment = @{}
foreach ($name in @('SCOOP', 'SCOOP_GLOBAL', 'SCOOP_CACHE', 'SCOOP_REPO', 'XDG_CONFIG_HOME', 'QODER_CONFIG_DIR', 'PATH')) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Invoke-Scoop([string[]]$Arguments) {
    Write-Host ("COMMAND: scoop {0}" -f ($Arguments -join ' '))
    & scoop @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "scoop $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Assert-QoderVersion([string]$ExpectedVersion) {
    $output = & qoder --version 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    if ($exitCode -ne 0 -or ($output -join "`n") -notmatch [regex]::Escape($ExpectedVersion)) {
        throw "qoder --version did not report ${ExpectedVersion} (exit $exitCode): $output"
    }
}

function Restore-ProcessEnvironment {
    foreach ($name in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
}

function Remove-TestRootSafely {
    if (-not (Test-Path -LiteralPath $runRoot)) { return }
    $resolvedRoot = [IO.Path]::GetFullPath($runRoot).TrimEnd('\')
    $resolvedBase = [IO.Path]::GetFullPath($tempBase).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($resolvedBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove test directory outside the temporary base: $resolvedRoot"
    }
    if ($resolvedRoot -eq [IO.Path]::GetFullPath($tempBase).TrimEnd('\')) {
        throw 'Refusing to remove the temporary base directory itself.'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}

if ($Mode -eq 'Upgrade') {
    if (-not $PreviousManifestPath -or -not (Test-Path -LiteralPath $PreviousManifestPath -PathType Leaf)) {
        Write-Host 'UPGRADE=SKIPPED: no historical manifest is available.'
        if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value 'upgrade_test=skipped' }
        return
    }
    $previous = Get-Content -LiteralPath $PreviousManifestPath -Raw | ConvertFrom-Json
    if ($previous.version -eq $candidate.version) {
        Write-Host "UPGRADE=SKIPPED: historical version $($previous.version) equals current version $($candidate.version)."
        if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value 'upgrade_test=skipped' }
        return
    }
}

try {
    New-Item -ItemType Directory -Path $runRoot -ErrorAction Stop | Out-Null
    $manifestDirectory = Join-Path $sourceBucket 'bucket'
    New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    $testManifest = if ($Mode -eq 'Upgrade') { (Resolve-Path -LiteralPath $PreviousManifestPath).Path } else { $candidatePath }
    $bucketManifestPath = Join-Path $manifestDirectory 'qoder-cli.json'
    Copy-Item -LiteralPath $testManifest -Destination $bucketManifestPath

    # Keep all Scoop and Qoder state under this unique temporary directory.
    $env:SCOOP = $scoopRoot
    $env:SCOOP_GLOBAL = $globalRoot
    $env:SCOOP_REPO = 'https://github.com/ScoopInstaller/Scoop'
    $env:XDG_CONFIG_HOME = $isolatedConfigHome
    $env:QODER_CONFIG_DIR = $isolatedQoderConfig
    New-Item -ItemType Directory -Path $isolatedConfigHome, $isolatedQoderConfig, $globalRoot, $cacheRoot -Force | Out-Null
    $qoderSettingsPath = Join-Path $isolatedQoderConfig 'settings.json'
    $qoderSettings = @{ general = @{ enableAutoUpdate = $false } } | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText(
        $qoderSettingsPath,
        $qoderSettings + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    $writtenQoderSettings = Get-Content -LiteralPath $qoderSettingsPath -Raw | ConvertFrom-Json
    if ($writtenQoderSettings.general.enableAutoUpdate -ne $false) {
        throw 'The isolated Qoder settings did not disable automatic updates.'
    }
    Write-Host "QODER_AUTO_UPDATE_ISOLATION=CONFIGURED: $qoderSettingsPath"

    # The official bootstrap normally persists its shims directory into the user PATH.
    # Run its reviewed source in a clean child PowerShell and replace only that function
    # so the shim path is added to the child process PATH without writing the registry.
    $installerPath = Join-Path $runRoot 'get-scoop.ps1'
    Invoke-WebRequest -Uri 'https://get.scoop.sh' -OutFile $installerPath -TimeoutSec 30
    if ((Get-Item -LiteralPath $installerPath).Length -lt 1000) {
        throw 'Official Scoop bootstrap source was unexpectedly small.'
    }
    $installerSource = Get-Content -LiteralPath $installerPath -Raw
    $shimPathPattern = '(?ms)^function Add-ShimsDirToPath\s*\{.*?^\}'
    $shimPathOverride = @'
function Add-ShimsDirToPath {
    # The lifecycle test must never persist Scoop shims to the user PATH registry value.
    $env:PATH = "$SCOOP_SHIMS_DIR;$env:PATH"
}
'@
    $shimPathMatches = [regex]::Matches($installerSource, $shimPathPattern)
    if ($shimPathMatches.Count -ne 1) {
        throw "Expected exactly one Add-ShimsDirToPath function in official Scoop bootstrap; found $($shimPathMatches.Count)."
    }
    $shimPathRegex = [regex]::new(
        $shimPathPattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
    )
    $replacementEvaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($match) return $shimPathOverride }
    $installerSource = $shimPathRegex.Replace($installerSource, $replacementEvaluator, 1)
    if ($installerSource -match "Write-Env\s+'PATH'") {
        throw 'Safe bootstrap rewrite failed; a persistent PATH write remains in the installer source.'
    }
    Set-Content -LiteralPath $installerPath -Value $installerSource -Encoding utf8

    $scoopCommands = @(Get-Command scoop -All -ErrorAction SilentlyContinue)
    $excludedScoopPaths = @($scoopCommands | ForEach-Object {
        if ($_.Source) { Split-Path -Parent $_.Source }
    } | Where-Object { $_ } | Sort-Object -Unique)
    $bootstrapContent = @'
param(
    [Parameter(Mandatory=$true)][string]$InstallerPath,
    [Parameter(Mandatory=$true)][string]$ScoopRoot,
    [Parameter(Mandatory=$true)][string]$GlobalRoot,
    [Parameter(Mandatory=$true)][string]$CacheRoot,
    [Parameter(Mandatory=$true)][string]$ConfigHome,
    [string[]]$ExcludedScoopPaths = @()
)
$ErrorActionPreference = 'Stop'
$env:SCOOP = $ScoopRoot
# Do not expose a custom SCOOP_GLOBAL to the bootstrap: when elevated, the official
# installer can otherwise persist it as a machine environment variable.
Remove-Item Env:SCOOP_GLOBAL -ErrorAction SilentlyContinue
Remove-Item Env:SCOOP_CACHE -ErrorAction SilentlyContinue
$env:XDG_CONFIG_HOME = $ConfigHome
$env:PATH = (($env:PATH -split ';' | Where-Object {
    $_ -and ($ExcludedScoopPaths -notcontains $_.TrimEnd('\'))
}) -join ';')
. $InstallerPath -ScoopDir $ScoopRoot -ScoopGlobalDir $GlobalRoot -ScoopCacheDir $CacheRoot
function Add-ShimsDirToPath {
    if ($env:PATH -notlike "*$SCOOP_SHIMS_DIR*") { $env:PATH = "$SCOOP_SHIMS_DIR;$env:PATH" }
}
Install-Scoop
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Scoop bootstrap failed with exit code $LASTEXITCODE" }
'@
    Set-Content -LiteralPath $bootstrapPath -Value $bootstrapContent -Encoding utf8
    $windowsPowerShell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell)) { $windowsPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source }
    & $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $bootstrapPath `
        -InstallerPath $installerPath -ScoopRoot $scoopRoot -GlobalRoot $globalRoot `
        -CacheRoot $cacheRoot -ConfigHome $isolatedConfigHome -ExcludedScoopPaths $excludedScoopPaths
    if ($LASTEXITCODE -ne 0) { throw "Isolated Scoop bootstrap process failed with exit code $LASTEXITCODE" }

    # Scoop's own shim() adds its shim directory to the persisted user PATH through
    # Add-Path. Patch only the disposable Scoop checkout so Add-Path changes this
    # test process PATH and never writes registry environment variables.
    $scoopSystemPath = Join-Path $scoopRoot 'apps\scoop\current\lib\system.ps1'
    $scoopSystemSource = Get-Content -LiteralPath $scoopSystemPath -Raw
    $addPathPattern = '(?ms)^function Add-Path\s*\{.*?^\}'
    $addPathOverride = @'
function Add-Path {
    param(
        [string[]]$Path,
        [string]$TargetEnvVar = 'PATH',
        [switch]$Global,
        [switch]$Force,
        [switch]$Quiet
    )
    $inPath, $strippedPath = Split-PathLikeEnvVar $Path $env:PATH
    if (!$inPath -or $Force) { $env:PATH = (@($Path) + $strippedPath) -join ';' }
}
'@
    $addPathRegex = [regex]::new(
        $addPathPattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
    )
    if ($addPathRegex.Matches($scoopSystemSource).Count -ne 1) {
        throw 'Could not safely isolate the disposable Scoop Add-Path implementation.'
    }
    $addPathEvaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($match) return $addPathOverride }
    $scoopSystemSource = $addPathRegex.Replace($scoopSystemSource, $addPathEvaluator, 1)
    Set-Content -LiteralPath $scoopSystemPath -Value $scoopSystemSource -Encoding utf8
    Write-Host 'SCOOP_PATH_ISOLATION=PASS: disposable Scoop Add-Path writes process PATH only.'

    $env:SCOOP_GLOBAL = $globalRoot
    $env:SCOOP_CACHE = $cacheRoot
    $env:PATH = "$(Join-Path $scoopRoot 'shims');$env:PATH"
    if ((Get-Command scoop -ErrorAction SilentlyContinue).Source -notlike "$(Join-Path $scoopRoot 'shims')*") {
        throw 'The Scoop command does not resolve to the isolated installation.'
    }

    git -C $sourceBucket init --quiet
    if ($LASTEXITCODE -ne 0) { throw "Initializing disposable test bucket failed with exit code $LASTEXITCODE" }
    git -C $sourceBucket config user.name 'Scoop Test'
    if ($LASTEXITCODE -ne 0) { throw 'Setting disposable bucket author name failed.' }
    git -C $sourceBucket config user.email 'scoop-test@example.invalid'
    if ($LASTEXITCODE -ne 0) { throw 'Setting disposable bucket author email failed.' }
    git -C $sourceBucket add bucket/qoder-cli.json
    if ($LASTEXITCODE -ne 0) { throw 'Staging disposable test manifest failed.' }
    git -C $sourceBucket commit --quiet -m 'test: initial manifest'
    if ($LASTEXITCODE -ne 0) { throw "Committing initial test manifest failed with exit code $LASTEXITCODE" }
    $sourceBucketUri = ([Uri]::new($sourceBucket)).AbsoluteUri
    Invoke-Scoop @('bucket', 'add', 'zevtest', $sourceBucketUri)

    $packageName = 'zevtest/qoder-cli'
    $appRoot = Join-Path $scoopRoot 'apps\qoder-cli'
    $binaryPath = Join-Path $appRoot 'current\qodercli.exe'
    Invoke-Scoop @('install', $packageName)
    if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
        throw "Installed executable not found at expected Scoop path: $binaryPath"
    }

    # Scoop verifies a manifest hash during install. Recompute it from Scoop's retained
    # download cache as an independent assertion against the exact bytes installed.
    $cacheArchives = @(Get-ChildItem -LiteralPath $cacheRoot -File -Recurse -Filter '*.zip' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*qoder-cli*' -or $_.Name -like '*qodercli-windows-x64*' })
    if (-not $cacheArchives.Count) { throw "Scoop did not retain the Qoder archive in the isolated cache: $cacheRoot" }
    $expectedHash = [string]$candidate.architecture.'64bit'.hash
    $actualHashes = @($cacheArchives | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
    if ($actualHashes -notcontains $expectedHash.ToLowerInvariant()) {
        throw "Downloaded Qoder archive SHA256 mismatch. Expected $expectedHash; got $($actualHashes -join ', ')."
    }
    Write-Host "SHA256=PASS: $expectedHash (verified from Scoop download cache)."
    Write-Host "INSTALL=PASS: $packageName $($candidate.version); executable=$binaryPath"
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value 'install_test=passed' }

    $qoderShimDirectory = Join-Path $scoopRoot 'shims'
    $shim = Get-Command qoder -ErrorAction Stop
    if ($shim.Source -notlike "$qoderShimDirectory*") {
        throw "qoder resolves outside the isolated Scoop shims directory: $($shim.Source)"
    }
    Write-Host "SHIM=PASS: $($shim.Source)"
    $installedManifest = Get-Content -LiteralPath $bucketManifestPath -Raw | ConvertFrom-Json
    Assert-QoderVersion ([string]$installedManifest.version)
    & qoder --help 2>&1 | ForEach-Object { Write-Host $_ }
    $helpExitCode = $LASTEXITCODE
    if ($helpExitCode -ne 0) { throw "qoder --help failed with exit code $helpExitCode" }
    Write-Host 'COMMAND=PASS: qoder --version and qoder --help.'

    if ($Mode -eq 'Upgrade') {
        Copy-Item -LiteralPath $candidatePath -Destination $bucketManifestPath -Force
        git -C $sourceBucket add bucket/qoder-cli.json
        if ($LASTEXITCODE -ne 0) { throw 'Staging candidate manifest failed.' }
        git -C $sourceBucket commit --quiet -m "test: candidate manifest $($candidate.version)"
        if ($LASTEXITCODE -ne 0) { throw "Committing candidate manifest failed with exit code $LASTEXITCODE" }
        Invoke-Scoop @('update')
        Invoke-Scoop @('update', 'qoder-cli')
        Assert-QoderVersion ([string]$candidate.version)
        Write-Host "UPGRADE=PASS: $($installedManifest.version) -> $($candidate.version)"
        if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value 'upgrade_test=passed' }
    }
    else {
        Write-Host 'UPGRADE=NOT_RUN: no historical version was supplied.'
    }

    Invoke-Scoop @('uninstall', 'qoder-cli')
    $remainingShimFiles = @(Get-ChildItem -LiteralPath $qoderShimDirectory -Filter 'qoder.*' -File -ErrorAction SilentlyContinue)
    if ($remainingShimFiles.Count) { throw "Qoder shim files remained after uninstall: $($remainingShimFiles.FullName -join ', ')" }
    if (Test-Path -LiteralPath $appRoot) { throw "Qoder Scoop app files remained after uninstall: $appRoot" }
    Write-Host 'UNINSTALL=PASS: app directory and Qoder shims were removed.'
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value 'uninstall_test=passed' }
}
finally {
    Restore-ProcessEnvironment
    Remove-TestRootSafely
}

if (Test-Path -LiteralPath $runRoot) {
    throw "CLEANUP=FAIL: temporary test root remains: $runRoot"
}
Write-Host "SCOOP_CLEANUP=PASS: isolated Scoop root, bucket, download cache, and Qoder configuration were removed from $runRoot."
Write-Warning 'TEMP_NATIVE_CACHE=NOT_CLEANED: Qoder may create qodercli-natives-* outside the isolated Scoop test root; no broad TEMP cleanup is attempted.'
if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value @'
### Cleanup status: PARTIAL

The isolated Scoop test root was removed. Qoder may leave `qodercli-natives-*` in the runner TEMP directory outside that root; the test does not delete these paths. This workflow uses a GitHub-hosted runner VM, which GitHub decommissions after the job.
'@
}
Write-Host 'CLEANUP=PARTIAL: isolated Scoop test root removed; external Qoder TEMP native cache is not tracked or deleted.'

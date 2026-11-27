param(
    [ValidateSet('Install', 'Upgrade', 'TestExcludedPathsTransport', 'TestOwnedDirectoryCleanup', 'TestOwnedDirectoryCleanupRace')]
    [string]$Mode = 'Install',
    [string]$PreviousManifestPath,
    [ValidateSet('qoder-cli', 'qoder-cn-cli', 'antigravity-cli', 'antigravity-ide')]
    [string]$Package = 'qoder-cli'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$candidatePath = Join-Path $repoRoot ("bucket\{0}.json" -f $Package)
$candidate = Get-Content -LiteralPath $candidatePath -Raw | ConvertFrom-Json
$packageCommand = switch ($Package) {
    'qoder-cli' { 'qoder' }
    'qoder-cn-cli' { 'qodercn' }
    'antigravity-cli' { 'agy' }
    'antigravity-ide' { 'antigravity-ide' }
}
$packageExecutable = switch ($Package) {
    'qoder-cli' { 'qodercli.exe' }
    'qoder-cn-cli' { 'qoderclicn.exe' }
    'antigravity-cli' { 'agy.exe' }
    'antigravity-ide' { 'Antigravity IDE.exe' }
}
$packageArchivePattern = switch ($Package) {
    'qoder-cli' { '*qodercli-windows-x64*.zip' }
    'qoder-cn-cli' { '*qoderclicn-windows-x64*.zip' }
    'antigravity-cli' { '*agy_cli_windows_x64*.zip' }
    'antigravity-ide' { '*Antigravity*IDE*.exe' }
}

function Test-AbsoluteWindowsPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0 -or $Path.Contains(';')) {
        return $false
    }

    $drivePath = $Path -match '^[A-Za-z]:[\\/]'
    $uncPath = $Path -match '^\\\\[^\\/]+\\[^\\/]+(?:\\.*)?$'
    $extendedDrivePath = $Path -match '^\\\\\?\\[A-Za-z]:[\\/].*$'
    $extendedUncPath = $Path -match '^\\\\\?\\UNC\\[^\\/]+\\[^\\/]+(?:\\.*)?$'
    return ($drivePath -or $uncPath -or $extendedDrivePath -or $extendedUncPath)
}

function Assert-PathWithinTestRoot {
    param([string]$Path, [string]$TestRoot)
    $fullRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath($Path)
    $prefix = $fullRoot + '\'
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Temporary artifact is outside the test root: $fullPath"
    }
}

function Assert-NotReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to use a reparse point in the temporary test tree: $Path"
    }
}

function Assert-NoReparseDirectoryChain {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Could not determine the root of temporary path: $Path"
    }
    Assert-NotReparsePoint -Path $root
    $current = $root
    $remainder = $fullPath.Substring($root.Length).Trim('\')
    foreach ($component in @($remainder -split '\\' | Where-Object { $_ })) {
        $current = Join-Path $current $component
        if (-not (Test-Path -LiteralPath $current -PathType Container)) {
            throw "Temporary directory component does not exist: $current"
        }
        Assert-NotReparsePoint -Path $current
    }
}

function Remove-OwnedDirectoryLinkSafely {
    param([string]$Path, [string]$OwnedRoot)
    Assert-PathWithinTestRoot -Path $Path -TestRoot $OwnedRoot
    $currentItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $currentItem.PSIsContainer -or (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
        throw "Refusing to unlink a path that is not currently a directory reparse point: $Path"
    }
    if (($currentItem.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
        # Scoop marks its current-version junction read-only. Clear that flag on the
        # link object itself (/L), never on the target, before unlinking it.
        $attribCommand = Get-Command 'attrib.exe' -ErrorAction Stop
        & $attribCommand.Source '-R' '/L' $Path
        if ($LASTEXITCODE -ne 0) {
            throw "Could not clear the read-only attribute from the owned directory link: $Path (attrib exit $LASTEXITCODE)"
        }
        $currentItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $currentItem.PSIsContainer -or
            (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) -or
            (($currentItem.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0)) {
            throw "Directory link changed unexpectedly while clearing its read-only flag: $Path"
        }
    }
    [IO.Directory]::Delete($Path, $false)
    if (Test-Path -LiteralPath $Path) {
        throw "Directory reparse point remains after unlink: $Path"
    }
}

function Remove-OwnedDirectoryTreeSafely {
    param([string]$Directory, [string]$OwnedRoot)

    $resolvedDirectory = [IO.Path]::GetFullPath($Directory)
    $resolvedOwnedRootPath = [IO.Path]::GetFullPath($OwnedRoot).TrimEnd('\')
    if ($resolvedDirectory -ine $resolvedOwnedRootPath -and
        -not $resolvedDirectory.StartsWith(($resolvedOwnedRootPath + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to recurse outside the owned test root: $resolvedDirectory"
    }
    $directoryItem = Get-Item -LiteralPath $resolvedDirectory -Force -ErrorAction Stop
    if (-not $directoryItem.PSIsContainer -or (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Refusing to enumerate a missing, non-directory, or reparse directory: $resolvedDirectory"
    }

    $resolvedOwnedRoot = [IO.Path]::GetFullPath($OwnedRoot).TrimEnd('\') + '\'
    $items = @(Get-ChildItem -LiteralPath $resolvedDirectory -Force -ErrorAction Stop)
    foreach ($item in $items) {
        $resolvedItem = [IO.Path]::GetFullPath($item.FullName)
        if (-not $resolvedItem.StartsWith($resolvedOwnedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean an item outside the owned test root: $resolvedItem"
        }

        # Test-only injection runs after enumeration but before the authoritative metadata re-read.
        if ($script:BeforeOwnedChildRecheck -and $item.PSIsContainer -and
            (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
            & $script:BeforeOwnedChildRecheck -ChildPath $resolvedItem
        }

        # Get-ChildItem metadata is only a snapshot. Re-read the current object before
        # deciding whether it is safe to recurse or must be unlinked as a directory link.
        $currentItem = Get-Item -LiteralPath $resolvedItem -Force -ErrorAction Stop
        if (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            if (-not $currentItem.PSIsContainer) {
                throw "Refusing to remove an unsupported file reparse point from the test root: $resolvedItem"
            }
            if ($script:CleanupRaceExpectedReparsePath -and
                $resolvedItem -ieq $script:CleanupRaceExpectedReparsePath) {
                Write-Host "RACE_INJECTION_REPARSEPOINT_RECHECK=PASS: $resolvedItem"
                $script:CleanupRaceExpectedReparsePath = $null
            }
            Remove-OwnedDirectoryLinkSafely -Path $resolvedItem -OwnedRoot $OwnedRoot
        }
        elseif ($currentItem.PSIsContainer) {
            Remove-OwnedDirectoryTreeSafely -Directory $resolvedItem -OwnedRoot $OwnedRoot

            # Re-read after recursion too. Directory.Delete(..., false) never walks a
            # replacement link target and fails safely if the directory is no longer empty.
            $afterRecursion = Get-Item -LiteralPath $resolvedItem -Force -ErrorAction Stop
            if (($afterRecursion.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if (-not $afterRecursion.PSIsContainer) {
                    throw "Directory changed to an unsupported file reparse point during cleanup: $resolvedItem"
                }
                Remove-OwnedDirectoryLinkSafely -Path $resolvedItem -OwnedRoot $OwnedRoot
            }
            elseif ($afterRecursion.PSIsContainer) {
                [IO.Directory]::Delete($resolvedItem, $false)
                if (Test-Path -LiteralPath $resolvedItem) {
                    throw "Directory remains after cleanup: $resolvedItem"
                }
            }
            else {
                throw "Directory changed type during cleanup; refusing removal: $resolvedItem"
            }
        }
        else {
            Remove-Item -LiteralPath $resolvedItem -Force -ErrorAction Stop
        }
    }
}

$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } elseif ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
if (-not (Test-AbsoluteWindowsPath $tempBase)) {
    throw "The temporary base must be an absolute Windows path: $tempBase"
}
$tempBase = [IO.Path]::GetFullPath($tempBase)
if ($tempBase -ne [IO.Path]::GetPathRoot($tempBase)) { $tempBase = $tempBase.TrimEnd('\') }
if (-not [IO.Directory]::Exists($tempBase)) {
    throw "The temporary base directory does not exist: $tempBase"
}
Assert-NoReparseDirectoryChain -Path $tempBase
$runRoot = Join-Path $tempBase ("zev-scoop-{0}-test-{1}" -f $Package, [guid]::NewGuid().ToString('N'))
$runRootCreated = $false
$script:BeforeOwnedChildRecheck = $null
$script:CleanupRaceExpectedReparsePath = $null
$scoopRoot = Join-Path $runRoot 'scoop'
$sourceBucket = Join-Path $runRoot 'source-bucket'
$isolatedConfigHome = Join-Path $runRoot 'config-home'
$isolatedQoderConfig = Join-Path $runRoot 'qoder-config'
$isolatedQoderCnConfig = Join-Path $runRoot 'qoder-cn-config'
$isolatedAntigravityUserProfile = Join-Path $runRoot 'antigravity-user-profile'
$isolatedAntigravityIdeUserProfile = Join-Path $runRoot 'antigravity-ide-user-profile'
$isolatedAntigravityIdeAppData = Join-Path $runRoot 'antigravity-ide-appdata'
$isolatedAntigravityIdeLocalAppData = Join-Path $runRoot 'antigravity-ide-localappdata'
$isolatedCliTemp = Join-Path $runRoot 'cli-temp'
$globalRoot = Join-Path $runRoot 'global'
$cacheRoot = Join-Path $runRoot 'cache'
$bootstrapPath = Join-Path $runRoot 'bootstrap-scoop.ps1'
$excludedPathReaderSource = @'
function Test-AbsoluteWindowsPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0 -or $Path.Contains(';')) {
        return $false
    }

    $drivePath = $Path -match '^[A-Za-z]:[\\/]'
    $uncPath = $Path -match '^\\\\[^\\/]+\\[^\\/]+(?:\\.*)?$'
    $extendedDrivePath = $Path -match '^\\\\\?\\[A-Za-z]:[\\/].*$'
    $extendedUncPath = $Path -match '^\\\\\?\\UNC\\[^\\/]+\\[^\\/]+(?:\\.*)?$'
    return ($drivePath -or $uncPath -or $extendedDrivePath -or $extendedUncPath)
}

function Assert-PathWithinTestRoot {
    param([string]$Path, [string]$TestRoot)
    $fullRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath($Path)
    $prefix = $fullRoot + '\'
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Temporary artifact is outside the test root: $fullPath"
    }
}

function Assert-NotReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to use a reparse point in the temporary test tree: $Path"
    }
}

function Read-ExcludedScoopPaths {
    param(
        [Parameter(Mandatory=$true)][string]$JsonPath,
        [Parameter(Mandatory=$true)][string]$TestRoot
    )

    Assert-PathWithinTestRoot -Path $JsonPath -TestRoot $TestRoot
    Assert-NotReparsePoint -Path $TestRoot
    if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) {
        throw "Excluded Scoop paths JSON file was not found: $JsonPath"
    }
    Assert-NotReparsePoint -Path $JsonPath

    $json = [IO.File]::ReadAllText($JsonPath)
    $index = 0
    while ($index -lt $json.Length -and ($json[$index] -eq ' ' -or $json[$index] -eq "`t" -or $json[$index] -eq "`r" -or $json[$index] -eq "`n")) {
        $index++
    }
    if ($index -ge $json.Length -or $json[$index] -ne '[') {
        throw 'Excluded Scoop paths JSON root must be an array.'
    }

    $index++
    $paths = New-Object 'System.Collections.Generic.List[string]'
    while ($true) {
        while ($index -lt $json.Length -and ($json[$index] -eq ' ' -or $json[$index] -eq "`t" -or $json[$index] -eq "`r" -or $json[$index] -eq "`n")) {
            $index++
        }
        if ($index -ge $json.Length) {
            throw 'Excluded Scoop paths JSON ended before the array was closed.'
        }
        if ($json[$index] -eq ']') {
            $index++
            break
        }
        if ($json[$index] -ne '"') {
            throw 'Each direct element of excluded Scoop paths JSON must be a string.'
        }

        $tokenStart = $index
        $index++
        $closedString = $false
        while ($index -lt $json.Length) {
            $character = $json[$index]
            if ($character -eq '\') {
                if (($index + 1) -ge $json.Length) {
                    throw 'Excluded Scoop paths JSON contains an incomplete string escape.'
                }
                $index += 2
                continue
            }
            if ($character -eq '"') {
                $index++
                $closedString = $true
                break
            }
            if ([int]$character -lt 0x20) {
                throw 'Excluded Scoop paths JSON contains an unescaped control character.'
            }
            $index++
        }
        if (-not $closedString) {
            throw 'Excluded Scoop paths JSON contains an unterminated string.'
        }

        $stringToken = $json.Substring($tokenStart, $index - $tokenStart)
        try {
            $path = ConvertFrom-Json -InputObject $stringToken -ErrorAction Stop
        }
        catch {
            throw "Excluded Scoop paths JSON contains an invalid string escape: $($_.Exception.Message)"
        }
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path)) {
            throw 'Excluded Scoop paths must be non-empty strings.'
        }
        if (-not (Test-AbsoluteWindowsPath $path)) {
            throw "Excluded Scoop path must be an absolute Windows drive or UNC path: $path"
        }
        $paths.Add([string]$path)

        while ($index -lt $json.Length -and ($json[$index] -eq ' ' -or $json[$index] -eq "`t" -or $json[$index] -eq "`r" -or $json[$index] -eq "`n")) {
            $index++
        }
        if ($index -ge $json.Length) {
            throw 'Excluded Scoop paths JSON ended before the array was closed.'
        }
        if ($json[$index] -eq ',') {
            $index++
            while ($index -lt $json.Length -and ($json[$index] -eq ' ' -or $json[$index] -eq "`t" -or $json[$index] -eq "`r" -or $json[$index] -eq "`n")) {
                $index++
            }
            if ($index -ge $json.Length -or $json[$index] -eq ']') {
                throw 'Excluded Scoop paths JSON cannot end with a trailing comma.'
            }
            continue
        }
        if ($json[$index] -eq ']') {
            $index++
            break
        }
        throw 'Excluded Scoop paths JSON must separate string elements with commas.'
    }

    while ($index -lt $json.Length -and ($json[$index] -eq ' ' -or $json[$index] -eq "`t" -or $json[$index] -eq "`r" -or $json[$index] -eq "`n")) {
        $index++
    }
    if ($index -ne $json.Length) {
        throw 'Excluded Scoop paths JSON contains data after the root array.'
    }

    [string[]]$typedPaths = $paths.ToArray()
    return [pscustomobject]@{ Paths = $typedPaths }
}
'@
$previousEnvironment = @{}
foreach ($name in @('SCOOP', 'SCOOP_GLOBAL', 'SCOOP_CACHE', 'SCOOP_REPO', 'XDG_CONFIG_HOME', 'QODER_CONFIG_DIR', 'QODERCN_CONFIG_DIR', 'AGY_CLI_DISABLE_AUTO_UPDATE', 'RUNNER_TEMP', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP', 'PATH')) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$previousUserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$previousMachinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')

function Invoke-Scoop([string[]]$Arguments) {
    Write-Host ("COMMAND: scoop {0}" -f ($Arguments -join ' '))
    $output = @(& scoop @Arguments 2>&1)
    $output | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "scoop $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Get-FileSha256([string]$Path) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
        $algorithm.Dispose()
    }
}

function Invoke-IsolatedPackageCommand {
    param([string]$CommandName, [string[]]$Arguments)

    $scopedNames = @('TEMP', 'TMP')
    if ($Package -eq 'antigravity-cli') { $scopedNames += 'USERPROFILE' }
    elseif ($Package -eq 'antigravity-ide') { $scopedNames += @('USERPROFILE', 'APPDATA', 'LOCALAPPDATA') }
    $saved = @{}
    foreach ($name in $scopedNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        [Environment]::SetEnvironmentVariable('TEMP', $isolatedCliTemp, 'Process')
        [Environment]::SetEnvironmentVariable('TMP', $isolatedCliTemp, 'Process')
        if ($Package -eq 'antigravity-cli') {
            [Environment]::SetEnvironmentVariable('USERPROFILE', $isolatedAntigravityUserProfile, 'Process')
        }
        elseif ($Package -eq 'antigravity-ide') {
            [Environment]::SetEnvironmentVariable('USERPROFILE', $isolatedAntigravityIdeUserProfile, 'Process')
            [Environment]::SetEnvironmentVariable('APPDATA', $isolatedAntigravityIdeAppData, 'Process')
            [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $isolatedAntigravityIdeLocalAppData, 'Process')
        }
        $output = @(& $CommandName @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $output | ForEach-Object { Write-Host $_ }
        return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join "`n") }
    }
    finally {
        foreach ($name in $scopedNames) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
    }
}

function Assert-CliVersion([string]$ExpectedVersion, [string]$CommandName) {
    $result = Invoke-IsolatedPackageCommand -CommandName $CommandName -Arguments @('--version')
    if ($Package -eq 'antigravity-ide') {
        if ($result.ExitCode -ne 0 -or $result.Output -notmatch '\d+\.\d+\.\d+') {
            throw "$CommandName --version did not report a valid core version (exit $($result.ExitCode)): $($result.Output)"
        }
        $currentDir = Join-Path $scoopRoot ("apps\{0}\current" -f $Package)
        $productPath = Join-Path $currentDir 'resources\app\product.json'
        if (-not (Test-Path -LiteralPath $productPath -PathType Leaf)) {
            throw "Antigravity IDE product.json was not found: $productPath"
        }
        $productRaw = Get-Content -LiteralPath $productPath -Raw -ErrorAction Stop
        $productJson = $productRaw | ConvertFrom-Json -ErrorAction Stop
        $exePath = Join-Path $currentDir $packageExecutable
        $versionInfo = (Get-Item -LiteralPath $exePath -ErrorAction Stop).VersionInfo
        $escapedVersion = [regex]::Escape($ExpectedVersion)
        $matched = ($productRaw -match $escapedVersion) -or
            ([string]$versionInfo.ProductVersion -match $escapedVersion) -or
            ([string]$versionInfo.FileVersion -match $escapedVersion)
        if (-not $matched) {
            $productVersionKeys = ($productJson.PSObject.Properties | Where-Object { $_.Name -match 'version' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
            throw "Antigravity IDE metadata did not report $ExpectedVersion (ProductVersion=$($versionInfo.ProductVersion), FileVersion=$($versionInfo.FileVersion), product.json=[$productVersionKeys])"
        }
        $coreOutput = ($result.Output -replace '\r?\n', ' ').Trim()
        Write-Host "ANTIGRAVITY_IDE_VERSION=PASS: $ExpectedVersion (CLI core output: $coreOutput)"
        return
    }
    if ($result.ExitCode -ne 0 -or $result.Output -notmatch [regex]::Escape($ExpectedVersion)) {
        throw "$CommandName --version did not report ${ExpectedVersion} (exit $($result.ExitCode)): $($result.Output)"
    }
}

function Restore-ProcessEnvironment {
    foreach ($name in $previousEnvironment.Keys) {
        $previousValue = $previousEnvironment[$name]
        if ($null -eq $previousValue) {
            $environmentPath = "Env:$name"
            if (Test-Path -LiteralPath $environmentPath) {
                Remove-Item -LiteralPath $environmentPath -ErrorAction Stop
            }
        }
        else {
            [Environment]::SetEnvironmentVariable($name, $previousValue, 'Process')
        }
    }
}

function Assert-EnvironmentUnchanged {
    $differences = @()
    foreach ($name in $previousEnvironment.Keys) {
        $current = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($current -cne $previousEnvironment[$name]) {
            $differences += "process:$name"
        }
    }
    if ([Environment]::GetEnvironmentVariable('PATH', 'User') -cne $previousUserPath) {
        $differences += 'user:PATH'
    }
    if ([Environment]::GetEnvironmentVariable('PATH', 'Machine') -cne $previousMachinePath) {
        $differences += 'machine:PATH'
    }
    if ($differences.Count) {
        throw "ISOLATION_STATE_UNCHANGED=False: $($differences -join ', ')"
    }
    Write-Host 'ISOLATION_STATE_UNCHANGED=True: tracked process variables and user/machine PATH match their initial snapshots.'
}

function New-TestRootSafely {
    if (-not (Test-AbsoluteWindowsPath $runRoot)) {
        throw "Test root is not an absolute Windows path: $runRoot"
    }
    if (Test-Path -LiteralPath $runRoot) {
        throw "Refusing to reuse an existing test root: $runRoot"
    }
    New-Item -ItemType Directory -Path $runRoot -ErrorAction Stop | Out-Null
    $script:runRootCreated = $true
    $resolvedBase = [IO.Path]::GetFullPath($tempBase)
    if ($resolvedBase -ne [IO.Path]::GetPathRoot($resolvedBase)) { $resolvedBase = $resolvedBase.TrimEnd('\') }
    $resolvedRoot = [IO.Path]::GetFullPath($runRoot).TrimEnd('\')
    if (-not $resolvedRoot.StartsWith(($resolvedBase.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Created test root is outside the temporary base: $resolvedRoot"
    }
    if ([IO.Directory]::GetParent($resolvedRoot).FullName.TrimEnd('\') -ine $resolvedBase.TrimEnd('\')) {
        throw "Created test root is not a direct child of the temporary base: $resolvedRoot"
    }
    Assert-NoReparseDirectoryChain -Path $runRoot
}

function Write-NewTestFileSafely {
    param([string]$Path, [string]$Content)
    Assert-PathWithinTestRoot -Path $Path -TestRoot $runRoot
    Assert-NotReparsePoint -Path $runRoot
    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to overwrite an existing temporary test file: $Path"
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $stream.Dispose()
    }
    Assert-NotReparsePoint -Path $Path
}

function ConvertTo-QuotedProcessArgument([string]$Argument) {
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            if ($backslashes) { [void]$builder.Append(('\' * (($backslashes * 2) + 1))) }
            else { [void]$builder.Append('\') }
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes) { [void]$builder.Append(('\' * $backslashes)) }
        [void]$builder.Append($character)
        $backslashes = 0
    }
    if ($backslashes) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-CapturedProcess {
    param([string]$Executable, [string[]]$ArgumentList)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-QuotedProcessArgument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Could not start child process: $Executable" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.Result
            StdErr = $stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function Remove-TestRootSafely {
    if (-not $runRootCreated) { return }
    if (-not (Test-Path -LiteralPath $runRoot -PathType Container)) {
        throw "The test root created by this run is missing: $runRoot"
    }
    $resolvedRoot = [IO.Path]::GetFullPath($runRoot).TrimEnd('\')
    $resolvedBasePath = [IO.Path]::GetFullPath($tempBase)
    if ($resolvedBasePath -ne [IO.Path]::GetPathRoot($resolvedBasePath)) { $resolvedBasePath = $resolvedBasePath.TrimEnd('\') }
    $resolvedBase = $resolvedBasePath.TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($resolvedBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove test directory outside the temporary base: $resolvedRoot"
    }
    if ($resolvedRoot -eq [IO.Path]::GetFullPath($tempBase).TrimEnd('\')) {
        throw 'Refusing to remove the temporary base directory itself.'
    }
    if ([IO.Directory]::GetParent($resolvedRoot).FullName.TrimEnd('\') -ine $resolvedBase.TrimEnd('\')) {
        throw "Refusing to remove a test directory that is not a direct child of the temporary base: $resolvedRoot"
    }
    Assert-NoReparseDirectoryChain -Path $tempBase
    Assert-NoReparseDirectoryChain -Path $resolvedRoot
    Remove-OwnedDirectoryTreeSafely -Directory $resolvedRoot -OwnedRoot $resolvedRoot
    Remove-Item -LiteralPath $resolvedRoot -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $resolvedRoot) {
        throw "The test root remains after cleanup: $resolvedRoot"
    }
    $script:runRootCreated = $false
}

if ($Mode -eq 'TestExcludedPathsTransport') {
    try {
        New-TestRootSafely
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $transportPowerShell = Join-Path $PSHOME 'pwsh.exe'
        }
        else {
            $transportPowerShell = Join-Path $PSHOME 'powershell.exe'
        }
        if (-not (Test-Path -LiteralPath $transportPowerShell)) {
            throw "Could not locate the current PowerShell host executable under PSHOME: $PSHOME"
        }
        $childPath = Join-Path $runRoot 'excluded-path-transport-child.ps1'
        $childContent = @'
param(
    [Parameter(Mandatory=$true)][string]$ExcludedScoopPathsJsonPath,
    [Parameter(Mandatory=$true)][string]$TestRoot,
    [Parameter(Mandatory=$true)][string]$InitialPath
)
$ErrorActionPreference = 'Stop'
__EXCLUDED_PATH_READER__
$excludedScoopPaths = (Read-ExcludedScoopPaths -JsonPath $ExcludedScoopPathsJsonPath -TestRoot $TestRoot).Paths
$env:PATH = $InitialPath
$env:PATH = (($env:PATH -split ';' | Where-Object {
    $_ -and ($excludedScoopPaths -notcontains $_.TrimEnd('\'))
}) -join ';')
[Console]::Out.WriteLine($excludedScoopPaths.GetType().FullName)
[Console]::Out.WriteLine([string]$excludedScoopPaths.Count)
[Console]::Out.Write($env:PATH)
'@
        $childContent = $childContent.Replace('__EXCLUDED_PATH_READER__', $excludedPathReaderSource)
        Write-NewTestFileSafely -Path $childPath -Content $childContent

        function Invoke-ExcludedPathTransportCase {
            param(
                [Parameter(Mandatory=$true)][string]$Name,
                [Parameter(Mandatory=$true)][string]$InitialPath,
                [string[]]$Paths = @(),
                [string]$ExpectedPath,
                [ValidateSet('Valid', 'RawJson', 'Missing')][string]$InputKind = 'Valid',
                [string]$RawJson,
                [string]$ExpectedError
            )

            $jsonPath = Join-Path $runRoot ("excluded-paths-{0}.json" -f [guid]::NewGuid().ToString('N'))
            if ($InputKind -eq 'Valid') {
                $serialized = ConvertTo-Json -InputObject ([string[]]$Paths) -Compress
                Write-NewTestFileSafely -Path $jsonPath -Content $serialized
                if ($Paths.Count -eq 0 -and $serialized -ne '[]') {
                    throw "${Name}: empty paths did not serialize as [] (got '$serialized')."
                }
            } elseif ($InputKind -eq 'RawJson') {
                Write-NewTestFileSafely -Path $jsonPath -Content $RawJson
            }

            $processResult = Invoke-CapturedProcess -Executable $transportPowerShell -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $childPath,
                '-ExcludedScoopPathsJsonPath', $jsonPath, '-TestRoot', $runRoot, '-InitialPath', $InitialPath
            )
            if ($InputKind -eq 'Valid') {
                if ($processResult.ExitCode -ne 0) {
                    throw "${Name}: child PowerShell failed ($($processResult.ExitCode)): $($processResult.StdErr)"
                }
                if (-not [string]::IsNullOrEmpty($processResult.StdErr)) {
                    throw "${Name}: child PowerShell wrote unexpected stderr: $($processResult.StdErr)"
                }
                $outputLines = $processResult.StdOut -split "`r?`n", 3
                if ($outputLines.Count -ne 3 -or $outputLines[0] -cne 'System.String[]') {
                    throw "${Name}: child did not return a string[] (output: $($processResult.StdOut))."
                }
                if ([int]$outputLines[1] -ne $Paths.Count) {
                    throw "${Name}: expected $($Paths.Count) paths, got $($outputLines[1])."
                }
                if ($outputLines[2] -cne $ExpectedPath) {
                    throw "${Name}: expected filtered PATH '$ExpectedPath', got '$($outputLines[2])'."
                }
            }
            else {
                if ($processResult.ExitCode -eq 0) { throw "${Name}: invalid input unexpectedly succeeded." }
                if ([string]::IsNullOrWhiteSpace($processResult.StdErr)) {
                    throw "${Name}: child failed without reporting an error."
                }
                if ($ExpectedError -and $processResult.StdErr -notmatch [regex]::Escape($ExpectedError)) {
                    throw "${Name}: expected error '$ExpectedError', got '$($processResult.StdErr)'."
                }
                if (-not [string]::IsNullOrEmpty($processResult.StdOut)) {
                    throw "${Name}: invalid input unexpectedly wrote stdout: $($processResult.StdOut)"
                }
            }
            Write-Host "PASS: $Name"
        }

        Invoke-ExcludedPathTransportCase -Name 'empty array' `
            -InitialPath 'C:\Keep One;D:\Keep Two' -Paths @() -ExpectedPath 'C:\Keep One;D:\Keep Two'
        Invoke-ExcludedPathTransportCase -Name 'single path' `
            -InitialPath 'C:\Keep;C:\Apps\Scoop\shims;D:\Keep' `
            -Paths @('C:\Apps\Scoop\shims') -ExpectedPath 'C:\Keep;D:\Keep'
        Invoke-ExcludedPathTransportCase -Name 'multiple paths' `
            -InitialPath 'C:\Keep;C:\Apps\Scoop\shims;D:\Tools\Scoop\shims;E:\Keep' `
            -Paths @('C:\Apps\Scoop\shims', 'D:\Tools\Scoop\shims') -ExpectedPath 'C:\Keep;E:\Keep'
        Invoke-ExcludedPathTransportCase -Name 'path containing spaces' `
            -InitialPath 'C:\Keep;C:\Program Files\Scoop App\shims;D:\Keep' `
            -Paths @('C:\Program Files\Scoop App\shims') -ExpectedPath 'C:\Keep;D:\Keep'
        Invoke-ExcludedPathTransportCase -Name 'UNC path' `
            -InitialPath 'C:\Keep;\\server\share\Tools Folder\shims;D:\Keep' `
            -Paths @('\\server\share\Tools Folder\shims') -ExpectedPath 'C:\Keep;D:\Keep'
        Invoke-ExcludedPathTransportCase -Name 'nested array rejected' -InitialPath 'C:\Keep' -InputKind RawJson `
            -RawJson '[["C:\\Scoop"]]' -ExpectedError 'Each direct element'
        Invoke-ExcludedPathTransportCase -Name 'object rejected' -InitialPath 'C:\Keep' -InputKind RawJson `
            -RawJson '{"path":"C:\\Scoop"}' -ExpectedError 'root must be an array'
        Invoke-ExcludedPathTransportCase -Name 'null rejected' -InitialPath 'C:\Keep' -InputKind RawJson `
            -RawJson 'null' -ExpectedError 'root must be an array'
        Invoke-ExcludedPathTransportCase -Name 'number rejected' -InitialPath 'C:\Keep' -InputKind RawJson `
            -RawJson '42' -ExpectedError 'root must be an array'
        Invoke-ExcludedPathTransportCase -Name 'boolean rejected' -InitialPath 'C:\Keep' -InputKind RawJson `
            -RawJson 'true' -ExpectedError 'root must be an array'
        Invoke-ExcludedPathTransportCase -Name 'number array element rejected' -InitialPath 'C:\Keep' -InputKind RawJson `
            -RawJson '[42]' -ExpectedError 'Each direct element'
        Invoke-ExcludedPathTransportCase -Name 'empty string rejected' -InitialPath 'C:\Keep' -InputKind RawJson `
            -RawJson '["" ]' -ExpectedError 'non-empty strings'
        Invoke-ExcludedPathTransportCase -Name 'whitespace string rejected' -InitialPath 'C:\Keep' -InputKind RawJson `
            -RawJson '["   "]' -ExpectedError 'non-empty strings'
        Invoke-ExcludedPathTransportCase -Name 'relative dot rejected' -InitialPath 'C:\Keep' -InputKind RawJson `
            -RawJson '["."]' -ExpectedError 'absolute Windows drive or UNC path'
        Invoke-ExcludedPathTransportCase -Name 'relative dot-dot rejected' -InitialPath 'C:\Keep' -InputKind RawJson `
            -RawJson '[".."]' -ExpectedError 'absolute Windows drive or UNC path'
        Invoke-ExcludedPathTransportCase -Name 'drive-relative path rejected' -InitialPath 'C:\Keep' -InputKind RawJson `
            -RawJson '["C:relative"]' -ExpectedError 'absolute Windows drive or UNC path'
        Invoke-ExcludedPathTransportCase -Name 'missing JSON file' `
            -InitialPath 'C:\Keep' -InputKind Missing -ExpectedError 'Excluded Scoop paths JSON file was not found'
        Invoke-ExcludedPathTransportCase -Name 'invalid JSON' -InitialPath 'C:\Keep' -InputKind RawJson `
            -RawJson '{"paths":'

        $restoreProbeNames = @('SCOOP', 'SCOOP_GLOBAL', 'SCOOP_CACHE', 'SCOOP_REPO', 'XDG_CONFIG_HOME', 'QODER_CONFIG_DIR')
        foreach ($name in $restoreProbeNames) {
            [Environment]::SetEnvironmentVariable($name, 'zev-scoop-process-env-restore-probe', 'Process')
        }
        Restore-ProcessEnvironment
        foreach ($name in $restoreProbeNames) {
            $restoredValue = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ($restoredValue -cne $previousEnvironment[$name]) {
                throw "Process environment restore probe failed for $name."
            }
        }
        Write-Host 'PROCESS_ENV_RESTORE=PASS: tracked values and originally absent variables were restored.'
    }
    finally {
        try { Remove-TestRootSafely }
        finally { Assert-EnvironmentUnchanged }
    }
    Write-Host 'TRANSPORT_TEST=PASS: all JSON transport cases; unique temporary root removed.'
    return
}

if ($Mode -eq 'TestOwnedDirectoryCleanup') {
    $testStartedUtc = [DateTime]::UtcNow.ToString('o')
    Write-Host "TEST_SCENARIO=Owned directory Junction cleanup"
    Write-Host "TEST_STARTED_UTC=$testStartedUtc"
    Write-Host "POWERSHELL_VERSION=$($PSVersionTable.PSVersion)"
    $targetRoot = Join-Path $tempBase ("zev-scoop-qoder-cli-target-{0}" -f [guid]::NewGuid().ToString('N'))
    $junctionPath = Join-Path $runRoot 'junction'
    $targetRootCreated = $false
    $cleanupAttempted = $false
    $runRootCleaned = $false
    $sentinelText = 'zev-scoop-owned-directory-junction-sentinel-v1'
    $sentinelPath = Join-Path $targetRoot 'sentinel.txt'
    $failureMessage = $null

    try {
        New-TestRootSafely
        Write-Host "RUN_ROOT=$runRoot"
        Write-Host "TARGET_ROOT=$targetRoot"
        Write-Host "JUNCTION_PATH=$junctionPath"
        if (Test-Path -LiteralPath $targetRoot) {
            throw "Refusing to reuse an existing target directory: $targetRoot"
        }
        New-Item -ItemType Directory -Path $targetRoot -ErrorAction Stop | Out-Null
        $targetRootCreated = $true
        Assert-NoReparseDirectoryChain -Path $targetRoot
        [IO.File]::WriteAllText($sentinelPath, $sentinelText, [Text.UTF8Encoding]::new($false))
        $sentinelHashBefore = Get-FileSha256 -Path $sentinelPath
        Write-Host "SENTINEL_SHA256_BEFORE=$sentinelHashBefore"
        Write-Host 'ASSERT=target and sentinel created under a unique GUID path: PASS'

        New-Item -ItemType Junction -Path $junctionPath -Target $targetRoot -ErrorAction Stop | Out-Null
        $junctionItem = Get-Item -LiteralPath $junctionPath -Force -ErrorAction Stop
        if (-not $junctionItem.PSIsContainer -or (($junctionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
            throw "Created Junction is not a directory ReparsePoint: $junctionPath"
        }
        $attribCommand = Get-Command 'attrib.exe' -ErrorAction Stop
        & $attribCommand.Source '+R' '/L' $junctionPath
        if ($LASTEXITCODE -ne 0) { throw "Could not mark the test Junction read-only: $junctionPath" }
        $junctionItem = Get-Item -LiteralPath $junctionPath -Force -ErrorAction Stop
        if (($junctionItem.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) {
            throw "The test Junction did not retain its read-only attribute: $junctionPath"
        }
        Write-Host 'ASSERT=read-only Junction flag set on link object: PASS'
        Write-Host 'ASSERT=Junction created and marked ReparsePoint: PASS'

        $cleanupAttempted = $true
        Remove-TestRootSafely
        $runRootCleaned = $true
        Write-Host 'ASSERT=Remove-TestRootSafely removed the owned runRoot: PASS'
        if (Test-Path -LiteralPath $runRoot) { throw "runRoot remains after cleanup: $runRoot" }
        Write-Host 'ASSERT=runRoot absent: PASS'
        if (Test-Path -LiteralPath $junctionPath) { throw "Junction remains after cleanup: $junctionPath" }
        Write-Host 'ASSERT=Junction absent: PASS'
        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { throw "Junction target was removed: $targetRoot" }
        if (-not (Test-Path -LiteralPath $sentinelPath -PathType Leaf)) { throw "Junction target sentinel was removed: $sentinelPath" }
        $sentinelHashAfter = Get-FileSha256 -Path $sentinelPath
        Write-Host "SENTINEL_SHA256_AFTER=$sentinelHashAfter"
        if ($sentinelHashAfter -cne $sentinelHashBefore) {
            throw "Junction target sentinel SHA256 changed: before=$sentinelHashBefore after=$sentinelHashAfter"
        }
        Write-Host 'ASSERT=targetRoot and sentinel remain unchanged: PASS'
    }
    catch {
        $failureMessage = $_.Exception.Message
        Write-Host "TEST_ERROR=$failureMessage"
    }

    if (-not $cleanupAttempted -and $runRootCreated) {
        $cleanupAttempted = $true
        try {
            Remove-TestRootSafely
            $runRootCleaned = $true
            Write-Host 'FAILURE_CLEANUP=owned runRoot safely removed: PASS'
        }
        catch {
            $failureMessage = @($failureMessage, "Safe runRoot cleanup failed: $($_.Exception.Message)") -join ' | '
            Write-Host "FAILURE_CLEANUP=FAIL: $($_.Exception.Message)"
        }
    }

    if ($runRootCleaned -and $targetRootCreated -and (Test-Path -LiteralPath $targetRoot)) {
        try {
            Assert-NoReparseDirectoryChain -Path $targetRoot
            $targetItems = @(Get-ChildItem -LiteralPath $targetRoot -Force -ErrorAction Stop)
            if ($targetItems.Count -ne 1 -or $targetItems[0].FullName -ine $sentinelPath -or
                (($targetItems[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw "Refusing target cleanup because targetRoot contents differ from the single test sentinel: $targetRoot"
            }
            Remove-Item -LiteralPath $sentinelPath -Force -ErrorAction Stop
            Remove-Item -LiteralPath $targetRoot -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $targetRoot) { throw "targetRoot remains after cleanup: $targetRoot" }
            Write-Host 'TEMP_CLEANUP=PASS: only this runRoot and targetRoot were removed.'
        }
        catch {
            $failureMessage = @($failureMessage, "Safe targetRoot cleanup failed: $($_.Exception.Message)") -join ' | '
            Write-Host "TEMP_CLEANUP=FAIL: $($_.Exception.Message)"
        }
    }

    if ($runRootCleaned -and -not (Test-Path -LiteralPath $runRoot) -and
        -not (Test-Path -LiteralPath $junctionPath) -and -not (Test-Path -LiteralPath $targetRoot)) {
        Write-Host 'TEMP_CLEANUP_STATE=PASS'
    }
    else {
        Write-Host "TEMP_CLEANUP_STATE=PARTIAL; runRootExists=$(Test-Path -LiteralPath $runRoot); targetRootExists=$(Test-Path -LiteralPath $targetRoot)"
    }
    Assert-EnvironmentUnchanged
    if ($failureMessage) { throw $failureMessage }
    Write-Host 'JUNCTION_CLEANUP_TEST=PASS'
    return
}

if ($Mode -eq 'TestOwnedDirectoryCleanupRace') {
    $testStartedUtc = [DateTime]::UtcNow.ToString('o')
    Write-Host 'TEST_SCENARIO=Owned directory replacement with Junction before recursive descent'
    Write-Host "TEST_STARTED_UTC=$testStartedUtc"
    Write-Host "POWERSHELL_VERSION=$($PSVersionTable.PSVersion)"
    $targetRoot = Join-Path $tempBase ("zev-scoop-qoder-cli-race-target-{0}" -f [guid]::NewGuid().ToString('N'))
    $childPath = Join-Path $runRoot 'child'
    $sentinelPath = Join-Path $targetRoot 'sentinel.txt'
    $sentinelText = 'zev-scoop-cleanup-race-sentinel-v1'
    $targetRootCreated = $false
    $hookInvoked = $false
    $failureMessage = $null

    try {
        New-TestRootSafely
        Write-Host "RUN_ROOT=$runRoot"
        Write-Host "CHILD_PATH=$childPath"
        Write-Host "EXTERNAL_TARGET=$targetRoot"
        if (Test-Path -LiteralPath $targetRoot) {
            throw "Refusing to reuse an existing race target directory: $targetRoot"
        }
        New-Item -ItemType Directory -Path $targetRoot -ErrorAction Stop | Out-Null
        $targetRootCreated = $true
        Assert-NoReparseDirectoryChain -Path $targetRoot
        [IO.File]::WriteAllText($sentinelPath, $sentinelText, [Text.UTF8Encoding]::new($false))
        $sentinelHashBefore = Get-FileSha256 -Path $sentinelPath
        Write-Host "SENTINEL_SHA256_BEFORE=$sentinelHashBefore"

        New-Item -ItemType Directory -Path $childPath -ErrorAction Stop | Out-Null
        Assert-NoReparseDirectoryChain -Path $childPath
        $script:cleanupRaceChildPath = $childPath
        $script:cleanupRaceTargetRoot = $targetRoot
        $script:cleanupRaceHookInvoked = $false
        $script:CleanupRaceExpectedReparsePath = $null
        $script:BeforeOwnedChildRecheck = {
            param([string]$ChildPath)
            if ($ChildPath -ine $script:cleanupRaceChildPath) { return }
            if ($script:cleanupRaceHookInvoked) { throw "Race injection ran more than once for $ChildPath" }
            $script:cleanupRaceHookInvoked = $true
            [IO.Directory]::Delete($ChildPath, $false)
            New-Item -ItemType Junction -Path $ChildPath -Target $script:cleanupRaceTargetRoot -ErrorAction Stop | Out-Null
            $script:CleanupRaceExpectedReparsePath = $ChildPath
            Write-Host "INJECTION=ordinary child replaced with Junction after enumeration: $ChildPath"
        }

        # The actual cleaner enumerates runRoot, invokes the test-only hook, then must
        # re-read attributes and unlink the Junction instead of recursing into its target.
        Remove-TestRootSafely
        $hookInvoked = $script:cleanupRaceHookInvoked
        if (-not $hookInvoked) { throw 'The deterministic directory replacement injection did not run.' }
        if ($script:CleanupRaceExpectedReparsePath) {
            throw 'The cleaner did not consume the expected Junction reparse-point observation.'
        }
        Write-Host 'ASSERT=real Remove-TestRootSafely re-read the replaced child as a ReparsePoint: PASS'
        if (Test-Path -LiteralPath $runRoot) { throw "runRoot remains after race cleanup: $runRoot" }
        if (Test-Path -LiteralPath $childPath) { throw "Injected Junction remains after cleanup: $childPath" }
        Write-Host 'ASSERT=runRoot and injected Junction absent: PASS'
        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container) -or
            -not (Test-Path -LiteralPath $sentinelPath -PathType Leaf)) {
            throw 'The external target or its sentinel was removed by cleanup.'
        }
        $sentinelHashAfter = Get-FileSha256 -Path $sentinelPath
        Write-Host "SENTINEL_SHA256_AFTER=$sentinelHashAfter"
        if ($sentinelHashAfter -cne $sentinelHashBefore) {
            throw "External sentinel changed: before=$sentinelHashBefore after=$sentinelHashAfter"
        }
        Write-Host 'ASSERT=external target and sentinel SHA256 unchanged: PASS'
    }
    catch {
        $failureMessage = $_.Exception.Message
        Write-Host "TEST_ERROR=$failureMessage"
    }
    finally {
        $script:BeforeOwnedChildRecheck = $null
        $script:CleanupRaceExpectedReparsePath = $null
        if ($runRootCreated -and (Test-Path -LiteralPath $runRoot -PathType Container)) {
            try {
                Remove-TestRootSafely
                Write-Host 'FAILURE_CLEANUP=owned runRoot safely removed: PASS'
            }
            catch {
                $failureMessage = @($failureMessage, "Safe runRoot cleanup failed: $($_.Exception.Message)") -join ' | '
                Write-Host "FAILURE_CLEANUP=FAIL: $($_.Exception.Message)"
            }
        }
        if ($targetRootCreated -and (Test-Path -LiteralPath $targetRoot -PathType Container)) {
            try {
                Assert-NoReparseDirectoryChain -Path $targetRoot
                $targetItems = @(Get-ChildItem -LiteralPath $targetRoot -Force -ErrorAction Stop)
                if ($targetItems.Count -ne 1 -or $targetItems[0].FullName -ine $sentinelPath -or
                    (($targetItems[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                    throw "Refusing race test target cleanup because its contents changed: $targetRoot"
                }
                if ($sentinelHashBefore -and (Get-FileSha256 -Path $sentinelPath) -cne $sentinelHashBefore) {
                    throw "Refusing race test target cleanup because sentinel changed: $sentinelPath"
                }
                Remove-Item -LiteralPath $sentinelPath -Force -ErrorAction Stop
                [IO.Directory]::Delete($targetRoot, $false)
                if (Test-Path -LiteralPath $targetRoot) { throw "Race target remains after cleanup: $targetRoot" }
                Write-Host 'TEMP_CLEANUP=PASS: only this runRoot and externalTarget were removed.'
            }
            catch {
                $failureMessage = @($failureMessage, "Safe targetRoot cleanup failed: $($_.Exception.Message)") -join ' | '
                Write-Host "TEMP_CLEANUP=FAIL: $($_.Exception.Message)"
            }
        }
        Assert-EnvironmentUnchanged
    }

    if ($failureMessage) { throw $failureMessage }
    if ((Test-Path -LiteralPath $runRoot) -or (Test-Path -LiteralPath $targetRoot)) {
        throw 'TEMP_CLEANUP_STATE=FAIL: one or more owned race-test directories remain.'
    }
    Write-Host 'TEMP_CLEANUP_STATE=PASS'
    Write-Host 'OWNED_DIRECTORY_CLEANUP_RACE_TEST=PASS'
    return
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
    New-TestRootSafely
    $manifestDirectory = Join-Path $sourceBucket 'bucket'
    New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    $testManifest = if ($Mode -eq 'Upgrade') { (Resolve-Path -LiteralPath $PreviousManifestPath).Path } else { $candidatePath }
    $bucketManifestPath = Join-Path $manifestDirectory ("{0}.json" -f $Package)
    Copy-Item -LiteralPath $testManifest -Destination $bucketManifestPath

    # Keep all Scoop and package-specific CLI settings under this unique temporary directory.
    $env:SCOOP = $scoopRoot
    $env:SCOOP_GLOBAL = $globalRoot
    $env:SCOOP_REPO = 'https://github.com/ScoopInstaller/Scoop'
    $env:XDG_CONFIG_HOME = $isolatedConfigHome
    New-Item -ItemType Directory -Path $isolatedConfigHome, $globalRoot, $cacheRoot, $isolatedCliTemp -Force | Out-Null
    if ($Package -eq 'antigravity-cli') {
        New-Item -ItemType Directory -Path $isolatedAntigravityUserProfile -ErrorAction Stop | Out-Null
        Write-Host "ANTIGRAVITY_CONFIG_ISOLATION=PROCESS_USERPROFILE: $isolatedAntigravityUserProfile"
    }
    elseif ($Package -eq 'antigravity-ide') {
        New-Item -ItemType Directory -Path $isolatedAntigravityIdeUserProfile, $isolatedAntigravityIdeAppData, $isolatedAntigravityIdeLocalAppData -ErrorAction Stop | Out-Null
        Write-Host "ANTIGRAVITY_IDE_CONFIG_ISOLATION=PROCESS_PROFILES: $isolatedAntigravityIdeUserProfile"
    }
    if ($Package -eq 'qoder-cli') {
        $env:QODER_CONFIG_DIR = $isolatedQoderConfig
        New-Item -ItemType Directory -Path $isolatedQoderConfig -Force | Out-Null
        $qoderSettingsPath = Join-Path $isolatedQoderConfig 'settings.json'
        $qoderSettings = @{ general = @{ enableAutoUpdate = $false } } | ConvertTo-Json -Depth 3
        [IO.File]::WriteAllText($qoderSettingsPath, $qoderSettings + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        $writtenQoderSettings = Get-Content -LiteralPath $qoderSettingsPath -Raw | ConvertFrom-Json
        if ($writtenQoderSettings.general.enableAutoUpdate -ne $false) { throw 'The isolated Qoder settings did not disable automatic updates.' }
        Write-Host "QODER_AUTO_UPDATE_ISOLATION=CONFIGURED: $qoderSettingsPath"
    }
    elseif ($Package -eq 'qoder-cn-cli') {
        $env:QODERCN_CONFIG_DIR = $isolatedQoderCnConfig
        New-Item -ItemType Directory -Path $isolatedQoderCnConfig -Force | Out-Null
        $qoderCnSettingsPath = Join-Path $isolatedQoderCnConfig 'settings.json'
        $qoderCnSettings = @{ general = @{ enableAutoUpdate = $false } } | ConvertTo-Json -Depth 3
        [IO.File]::WriteAllText($qoderCnSettingsPath, $qoderCnSettings + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        $writtenQoderCnSettings = Get-Content -LiteralPath $qoderCnSettingsPath -Raw | ConvertFrom-Json
        if ($writtenQoderCnSettings.general.enableAutoUpdate -ne $false) { throw 'The isolated Qoder CN settings did not disable automatic updates.' }
        Write-Host "QODER_CN_AUTO_UPDATE_ISOLATION=CONFIGURED: $qoderCnSettingsPath"
    }

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
    $excludedScoopPathsJsonPath = Join-Path $runRoot 'excluded-scoop-paths.json'
    $excludedScoopPathsJson = ConvertTo-Json -InputObject ([string[]]$excludedScoopPaths) -Compress
    Write-NewTestFileSafely -Path $excludedScoopPathsJsonPath -Content $excludedScoopPathsJson
    if ($excludedScoopPaths.Count -eq 0 -and $excludedScoopPathsJson -ne '[]') {
        throw "Empty excluded Scoop path list did not serialize as [] (got '$excludedScoopPathsJson')."
    }
    $bootstrapContent = @'
param(
    [Parameter(Mandatory=$true)][string]$InstallerPath,
    [Parameter(Mandatory=$true)][string]$ScoopRoot,
    [Parameter(Mandatory=$true)][string]$GlobalRoot,
    [Parameter(Mandatory=$true)][string]$CacheRoot,
    [Parameter(Mandatory=$true)][string]$ConfigHome,
    [Parameter(Mandatory=$true)][string]$ExcludedScoopPathsJsonPath,
    [Parameter(Mandatory=$true)][string]$TestRoot
)
$ErrorActionPreference = 'Stop'
__EXCLUDED_PATH_READER__
$ExcludedScoopPaths = (Read-ExcludedScoopPaths -JsonPath $ExcludedScoopPathsJsonPath -TestRoot $TestRoot).Paths
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
    $bootstrapContent = $bootstrapContent.Replace('__EXCLUDED_PATH_READER__', $excludedPathReaderSource)
    Set-Content -LiteralPath $bootstrapPath -Value $bootstrapContent -Encoding utf8
    $windowsPowerShell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell)) { $windowsPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source }
    & $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $bootstrapPath `
        -InstallerPath $installerPath -ScoopRoot $scoopRoot -GlobalRoot $globalRoot `
        -CacheRoot $cacheRoot -ConfigHome $isolatedConfigHome `
        -ExcludedScoopPathsJsonPath $excludedScoopPathsJsonPath -TestRoot $runRoot
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
    git -C $sourceBucket add ("bucket/{0}.json" -f $Package)
    if ($LASTEXITCODE -ne 0) { throw 'Staging disposable test manifest failed.' }
    git -C $sourceBucket commit --quiet -m 'test: initial manifest'
    if ($LASTEXITCODE -ne 0) { throw "Committing initial test manifest failed with exit code $LASTEXITCODE" }
    $sourceBucketUri = ([Uri]::new($sourceBucket)).AbsoluteUri
    Invoke-Scoop @('bucket', 'add', 'zevtest', $sourceBucketUri)

    $packageName = "zevtest/$Package"
    $appRoot = Join-Path $scoopRoot ("apps\{0}" -f $Package)
    $binaryPath = Join-Path $appRoot ("current\{0}" -f $packageExecutable)
    if ($Package -eq 'antigravity-ide') {
        Invoke-Scoop @('install', 'innounp')
    }
    Invoke-Scoop @('install', $packageName)
    if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
        throw "Installed executable not found at expected Scoop path: $binaryPath"
    }

    # Scoop verifies a manifest hash during install. Recompute it from Scoop's retained
    # download cache as an independent assertion against the exact bytes installed.
    $installedManifest = Get-Content -LiteralPath $bucketManifestPath -Raw | ConvertFrom-Json
    $expectedHash = [string]$installedManifest.architecture.'64bit'.hash
    if ($expectedHash -notmatch '^[a-fA-F0-9]{64}$') { throw "Manifest SHA256 is missing or malformed for $Package." }
    # Scoop checks the manifest SHA256 before extraction and aborts installation on a mismatch.
    # The transcript preserves Scoop's explicit `Checking hash ... OK.` output for this run.
    Write-Host "SHA256=PASS: Scoop accepted archive against manifest SHA256 $expectedHash before extraction."
    Write-Host "INSTALL=PASS: $packageName $($installedManifest.version); executable=$binaryPath"
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value 'install_test=passed' }

    $scoopShimDirectory = Join-Path $scoopRoot 'shims'
    $shim = Get-Command $packageCommand -ErrorAction Stop
    if ($shim.Source -notlike "$scoopShimDirectory*") {
        throw "$packageCommand resolves outside the isolated Scoop shims directory: $($shim.Source)"
    }
    Write-Host "SHIM=PASS: $($shim.Source)"
    if ($Package -eq 'qoder-cn-cli') {
        $legacyShim = Get-Command 'qoderclicn' -ErrorAction Stop
        if ($legacyShim.Source -notlike "$scoopShimDirectory*") { throw "Legacy qoderclicn shim resolves outside the isolated Scoop shims directory: $($legacyShim.Source)" }
        $persistedSettingsPath = Join-Path $scoopRoot 'persist\qoder-cn-cli\qodercn-config\settings.json'
        if (-not (Test-Path -LiteralPath $persistedSettingsPath -PathType Leaf)) { throw "Qoder CN's isolated persisted auto-update settings were not created: $persistedSettingsPath" }
        $persistedSettings = Get-Content -LiteralPath $persistedSettingsPath -Raw | ConvertFrom-Json
        if ($persistedSettings.general.enableAutoUpdate -ne $false) { throw "Qoder CN's persisted settings do not disable CLI self-updates." }
        Write-Host "QODER_CN_CONFIG_ISOLATION=PASS: $persistedSettingsPath; compatibility shim=$($legacyShim.Source)"
    }
    elseif ($Package -eq 'antigravity-cli') {
        $wrapperPath = Join-Path $appRoot 'current\agy.cmd'
        $wrapperText = Get-Content -LiteralPath $wrapperPath -Raw
        if ($wrapperText -notmatch 'AGY_CLI_DISABLE_AUTO_UPDATE=true' -or $wrapperText -notmatch 'agy\.exe') { throw 'Antigravity CLI wrapper does not disable its self-updater or invoke agy.exe.' }
        Write-Host "ANTIGRAVITY_SELF_UPDATE_ISOLATION=PASS: $wrapperPath"
    }
    elseif ($Package -eq 'antigravity-ide') {
        $innoUpdaterPath = Join-Path $appRoot 'current\tools\inno_updater.exe'
        if (Test-Path -LiteralPath $innoUpdaterPath) { throw "Unexpected Inno updater binary remains in unpacked Antigravity IDE directory: $innoUpdaterPath" }
        $ideCliPath = Join-Path $appRoot 'current\bin\antigravity-ide.cmd'
        if (-not (Test-Path -LiteralPath $ideCliPath -PathType Leaf)) { throw "Expected Antigravity IDE CLI wrapper was not unpacked: $ideCliPath" }
        Write-Host "ANTIGRAVITY_IDE_LAYOUT=PASS: $ideCliPath"
    }
    Assert-CliVersion ([string]$installedManifest.version) $packageCommand
    $helpResult = Invoke-IsolatedPackageCommand -CommandName $packageCommand -Arguments @('--help')
    if ($helpResult.ExitCode -ne 0) { throw "$packageCommand --help failed with exit code $($helpResult.ExitCode): $($helpResult.Output)" }
    if ($Package -eq 'qoder-cn-cli') {
        Assert-CliVersion ([string]$installedManifest.version) 'qoderclicn'
        Write-Host 'QODER_CN_COMPAT_COMMAND=PASS: qoderclicn --version.'
    }
    Write-Host "COMMAND=PASS: $packageCommand --version and $packageCommand --help."

    if ($Mode -eq 'Upgrade') {
        Copy-Item -LiteralPath $candidatePath -Destination $bucketManifestPath -Force
        git -C $sourceBucket add ("bucket/{0}.json" -f $Package)
        if ($LASTEXITCODE -ne 0) { throw 'Staging candidate manifest failed.' }
        git -C $sourceBucket commit --quiet -m "test: candidate manifest $($candidate.version)"
        if ($LASTEXITCODE -ne 0) { throw "Committing candidate manifest failed with exit code $LASTEXITCODE" }
        Invoke-Scoop @('update')
        Invoke-Scoop @('update', $Package)
        Assert-CliVersion ([string]$candidate.version) $packageCommand
        Write-Host "UPGRADE=PASS: $($installedManifest.version) -> $($candidate.version)"
        if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value 'upgrade_test=passed' }
    }
    else {
        Write-Host 'UPGRADE=NOT_RUN: no historical version was supplied.'
    }

    Invoke-Scoop @('uninstall', $Package)
    function Assert-PackageUninstalled {
        $remaining = @(Get-ChildItem -LiteralPath $scoopShimDirectory -Filter ("{0}.*" -f $packageCommand) -File -ErrorAction SilentlyContinue)
        if ($Package -eq 'qoder-cn-cli') {
            $remaining += @(Get-ChildItem -LiteralPath $scoopShimDirectory -Filter 'qoderclicn.*' -File -ErrorAction SilentlyContinue)
        }
        if ($remaining.Count) { throw "$Package shim files remained after uninstall: $($remaining.FullName -join ', ')" }
        if (Test-Path -LiteralPath $appRoot) { throw "$Package Scoop app files remained after uninstall: $appRoot" }
    }
    Assert-PackageUninstalled
    Write-Host "UNINSTALL=PASS: $Package app directory and command shims were removed."

    Invoke-Scoop @('install', $packageName)
    if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
        throw "Reinstalled executable not found at expected Scoop path: $binaryPath"
    }
    $reinstallShim = Get-Command $packageCommand -ErrorAction Stop
    if ($reinstallShim.Source -notlike "$scoopShimDirectory*") { throw "Reinstalled command resolves outside isolated shims: $($reinstallShim.Source)" }
    $reinstalledVersion = if ($Mode -eq 'Upgrade') { [string]$candidate.version } else { [string]$installedManifest.version }
    Assert-CliVersion $reinstalledVersion $packageCommand
    if ($Package -eq 'qoder-cn-cli') { Assert-CliVersion $reinstalledVersion 'qoderclicn' }
    $reinstallHelp = Invoke-IsolatedPackageCommand -CommandName $packageCommand -Arguments @('--help')
    if ($reinstallHelp.ExitCode -ne 0) { throw "Reinstalled $packageCommand --help failed with exit code $($reinstallHelp.ExitCode)." }
    Write-Host "REINSTALL=PASS: $packageName $reinstalledVersion; executable=$binaryPath"
    Invoke-Scoop @('uninstall', $Package)
    Assert-PackageUninstalled
    Write-Host "FINAL_UNINSTALL=PASS: $Package app directory and command shims were removed after reinstall."
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value 'uninstall_test=passed' }
}
finally {
    Restore-ProcessEnvironment
    Remove-TestRootSafely
    Assert-EnvironmentUnchanged
}

if (Test-Path -LiteralPath $runRoot) {
    throw "CLEANUP=FAIL: temporary test root remains: $runRoot"
}
Write-Host "SCOOP_CLEANUP=PASS: isolated Scoop root, bucket, download cache, and package test state were removed from $runRoot."
if ($Package -in @('qoder-cli', 'qoder-cn-cli')) {
    Write-Warning 'TEMP_NATIVE_CACHE=NOT_CLEANED: Qoder may create a native dependency cache outside the isolated Scoop test root; no broad TEMP cleanup is attempted.'
}
if ($env:GITHUB_STEP_SUMMARY) {
    $cleanupSummary = if ($Package -in @('qoder-cli', 'qoder-cn-cli')) { @'
### Cleanup status: PARTIAL

The isolated Scoop test root was removed. Qoder may leave a native dependency cache in the runner TEMP directory outside that root; the test does not delete these paths. This workflow uses a GitHub-hosted runner VM, which GitHub decommissions after the job.
'@ } else { @'
### Cleanup status: PASS

The isolated Scoop test root, download cache, and test bucket were removed. The workflow uses a GitHub-hosted runner VM, which GitHub decommissions after the job.
'@ }
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $cleanupSummary
}
if ($Package -in @('qoder-cli', 'qoder-cn-cli')) {
    Write-Host 'CLEANUP=PARTIAL: isolated Scoop test root removed; external Qoder TEMP native cache is not tracked or deleted.'
}
else {
    Write-Host 'CLEANUP=PASS: isolated Scoop root, bucket, and download cache removed.'
}

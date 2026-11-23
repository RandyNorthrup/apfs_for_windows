#Requires -Version 5.1
<#
.SYNOPSIS
    Fetch, verify, and stage the pinned official WinFsp SDK.

.DESCRIPTION
    Dot-source this file, then call Get-ApfsWinFspSdk. It downloads the
    official WinFsp MSI pinned in dependencies\winfsp.json (if not cached),
    verifies its SHA-256 and a Valid Authenticode signature from the pinned
    MSI signer, admin-extracts it (no installation, no elevation), and stages

        <CacheRoot>\<version>\inc\...
        <CacheRoot>\<version>\lib\winfsp-x64.lib
        <CacheRoot>\<version>\bin\winfsp-x64.dll
        <CacheRoot>\<version>\bin\winfsp-x64.sys
        <CacheRoot>\<version>\winfsp-sdk.json

    The staged kernel driver must carry a Valid signature from the pinned
    driver signer. Repeated calls reuse a verified cache.

    Pass the returned SdkRoot to CMake as -DWinFsp_ROOT and MsiPath to
    scripts\build-msi.ps1 -WinFspMsi.

.EXAMPLE
    . .\scripts\lib\winfsp-sdk.ps1
    $sdk = Get-ApfsWinFspSdk
    cmake -S . -B build -DWinFsp_ROOT="$($sdk.SdkRoot)" -DAPFS_PRODUCTION_BUILD=ON
#>

function Get-ApfsWinFspRepoRoot {
    Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

function Resolve-ApfsWinFspPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Get-ApfsWinFspDependency {
    param([string]$ManifestPath = "")

    $repoRoot = Get-ApfsWinFspRepoRoot
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Join-Path $repoRoot "dependencies\winfsp.json"
    }
    $resolved = Resolve-ApfsWinFspPath -Path $ManifestPath -RepoRoot $repoRoot
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "WinFsp dependency manifest is missing: $resolved"
    }
    $dependency = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    foreach ($field in @("version", "tag", "msi_url", "msi_sha256", "msi_signer", "driver_signer")) {
        if ([string]::IsNullOrWhiteSpace([string]$dependency.$field)) {
            throw "WinFsp dependency manifest field '$field' is empty: $resolved"
        }
    }
    if ([string]$dependency.version -notmatch '^\d+\.\d+\.\d+$') {
        throw "WinFsp dependency version is not a dotted build number: $($dependency.version)"
    }
    if ([string]$dependency.msi_sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "WinFsp dependency msi_sha256 is not a SHA-256 hash."
    }
    if (-not ([string]$dependency.msi_url).StartsWith(
            "https://github.com/winfsp/winfsp/releases/download/", [StringComparison]::Ordinal)) {
        throw "WinFsp dependency msi_url must be an official winfsp/winfsp GitHub release asset."
    }
    $dependency
}

function Test-ApfsSignerSubject {
    param(
        [AllowNull()][string]$Subject,
        [Parameter(Mandatory = $true)][string]$ExpectedCommonName
    )
    if ([string]::IsNullOrWhiteSpace($Subject)) {
        return $false
    }
    $escaped = [regex]::Escape($ExpectedCommonName)
    [bool]($Subject -match "^CN=`"?$escaped`"?(,|$)")
}

function Assert-ApfsAuthenticode {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedCommonName
    )
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $subject = if ($signature.SignerCertificate) {
        [string]$signature.SignerCertificate.Subject
    } else { $null }
    if ([string]$signature.Status -cne "Valid") {
        throw "Authenticode signature of $Path is $($signature.Status): $($signature.StatusMessage)"
    }
    if (-not (Test-ApfsSignerSubject -Subject $subject -ExpectedCommonName $ExpectedCommonName)) {
        throw "Authenticode signer of $Path is '$subject', expected CN=$ExpectedCommonName."
    }
    [ordered]@{
        path = $Path
        status = [string]$signature.Status
        signer = $subject
        thumbprint = [string]$signature.SignerCertificate.Thumbprint
    }
}

function Get-ApfsFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Save-ApfsWinFspMsi {
    param(
        [Parameter(Mandatory = $true)]$Dependency,
        [Parameter(Mandatory = $true)][string]$DownloadRoot
    )

    $expectedHash = ([string]$Dependency.msi_sha256).ToUpperInvariant()
    $msiName = if ([string]::IsNullOrWhiteSpace([string]$Dependency.msi_name)) {
        [IO.Path]::GetFileName(([Uri][string]$Dependency.msi_url).AbsolutePath)
    } else { [string]$Dependency.msi_name }
    if ($msiName -notmatch '^[A-Za-z0-9._-]+\.msi$') {
        throw "Unexpected WinFsp MSI file name: $msiName"
    }
    New-Item -ItemType Directory -Force -Path $DownloadRoot | Out-Null
    $msiPath = Join-Path $DownloadRoot $msiName

    if (Test-Path -LiteralPath $msiPath -PathType Leaf) {
        if ((Get-ApfsFileSha256 -Path $msiPath) -ceq $expectedHash) {
            return $msiPath
        }
        Remove-Item -LiteralPath $msiPath -Force
    }

    # Download into a fresh, private directory and move into place only after
    # the hash matches, so an interrupted or tampered download is never reused.
    $partialRoot = Join-Path $DownloadRoot (".partial-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $partialRoot | Out-Null
    try {
        $partialPath = Join-Path $partialRoot $msiName
        $previousProgress = $ProgressPreference
        $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
        try {
            $ProgressPreference = "SilentlyContinue"
            [Net.ServicePointManager]::SecurityProtocol =
                $previousProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri ([string]$Dependency.msi_url) -OutFile $partialPath `
                -UseBasicParsing -MaximumRedirection 10
        } finally {
            $ProgressPreference = $previousProgress
            [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
        }
        $actualHash = Get-ApfsFileSha256 -Path $partialPath
        if ($actualHash -cne $expectedHash) {
            throw "Downloaded WinFsp MSI hash $actualHash does not match pinned $expectedHash."
        }
        Move-Item -LiteralPath $partialPath -Destination $msiPath -Force
    } finally {
        if (Test-Path -LiteralPath $partialRoot) {
            Remove-Item -LiteralPath $partialRoot -Recurse -Force
        }
    }
    $msiPath
}

function Find-ApfsSingleFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [scriptblock]$Where = { $true }
    )
    $found = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Name -ErrorAction Stop |
        Where-Object $Where | Sort-Object { $_.FullName.Length }, FullName)
    if ($found.Count -eq 0) {
        throw "WinFsp admin extract does not contain $Name."
    }
    $found[0]
}

function Test-ApfsStagedWinFspSdk {
    param(
        [Parameter(Mandatory = $true)][string]$SdkRoot,
        [Parameter(Mandatory = $true)]$Dependency
    )
    $metadataPath = Join-Path $SdkRoot "winfsp-sdk.json"
    $required = @(
        (Join-Path $SdkRoot "inc\winfsp\winfsp.h"),
        (Join-Path $SdkRoot "lib\winfsp-x64.lib"),
        (Join-Path $SdkRoot "bin\winfsp-x64.dll"),
        (Join-Path $SdkRoot "bin\winfsp-x64.sys"),
        $metadataPath)
    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }
    }
    try {
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    } catch {
        return $false
    }
    if ([string]$metadata.version -cne [string]$Dependency.version -or
        ([string]$metadata.msi_sha256).ToUpperInvariant() -cne
            ([string]$Dependency.msi_sha256).ToUpperInvariant()) {
        return $false
    }
    foreach ($file in @($metadata.files)) {
        $path = Join-Path $SdkRoot (([string]$file.path).Replace("/", "\"))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-ApfsFileSha256 -Path $path) -cne ([string]$file.sha256).ToUpperInvariant()) {
            return $false
        }
    }
    $true
}

function Get-ApfsWinFspSdk {
    [CmdletBinding()]
    param(
        [string]$CacheRoot = "artifacts\winfsp-sdk",
        [string]$ManifestPath = "",
        [switch]$Force
    )

    $ErrorActionPreference = "Stop"
    $repoRoot = Get-ApfsWinFspRepoRoot
    $dependency = Get-ApfsWinFspDependency -ManifestPath $ManifestPath
    $version = [string]$dependency.version
    $resolvedCache = Resolve-ApfsWinFspPath -Path $CacheRoot -RepoRoot $repoRoot
    $sdkRoot = Join-Path $resolvedCache $version
    New-Item -ItemType Directory -Force -Path $resolvedCache | Out-Null

    $msiPath = Save-ApfsWinFspMsi -Dependency $dependency `
        -DownloadRoot (Join-Path $resolvedCache "downloads")
    $msiSignature = Assert-ApfsAuthenticode -Path $msiPath `
        -ExpectedCommonName ([string]$dependency.msi_signer)

    if ($Force -or -not (Test-ApfsStagedWinFspSdk -SdkRoot $sdkRoot -Dependency $dependency)) {
        $workId = [guid]::NewGuid().ToString("N")
        $extractRoot = Join-Path $resolvedCache ".extract-$workId"
        $stageRoot = Join-Path $resolvedCache ".stage-$workId"
        $logPath = Join-Path $resolvedCache "winfsp-admin-extract.log"
        New-Item -ItemType Directory -Path $extractRoot | Out-Null
        try {
            # An administrative image only unpacks files; nothing is installed
            # and no driver is registered, so elevation is not needed.
            $arguments = "/a `"$msiPath`" /qn /norestart TARGETDIR=`"$extractRoot`" /l*v `"$logPath`""
            $process = Start-Process -FilePath (Join-Path $env:SystemRoot "System32\msiexec.exe") `
                -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
            if ($process.ExitCode -ne 0) {
                throw "WinFsp MSI admin extract failed with exit code $($process.ExitCode); see $logPath"
            }

            $header = Find-ApfsSingleFile -Root $extractRoot -Name "winfsp.h" -Where {
                $_.Directory.Name -ieq "winfsp" -and $_.Directory.Parent.Name -ieq "inc"
            }
            $includeSource = $header.Directory.Parent.FullName
            $library = Find-ApfsSingleFile -Root $extractRoot -Name "winfsp-x64.lib"
            $runtime = Find-ApfsSingleFile -Root $extractRoot -Name "winfsp-x64.dll" -Where {
                Test-Path -LiteralPath (Join-Path $_.DirectoryName "winfsp-x64.sys") -PathType Leaf
            }

            New-Item -ItemType Directory -Path $stageRoot | Out-Null
            Copy-Item -LiteralPath $includeSource -Destination (Join-Path $stageRoot "inc") -Recurse
            New-Item -ItemType Directory -Path (Join-Path $stageRoot "lib") | Out-Null
            Copy-Item -LiteralPath $library.FullName -Destination (Join-Path $stageRoot "lib\winfsp-x64.lib")
            New-Item -ItemType Directory -Path (Join-Path $stageRoot "bin") | Out-Null
            Copy-Item -LiteralPath $runtime.FullName -Destination (Join-Path $stageRoot "bin\winfsp-x64.dll")
            Copy-Item -LiteralPath (Join-Path $runtime.DirectoryName "winfsp-x64.sys") `
                -Destination (Join-Path $stageRoot "bin\winfsp-x64.sys")

            [void](Assert-ApfsAuthenticode -Path (Join-Path $stageRoot "bin\winfsp-x64.sys") `
                -ExpectedCommonName ([string]$dependency.driver_signer))
            [void](Assert-ApfsAuthenticode -Path (Join-Path $stageRoot "bin\winfsp-x64.dll") `
                -ExpectedCommonName ([string]$dependency.msi_signer))

            [string[]]$relativePaths = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File |
                ForEach-Object { $_.FullName.Substring($stageRoot.Length + 1).Replace("\", "/") })
            [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
            $metadata = [ordered]@{
                schema_version = 1
                name = [string]$dependency.name
                version = $version
                tag = [string]$dependency.tag
                msi_url = [string]$dependency.msi_url
                msi_sha256 = ([string]$dependency.msi_sha256).ToUpperInvariant()
                msi_signer = [string]$dependency.msi_signer
                driver_signer = [string]$dependency.driver_signer
                files = @($relativePaths | ForEach-Object {
                    [ordered]@{
                        path = $_
                        sha256 = Get-ApfsFileSha256 -Path (Join-Path $stageRoot ($_.Replace("/", "\")))
                    }
                })
            }
            [IO.File]::WriteAllText(
                (Join-Path $stageRoot "winfsp-sdk.json"),
                ($metadata | ConvertTo-Json -Depth 5) + "`n",
                [Text.UTF8Encoding]::new($false))

            if (Test-Path -LiteralPath $sdkRoot) {
                Remove-Item -LiteralPath $sdkRoot -Recurse -Force
            }
            Move-Item -LiteralPath $stageRoot -Destination $sdkRoot
        } finally {
            foreach ($temporary in @($extractRoot, $stageRoot)) {
                if (Test-Path -LiteralPath $temporary) {
                    Remove-Item -LiteralPath $temporary -Recurse -Force
                }
            }
        }
        if (-not (Test-ApfsStagedWinFspSdk -SdkRoot $sdkRoot -Dependency $dependency)) {
            throw "Staged WinFsp SDK failed verification: $sdkRoot"
        }
    }

    $driverSignature = Assert-ApfsAuthenticode -Path (Join-Path $sdkRoot "bin\winfsp-x64.sys") `
        -ExpectedCommonName ([string]$dependency.driver_signer)

    [pscustomobject][ordered]@{
        SdkRoot = $sdkRoot
        MsiPath = $msiPath
        Version = $version
        MsiSha256 = ([string]$dependency.msi_sha256).ToUpperInvariant()
        IncludeDir = Join-Path $sdkRoot "inc"
        LibDir = Join-Path $sdkRoot "lib"
        BinDir = Join-Path $sdkRoot "bin"
        MsiSigner = [string]$msiSignature.signer
        DriverSigner = [string]$driverSignature.signer
    }
}

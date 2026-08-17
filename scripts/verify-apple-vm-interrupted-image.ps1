#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MacHost,
    [Parameter(Mandatory = $true)][string]$MacUser,
    [Parameter(Mandatory = $true)][string]$PasswordFile,
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [Parameter(Mandatory = $true)][int64]$ExpectedFileSize,
    [Parameter(Mandatory = $true)][string]$ExpectedFileSha256,
    [string]$ExpectedInvariantSha256 = "61A497B863F48F5ED9128653D6564E435E3C40612DE1BC58C2E94B95366C4BF9",
    [string]$PlinkPath,
    [string]$PscpPath,
    [string]$HostKey,
    [string]$OutputPath = "artifacts\device-loss\apple-vm-interrupted-image-proof.json"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Resolve-Executable {
    param([string]$Requested, [string]$Name, [string[]]$KnownPaths)
    if ($Requested) {
        $path = Resolve-RepoPath $Requested
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        throw "$Name not found at $path"
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($path in $KnownPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    throw "$Name was not found."
}

function ConvertTo-PosixSingleQuoted {
    param([Parameter(Mandatory = $true)][string]$Text)
    $quote = [string][char]39
    $replacement = $quote + '"' + $quote + '"' + $quote
    $quote + $Text.Replace($quote, $replacement) + $quote
}

function Get-AuthArguments {
    $arguments = @("-batch", "-pwfile", $password)
    if ($HostKey) { $arguments += @("-hostkey", $HostKey) }
    $arguments
}

function Invoke-Remote {
    param([Parameter(Mandatory = $true)][string]$Command)
    $arguments = @(Get-AuthArguments) + @("-ssh", "$MacUser@$MacHost", $Command)
    $raw = @(& $plink @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Remote command failed with exit code ${exitCode}: $($raw -join "`n")"
    }
    $raw -join "`n"
}

function Copy-ToVm {
    param([string]$Source, [string]$Destination)
    $arguments = @(Get-AuthArguments) + @("-q", $Source, "$MacUser@${MacHost}:$Destination")
    & $pscp @arguments
    if ($LASTEXITCODE -ne 0) { throw "macOS VM upload failed: $Source" }
}

function Copy-FromVm {
    param([string]$Source, [string]$Destination)
    $arguments = @(Get-AuthArguments) + @("-q", "$MacUser@${MacHost}:$Source", $Destination)
    & $pscp @arguments
    if ($LASTEXITCODE -ne 0) { throw "macOS VM download failed: $Source" }
}

function ConvertFrom-KeyValueOutput {
    param([string]$Value)
    $result = [ordered]@{}
    foreach ($line in ($Value -split "`r?`n")) {
        if ($line -match '^([^=]+)=(.*)$') { $result[$matches[1]] = $matches[2] }
    }
    [pscustomobject]$result
}

$password = Resolve-RepoPath $PasswordFile
$image = Resolve-RepoPath $ImagePath
$output = Resolve-RepoPath $OutputPath
$validator = Resolve-RepoPath "scripts\apple-vm\validate-interrupted-apfs.sh"
$plink = Resolve-Executable $PlinkPath "plink.exe" @("C:\Program Files\PuTTY\plink.exe")
$pscp = Resolve-Executable $PscpPath "pscp.exe" @("C:\Program Files\PuTTY\pscp.exe")
foreach ($required in @($password, $image, $validator)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required Apple interruption input is missing: $required"
    }
}
foreach ($hash in @($ExpectedFileSha256, $ExpectedInvariantSha256)) {
    if ($hash -notmatch '^[0-9A-Fa-f]{64}$') { throw "Expected SHA-256 is invalid: $hash" }
}

$runId = "apfs-interruption-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$remoteRoot = "/tmp/$runId"
$localRoot = Join-Path (Split-Path -Parent $output) $runId
$localScript = Join-Path $localRoot "validate.sh"
$remoteImage = "$remoteRoot/interrupted.apfs"
$remoteEvidence = "$remoteRoot/evidence"
$startedUtc = (Get-Date).ToUniversalTime()
$imageHash = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash
$validation = $null
$remoteCleaned = $false
$errorText = $null

New-Item -ItemType Directory -Force -Path $localRoot | Out-Null
$scriptText = [IO.File]::ReadAllText($validator).Replace("`r`n", "`n")
[IO.File]::WriteAllText($localScript, $scriptText, [Text.UTF8Encoding]::new($false))
try {
    Invoke-Remote "mkdir -p $(ConvertTo-PosixSingleQuoted $remoteRoot)" | Out-Null
    Copy-ToVm $image $remoteImage
    Copy-ToVm $localScript "$remoteRoot/validate.sh"
    $command = "chmod 700 $(ConvertTo-PosixSingleQuoted "$remoteRoot/validate.sh") && " +
        "$(ConvertTo-PosixSingleQuoted "$remoteRoot/validate.sh") " +
        "$(ConvertTo-PosixSingleQuoted $remoteImage) " +
        "$(ConvertTo-PosixSingleQuoted $remoteEvidence) " +
        "$imageHash $($ExpectedInvariantSha256.ToUpperInvariant()) " +
        "$ExpectedFileSize $($ExpectedFileSha256.ToUpperInvariant())"
    $validation = ConvertFrom-KeyValueOutput (Invoke-Remote $command)
    foreach ($name in @("fsck-before.txt", "fsck-after.txt", "disk-info.txt", "attach.txt")) {
        Copy-FromVm "$remoteEvidence/$name" (Join-Path $localRoot $name)
    }
    $validationOk = $validation.APPLE_INTERRUPTION_OK -ceq "1" -and
        $validation.IMAGE_SHA256 -ceq $imageHash -and
        $validation.INVARIANT_SHA256 -ceq $ExpectedInvariantSha256.ToUpperInvariant() -and
        [int64]$validation.INTERRUPTED_FILE_SIZE -eq $ExpectedFileSize -and
        $validation.INTERRUPTED_FILE_SHA256 -ceq $ExpectedFileSha256.ToUpperInvariant() -and
        $validation.VOLUME_READ_ONLY -ceq "Yes" -and
        [int]$validation.FSCK_PASSES -eq 2
    if (-not $validationOk) { throw "macOS interrupted-image validation values did not match." }
} catch {
    $errorText = $_.Exception.Message
} finally {
    try {
        if ($remoteRoot.StartsWith("/tmp/apfs-interruption-", [StringComparison]::Ordinal)) {
            Invoke-Remote "rm -rf -- $(ConvertTo-PosixSingleQuoted $remoteRoot)" | Out-Null
            $remoteCleaned = $true
        }
    } catch {
        if (-not $errorText) { $errorText = $_.Exception.Message }
    }
}

$ok = -not $errorText -and $validation -and $remoteCleaned
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "apple_vm_interrupted_image"
    ok = [bool]$ok
    no_host_reboot_performed = $true
    macos_vm_rebooted = $false
    credential_material_recorded = $false
    vm_endpoint = "$MacUser@$MacHost"
    image_path = $image
    image_sha256 = $imageHash
    expected_invariant_sha256 = $ExpectedInvariantSha256.ToUpperInvariant()
    expected_file_size = $ExpectedFileSize
    expected_file_sha256 = $ExpectedFileSha256.ToUpperInvariant()
    validation = $validation
    evidence_directory = $localRoot
    remote_artifacts_cleaned = [bool]$remoteCleaned
    error = $errorText
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $output -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) { exit 1 }

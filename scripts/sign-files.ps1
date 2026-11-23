#Requires -Version 5.1
<#
.SYNOPSIS
    Authenticode-sign files with Azure Artifact Signing (formerly Trusted Signing).

.DESCRIPTION
    Signs PE files and MSIs with signtool from the Windows SDK and the pinned
    Microsoft.ArtifactSigning.Client dlib. Authentication uses the Azure
    default credential chain: an `az login` session on a workstation, or the
    workload identity that azure/login establishes in GitHub Actions.

    Files that already carry a valid signature from another publisher (for
    example Microsoft-signed Visual C++ runtime DLLs) are skipped. Kernel
    drivers (*.sys) are never re-signed here: Artifact Signing certificates are
    not trusted for kernel-mode code.

.EXAMPLE
    .\scripts\sign-files.ps1 -Path artifacts\package\APFS-for-Windows-0.2.0-test-signed\*.exe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Path,
    [string]$Endpoint = $(if ($env:APFS_SIGNING_ENDPOINT) { $env:APFS_SIGNING_ENDPOINT } else { "https://wus.codesigning.azure.net/" }),
    [string]$AccountName = $(if ($env:APFS_SIGNING_ACCOUNT) { $env:APFS_SIGNING_ACCOUNT } else { "scnetsolutions" }),
    [string]$ProfileName = $(if ($env:APFS_SIGNING_PROFILE) { $env:APFS_SIGNING_PROFILE } else { "SAKUtility" }),
    [string]$TimestampUrl = "http://timestamp.acs.microsoft.com",
    [string]$Description = "APFS for Windows",
    [string]$DescriptionUrl = "https://github.com/RandyNorthrup/apfs_for_windows",
    [string]$ExpectedPublisher = "CN=Randy Northrup"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

# -- Resolve targets ---------------------------------------------------------
$targets = @()
foreach ($pattern in $Path) {
    $items = @(Get-ChildItem -Path $pattern -File -ErrorAction Stop)
    if ($items.Count -eq 0) { throw "No files match $pattern" }
    $targets += $items
}
$targets = @($targets | Sort-Object FullName -Unique)
$toSign = @()
foreach ($item in $targets) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to sign reparse point: $($item.FullName)"
    }
    if ($item.Extension -ieq ".sys") {
        throw "Kernel drivers cannot be signed with Artifact Signing: $($item.FullName)"
    }
    $existing = Get-AuthenticodeSignature -LiteralPath $item.FullName
    if ($existing.Status -eq "Valid" -and $existing.SignerCertificate -and
        -not ([string]$existing.SignerCertificate.Subject).StartsWith($ExpectedPublisher)) {
        Write-Host "Skipping (already signed by $($existing.SignerCertificate.Subject)): $($item.Name)"
        continue
    }
    $toSign += $item.FullName
}
if ($toSign.Count -eq 0) {
    Write-Host "Nothing to sign."
    return
}

# -- signtool from the Windows SDK only (never PATH) -------------------------
$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $signtool) { throw "signtool.exe not found under the Windows SDK." }

# -- Pinned Artifact Signing client dlib --------------------------------------
$dlibPackage = "Microsoft.ArtifactSigning.Client"
$dlibVersion = "1.0.146"
$dlibSha512 = "/G0hG/VDIS6psW23b5t1V/ORIgn0PVAOtGj9w+hkPmAuI4pempfwlW50E2GtHscnz9+5Qz3hbC4mcb7ej2Yn1A=="
$dlibDir = Join-Path $repoRoot "build\artifact-signing-client\$dlibVersion"
$dlibDll = Join-Path $dlibDir "bin\x64\Azure.CodeSigning.Dlib.dll"
if (-not (Test-Path -LiteralPath $dlibDll)) {
    New-Item -ItemType Directory -Force -Path $dlibDir | Out-Null
    $nugetZip = Join-Path $dlibDir "$dlibPackage.$dlibVersion.zip"
    Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/$dlibPackage/$dlibVersion" `
        -OutFile $nugetZip -UseBasicParsing
    $sha512 = [Convert]::ToBase64String(
        [Security.Cryptography.SHA512]::Create().ComputeHash([IO.File]::ReadAllBytes($nugetZip)))
    if ($sha512 -cne $dlibSha512) {
        Remove-Item -LiteralPath $nugetZip -ErrorAction SilentlyContinue
        throw "$dlibPackage $dlibVersion SHA-512 mismatch."
    }
    Expand-Archive -Path $nugetZip -DestinationPath $dlibDir -Force
    Remove-Item -LiteralPath $nugetZip -ErrorAction SilentlyContinue
}
$dlibSignature = Get-AuthenticodeSignature -LiteralPath $dlibDll
if ($dlibSignature.Status -ne "Valid") {
    throw "Artifact Signing dlib signature is not valid ($($dlibSignature.Status))."
}

$metadataPath = Join-Path $dlibDir "metadata-apfs.json"
$metadata = [ordered]@{
    Endpoint = $Endpoint
    CodeSigningAccountName = $AccountName
    CertificateProfileName = $ProfileName
    ExcludeCredentials = @("ManagedIdentityCredential", "EnvironmentCredential", "WorkloadIdentityCredential",
        "SharedTokenCacheCredential", "VisualStudioCredential", "VisualStudioCodeCredential",
        "AzurePowerShellCredential", "AzureDeveloperCliCredential", "InteractiveBrowserCredential")
} | ConvertTo-Json
[IO.File]::WriteAllText($metadataPath, $metadata, [Text.UTF8Encoding]::new($false))

# -- Sign in batches (signtool command lines have a length limit) -------------
$batchSize = 20
for ($i = 0; $i -lt $toSign.Count; $i += $batchSize) {
    $batch = @($toSign[$i..([Math]::Min($i + $batchSize, $toSign.Count) - 1)])
    & $signtool sign /v /fd SHA256 /tr $TimestampUrl /td SHA256 `
        /d $Description /du $DescriptionUrl `
        /dlib $dlibDll /dmdf $metadataPath @batch
    if ($LASTEXITCODE -ne 0) { throw "signtool failed with exit code $LASTEXITCODE." }
}

# -- Verify -------------------------------------------------------------------
$report = @()
foreach ($file in $toSign) {
    $signature = Get-AuthenticodeSignature -LiteralPath $file
    if ($signature.Status -ne "Valid" -or -not $signature.SignerCertificate -or
        -not $signature.TimeStamperCertificate -or
        -not ([string]$signature.SignerCertificate.Subject).StartsWith($ExpectedPublisher)) {
        throw "Signature verification failed for $file ($($signature.Status))."
    }
    $report += [ordered]@{
        file = [IO.Path]::GetFileName($file)
        status = [string]$signature.Status
        signer = [string]$signature.SignerCertificate.Subject
        thumbprint = [string]$signature.SignerCertificate.Thumbprint
        timestamped = $true
    }
}
$report | ConvertTo-Json -Depth 3

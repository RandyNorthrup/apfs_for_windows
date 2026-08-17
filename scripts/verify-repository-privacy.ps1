#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ScanRoot = "",
    [string]$OutputPath = "artifacts\repository\repository-privacy.json",
    [switch]$SkipGitMetadata
)

$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))

function Resolve-PathFromRepo {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Test-AllowedEmail {
    param([Parameter(Mandatory = $true)][string]$Email)
    return $Email -match '(?i)@(users\.noreply\.github\.com|example\.com|example\.invalid)$' -or
        $Email -match '(?i)^noreply@github\.com$'
}

$resolvedScanRoot = if ([string]::IsNullOrWhiteSpace($ScanRoot)) {
    $repoRoot
} else {
    Resolve-PathFromRepo $ScanRoot
}
if (-not (Test-Path -LiteralPath $resolvedScanRoot -PathType Container)) {
    throw "Privacy scan root does not exist: $resolvedScanRoot"
}

$isRepositoryScan = $resolvedScanRoot.TrimEnd('\') -ceq $repoRoot.TrimEnd('\')
$relativeFiles = if ($isRepositoryScan) {
    @(& git -C $repoRoot ls-files --cached --others --exclude-standard 2>$null |
        Where-Object { $_ } |
        Where-Object {
            $_ -notmatch '^(third_party/(winfsp|lzfse)/|build[^/]*/|artifacts/|temp/)'
        })
} else {
    @(Get-ChildItem -LiteralPath $resolvedScanRoot -Recurse -File |
        ForEach-Object {
            $_.FullName.Substring($resolvedScanRoot.Length + 1).Replace('\', '/')
        })
}

$sensitiveNames = @($relativeFiles | Where-Object {
    $_ -match '(?i)(^|/)(creds?|credentials?|passwords?|secrets?)([./]|$)' -or
        $_ -match '(?i)(^|/)\.env($|\.)' -or
        $_ -match '(?i)\.(key|p12|pfx|pem)$'
})

$textExtensions = @(
    '.c', '.cmake', '.cpp', '.h', '.json', '.md', '.props', '.ps1', '.sh',
    '.txt', '.vcxproj', '.xml', '.yaml', '.yml'
)
$textNames = @('CMakeLists.txt', 'VERSION')
$rules = @(
    [pscustomobject]@{
        name = 'windows_user_profile_path'
        regex = [regex]::new('(?i)\b[A-Z]:[\\/]+Users[\\/]+(?![<%$])[A-Za-z0-9._-]+')
        documentation_only = $false
    },
    [pscustomobject]@{
        name = 'macos_user_profile_path'
        regex = [regex]::new('(?i)/Users/(?![<%$])[A-Za-z0-9._-]+')
        documentation_only = $false
    },
    [pscustomobject]@{
        name = 'private_ipv4_address'
        regex = [regex]::new('(?<![0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})(?![0-9])')
        documentation_only = $false
    },
    [pscustomobject]@{
        name = 'private_key_material'
        regex = [regex]::new(('-----' + 'BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----'))
        documentation_only = $false
    },
    [pscustomobject]@{
        name = 'numbered_raw_device_in_documentation'
        regex = [regex]::new('(?i)(Harddisk|PhysicalDrive)[0-9]+|\bDisk\s+[0-9]+\b')
        documentation_only = $true
    },
    [pscustomobject]@{
        name = 'machine_evidence_field'
        regex = [regex]::new('(?i)"(disk_number|partition_number|serial_sha256)"\s*:')
        documentation_only = $true
    }
)
$emailRegex = [regex]::new('[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
$violations = [Collections.Generic.List[object]]::new()

foreach ($relativePath in $sensitiveNames) {
    $violations.Add([ordered]@{
        rule = 'sensitive_filename'
        path = $relativePath
        line = $null
    })
}

foreach ($relativePath in $relativeFiles) {
    $fullPath = Join-Path $resolvedScanRoot $relativePath.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        continue
    }
    $extension = [IO.Path]::GetExtension($fullPath).ToLowerInvariant()
    $name = [IO.Path]::GetFileName($fullPath)
    if ($textExtensions -notcontains $extension -and $textNames -notcontains $name) {
        continue
    }
    $isDocumentation = $extension -in @('.md', '.json')
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadLines($fullPath)) {
        $lineNumber++
        foreach ($rule in $rules) {
            if ((-not $rule.documentation_only -or $isDocumentation) -and
                $rule.regex.IsMatch($line)) {
                $violations.Add([ordered]@{
                    rule = $rule.name
                    path = $relativePath
                    line = $lineNumber
                })
            }
        }
        foreach ($emailMatch in $emailRegex.Matches($line)) {
            if (-not (Test-AllowedEmail -Email $emailMatch.Value)) {
                $violations.Add([ordered]@{
                    rule = 'personal_email_address'
                    path = $relativePath
                    line = $lineNumber
                })
            }
        }
    }
}

if (-not $isRepositoryScan) {
    $binaryRules = @($rules | Where-Object { -not $_.documentation_only })
    foreach ($relativePath in @($relativeFiles | Where-Object {
        [IO.Path]::GetFileName($_) -match '(?i)^apfs_.*\.exe$'
    })) {
        $fullPath = Join-Path $resolvedScanRoot $relativePath.Replace('/', '\')
        $bytes = [IO.File]::ReadAllBytes($fullPath)
        $binaryText = @(
            [Text.Encoding]::ASCII.GetString($bytes),
            [Text.Encoding]::Unicode.GetString($bytes)
        )
        foreach ($rule in $binaryRules) {
            if (@($binaryText | Where-Object { $rule.regex.IsMatch($_) }).Count -gt 0) {
                $violations.Add([ordered]@{
                    rule = "embedded_$($rule.name)"
                    path = $relativePath
                    line = $null
                })
            }
        }
        $embeddedEmails = @($binaryText | ForEach-Object { $emailRegex.Matches($_) } |
            ForEach-Object { $_.Value } | Sort-Object -Unique)
        if (@($embeddedEmails | Where-Object { -not (Test-AllowedEmail -Email $_) }).Count -gt 0) {
            $violations.Add([ordered]@{
                rule = 'embedded_personal_email_address'
                path = $relativePath
                line = $null
            })
        }
    }
}

$gitMetadataChecked = $isRepositoryScan -and -not $SkipGitMetadata
if ($gitMetadataChecked) {
    $metadataEmails = @(& git -C $repoRoot log --all --format='%ae%n%ce' 2>$null |
        Where-Object { $_ } | Sort-Object -Unique)
    foreach ($email in $metadataEmails) {
        if (-not (Test-AllowedEmail -Email $email)) {
            $violations.Add([ordered]@{
                rule = 'personal_git_email'
                path = '.git/history'
                line = $null
            })
        }
    }
}

$ok = $violations.Count -eq 0
$result = [ordered]@{
    component = 'apfs_for_windows'
    check = 'repository_privacy'
    ok = [bool]$ok
    scan_root_kind = if ($isRepositoryScan) { 'repository' } else { 'package' }
    git_metadata_checked = [bool]$gitMetadataChecked
    files_scanned = $relativeFiles.Count
    violations = @($violations)
    completed_utc = (Get-Date).ToUniversalTime().ToString('o')
}

$resolvedOutput = Resolve-PathFromRepo $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}

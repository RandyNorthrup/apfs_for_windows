#Requires -Version 5.1

function Get-CanonicalTextSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $text = [IO.File]::ReadAllText($Path, $utf8)
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = $utf8.GetBytes($normalized)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash)).Replace("-", "")
    } finally {
        $sha256.Dispose()
    }
}

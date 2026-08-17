#Requires -Version 5.1

function Get-ApfsProjectVersion {
    param(
        [string]$ExplicitVersion,
        [Parameter(Mandatory = $true)][string]$CallerRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitVersion)) {
        if ($ExplicitVersion -notmatch '^\d+\.\d+\.\d+$') {
            throw "Explicit project version is not semantic: $ExplicitVersion"
        }
        return $ExplicitVersion
    }

    $candidates = @(
        (Join-Path $CallerRoot "VERSION"),
        (Join-Path (Split-Path -Parent $CallerRoot) "VERSION")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $version = (Get-Content -LiteralPath $candidate -Raw).Trim()
            if ($version -notmatch '^\d+\.\d+\.\d+$') {
                throw "VERSION is not semantic: $candidate"
            }
            return $version
        }
    }
    throw "VERSION was not found beside the package or repository scripts."
}

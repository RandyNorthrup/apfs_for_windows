#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$Mount = "Q:",
    [int]$TimeoutSeconds = 30,
    [string]$OutputPath = "artifacts\local-crash-recovery\worker-crash-recovery-proof.json"
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return Join-Path (Split-Path -Parent $PSScriptRoot) $Path
}

function Get-MountRoot {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name.Length -eq 2 -and $Name.EndsWith(":")) {
        return "$Name\"
    }
    return $Name
}

function Add-PathFront {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ((Test-Path -LiteralPath $Path -PathType Container) -and
        -not ($env:PATH.Split([IO.Path]::PathSeparator) -contains $Path)) {
        $env:PATH = "$Path$([IO.Path]::PathSeparator)$env:PATH"
    }
}

function Add-WinFspRuntimePath {
    $candidates = @(
        "C:\Program Files (x86)\WinFsp\bin",
        "C:\Program Files\WinFsp\bin"
    )
    $sxs = Get-ChildItem "C:\Program Files (x86)\WinFsp\SxS" -Recurse `
        -Filter winfsp-x64.dll -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($sxs) {
        $candidates = @((Split-Path -Parent $sxs.FullName)) + $candidates
    }
    foreach ($candidate in $candidates) {
        Add-PathFront -Path $candidate
    }
}

function Wait-PathState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$Present,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        if ((Test-Path -LiteralPath $Path -PathType Container) -eq $Present) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Wait-ProcessExit {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    return $Process.WaitForExit($Timeout * 1000)
}

function Start-FaultWorker {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = Split-Path -Parent $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (@($Arguments | ForEach-Object {
        '"' + $_.Replace('"', '\"') + '"'
    }) -join ' ')
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Unable to start fault-injection worker."
    }
    return $process
}

function Invoke-GuardedWorker {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $process = Start-FaultWorker -Executable $Executable -Arguments $Arguments
    try {
        if (-not (Wait-ProcessExit -Process $process -Timeout $Timeout)) {
            throw "Guarded worker did not exit within $Timeout seconds."
        }
        $process.WaitForExit()
        $process.Refresh()
        return [ordered]@{
            exit_code = $process.ExitCode
            stdout = $process.StandardOutput.ReadToEnd()
            stderr = $process.StandardError.ReadToEnd()
        }
    } finally {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $process.WaitForExit(5000) | Out-Null
        }
    }
}

function Get-BytesSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return ([BitConverter]::ToString(
        [Security.Cryptography.SHA256]::Create().ComputeHash($Bytes))).Replace("-", "")
}

function Get-ProbeFile {
    param(
        [Parameter(Mandatory = $true)][string]$Probe,
        [Parameter(Mandatory = $true)][string]$Image,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $raw = & $Probe --target $Image --read-file $Path --max-read-bytes 1048576
    if ($LASTEXITCODE -ne 0) {
        throw "apfs_probe failed for $Image"
    }
    return ($raw | ConvertFrom-Json).whole_device_read_file
}

function Select-CrashMount {
    param([Parameter(Mandatory = $true)][string]$Requested)
    if (-not (Test-Path -LiteralPath (Get-MountRoot -Name $Requested))) {
        return $Requested
    }
    foreach ($candidate in @("Q:", "P:", "O:", "N:", "M:", "L:", "K:", "J:", "I:", "H:")) {
        if (-not (Test-Path -LiteralPath (Get-MountRoot -Name $candidate))) {
            return $candidate
        }
    }
    throw "No free crash-recovery mount letter found."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedBuild = Resolve-RepoPath $BuildDir
$resolvedOutput = Resolve-RepoPath $OutputPath
$artifactDir = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

$worker = Join-Path $resolvedBuild "apfs_winfs_worker.exe"
$selftest = Join-Path $resolvedBuild "apfs_core_selftest.exe"
$probe = Join-Path $resolvedBuild "apfs_probe.exe"
foreach ($tool in @($worker, $selftest, $probe)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Required build output missing: $tool"
    }
}

$mountExplicit = $PSBoundParameters.ContainsKey("Mount")
$mountRoot = Get-MountRoot -Name $Mount
if (Test-Path -LiteralPath $mountRoot) {
    if ($mountExplicit) {
        throw "Requested crash-recovery mount is already in use: $mountRoot"
    }
    $Mount = Select-CrashMount -Requested $Mount
    $mountRoot = Get-MountRoot -Name $Mount
}

Add-PathFront -Path "C:\Qt\6.10.3\msvc2022_64\bin"
Add-PathFront -Path "$env:ProgramFiles\APFS for Windows"
Add-WinFspRuntimePath

$baseImage = Join-Path $artifactDir "worker-crash-base.apfs"
Remove-Item -LiteralPath $baseImage, $resolvedOutput -Force -ErrorAction SilentlyContinue
& $selftest --make-image $baseImage | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $baseImage -PathType Leaf)) {
    throw "Unable to generate APFS crash-recovery image."
}

$oldBytes = [Text.Encoding]::UTF8.GetBytes("APFS for Windows copied-core insert proof")
$oldHash = Get-BytesSha256 -Bytes $oldBytes
$baseProbe = Get-ProbeFile -Probe $probe -Image $baseImage -Path "/renamed.txt"
if (-not $baseProbe.ok -or $baseProbe.sha256 -ine $oldHash) {
    throw "Crash-recovery base image has unexpected renamed.txt content."
}

$readOnlyGuard = Invoke-GuardedWorker -Executable $worker -Timeout $TimeoutSeconds `
    -Arguments @(
        "--target", $baseImage,
        "--mount", $Mount,
        "--test-fault-exit-phase", "before-image-replace",
        "--test-fault-path", "/renamed.txt"
    )
$rawGuardTarget = "\\.\PhysicalDrive2147483647"
$rawGuard = Invoke-GuardedWorker -Executable $worker -Timeout $TimeoutSeconds `
    -Arguments @(
        "--target", $rawGuardTarget,
        "--mount", $Mount,
        "--read-write",
        "--test-fault-exit-phase", "before-image-replace",
        "--test-fault-path", "/renamed.txt"
    )
$testFaultGuardsOk = $readOnlyGuard.exit_code -eq 2 -and $rawGuard.exit_code -eq 2 -and
    $readOnlyGuard.stderr -match "restricted to writable image files" -and
    $rawGuard.stderr -match "restricted to writable image files"

$phaseResults = @()
foreach ($phase in @("before-image-replace", "after-image-replace")) {
    $slug = $phase.Replace("-image-replace", "")
    $image = Join-Path $artifactDir "worker-crash-$slug.apfs"
    $stdout = Join-Path $artifactDir "worker-crash-$slug.out.txt"
    $stderr = Join-Path $artifactDir "worker-crash-$slug.err.txt"
    $trace = Join-Path $artifactDir "worker-crash-$slug.trace.txt"
    Remove-Item -LiteralPath $image, $stdout, $stderr, $trace -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $baseImage -Destination $image -Force

    $newBytes = [Text.Encoding]::UTF8.GetBytes("APFS worker crash boundary $phase`r`n")
    $newHash = Get-BytesSha256 -Bytes $newBytes
    $expectedHash = if ($phase -eq "before-image-replace") { $oldHash } else { $newHash }
    $expectedGeneration = if ($phase -eq "before-image-replace") { "old" } else { "new" }
    $process = $null
    $readProcess = $null
    $writeError = $null
    try {
        $env:APFS_WORKER_TRACE = $trace
        $process = Start-FaultWorker -Executable $worker `
            -Arguments @(
                "--target", $image,
                "--mount", $Mount,
                "--read-write",
                "--test-fault-exit-phase", $phase,
                "--test-fault-path", "/renamed.txt"
            )
        if (-not (Wait-PathState -Path $mountRoot -Present $true -Timeout $TimeoutSeconds)) {
            throw "Fault-injection mount did not appear for $phase"
        }

        try {
            [IO.File]::WriteAllBytes((Join-Path $mountRoot "renamed.txt"), $newBytes)
        } catch {
            $writeError = $_.Exception.Message
        }
        if (-not (Wait-ProcessExit -Process $process -Timeout $TimeoutSeconds)) {
            throw "Worker did not exit at test fault $phase"
        }
        $process.WaitForExit()
        $process.Refresh()
        $workerExitCode = $process.ExitCode
        $process.StandardOutput.ReadToEnd() | Set-Content -LiteralPath $stdout -Encoding UTF8
        $process.StandardError.ReadToEnd() | Set-Content -LiteralPath $stderr -Encoding UTF8
        $faultTraceMatch = (Get-Content -LiteralPath $trace -Raw -ErrorAction SilentlyContinue) `
            -match "TestFaultExit phase=$phase path=/renamed\.txt bytes=[1-9][0-9]* code=197"
        if (-not (Wait-PathState -Path $mountRoot -Present $false -Timeout $TimeoutSeconds)) {
            throw "Mount remained visible after worker exit at $phase"
        }

        $probeResult = Get-ProbeFile -Probe $probe -Image $image -Path "/renamed.txt"
        $probeHash = [string]$probeResult.sha256
        $scratchPattern = ".$([IO.Path]::GetFileName($image))-*.apfs"
        $scratchBeforeRemount = @(Get-ChildItem -LiteralPath $artifactDir `
            -Filter $scratchPattern -File -ErrorAction SilentlyContinue)

        Remove-Item Env:APFS_WORKER_TRACE -ErrorAction SilentlyContinue
        $readProcess = Start-Process -FilePath $worker `
            -ArgumentList @("--target", $image, "--mount", $Mount) `
            -WorkingDirectory (Split-Path -Parent $worker) `
            -WindowStyle Hidden `
            -PassThru
        if (-not (Wait-PathState -Path $mountRoot -Present $true -Timeout $TimeoutSeconds)) {
            throw "Read-only remount did not appear after $phase"
        }
        $remountHash = (Get-FileHash -LiteralPath (Join-Path $mountRoot "renamed.txt") `
            -Algorithm SHA256).Hash

        Stop-Process -Id $readProcess.Id -Force -ErrorAction SilentlyContinue
        $readProcess.WaitForExit(5000) | Out-Null
        $readProcess = $null
        Wait-PathState -Path $mountRoot -Present $false -Timeout $TimeoutSeconds | Out-Null

        $scratchAfterRemount = @(Get-ChildItem -LiteralPath $artifactDir -Filter $scratchPattern -File `
            -ErrorAction SilentlyContinue)
        $phaseOk = $workerExitCode -eq 197 -and $faultTraceMatch -and $probeResult.ok -and
            $probeHash -ieq $expectedHash -and $remountHash -ieq $expectedHash -and
            $scratchAfterRemount.Count -eq 0
        $phaseResults += [ordered]@{
            phase = $phase
            ok = [bool]$phaseOk
            worker_exit_code = $workerExitCode
            fault_trace_match = [bool]$faultTraceMatch
            selected_generation = $expectedGeneration
            expected_sha256 = $expectedHash
            probe_sha256 = $probeHash
            remount_sha256 = $remountHash
            probe_matches = [bool]($probeHash -ieq $expectedHash)
            remount_matches = [bool]($remountHash -ieq $expectedHash)
            write_error = $writeError
            abandoned_scratch_detected = @($scratchBeforeRemount | ForEach-Object { $_.Name })
            scratch_files_after_remount = @($scratchAfterRemount | ForEach-Object { $_.Name })
            scratch_cleanup_ok = [bool]($scratchAfterRemount.Count -eq 0)
            stdout = $stdout
            stderr = $stderr
            trace = $trace
        }
        $scratchAfterRemount | Remove-Item -Force -ErrorAction SilentlyContinue
    } finally {
        Remove-Item Env:APFS_WORKER_TRACE -ErrorAction SilentlyContinue
        foreach ($candidate in @($process, $readProcess)) {
            if ($candidate -and -not $candidate.HasExited) {
                Stop-Process -Id $candidate.Id -Force -ErrorAction SilentlyContinue
                $candidate.WaitForExit(5000) | Out-Null
            }
        }
    }
}

$ok = $testFaultGuardsOk -and $phaseResults.Count -eq 2 -and
    @($phaseResults | Where-Object { -not $_.ok }).Count -eq 0
$result = [ordered]@{
    component = "apfs_winfs_worker"
    check = "local_worker_crash_recovery"
    ok = [bool]$ok
    no_admin_required = -not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    no_reboot_performed = $true
    mount = $Mount
    base_image = $baseImage
    base_sha256 = (Get-FileHash -LiteralPath $baseImage -Algorithm SHA256).Hash
    old_content_sha256 = $oldHash
    test_fault_guards = [ordered]@{
        ok = [bool]$testFaultGuardsOk
        read_only_image_exit_code = $readOnlyGuard.exit_code
        read_only_image_rejected = [bool]($readOnlyGuard.stderr -match "restricted to writable image files")
        raw_target_exit_code = $rawGuard.exit_code
        raw_target_rejected = [bool]($rawGuard.stderr -match "restricted to writable image files")
    }
    phases = @($phaseResults)
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}

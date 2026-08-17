#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [string]$PackageName = "package.zip",
    [string]$BaseImageName = "base.apfs",
    [string]$OutputName = "raw-interruption-proof.json",
    [string]$Mount = "W:",
    [int]$PayloadBytes = 16777216,
    [int[]]$KillDelayMilliseconds = @(0, 100, 250, 500),
    [int]$TimeoutSeconds = 45,
    [switch]$AllowTestSignedDriver
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator rights are required for disposable VHD testing."
    }
}

function Wait-Condition {
    param([scriptblock]$Condition, [int]$Timeout)
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        try {
            if (& $Condition) { return $true }
        } catch {
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Invoke-DiskPart {
    param([string[]]$Commands)
    $scriptPath = Join-Path $RunRoot "diskpart-$([guid]::NewGuid().ToString('N')).txt"
    try {
        [IO.File]::WriteAllLines($scriptPath, $Commands, [Text.ASCIIEncoding]::new())
        $raw = @(& diskpart.exe /s $scriptPath 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "diskpart failed: $($raw -join ' ')"
        }
        return $raw
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Copy-Prefix {
    param(
        [string]$Source,
        [string]$Destination,
        [int64]$Length,
        [switch]$PreserveDestinationLength
    )
    $input = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite)
    $outputMode = if ($PreserveDestinationLength) {
        [IO.FileMode]::Open
    } else {
        [IO.FileMode]::Create
    }
    $output = [IO.File]::Open($Destination, $outputMode,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        if ($PreserveDestinationLength -and $output.Length -lt $Length) {
            throw "Destination is smaller than the requested prefix length."
        }
        $output.Position = 0
        $buffer = New-Object byte[] (1024 * 1024)
        [int64]$remaining = $Length
        while ($remaining -gt 0) {
            $wanted = [int][Math]::Min([int64]$buffer.Length, $remaining)
            $read = $input.Read($buffer, 0, $wanted)
            if ($read -le 0) { throw "Source ended before $Length bytes were copied." }
            $output.Write($buffer, 0, $read)
            $remaining -= $read
        }
        $output.Flush($true)
    } finally {
        $output.Dispose()
        $input.Dispose()
    }
}

function Get-ChangedBlockCount {
    param([string]$First, [string]$Second, [int]$BlockSize = 4096)
    $a = [IO.File]::OpenRead($First)
    $b = [IO.File]::OpenRead($Second)
    try {
        if ($a.Length -ne $b.Length) { throw "Compared APFS images have different sizes." }
        $aBytes = New-Object byte[] $BlockSize
        $bBytes = New-Object byte[] $BlockSize
        [int64]$changed = 0
        while ($a.Position -lt $a.Length) {
            $aRead = $a.Read($aBytes, 0, $aBytes.Length)
            $bRead = $b.Read($bBytes, 0, $bBytes.Length)
            if ($aRead -ne $bRead) { throw "Compared APFS image reads diverged." }
            $same = $true
            for ($index = 0; $index -lt $aRead; $index++) {
                if ($aBytes[$index] -ne $bBytes[$index]) { $same = $false; break }
            }
            if (-not $same) { $changed++ }
        }
        return $changed
    } finally {
        $b.Dispose()
        $a.Dispose()
    }
}

function Start-Worker {
    param([string]$Executable, [string[]]$Arguments, [string]$TracePath)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.WorkingDirectory = Split-Path -Parent $Executable
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.Arguments = (@($Arguments | ForEach-Object {
        '"' + $_.Replace('"', '\"') + '"'
    }) -join ' ')
    if ($TracePath) { $info.EnvironmentVariables["APFS_WORKER_TRACE"] = $TracePath }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw "Unable to start APFS worker." }
    return $process
}

function Stop-BoundedProcess {
    param($Process)
    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        $Process.WaitForExit(5000) | Out-Null
    }
}

function Detach-Vhd {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try {
            Invoke-DiskPart -Commands @(
                "select vdisk file=`"$Path`"",
                "detach vdisk") | Out-Null
        } catch {
        }
    }
}

function Get-DisposableDiskIdentity {
    param($Disk, [int64]$ExpectedSize)
    if (-not $Disk) { throw "Disposable VHD disk identity is missing." }
    $identity = [ordered]@{
        number = [int]$Disk.Number
        friendly_name = [string]$Disk.FriendlyName
        bus_type = [string]$Disk.BusType
        size_bytes = [int64]$Disk.Size
    }
    if ($identity.friendly_name -cne "Msft Virtual Disk" -or
        $identity.size_bytes -ne $ExpectedSize) {
        throw "Refusing raw write: attached disk is not the expected disposable VHD."
    }
    return $identity
}

function Start-PayloadWriter {
    param([string]$Source, [string]$Path)
    $escapedSource = $Source.Replace("'", "''")
    $escapedPath = $Path.Replace("'", "''")
    $code = @"
`$ErrorActionPreference='Stop'
[IO.File]::Copy('$escapedSource','$escapedPath',`$true)
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    Start-Process powershell.exe -ArgumentList @(
        "-NoProfile", "-NonInteractive", "-EncodedCommand", $encoded) `
        -WindowStyle Hidden -PassThru
}

Assert-Admin
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
if (-not $RunRoot.StartsWith("C:\Temp\apfs-raw-interruption-",
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "RunRoot must be a generated C:\Temp\apfs-raw-interruption-* path."
}
$packagePath = Join-Path $RunRoot $PackageName
$baseImage = Join-Path $RunRoot $BaseImageName
$outputPath = Join-Path $RunRoot $OutputName
foreach ($required in @($packagePath, $baseImage)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required VM test input is missing: $required"
    }
}
if (Test-Path -LiteralPath "$Mount\") {
    throw "Disposable test mount is already occupied: $Mount"
}
if (Get-Service ApfsForWindowsMountService -ErrorAction SilentlyContinue) {
    throw "APFS for Windows must be absent before the disposable VM test."
}

$startedUtc = (Get-Date).ToUniversalTime()
$packageHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
$baseHash = (Get-FileHash -LiteralPath $baseImage -Algorithm SHA256).Hash
$baseLength = [int64](Get-Item -LiteralPath $baseImage).Length
if ($baseLength -ne 67108864) { throw "Disposable APFS base image must be exactly 64 MiB." }
$payloadPath = Join-Path $RunRoot "payload.bin"
$payloadChunk = New-Object byte[] (1024 * 1024)
for ($i = 0; $i -lt $payloadChunk.Length; $i++) {
    $payloadChunk[$i] = [byte](($i * 31 + 17) -band 255)
}
$payloadStream = [IO.File]::Open($payloadPath, [IO.FileMode]::Create,
    [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    [int64]$remainingPayload = $PayloadBytes
    while ($remainingPayload -gt 0) {
        $count = [int][Math]::Min([int64]$payloadChunk.Length, $remainingPayload)
        $payloadStream.Write($payloadChunk, 0, $count)
        $remainingPayload -= $count
    }
    $payloadStream.Flush($true)
} finally {
    $payloadStream.Dispose()
}
$payloadChunk = $null
$payloadHash = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash
$invariantHash = "61A497B863F48F5ED9128653D6564E435E3C40612DE1BC58C2E94B95366C4BF9"
$emptyHash = "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
$extractRoot = Join-Path $RunRoot "package"
$packageDir = $null
$control = $null
$attempts = @()
$selected = $null
$installed = $false
$uninstalled = $false
$uninstallProof = Join-Path $RunRoot "uninstall-proof.json"
$activeWorker = $null
$activeWriter = $null
$activeVhd = $null
$errorText = $null

try {
    Expand-Archive -LiteralPath $packagePath -DestinationPath $extractRoot -Force
    $packageDir = if (Test-Path -LiteralPath (Join-Path $extractRoot `
            "install-apfs-for-windows.ps1") -PathType Leaf) {
        Get-Item -LiteralPath $extractRoot
    } else {
        Get-ChildItem -LiteralPath $extractRoot -Directory | Where-Object {
            Test-Path -LiteralPath (Join-Path $_.FullName `
                "install-apfs-for-windows.ps1") -PathType Leaf
        } | Select-Object -First 1
    }
    if (-not $packageDir) { throw "Package payload root was not found." }
    $installArgs = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $packageDir.FullName "install-apfs-for-windows.ps1"))
    if ($AllowTestSignedDriver) { $installArgs += "-AllowTestSignedDriver" }
    $installProcess = Start-Process powershell.exe -ArgumentList $installArgs `
        -WindowStyle Hidden -PassThru -Wait
    if ($installProcess.ExitCode -ne 0) { throw "Package install failed with exit code $($installProcess.ExitCode)." }
    $installed = $true
    Stop-Service ApfsForWindowsMountService -Force -ErrorAction Stop

    $installRoot = "$env:ProgramFiles\APFS for Windows"
    $worker = Join-Path $installRoot "apfs_winfs_worker.exe"
    $probe = Join-Path $installRoot "apfs_probe.exe"
    $metadata = Get-Content (Join-Path $packageDir.FullName `
        "apfs-build-metadata.json") -Raw | ConvertFrom-Json
    $workerHash = (Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash

    $mutationBase = Join-Path $RunRoot "mutation-base.apfs"
    Copy-Item -LiteralPath $baseImage -Destination $mutationBase -Force
    $prepareTrace = Join-Path $RunRoot "mutation-base.trace.log"
    $prepareWorker = Start-Worker -Executable $worker -TracePath $prepareTrace -Arguments @(
        "--target", $mutationBase, "--mount", $Mount, "--read-write")
    $activeWorker = $prepareWorker
    if (-not (Wait-Condition -Timeout $TimeoutSeconds -Condition {
            Test-Path -LiteralPath "$Mount\" })) {
        Stop-BoundedProcess -Process $prepareWorker
        throw "Mutation-baseline image mount did not appear."
    }
    [IO.File]::WriteAllBytes((Join-Path "$Mount\" "interrupted.bin"), [byte[]]@())
    $baselineReady = Wait-Condition -Timeout $TimeoutSeconds -Condition {
        $path = Join-Path "$Mount\" "interrupted.bin"
        (Test-Path -LiteralPath $path -PathType Leaf) -and
            [int64](Get-Item -LiteralPath $path).Length -eq 0
    }
    Stop-BoundedProcess -Process $prepareWorker
    $activeWorker = $null
    Wait-Condition -Timeout $TimeoutSeconds -Condition {
        -not (Test-Path -LiteralPath "$Mount\")
    } | Out-Null
    if (-not $baselineReady) { throw "Empty-file mutation baseline was not committed." }
    $mutationBaseHash = (Get-FileHash -LiteralPath $mutationBase -Algorithm SHA256).Hash

    $controlVhd = Join-Path $RunRoot "control.vhd"
    $controlPostImage = Join-Path $RunRoot "control-post.apfs"
    $controlTrace = Join-Path $RunRoot "control-worker.trace.log"
    $controlReadTrace = Join-Path $RunRoot "control-read.trace.log"
    $activeVhd = $controlVhd
    Remove-Item -LiteralPath $controlVhd, $controlPostImage, $controlTrace, `
        $controlReadTrace -Force -ErrorAction SilentlyContinue
    Invoke-DiskPart -Commands @(
        "create vdisk file=`"$controlVhd`" maximum=64 type=fixed") | Out-Null
    Copy-Prefix -Source $mutationBase -Destination $controlVhd -Length $baseLength `
        -PreserveDestinationLength

    $beforeControlDisks = @(Get-Disk | ForEach-Object Number)
    Invoke-DiskPart -Commands @(
        "select vdisk file=`"$controlVhd`"", "attach vdisk") | Out-Null
    $script:controlDisk = $null
    $controlDiskReady = Wait-Condition -Timeout $TimeoutSeconds -Condition {
        $script:controlDisk = Get-Disk |
            Where-Object { $beforeControlDisks -notcontains $_.Number } |
            Sort-Object Number | Select-Object -First 1
        $null -ne $script:controlDisk
    }
    $controlDisk = $script:controlDisk
    $script:controlDisk = $null
    if (-not $controlDiskReady -or -not $controlDisk) {
        throw "Attached control VHD disk was not discovered."
    }
    Set-Disk -Number $controlDisk.Number -IsReadOnly $false -ErrorAction Stop
    Set-Disk -Number $controlDisk.Number -IsOffline $true -ErrorAction Stop
    $controlDiskIdentity = Get-DisposableDiskIdentity -Disk $controlDisk `
        -ExpectedSize $baseLength
    $controlRawTarget = "\\.\PhysicalDrive$($controlDisk.Number)"

    $activeWorker = Start-Worker -Executable $worker -TracePath $controlTrace -Arguments @(
        "--target", $controlRawTarget, "--mount", $Mount, "--read-write", "--allow-raw-writes")
    if (-not (Wait-Condition -Timeout $TimeoutSeconds -Condition {
            Test-Path -LiteralPath "$Mount\" })) {
        throw "Control raw VHD APFS mount did not appear."
    }
    $activeWriter = Start-PayloadWriter -Source $payloadPath `
        -Path (Join-Path "$Mount\" "interrupted.bin")
    if (-not $activeWriter.WaitForExit($TimeoutSeconds * 1000)) {
        throw "Control payload writer did not finish."
    }
    $controlWriterExit = $activeWriter.ExitCode
    $activeWriter = $null
    $controlFlushDone = Wait-Condition -Timeout $TimeoutSeconds -Condition {
        (Get-Content -LiteralPath $controlTrace -Raw -ErrorAction SilentlyContinue) -match
            "StagedFlushDone status=0x00000000"
    }
    $controlMountedPath = Join-Path "$Mount\" "interrupted.bin"
    $controlMountedLength = if (Test-Path -LiteralPath $controlMountedPath -PathType Leaf) {
        [int64](Get-Item -LiteralPath $controlMountedPath).Length
    } else { $null }
    $controlMountedHash = if ($controlMountedLength -eq $PayloadBytes) {
        (Get-FileHash -LiteralPath $controlMountedPath -Algorithm SHA256).Hash
    } else { $null }
    Stop-BoundedProcess -Process $activeWorker
    $activeWorker = $null
    Wait-Condition -Timeout $TimeoutSeconds -Condition {
        -not (Test-Path -LiteralPath "$Mount\")
    } | Out-Null

    Detach-Vhd -Path $controlVhd
    Copy-Prefix -Source $controlVhd -Destination $controlPostImage -Length $baseLength
    $controlChangedBlocks = Get-ChangedBlockCount -First $mutationBase -Second $controlPostImage
    $controlProbeRaw = @(& $probe --target $controlPostImage 2>&1)
    $controlProbeExit = $LASTEXITCODE
    $controlProbeJson = if ($controlProbeExit -eq 0) {
        ($controlProbeRaw -join "`n") | ConvertFrom-Json
    } else { $null }
    $controlProbeOk = $controlProbeJson -and
        [string]$controlProbeJson.whole_device_detection.file_system -ceq "APFS"

    $controlReadWorker = Start-Worker -Executable $worker -TracePath $controlReadTrace -Arguments @(
        "--target", $controlPostImage, "--mount", $Mount)
    $activeWorker = $controlReadWorker
    $controlReadMounted = Wait-Condition -Timeout $TimeoutSeconds -Condition {
        Test-Path -LiteralPath "$Mount\"
    }
    $controlInvariantOk = $false
    $controlReadLength = $null
    $controlReadHash = $null
    if ($controlReadMounted) {
        $controlInvariantPath = Join-Path "$Mount\" "renamed.txt"
        $controlInvariantOk =
            (Test-Path -LiteralPath $controlInvariantPath -PathType Leaf) -and
            (Get-FileHash -LiteralPath $controlInvariantPath -Algorithm SHA256).Hash -ieq
                $invariantHash
        $controlReadPath = Join-Path "$Mount\" "interrupted.bin"
        if (Test-Path -LiteralPath $controlReadPath -PathType Leaf) {
            $controlReadLength = [int64](Get-Item -LiteralPath $controlReadPath).Length
            $controlReadHash = (Get-FileHash -LiteralPath $controlReadPath -Algorithm SHA256).Hash
        }
    }
    Stop-BoundedProcess -Process $controlReadWorker
    $activeWorker = $null
    Wait-Condition -Timeout $TimeoutSeconds -Condition {
        -not (Test-Path -LiteralPath "$Mount\")
    } | Out-Null

    $controlOk = $controlWriterExit -eq 0 -and $controlFlushDone -and
        $controlMountedLength -eq $PayloadBytes -and $controlMountedHash -ieq $payloadHash -and
        $controlChangedBlocks -gt 0 -and $controlProbeOk -and $controlInvariantOk -and
        $controlReadLength -eq $PayloadBytes -and $controlReadHash -ieq $payloadHash
    $control = [ordered]@{
        ok = [bool]$controlOk
        disk = $controlDiskIdentity
        writer_exit_code = $controlWriterExit
        flush_completed = [bool]$controlFlushDone
        mounted_file_size = $controlMountedLength
        mounted_file_sha256 = $controlMountedHash
        changed_blocks = [int64]$controlChangedBlocks
        probe_ok = [bool]$controlProbeOk
        invariant_ok = [bool]$controlInvariantOk
        remounted_file_size = $controlReadLength
        remounted_file_sha256 = $controlReadHash
        image_sha256 = (Get-FileHash -LiteralPath $controlPostImage -Algorithm SHA256).Hash
    }
    if (-not $controlOk) {
        throw "Completed raw-write control did not preserve the exact payload."
    }
    Remove-Item -LiteralPath $controlVhd, $controlPostImage -Force -ErrorAction SilentlyContinue
    $activeVhd = $null

    foreach ($delay in $KillDelayMilliseconds) {
        $attemptId = "delay-$delay"
        $vhdPath = Join-Path $RunRoot "$attemptId.vhd"
        $postImage = Join-Path $RunRoot "$attemptId-post.apfs"
        $tracePath = Join-Path $RunRoot "$attemptId-worker.trace.log"
        $activeVhd = $vhdPath
        Remove-Item -LiteralPath $vhdPath, $postImage, $tracePath -Force -ErrorAction SilentlyContinue
        Invoke-DiskPart -Commands @("create vdisk file=`"$vhdPath`" maximum=64 type=fixed") | Out-Null
        Copy-Prefix -Source $mutationBase -Destination $vhdPath -Length $baseLength `
            -PreserveDestinationLength

        $beforeDisks = @(Get-Disk | ForEach-Object Number)
        Invoke-DiskPart -Commands @("select vdisk file=`"$vhdPath`"", "attach vdisk") | Out-Null
        $script:attachedDisk = $null
        $diskReady = Wait-Condition -Timeout $TimeoutSeconds -Condition {
            $script:attachedDisk = Get-Disk |
                Where-Object { $beforeDisks -notcontains $_.Number } |
                Sort-Object Number | Select-Object -First 1
            $null -ne $script:attachedDisk
        }
        $newDisk = $script:attachedDisk
        $script:attachedDisk = $null
        if (-not $diskReady -or -not $newDisk) { throw "Attached VHD disk was not discovered." }
        Set-Disk -Number $newDisk.Number -IsReadOnly $false -ErrorAction Stop
        Set-Disk -Number $newDisk.Number -IsOffline $true -ErrorAction Stop
        $diskIdentity = Get-DisposableDiskIdentity -Disk $newDisk `
            -ExpectedSize $baseLength
        $rawTarget = "\\.\PhysicalDrive$($newDisk.Number)"

        $activeWorker = Start-Worker -Executable $worker -TracePath $tracePath -Arguments @(
            "--target", $rawTarget, "--mount", $Mount, "--read-write", "--allow-raw-writes")
        if (-not (Wait-Condition -Timeout $TimeoutSeconds -Condition { Test-Path -LiteralPath "$Mount\" })) {
            throw "Raw VHD APFS mount did not appear."
        }

        $activeWriter = Start-PayloadWriter -Source $payloadPath `
            -Path (Join-Path "$Mount\" "interrupted.bin")
        $flushObserved = Wait-Condition -Timeout $TimeoutSeconds -Condition {
            (Get-Content -LiteralPath $tracePath -Raw -ErrorAction SilentlyContinue) -match
                "StagedFlush /interrupted\.bin bytes=$PayloadBytes file_backed=1"
        }
        if (-not $flushObserved) { throw "Worker never entered staged raw flush." }
        if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
        $flushCompletedBeforeKill =
            (Get-Content -LiteralPath $tracePath -Raw -ErrorAction SilentlyContinue) -match
                "StagedFlushDone status=0x00000000"
        $killed = -not $activeWorker.HasExited
        if ($killed) { Stop-BoundedProcess -Process $activeWorker }
        $activeWorker = $null
        $flushCompletedAfterKill =
            (Get-Content -LiteralPath $tracePath -Raw -ErrorAction SilentlyContinue) -match
                "StagedFlushDone status=0x00000000"
        if (-not $activeWriter.WaitForExit(10000)) { Stop-BoundedProcess -Process $activeWriter }
        $writerExit = if ($activeWriter.HasExited) { $activeWriter.ExitCode } else { $null }
        $activeWriter = $null
        Wait-Condition -Timeout $TimeoutSeconds -Condition { -not (Test-Path -LiteralPath "$Mount\") } | Out-Null

        Detach-Vhd -Path $vhdPath
        Copy-Prefix -Source $vhdPath -Destination $postImage -Length $baseLength
        $changedBlocks = Get-ChangedBlockCount -First $mutationBase -Second $postImage
        $probeRaw = @(& $probe --target $postImage 2>&1)
        $probeExit = $LASTEXITCODE
        $probeJson = if ($probeExit -eq 0) { ($probeRaw -join "`n") | ConvertFrom-Json } else { $null }
        $probeOk = $probeJson -and
            [string]$probeJson.whole_device_detection.file_system -ceq "APFS"

        $readTrace = Join-Path $RunRoot "$attemptId-read.trace.log"
        $readWorker = Start-Worker -Executable $worker -TracePath $readTrace -Arguments @(
            "--target", $postImage, "--mount", $Mount)
        $activeWorker = $readWorker
        $readMounted = Wait-Condition -Timeout $TimeoutSeconds -Condition {
            Test-Path -LiteralPath "$Mount\"
        }
        $invariantOk = $false
        $generation = "invalid"
        $fileHash = $null
        $fileLength = $null
        if ($readMounted) {
            $invariantPath = Join-Path "$Mount\" "renamed.txt"
            $invariantOk = (Test-Path -LiteralPath $invariantPath -PathType Leaf) -and
                (Get-FileHash -LiteralPath $invariantPath -Algorithm SHA256).Hash -ieq
                    $invariantHash
            $interruptedPath = Join-Path "$Mount\" "interrupted.bin"
            if (Test-Path -LiteralPath $interruptedPath -PathType Leaf) {
                $item = Get-Item -LiteralPath $interruptedPath
                $fileLength = [int64]$item.Length
                $fileHash = (Get-FileHash -LiteralPath $interruptedPath -Algorithm SHA256).Hash
                if ($fileLength -eq 0 -and $fileHash -ieq $emptyHash) {
                    $generation = "old"
                } elseif ($fileLength -eq $PayloadBytes -and $fileHash -ieq $payloadHash) {
                    $generation = "new"
                }
            }
        }
        Stop-BoundedProcess -Process $readWorker
        $activeWorker = $null
        Wait-Condition -Timeout $TimeoutSeconds -Condition { -not (Test-Path -LiteralPath "$Mount\") } | Out-Null

        $attemptOk = $killed -and -not $flushCompletedBeforeKill -and
            -not $flushCompletedAfterKill -and $changedBlocks -gt 0 -and
            $probeOk -and $invariantOk -and
            $generation -in @("old", "new")
        $attempt = [ordered]@{
            delay_milliseconds = $delay
            ok = [bool]$attemptOk
            disk = $diskIdentity
            flush_observed = [bool]$flushObserved
            flush_completed_before_kill = [bool]$flushCompletedBeforeKill
            flush_completed_after_kill = [bool]$flushCompletedAfterKill
            worker_killed_during_flush = [bool]$killed
            writer_exit_code = $writerExit
            changed_blocks = [int64]$changedBlocks
            probe_ok = [bool]$probeOk
            invariant_ok = [bool]$invariantOk
            selected_generation = $generation
            interrupted_file_size = $fileLength
            interrupted_file_sha256 = $fileHash
            image_name = [IO.Path]::GetFileName($postImage)
            image_sha256 = (Get-FileHash -LiteralPath $postImage -Algorithm SHA256).Hash
        }
        $attempts += $attempt
        Remove-Item -LiteralPath $vhdPath -Force -ErrorAction SilentlyContinue
        $activeVhd = $null
        if ($attemptOk) { $selected = $attempt; break }
        Remove-Item -LiteralPath $postImage -Force -ErrorAction SilentlyContinue
    }
} catch {
    $errorText = $_.Exception.Message
} finally {
    Stop-BoundedProcess -Process $activeWriter
    Stop-BoundedProcess -Process $activeWorker
    Detach-Vhd -Path $activeVhd
    $installRoot = "$env:ProgramFiles\APFS for Windows"
    $mountServicePresent =
        [bool](Get-Service ApfsForWindowsMountService -ErrorAction SilentlyContinue)
    if ($installed -or $mountServicePresent -or
        (Test-Path -LiteralPath $installRoot)) {
        try {
            $uninstall = Join-Path $installRoot "uninstall-apfs-for-windows.ps1"
            if (-not (Test-Path -LiteralPath $uninstall -PathType Leaf) -and
                $packageDir) {
                $uninstall = Join-Path $packageDir.FullName "uninstall-apfs-for-windows.ps1"
            }
            if (-not (Test-Path -LiteralPath $uninstall -PathType Leaf)) {
                throw "Uninstaller was unavailable during partial-install cleanup."
            }
            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -File $uninstall -RemoveFiles -OutputPath $uninstallProof *> $null
            $uninstalled = $LASTEXITCODE -eq 0 -and
                -not (Get-Service ApfsForWindowsMountService -ErrorAction SilentlyContinue) -and
                -not (Get-Service "WinFsp+apfs-main" -ErrorAction SilentlyContinue) -and
                -not (Test-Path -LiteralPath $installRoot)
        } catch {
            if (-not $errorText) { $errorText = $_.Exception.Message }
        }
    } else {
        $uninstalled = $true
    }
}

$ok = -not $errorText -and $installed -and $uninstalled -and $selected -and $selected.ok
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "windows_vm_disposable_raw_interruption"
    ok = [bool]$ok
    no_host_reboot_performed = $true
    windows_vm_rebooted = $false
    physical_media_used = $false
    test_classification = "worker termination during raw commit to fixed disposable VHD"
    package_sha256 = $packageHash
    source_commit = if ($metadata) { [string]$metadata.source_commit } else { $null }
    worker_sha256 = if ($workerHash) { $workerHash } else { $null }
    base_image_sha256 = $baseHash
    mutation_base_sha256 = if ($mutationBaseHash) { $mutationBaseHash } else { $null }
    payload_bytes = $PayloadBytes
    payload_sha256 = $payloadHash
    completed_write_control = $control
    installed = [bool]$installed
    uninstalled = [bool]$uninstalled
    attempts = @($attempts)
    selected_attempt = $selected
    error = $errorText
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outputPath -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $ok) { exit 1 }

# Run a .z64 in standalone ares, capture the ISViewer log, and stop when the
# done marker appears or after a time limit. Retries when a run logs (almost)
# nothing: the first ares run after a build often stalls.
#
# Based on mvs64's tools/ps-ares-run.ps1 and shares its one-emulator lock
# (the "Global\mvs64-one-emulator" mutex), so runs from both repos never
# overlap.
#
# Usage: powershell -File tools\ares-run.ps1 -Rom n64z80_testsuite.z64
#            [-Out build\ares-testsuite.log] [-Seconds 900]
#            [-Done "*** N64Z80 TESTSUITE DONE ***"] [-MinLines 20] [-Tries 3]
#            [-Ares <ares.exe>]
# Exit code: 0 = done marker seen and no ">>> FAIL" lines, 1 = failures or no
# marker, 2 = could not run.
param(
    [Parameter(Mandatory=$true)][string]$Rom,
    [string]$Out = "build\ares-testsuite.log",
    [int]$Seconds = 900,
    [string]$Done = "*** N64Z80 TESTSUITE DONE ***",
    [int]$MinLines = 20,
    [int]$Tries = 3,
    [string]$Ares = $env:ARES_EXE
)

if (-not $Ares) {
    $cmd = Get-Command ares.exe -ErrorAction SilentlyContinue
    if ($cmd) { $Ares = $cmd.Source }
}
if (-not $Ares -or -not (Test-Path $Ares)) { Write-Host "[ares-run] ares not found: pass -Ares or set ARES_EXE"; exit 2 }
if (-not (Test-Path $Rom)) { Write-Host "[ares-run] ROM not found: $Rom"; exit 2 }
$Rom = (Resolve-Path $Rom).Path
$outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path (Get-Location) $Out }

# Read the log while ares still has it open for writing.
function Read-Log([string]$path) {
    if (-not (Test-Path $path)) { return @() }
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs)
        $text = $sr.ReadToEnd(); $sr.Close()
        return $text -split "`r?`n"
    } catch { return @() }
}

$mtx = New-Object System.Threading.Mutex($false, "Global\mvs64-one-emulator")
$got = $false
try { $got = $mtx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
if (-not $got) { Write-Host "[ares-run] REFUSED: another emulator run holds the lock"; exit 2 }
try {
    $busy = Get-Process -Name ares -ErrorAction SilentlyContinue
    if ($busy) { Write-Host "[ares-run] REFUSED: ares already running (pid $($busy.Id -join ','))"; exit 2 }

    for ($try = 1; $try -le $Tries; $try++) {
        Remove-Item $outPath, "$outPath.err" -ErrorAction SilentlyContinue
        Write-Host "[ares-run] try $try/${Tries}: $Rom (limit ${Seconds}s, log $outPath)"
        # Minimized: emulator windows must never steal focus.
        $p = Start-Process -FilePath $Ares -ArgumentList "`"$Rom`"" `
             -RedirectStandardOutput $outPath -RedirectStandardError "$outPath.err" `
             -PassThru -WindowStyle Minimized
        $start = Get-Date
        $deadline = $start.AddSeconds($Seconds)
        $sawDone = $false
        $stallAt = $start.AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            if ($p.HasExited) { Write-Host "[ares-run] ares exited early (code $($p.ExitCode))"; break }
            Start-Sleep -Seconds 3
            $log = Read-Log $outPath
            if ($log | Where-Object { $_.Contains($Done) }) { $sawDone = $true; break }
            # Nothing at all after a minute: a stalled first run, retry now.
            if ((Get-Date) -gt $stallAt -and $log.Count -lt 2) { break }
        }
        if (-not $p.HasExited) {
            # CloseMainWindow first: a clean quit flushes ares' block-buffered
            # stdout (a force-kill loses the last ~16KB).
            $null = $p.CloseMainWindow()
            if (-not $p.WaitForExit(8000)) { $p.Kill(); $p.WaitForExit() | Out-Null }
        }
        $log = Read-Log $outPath
        $secs = [int]((Get-Date) - $start).TotalSeconds
        Write-Host "[ares-run] stopped after ${secs}s: $($log.Count) lines"
        if ($log | Where-Object { $_.Contains($Done) }) { $sawDone = $true }
        if ($log.Count -ge $MinLines -or $sawDone) { break }
        Write-Host "[ares-run] fewer than $MinLines lines: retrying"
    }

    $log = Read-Log $outPath
    $log | Where-Object { $_ -match '^(>>>|\[BENCH\]|case |    )' } | ForEach-Object { Write-Host $_ }
    $fails = @($log | Where-Object { $_.StartsWith(">>> FAIL") }).Count
    if (-not $sawDone) { Write-Host "[ares-run] RESULT: no done marker"; exit 1 }
    if ($fails) { Write-Host "[ares-run] RESULT: $fails FAIL line(s)"; exit 1 }
    Write-Host "[ares-run] RESULT: done, no failures"
    exit 0
} finally {
    $mtx.ReleaseMutex()
}

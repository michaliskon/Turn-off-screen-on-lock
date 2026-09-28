# Provides the interactive launcher and hidden administrator handoff for wake tracing.
# The recorder module owns capture setup; this launcher never locks the PC itself.
param([switch]$check_only, [switch]$elevated, [ValidatePattern('^\d{8}-\d{6}-[a-f0-9]{8}$')][string]$run_id)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WakeTrace.psm1') -Force -DisableNameChecking
$capture_directory = $null
$result_path = $null

try {
    # A preparation-only invocation must never enter the recording handoff.
    if ($check_only -and $elevated) { throw 'Preparation checking cannot be combined with recording mode.' }
    if (-not $elevated) {
        Write-Host '20-minute screen-wake recording' -ForegroundColor Magenta
        Write-Host '0% [EXECUTION] Check Windows recording support'
        test_wake_trace_support
        Write-Host "50% $([char]0x2713) Windows recording support is available" -ForegroundColor Green
        if ($check_only) {
            Write-Host "100% $([char]0x2713) Preparation check passed. No recording was started." -ForegroundColor Green
            exit 0
        }
    }

    # Keep all elevated writes in a new folder beneath this repository's logs directory.
    $repository_root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    if (-not $run_id) {
        if ($elevated) { throw 'The administrator handoff is missing its recording identifier.' }
        $run_id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    }
    $capture_directory = Join-Path $repository_root "logs\wake-trace\$run_id"
    $ancestor = $capture_directory
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Recording paths must not traverse directory links: $ancestor"
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    $result_path = Join-Path $capture_directory 'launch-result.json'

    if ($elevated) {
        # The admin process stays hidden; its result is read by the original console.
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Windows administrator permission was not granted.'
        }
        $capture = start_wake_trace -capture_directory $capture_directory
        @{ success = $true; capture = $capture } | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $result_path -Encoding UTF8
        exit 0
    }

    # Wait only for startup. Windows subsequently stops the recording independently.
    New-Item -ItemType Directory -Path $capture_directory -ErrorAction Stop | Out-Null
    Write-Host 'Duration: 20 minutes. Trace size limit: 512 MB.'
    Write-Host "Save folder: $capture_directory"
    Write-Host '50% [EXECUTION] Start recording with administrator permission'
    $child_arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -elevated -run_id {1}' -f $PSCommandPath, $run_id
    $child = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $child_arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if (-not (Test-Path -LiteralPath $result_path)) {
        throw "The recorder did not return a startup result (exit $($child.ExitCode))."
    }
    $result = Get-Content -LiteralPath $result_path -Raw | ConvertFrom-Json
    if (-not $result.success) { throw $result.error }
    if ($child.ExitCode -ne 0) { throw "The recorder exited with code $($child.ExitCode)." }
    $stop_time = [DateTimeOffset]::Parse($result.capture.expected_stop_at).ToLocalTime().ToString('HH:mm:ss')
    Write-Host "100% $([char]0x2713) Recording started. Windows will stop it around $stop_time." -ForegroundColor Green
    Write-Host 'Press Win+L now, leave the usual devices connected, and leave the PC on.' -ForegroundColor Yellow
    Write-Host 'You can close this window. No need to return after 20 minutes.'
    exit 0
}
catch {
    $failure_message = $_.Exception.Message
    if ($elevated -and $result_path -and (Test-Path -LiteralPath $capture_directory)) {
        try { @{ success = $false; error = $failure_message } | ConvertTo-Json | Set-Content -LiteralPath $result_path -Encoding UTF8 }
        catch { Write-Error -Message "Could not save the startup error: $($_.Exception.Message)" -ErrorAction Continue }
    }
    if (-not $elevated) {
        Write-Host "[X] Recording was not confirmed: $failure_message" -ForegroundColor Red
    }
    exit 1
}

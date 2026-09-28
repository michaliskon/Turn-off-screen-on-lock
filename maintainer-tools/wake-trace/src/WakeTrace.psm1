# Configures the one-time Windows wake recording and its diagnostic files.
# Windows owns the stop timer; this module does not change display or wake settings.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TRACE_PROVIDERS = @(
    @{ name = 'Microsoft-Windows-Kernel-Power'; keywords = '0x10405' }
    @{ name = 'Microsoft-Windows-Input-HIDCLASS'; keywords = '0x1' }
    @{ name = 'Microsoft-Windows-USB-USBHUB3'; keywords = '0x8048' }
    @{ name = 'Microsoft-Windows-USB-UCX'; keywords = '0x8048' }
    @{ name = 'Microsoft-Windows-USB-USBXHCI'; keywords = '0x8048' }
)

# Starts a bounded capture in the caller's fresh directory and returns its timing.
# Only the uniquely named collector created here may be stopped or removed on failure.
function start_wake_trace {
    param([Parameter(Mandatory)][string]$capture_directory)

    # Restrict writes to project diagnostic history and preserve earlier recordings.
    $capture_root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\logs\wake-trace')) + [IO.Path]::DirectorySeparatorChar
    $requested_directory = [IO.Path]::GetFullPath($capture_directory)
    if (-not $requested_directory.StartsWith($capture_root, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The recording folder must be inside the repository logs/wake-trace directory.'
    }
    $capture_directory = (Resolve-Path -LiteralPath $capture_directory).ProviderPath
    if (@(Get-ChildItem -LiteralPath $capture_directory -Force).Count -ne 0) {
        throw 'The recording folder must be empty. Start the launcher again for a fresh folder.'
    }

    # Save the connected device names before tracing so identifiers remain interpretable.
    $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Class -in @('Mouse', 'Keyboard', 'HIDClass', 'USB') } | Select-Object Class, FriendlyName, InstanceId, Status)
    ConvertTo-Json -InputObject $devices -Depth 4 | Set-Content -LiteralPath (Join-Path $capture_directory 'devices.json') -Encoding UTF8
    $collector_name = 'TurnOffScreen-WakeTrace-' + [Guid]::NewGuid().ToString('N')
    $collector_created = $false
    $start_attempted = $false

    try {
        # The persisted Windows collector owns the stop timer after this process exits.
        # Circular storage limits disk use; USB 0x8048 selects Rundown, Power and headers,
        # deliberately excluding PartialDataBusTrace and FullDataBusTrace payloads.
        $trace_path = Join-Path $capture_directory 'wake.etl'
        invoke_trace_command -command_arguments @('create', 'trace', $collector_name, '-o', "`"$trace_path`"", '-f', 'bincirc', '-max', '512', '-ct', 'perf', '-bs', '64', '-nb', '16', '128')
        $collector_created = $true
        foreach ($provider in $TRACE_PROVIDERS) {
            invoke_trace_command -command_arguments @('update', 'trace', $collector_name, '-p', $provider.name, $provider.keywords, '5')
        }

        # Set the 20-minute stop condition via PLA COM directly. logman's -rf
        # parser uses the OS locale's time separator, which can differ from
        # PowerShell's CurrentCulture (e.g. en-DK uses '.' while WinPS 5.1
        # reports en-US with ':'), making string-based durations unreliable.
        $collector = New-Object -ComObject Pla.DataCollectorSet
        $collector.Query($collector_name, $null)
        $collector.Duration = 1200
        $collector.Commit($collector_name, $null, 0x0003) | Out-Null

        # Re-read to verify: no repeat schedule, no segmentation, and an
        # actual 1200-second overall stop condition are required.
        $collector.Query($collector_name, $null)
        if ($collector.Duration -ne 1200 -or $collector.Schedules.Count -ne 0 -or $collector.Segment) {
            throw "Windows did not save the required one-time 20-minute stop condition (Duration=$($collector.Duration), Schedules=$($collector.Schedules.Count), Segment=$($collector.Segment))."
        }
        $started_at = [DateTimeOffset]::Now
        $start_attempted = $true
        invoke_trace_command -command_arguments @('start', $collector_name)
        $collector.Query($collector_name, $null)
        if ([int]$collector.Status -ne 1) {
            throw 'Windows did not report that the recording is running.'
        }

        # Persist the session identity for analysis, an early manual stop and later cleanup.
        $capture = [pscustomobject]@{ collector_name = $collector_name; start_requested_at = $started_at.ToString('o'); expected_stop_at = $started_at.AddMinutes(20).ToString('o'); duration_seconds = 1200; output_directory = $capture_directory; trace_files = 'wake*.etl'; maximum_trace_mb = 512; providers = $TRACE_PROVIDERS }
        $capture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $capture_directory 'capture.json') -Encoding UTF8
        return $capture
    }
    catch {
        # Roll back only this attempted recording, retaining files and the original error.
        $failure_message = $_.Exception.Message
        if ($start_attempted) {
            try { invoke_trace_command -command_arguments @('stop', $collector_name) }
            catch { $failure_message += "`nCould not confirm this recorder stopped: $($_.Exception.Message)" }
        }
        if ($collector_created) {
            try { invoke_trace_command -command_arguments @('delete', $collector_name) }
            catch { $failure_message += "`nCould not remove this recorder's definition: $($_.Exception.Message)" }
        }
        throw $failure_message
    }
}

# Checks the installed providers without enabling a trace or writing any files.
function test_wake_trace_support {
    foreach ($provider in $TRACE_PROVIDERS) {
        invoke_trace_command -command_arguments @('query', 'providers', $provider.name)
    }
    Get-Command Get-PnpDevice -ErrorAction Stop | Out-Null
}

# Runs the Windows tracing command and preserves a nonzero native exit as a failure.
function invoke_trace_command {
    param([string[]]$command_arguments)

    $command_output = & "$env:SystemRoot\System32\logman.exe" @command_arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "logman $($command_arguments -join ' ') failed (exit $LASTEXITCODE): $($command_output -join [Environment]::NewLine)"
    }
}

Export-ModuleMember -Function test_wake_trace_support, start_wake_trace

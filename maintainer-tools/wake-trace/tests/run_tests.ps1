# Runs only the wake recorder's maintenance suite, with no capture, elevation or files.
# Windows mutations are isolated; a real read-only native failure checks exit propagation.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WakeTrace.TestSupport.ps1')
$module_path = Join-Path $PSScriptRoot '..\src\WakeTrace.psm1'
$repository_root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$capture_directory = Join-Path $repository_root 'logs\wake-trace\in-memory-test'

# Fails immediately when a real recorder decision violates the stated safety property.
function assert_true {
    param([bool]$condition, [string]$message)
    if (-not $condition) { throw $message }
}

# The real startup must request a persisted, bounded capture and preserve useful metadata.
$case = invoke_wake_trace_case $module_path $capture_directory
assert_true ($null -eq $case.failure) "Startup failed: $($case.failure)"
$create = $case.commands[0]
assert_true ($create[0] -eq 'create') 'Startup did not create its own collector first.'
assert_true ($create[[Array]::IndexOf($create, '-max') + 1] -eq '512') 'Trace disk use is not bounded.'
assert_true ($create[[Array]::IndexOf($create, '-f') + 1] -eq 'bincirc') 'The recorder is not circular.'
assert_true (-not (($case.commands | ForEach-Object { $_ -join ' ' }) -match '-ets')) 'A direct session would bypass the persisted timer.'
$updates = @($case.commands | Where-Object { $_[0] -eq 'update' })
assert_true ($updates.Count -eq 5) 'Required providers are missing.'
foreach ($update in $updates) {
    if ($update[4] -like 'Microsoft-Windows-USB-*') {
        $keywords = [Convert]::ToInt32($update[5].Substring(2), 16)
        assert_true (($keywords -band 0x180) -eq 0) 'USB input payload capture must remain disabled.'
        assert_true (($keywords -band 0x8048) -eq 0x8048) 'USB identity, power or transfer headers are missing.'
    }
}
assert_true ($case.commands[-1][0] -eq 'start') 'Startup unexpectedly stopped or deleted the capture.'
$manifest = $case.writes['capture.json'] | ConvertFrom-Json
assert_true ($manifest.duration_seconds -eq 1200) 'Capture metadata has the wrong duration.'
assert_true (([DateTimeOffset]::Parse($manifest.expected_stop_at) - [DateTimeOffset]::Parse($manifest.start_requested_at)).TotalSeconds -eq 1200) 'Reported stop time does not match the requested duration.'
assert_true ($manifest.collector_name -eq $create[2]) 'Saved collector identity does not identify this capture.'
assert_true ($case.writes.ContainsKey('devices.json')) 'Connected device metadata was not saved.'
Write-Host 'PASS: bounded 20-minute capture, payload exclusion and saved metadata'

# A bad native timer, repeat schedule or segmentation must prevent the trace from starting.
foreach ($options in @(@{ duration = 0 }, @{ scheduled = 1 }, @{ segment = $true })) {
    $case = invoke_wake_trace_case $module_path $capture_directory $options
    assert_true ($case.failure -like '*stop condition*') 'Unsafe Windows timer readback was accepted.'
    assert_true (@($case.commands | Where-Object { $_[0] -eq 'start' }).Count -eq 0) 'An unbounded collector was started.'
    assert_true ($case.commands[-1][0] -eq 'delete') 'The rejected collector was not cleaned up.'
}
Write-Host 'PASS: Windows timer readback rejects unbounded or repeating capture'

# Each native failure must propagate; cleanup must only target the newly created collector.
foreach ($verb in @('create', 'update', 'start')) {
    $case = invoke_wake_trace_case $module_path $capture_directory @{ failed_verb = $verb }
    assert_true ($case.failure -like "*Controlled $verb failure*") "The $verb failure was hidden."
    if ($verb -eq 'create') {
        assert_true ($case.commands.Count -eq 1) 'A failed create must not touch another collector.'
        continue
    }
    $owned_name = $case.commands[0][2]
    $cleanup = @($case.commands | Where-Object { $_[0] -in @('stop', 'delete') })
    foreach ($command in $cleanup) { assert_true ($command[1] -eq $owned_name) 'Cleanup targeted a different recording.' }
    assert_true ($case.commands[-1][0] -eq 'delete') 'Failed startup did not remove its collector.'
}
Write-Host 'PASS: native failures propagate and cleanup is limited to the owned collector'

# A failed running-state check or metadata write must stop the just-started capture.
foreach ($options in @(@{ status = 0 }, @{ failed_file = 'capture.json' })) {
    $case = invoke_wake_trace_case $module_path $capture_directory $options
    assert_true ($null -ne $case.failure) 'Startup falsely reported success.'
    assert_true ($case.commands[-2][0] -eq 'stop') 'Failed startup left its trace running.'
    assert_true ($case.commands[-1][0] -eq 'delete') 'Failed startup left its collector definition behind.'
}
Write-Host 'PASS: startup verification and metadata failures stop the attempted recording'

# Existing recordings, unavailable inventory and external output paths cannot start traces.
foreach ($options in @(@{ occupied = $true }, @{ inventory_failure = $true }, @{ failed_file = 'devices.json' })) {
    $case = invoke_wake_trace_case $module_path $capture_directory $options
    assert_true ($null -ne $case.failure -and $case.commands.Count -eq 0) 'Invalid preparation reached Windows trace startup.'
}
$case = invoke_wake_trace_case $module_path (Join-Path $repository_root '..\outside-capture')
assert_true ($case.failure -like '*inside the repository*' -and $case.commands.Count -eq 0 -and $case.writes.Count -eq 0) 'An external output path was accepted.'
Write-Host 'PASS: existing files and output containment are protected'

# Exercise the actual native adapter with a nonexistent provider; this is read-only.
$module = Import-Module $module_path -Force -PassThru -DisableNameChecking
try {
    $native_failure = $null
    try { & $module { invoke_trace_command -command_arguments @('query', 'providers', 'TurnOffScreen-Test-Missing-Provider') } }
    catch { $native_failure = $_.Exception.Message }
    assert_true ($native_failure -like '*logman query providers*failed (exit*') 'The real logman adapter did not propagate a nonzero exit.'
}
finally { Remove-Module $module }
Write-Host 'PASS: real native failure propagation (read-only provider query)'
Write-Host 'All wake recorder checks passed. No recording was started.'

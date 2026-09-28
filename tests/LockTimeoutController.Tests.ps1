# Checks real controller success and failure paths using in-memory boundaries.
# No runtime files, Windows power settings, secrets, or external APIs are used.
param([Parameter(Mandatory = $true)][string]$source_root)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LockTimeoutController.TestSupport.ps1')
$controller_path = Join-Path $source_root 'LockTimeoutController.ps1'

# Each action must retain its existing timeout and avoid logging on success.
foreach ($action in @('OnLock', 'OnUnlock', 'PromoteOnWake')) {
    $result = invoke_controller_case $controller_path $action
    $seconds = if ($action -eq 'PromoteOnWake') { 60 } else { 5 }
    $expected = @("/setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK $seconds", "/setdcvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK $seconds", '/setactive SCHEME_CURRENT')
    if ($result.error_record -or ($result.power_calls -join '|') -ne ($expected -join '|') -or $result.writes.ContainsKey('last-error.log')) { throw "Success behavior changed for $action" }
    if ($action -ne 'PromoteOnWake') {
        $state = $result.writes['state.json'] | ConvertFrom-Json
        $expected_status = if ($action -eq 'OnLock') { 'locked' } else { 'unlocked' }
        if ($state.status -ne $expected_status -or -not $state.generation) { throw "State behavior changed for $action" }
    }
    Write-Output "PASS: $action retains its timeout and successful behavior"
}

# Wake events must remain harmless when unlocked or missing a cycle identifier.
foreach ($options in @(@{ status = 'unlocked' }, @{ generation = '' })) {
    $result = invoke_controller_case $controller_path PromoteOnWake $options
    if ($result.error_record -or $result.power_calls.Count -ne 0 -or $result.writes.Count -ne 0) { throw 'A wake no-op changed settings or logged an error' }
}
Write-Output 'PASS: wake no-ops remain unchanged'

# Each native command failure must stop later commands and identify its cause.
$command_index = 0
foreach ($command in @('/setacvalueindex', '/setdcvalueindex', '/setactive')) {
    $command_index++
    $result = invoke_controller_case $controller_path OnLock @{ failed_command = $command }
    $log_entry = $result.writes['last-error.log']
    if (-not $result.error_record -or $result.power_calls.Count -ne $command_index) { throw "Failure did not stop at $command" }
    if ($log_entry -notmatch '^\d{4}-\d{2}-\d{2}T.*Z Action=OnLock' -or -not $log_entry.Contains("powercfg $command failed (exit code 5)") -or -not $log_entry.Contains('Simulated power setting failure')) { throw "Missing diagnostic details for $command" }
    Write-Output "PASS: $command failure is logged and propagated"
}

# A failed log write must preserve the original powercfg failure and warn explicitly.
$result = invoke_controller_case $controller_path OnUnlock @{ failed_command = '/setacvalueindex'; log_failure = $true }
if ($result.error_record.Exception.Message -notlike '*powercfg /setacvalueindex failed*' -or $result.warnings.Count -ne 1) { throw 'Log failure replaced the controller error' }
Write-Output 'PASS: log-write failure preserves the original error'

# Malformed state must be logged without promoting the power timeout.
$result = invoke_controller_case $controller_path PromoteOnWake @{ corrupt_state = $true }
if (-not $result.error_record -or $result.power_calls.Count -ne 0 -or $result.writes['last-error.log'] -notlike '*Action=PromoteOnWake*') { throw 'Malformed state was not logged safely' }
Write-Output 'PASS: malformed state is logged without changing power settings'

# State-write failures must be reported before any power command is attempted.
$result = invoke_controller_case $controller_path OnLock @{ state_failure = $true }
if ($result.error_record.Exception.Message -ne 'Simulated state write failure' -or $result.power_calls.Count -ne 0 -or $result.writes['last-error.log'] -notlike '*Simulated state write failure*') { throw 'State-write failure was not preserved and logged' }
Write-Output 'PASS: state-write failure is logged and stops the action'

# Startup failures must enter the same error path, even if no log can be written.
$result = invoke_controller_case $controller_path OnLock @{ directory_failure = $true }
if ($result.error_record.Exception.Message -ne 'Simulated runtime directory failure' -or $result.power_calls.Count -ne 0 -or $result.warnings.Count -ne 1) { throw 'Runtime directory failure was not preserved' }
Write-Output 'PASS: runtime directory failure preserves its original cause'

# Very long native errors must be bounded in the log but preserved for the caller.
$result = invoke_controller_case $controller_path OnLock @{ failed_command = '/setacvalueindex'; error_text = ('x' * 10000) }
if ($result.writes['last-error.log'].Length -gt 4250 -or $result.writes['last-error.log'] -notlike '*[[]truncated]' -or $result.error_record.Exception.Message.Length -lt 10000) { throw 'Error truncation did not preserve the caller error or bound the log' }
Write-Output 'PASS: log size is bounded without truncating the propagated error'

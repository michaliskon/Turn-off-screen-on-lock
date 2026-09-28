# Exercises the real hidden launcher and real controller in Windows Script Host.
# An existing file blocks the test data directory before any power-setting writes.
param([Parameter(Mandatory = $true)][string]$source_root)

$ErrorActionPreference = 'Stop'
$controller_path = Join-Path $source_root 'LockTimeoutController.ps1'
$launcher_path = Join-Path $source_root 'RunHidden.vbs'
$original_local_app_data = $env:LOCALAPPDATA

# A file cannot contain the runtime directory, so the real controller must fail safely.
try {
    $env:LOCALAPPDATA = $controller_path
    $ErrorActionPreference = 'Continue'
    $controller_output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $controller_path -Action OnLock 2>&1
    $controller_exit = $LASTEXITCODE
    $launcher_output = & cscript.exe //B //Nologo $launcher_path OnLock 2>&1
    $launcher_exit = $LASTEXITCODE
}
finally {
    $env:LOCALAPPDATA = $original_local_app_data
    $ErrorActionPreference = 'Stop'
}

if ($controller_exit -ne 1 -or ($controller_output -join "`n") -notlike '*original controller error is preserved*') { throw 'The controlled controller failure did not reach the expected error path' }
if ($launcher_output) { throw "Windows Script Host failed before the launcher check: $launcher_output" }
if ($launcher_exit -ne $controller_exit) { throw "Launcher masked controller exit code $controller_exit with $launcher_exit" }
Write-Output 'PASS: real launcher waits for the controller and returns its failure code'

# Invalid actions must still be rejected before a controller is launched.
& cscript.exe //B //Nologo $launcher_path InvalidAction
if ($LASTEXITCODE -ne 1) { throw 'Launcher no longer rejects invalid actions' }
Write-Output 'PASS: launcher action validation is preserved'

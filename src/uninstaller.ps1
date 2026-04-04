[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host $Message -ForegroundColor $Color
}

function Invoke-VerificationCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Check
    )

    Write-Host "  Checking: $Label...  " -NoNewline

    try {
        $result = & $Check
        Write-Host 'PASS' -ForegroundColor Green
        return $result
    }
    catch {
        Write-Host 'FAIL' -ForegroundColor Red
        throw
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-ExistingTaskIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        return
    }

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop

    $deadline = (Get-Date).AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 200
        $stillThere = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $stillThere) {
            return
        }
    } while ((Get-Date) -lt $deadline)

    throw "Existing task could not be removed cleanly: $TaskName"
}

function Get-VideoConLockValues {
    $output = & powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query VIDEOCONLOCK. Output: $($output -join [Environment]::NewLine)"
    }

    $text = ($output -join [Environment]::NewLine)
    $acMatch = [regex]::Match($text, 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)')
    $dcMatch = [regex]::Match($text, 'Current DC Power Setting Index:\s+0x([0-9a-fA-F]+)')

    if (-not $acMatch.Success -or -not $dcMatch.Success) {
        throw 'Unable to parse VIDEOCONLOCK AC/DC values from powercfg output.'
    }

    [pscustomobject]@{
        AC  = [Convert]::ToInt32($acMatch.Groups[1].Value, 16)
        DC  = [Convert]::ToInt32($dcMatch.Groups[1].Value, 16)
        Raw = $text
    }
}

function Restore-VideoConLock {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 86400)]
        [int]$AC,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 86400)]
        [int]$DC
    )

    $output = & powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK $AC 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /setacvalueindex failed (exit code $LASTEXITCODE). Output: $($output -join [Environment]::NewLine)"
    }

    $output = & powercfg /setdcvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK $DC 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /setdcvalueindex failed (exit code $LASTEXITCODE). Output: $($output -join [Environment]::NewLine)"
    }

    $output = & powercfg /setactive SCHEME_CURRENT 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /setactive failed (exit code $LASTEXITCODE). Output: $($output -join [Environment]::NewLine)"
    }
}

if (-not (Test-IsAdministrator)) {
    Write-Host ''
    Write-Status 'ERROR: uninstaller.ps1 must be run from an elevated PowerShell window.' Red
    Write-Status 'Open PowerShell with "Run as administrator" and run the uninstaller again.' Yellow
    Write-Host ''
    exit 1
}

$TaskNameOnLock = 'Turn-off screen on lock - On Lock'
$TaskNameOnUnlock = 'Turn-off screen on lock - On Unlock'
$TaskNameOnWake = 'Turn-off screen on lock - On Wake'

$DataDir = Join-Path $env:LOCALAPPDATA 'Turn-off-screen-on-lock'
$BaselinePath = Join-Path $DataDir 'baseline.json'

$DefaultAC = 60
$DefaultDC = 60

try {
    Write-Status 'Starting uninstallation...' Cyan

    # --- Actions ---

    Write-Status 'Removing scheduled tasks...' Cyan
    Remove-ExistingTaskIfPresent -TaskName $TaskNameOnLock
    Remove-ExistingTaskIfPresent -TaskName $TaskNameOnUnlock
    Remove-ExistingTaskIfPresent -TaskName $TaskNameOnWake

    Write-Status 'Restoring VIDEOCONLOCK...' Cyan
    $restoreAC = $DefaultAC
    $restoreDC = $DefaultDC

    if (Test-Path -LiteralPath $BaselinePath) {
        try {
            $b = Get-Content -LiteralPath $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $b.originalAC -and $null -ne $b.originalDC) {
                $restoreAC = [int]$b.originalAC
                $restoreDC = [int]$b.originalDC
            }
            else {
                Write-Status '  baseline.json is missing values. Falling back to defaults.' Yellow
            }
        }
        catch {
            Write-Status '  baseline.json is malformed. Falling back to defaults.' Yellow
        }
    }
    else {
        Write-Status '  baseline.json not found. Falling back to defaults.' Yellow
    }

    Restore-VideoConLock -AC $restoreAC -DC $restoreDC

    Write-Status 'Removing uninstaller environment variable...' Cyan
    $sourceDir = $null
    $uninstallVar = [Environment]::GetEnvironmentVariable('TURN_OFF_SCREEN_ON_LOCK_UNINSTALL', 'User')
    if ($uninstallVar) {
        $sourceDir = Split-Path -Parent $uninstallVar
    }
    [Environment]::SetEnvironmentVariable('TURN_OFF_SCREEN_ON_LOCK_UNINSTALL', $null, 'User')
    Remove-Item -Path 'Env:\TURN_OFF_SCREEN_ON_LOCK_UNINSTALL' -ErrorAction SilentlyContinue

    Write-Status 'Removing runtime state directory...' Cyan
    if (Test-Path -LiteralPath $DataDir) {
        [System.IO.Directory]::Delete($DataDir, $true)
    }

    # --- Verification ---

    Invoke-VerificationCheck -Label 'On Lock task is removed' -Check {
        $t = Get-ScheduledTask -TaskName $TaskNameOnLock -ErrorAction SilentlyContinue
        if ($null -ne $t) { throw "Task still exists: $TaskNameOnLock" }
        $true
    } | Out-Null

    Invoke-VerificationCheck -Label 'On Unlock task is removed' -Check {
        $t = Get-ScheduledTask -TaskName $TaskNameOnUnlock -ErrorAction SilentlyContinue
        if ($null -ne $t) { throw "Task still exists: $TaskNameOnUnlock" }
        $true
    } | Out-Null

    Invoke-VerificationCheck -Label 'On Wake task is removed' -Check {
        $t = Get-ScheduledTask -TaskName $TaskNameOnWake -ErrorAction SilentlyContinue
        if ($null -ne $t) { throw "Task still exists: $TaskNameOnWake" }
        $true
    } | Out-Null

    Invoke-VerificationCheck -Label "VIDEOCONLOCK AC=$restoreAC DC=$restoreDC" -Check {
        $values = Get-VideoConLockValues
        if ($values.AC -ne $restoreAC -or $values.DC -ne $restoreDC) {
            throw "Expected AC=$restoreAC DC=$restoreDC, found AC=$($values.AC) DC=$($values.DC)."
        }
        $values
    } | Out-Null

    Invoke-VerificationCheck -Label 'Uninstaller environment variable is removed' -Check {
        $val = [Environment]::GetEnvironmentVariable('TURN_OFF_SCREEN_ON_LOCK_UNINSTALL', 'User')
        if ($null -ne $val) {
            throw "Environment variable still exists with value: $val"
        }
        $true
    } | Out-Null

    Invoke-VerificationCheck -Label 'State directory is removed' -Check {
        if (Test-Path -LiteralPath $DataDir) {
            throw "State directory still exists: $DataDir"
        }
        $true
    } | Out-Null

    Write-Host ''
    Write-Status 'Uninstallation completed successfully.' Green
    if ($sourceDir) {
        Write-Status "You may now delete the script folder if desired: $sourceDir" Yellow
    }
    else {
        Write-Status 'You may now delete the script folder if desired.' Yellow
    }
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Status 'Uninstallation failed.' Red
    Write-Status $_.Exception.Message Yellow
    Write-Host ''
    throw
}

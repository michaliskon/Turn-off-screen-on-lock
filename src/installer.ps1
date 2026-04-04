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

    # Print the check label first, keep the final result on the same line,
    # and stop the installer immediately if the check throws.
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

function Test-FileExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required file is missing: $Path"
    }
}

function Initialize-StateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $defaultState = [pscustomobject]@{
        status        = 'unlocked'
        generation    = [guid]::NewGuid().Guid
        lastActionUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $defaultState | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
        return
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw 'state.json is empty.'
        }

        $parsed = $raw | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$parsed.status)) {
            throw 'state.json is missing status.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$parsed.generation)) {
            throw 'state.json is missing generation.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$parsed.lastActionUtc)) {
            throw 'state.json is missing lastActionUtc.'
        }
    }
    catch {
        # If the current file is missing, empty, or malformed, repair it in place
        # instead of leaving the runtime components to fail later.
        $defaultState | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

function Set-VideoConLock {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 86400)]
        [int]$Seconds
    )

    # Always write both AC and DC because the feature must behave the same on
    # mains power and battery unless explicitly changed later.
    $output = & powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK $Seconds 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /setacvalueindex failed (exit code $LASTEXITCODE). Output: $($output -join [Environment]::NewLine)"
    }

    $output = & powercfg /setdcvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK $Seconds 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /setdcvalueindex failed (exit code $LASTEXITCODE). Output: $($output -join [Environment]::NewLine)"
    }

    $output = & powercfg /setactive SCHEME_CURRENT 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /setactive failed (exit code $LASTEXITCODE). Output: $($output -join [Environment]::NewLine)"
    }
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

function Register-TaskFromXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [Parameter(Mandatory = $true)]
        [string]$Xml,

        [string[]]$ExpectedStates = @('Ready')
    )

    Remove-ExistingTaskIfPresent -TaskName $TaskName

    Register-ScheduledTask -TaskName $TaskName -Xml $Xml -ErrorAction Stop | Out-Null
    Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null

    # Verify the new task immediately after registration so task creation fails
    # early instead of surfacing much later in post-install verification.
    $null = Assert-TaskReady -TaskName $TaskName -AllowedStates $ExpectedStates
}

function Assert-TaskReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [string[]]$AllowedStates = @('Ready', 'Running')
    )

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop

    if (-not $task.Settings.Enabled) {
        throw "Task is disabled: $TaskName"
    }

    if ($AllowedStates -notcontains [string]$task.State) {
        throw "Task $TaskName is in unexpected state '$($task.State)'. Expected one of: $($AllowedStates -join ', ')"
    }

    return $task
}

function Assert-StateFileValid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$state.status)) {
        throw 'state.json is missing status.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$state.generation)) {
        throw 'state.json is missing generation.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$state.lastActionUtc)) {
        throw 'state.json is missing lastActionUtc.'
    }

    return $state
}

if (-not (Test-IsAdministrator)) {
    Write-Host ''
    Write-Status 'ERROR: installer.ps1 must be run from an elevated PowerShell window.' Red
    Write-Status 'Open PowerShell with "Run as administrator" and run the installer again.' Yellow
    Write-Host ''
    exit 1
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallerPath = Join-Path $Root 'installer.ps1'
$UninstallerPath = Join-Path $Root 'uninstaller.ps1'
$ControllerPath = Join-Path $Root 'LockTimeoutController.ps1'
$RunHiddenPath = Join-Path $Root 'RunHidden.vbs'

$EnvVarName = 'TURN_OFF_SCREEN_ON_LOCK_UNINSTALL'

$DataDir = Join-Path $env:LOCALAPPDATA 'Turn-off-screen-on-lock'
if (-not (Test-Path -LiteralPath $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}
$StatePath = Join-Path $DataDir 'state.json'

$TaskNameOnLock = 'Turn-off screen on lock - On Lock'
$TaskNameOnUnlock = 'Turn-off screen on lock - On Unlock'
$TaskNameOnWake = 'Turn-off screen on lock - On Wake'

$currentUserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name

try {
    Write-Status 'Starting installation...' Cyan
    Write-Status "Root: $Root" DarkGray

    Write-Status 'Validating required files...' Cyan
    Test-FileExists -Path $InstallerPath
    Test-FileExists -Path $ControllerPath
    Test-FileExists -Path $RunHiddenPath

    Write-Status 'Initializing runtime files...' Cyan
    Initialize-StateFile -Path $StatePath

    $BaselinePath = Join-Path $DataDir 'baseline.json'
    $baselineExists = $false
    if (Test-Path -LiteralPath $BaselinePath) {
        try {
            $existingBaseline = Get-Content -LiteralPath $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $existingBaseline.originalAC -and $null -ne $existingBaseline.originalDC) {
                $baselineExists = $true
                Write-Status 'Existing baseline.json found -- preserving original VIDEOCONLOCK values.' Cyan
            }
        }
        catch {
            # Malformed file -- will be overwritten below.
        }
    }

    if (-not $baselineExists) {
        Write-Status 'Saving original VIDEOCONLOCK values...' Cyan
        $originalValues = Get-VideoConLockValues
        $baseline = [pscustomobject]@{
            originalAC = $originalValues.AC
            originalDC = $originalValues.DC
            savedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        $baseline | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $BaselinePath -Encoding UTF8
    }

    $DefaultBaseline = 1
    $DefaultWake     = 300

    $ConfigPath = Join-Path $DataDir 'config.json'
    $configExists = $false
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $existingConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $existingConfig.baselineTimeoutSeconds -and $null -ne $existingConfig.wakeTimeoutSeconds) {
                $configExists = $true
                Write-Status 'Existing config.json found -- preserving user configuration.' Cyan
            }
        }
        catch {
            # Malformed file -- will be overwritten below.
        }
    }

    if (-not $configExists) {
        Write-Status 'Creating default config.json...' Cyan
        $defaultConfig = [pscustomobject]@{
            baselineTimeoutSeconds = $DefaultBaseline
            wakeTimeoutSeconds     = $DefaultWake
        }
        $defaultConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    }

    # Determine effective baseline: use existing config if present, otherwise default.
    $baselineTimeout = $DefaultBaseline
    if ($configExists) {
        try {
            $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $cfg.baselineTimeoutSeconds) {
                $val = [int]$cfg.baselineTimeoutSeconds
                if ($val -ge 1 -and $val -le 86400) { $baselineTimeout = $val }
            }
        }
        catch { }
        Write-Status "Applying baseline VIDEOCONLOCK = $baselineTimeout seconds (from existing config)..." Cyan
    } else {
        Write-Status "Applying baseline VIDEOCONLOCK = $baselineTimeout seconds..." Cyan
    }
    Set-VideoConLock -Seconds $baselineTimeout

    Write-Status 'Preparing task definitions...' Cyan

    $escapedExe = [System.Security.SecurityElement]::Escape('wscript.exe')
    $lockArgs = [System.Security.SecurityElement]::Escape("`"$RunHiddenPath`" OnLock")
    $unlockArgs = [System.Security.SecurityElement]::Escape("`"$RunHiddenPath`" OnUnlock")
    $wakeArgs = [System.Security.SecurityElement]::Escape("`"$RunHiddenPath`" PromoteOnWake")
    $escapedUser = [System.Security.SecurityElement]::Escape($currentUserName)

    $onLockXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>$escapedUser</Author>
    <Description>Marks the beginning of a new locked cycle.</Description>
  </RegistrationInfo>
  <Triggers>
    <SessionStateChangeTrigger>
      <Enabled>true</Enabled>
      <StateChange>SessionLock</StateChange>
      <UserId>$escapedUser</UserId>
    </SessionStateChangeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$escapedUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$escapedExe</Command>
      <Arguments>$lockArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    $onUnlockXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>$escapedUser</Author>
    <Description>Restores the unlocked steady state and rearms the baseline timeout.</Description>
  </RegistrationInfo>
  <Triggers>
    <SessionStateChangeTrigger>
      <Enabled>true</Enabled>
      <StateChange>SessionUnlock</StateChange>
      <UserId>$escapedUser</UserId>
    </SessionStateChangeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$escapedUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$escapedExe</Command>
      <Arguments>$unlockArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    $onWakeXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>$escapedUser</Author>
    <Description>Promotes VIDEOCONLOCK when the system exits Modern Standby while locked.</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=507]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$escapedUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$escapedExe</Command>
      <Arguments>$wakeArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    Write-Status 'Registering scheduled tasks (this might take a few seconds)...' Cyan
    Register-TaskFromXml -TaskName $TaskNameOnLock -Xml $onLockXml -ExpectedStates @('Ready')
    Register-TaskFromXml -TaskName $TaskNameOnUnlock -Xml $onUnlockXml -ExpectedStates @('Ready')
    Register-TaskFromXml -TaskName $TaskNameOnWake -Xml $onWakeXml -ExpectedStates @('Ready')

    Write-Status 'Setting uninstaller environment variable...' Cyan
    [Environment]::SetEnvironmentVariable($EnvVarName, $null, 'User')
    [Environment]::SetEnvironmentVariable($EnvVarName, $UninstallerPath, 'User')
    Set-Item -Path "Env:\$EnvVarName" -Value $UninstallerPath

    Write-Status 'Running post-install verification...' Cyan

    Invoke-VerificationCheck -Label 'Support files exist' -Check {
        Test-FileExists -Path $InstallerPath
        Test-FileExists -Path $ControllerPath
        Test-FileExists -Path $RunHiddenPath
        $true
    } | Out-Null

    Invoke-VerificationCheck -Label 'state.json is valid' -Check {
        Assert-StateFileValid -Path $StatePath
    } | Out-Null

    Invoke-VerificationCheck -Label "VIDEOCONLOCK AC/DC are both $baselineTimeout seconds" -Check {
        $values = Get-VideoConLockValues
        if ($values.AC -ne $baselineTimeout -or $values.DC -ne $baselineTimeout) {
            throw "VIDEOCONLOCK verification failed. Expected AC=$baselineTimeout and DC=$baselineTimeout, found AC=$($values.AC) DC=$($values.DC)."
        }
        $values
    } | Out-Null

    Invoke-VerificationCheck -Label 'config.json is valid' -Check {
        $c = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $c.baselineTimeoutSeconds -or $null -eq $c.wakeTimeoutSeconds) {
            throw 'config.json is missing required values.'
        }
        $c
    } | Out-Null

    Invoke-VerificationCheck -Label 'baseline.json is valid' -Check {
        $b = Get-Content -LiteralPath $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $b.originalAC -or $null -eq $b.originalDC) {
            throw 'baseline.json is missing required values.'
        }
        $b
    } | Out-Null

    Invoke-VerificationCheck -Label 'Uninstaller environment variable is set' -Check {
        $persisted = [Environment]::GetEnvironmentVariable($EnvVarName, 'User')
        if ($persisted -ne $UninstallerPath) {
            throw "Expected $EnvVarName = '$UninstallerPath', found '$persisted'."
        }
        $true
    } | Out-Null

    Invoke-VerificationCheck -Label 'On Lock task exists, is enabled, and is in the correct state' -Check {
        Assert-TaskReady -TaskName $TaskNameOnLock -AllowedStates @('Ready')
    } | Out-Null

    Invoke-VerificationCheck -Label 'On Unlock task exists, is enabled, and is in the correct state' -Check {
        Assert-TaskReady -TaskName $TaskNameOnUnlock -AllowedStates @('Ready')
    } | Out-Null

    Invoke-VerificationCheck -Label 'On Wake task exists, is enabled, and is in the correct state' -Check {
        Assert-TaskReady -TaskName $TaskNameOnWake -AllowedStates @('Ready')
    } | Out-Null

    Write-Host ''
    Write-Status 'Installation completed successfully.' Green
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Status 'Installation failed.' Red
    Write-Status $_.Exception.Message Yellow
    Write-Host ''
    throw
}

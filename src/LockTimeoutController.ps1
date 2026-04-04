[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('OnLock', 'OnUnlock', 'PromoteOnWake')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'

$DataDir = Join-Path $env:LOCALAPPDATA 'Turn-off-screen-on-lock'
if (-not (Test-Path -LiteralPath $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}
$StatePath = Join-Path $DataDir 'state.json'

function Save-State {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $json = [pscustomobject]$State | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $StatePath -Value $json -Encoding UTF8
}

function Get-State {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        $initial = @{
            status        = 'unlocked'
            generation    = [guid]::NewGuid().Guid
            lastActionUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        Save-State -State $initial
    }

    return Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-Config {
    $DefaultBaseline = 1
    $DefaultWake     = 300
    $ConfigPath      = Join-Path $DataDir 'config.json'

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $default = [pscustomobject]@{
            baselineTimeoutSeconds = $DefaultBaseline
            wakeTimeoutSeconds     = $DefaultWake
        }
        $default | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
        return @{ baselineTimeoutSeconds = $DefaultBaseline; wakeTimeoutSeconds = $DefaultWake }
    }

    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @{ baselineTimeoutSeconds = $DefaultBaseline; wakeTimeoutSeconds = $DefaultWake }
        }
        $parsed = $raw | ConvertFrom-Json

        $baseline = $DefaultBaseline
        if ($null -ne $parsed.baselineTimeoutSeconds) {
            $val = [int]$parsed.baselineTimeoutSeconds
            if ($val -ge 1 -and $val -le 86400) { $baseline = $val }
        }

        $wake = $DefaultWake
        if ($null -ne $parsed.wakeTimeoutSeconds) {
            $val = [int]$parsed.wakeTimeoutSeconds
            if ($val -ge 1 -and $val -le 86400) { $wake = $val }
        }

        if ($wake -lt $baseline) { $wake = $baseline }

        return @{ baselineTimeoutSeconds = $baseline; wakeTimeoutSeconds = $wake }
    }
    catch {
        return @{ baselineTimeoutSeconds = $DefaultBaseline; wakeTimeoutSeconds = $DefaultWake }
    }
}

function Set-VideoConLock {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 86400)]
        [int]$Seconds
    )

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

function New-State {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('locked', 'unlocked')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$GenerationValue
    )

    return @{
        status        = $Status
        generation    = $GenerationValue
        lastActionUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

try {
    switch ($Action) {
        'OnLock' {
            $newGeneration = [guid]::NewGuid().Guid
            Save-State -State (New-State -Status 'locked' -GenerationValue $newGeneration)
        }

        'OnUnlock' {
            $newGeneration = [guid]::NewGuid().Guid
            Save-State -State (New-State -Status 'unlocked' -GenerationValue $newGeneration)
            $config = Get-Config
            Set-VideoConLock -Seconds $config.baselineTimeoutSeconds
        }

        'PromoteOnWake' {
            $state = Get-State

            if ($state.status -ne 'locked') {
                break
            }

            $gen = [string]$state.generation
            if ([string]::IsNullOrWhiteSpace($gen)) {
                break
            }

            $config = Get-Config
            Set-VideoConLock -Seconds $config.wakeTimeoutSeconds
        }
    }
}
catch {
    throw
}

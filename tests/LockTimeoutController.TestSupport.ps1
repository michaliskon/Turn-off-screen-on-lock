# Runs the real controller with in-memory file and powercfg boundaries so regression
# checks cannot change Windows settings, write runtime files, or call external APIs.

# Supplies controlled boundary failures and records the real controller's decisions.
function invoke_controller_case {
    param([string]$controller_path, [string]$action, [hashtable]$options = @{})

    $observed = @{ power_calls = @(); writes = @{}; warnings = @(); error_record = $null }
    $settings = @{ status = 'locked'; generation = 'test-generation'; corrupt_state = $false; failed_command = ''; error_text = 'Simulated power setting failure'; log_failure = $false; state_failure = $false; directory_failure = $false }
    foreach ($key in $options.Keys) { $settings[$key] = $options[$key] }

    # Keeps existence checks inside the controlled runtime boundary.
    function Test-Path {
        param([string]$LiteralPath)
        return -not $settings.directory_failure
    }

    # Models an unavailable runtime directory without creating one.
    function New-Item {
        param([string]$ItemType, [string]$Path, [switch]$Force)
        throw 'Simulated runtime directory failure'
    }

    # Supplies state and configuration inputs; the production parser still runs.
    function Get-Content {
        param([string]$LiteralPath, [switch]$Raw, [string]$Encoding)
        switch ([IO.Path]::GetFileName($LiteralPath)) {
            'config.json' { return '{"baselineTimeoutSeconds":5,"wakeTimeoutSeconds":60}' }
            'state.json' {
                if ($settings.corrupt_state) { return '{invalid json' }
                return (@{ status = $settings.status; generation = $settings.generation } | ConvertTo-Json)
            }
            default { throw "Unexpected file read: $LiteralPath" }
        }
    }

    # Records actual state/log writes and can reproduce an unwritable destination.
    function Set-Content {
        param([string]$LiteralPath, $Value, [string]$Encoding)
        $file_name = [IO.Path]::GetFileName($LiteralPath)
        if ($file_name -eq 'last-error.log' -and ($settings.log_failure -or $settings.directory_failure)) { throw 'Simulated log write failure' }
        if ($file_name -eq 'state.json' -and $settings.state_failure) { throw 'Simulated state write failure' }
        if ($file_name -notin @('state.json', 'last-error.log')) { throw "Unexpected file write: $LiteralPath" }
        $observed.writes[$file_name] = [string]$Value
    }

    # Records commands instead of changing power settings, including native failures.
    function powercfg {
        $observed.power_calls += ($args -join ' ')
        $global:LASTEXITCODE = 0
        if ($args[0] -eq $settings.failed_command) {
            $global:LASTEXITCODE = 5
            return $settings.error_text
        }
    }

    # Captures logging warnings without hiding the original terminating error.
    function Write-Warning {
        param([string]$Message, [string]$WarningAction)
        $observed.warnings += $Message
    }

    try { & $controller_path -Action $action }
    catch { $observed.error_record = $_ }
    return $observed
}

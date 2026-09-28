# Isolates Windows tracing, device inventory and file writes in memory while running
# the real recorder. No trace, administrator prompt, external API or test file is created.

# Supplies boundary responses and records the recorder's actual decisions for one case.
function invoke_wake_trace_case {
    param([string]$module_path, [string]$capture_directory, [hashtable]$options = @{})

    $module = Import-Module $module_path -Force -PassThru -DisableNameChecking
    try {
        return (& $module {
            param($capture_directory, $options)
            $script:observed = @{ commands = @(); writes = @{}; failure = $null; result = $null }
            $script:settings = @{ failed_verb = ''; duration = 1200; scheduled = 0; segment = $false; status = 1; occupied = $false; failed_file = ''; inventory_failure = $false }
            foreach ($key in $options.Keys) { $script:settings[$key] = $options[$key] }

            # Records the native command boundary without running an event trace.
            function script:invoke_trace_command {
                param([string[]]$command_arguments)
                $script:observed.commands += ,$command_arguments
                if ($command_arguments[0] -eq $script:settings.failed_verb) { throw "Controlled $($command_arguments[0]) failure" }
            }

            # Supplies path existence in memory, after the real containment check runs.
            function script:Resolve-Path {
                param([string]$LiteralPath)
                return [pscustomobject]@{ ProviderPath = $LiteralPath }
            }

            # Models a fresh or previously used folder without creating disk output.
            function script:Get-ChildItem {
                param([string]$LiteralPath, [switch]$Force)
                if ($script:settings.occupied) { return 'previous-recording.etl' }
            }

            # Supplies a placeholder device at the Windows inventory boundary.
            function script:Get-PnpDevice {
                param([switch]$PresentOnly, [string]$ErrorAction)
                if ($script:settings.inventory_failure) { throw 'Controlled device inventory failure' }
                return [pscustomobject]@{ Class = 'Mouse'; FriendlyName = 'Test input device'; InstanceId = 'TEST\DEVICE'; Status = 'OK' }
            }

            # Captures JSON written by the real serializer and can model storage failure.
            function script:Set-Content {
                param([string]$LiteralPath, [Parameter(ValueFromPipeline)]$Value, [string]$Encoding)
                process {
                    $file_name = [IO.Path]::GetFileName($LiteralPath)
                    if ($file_name -eq $script:settings.failed_file) { throw "Controlled $file_name write failure" }
                    $script:observed.writes[$file_name] = [string]$Value
                }
            }

            # Models Windows' readback, including a rejected timer or failed startup.
            function script:New-Object {
                param([string]$ComObject)
                if ($ComObject -ne 'Pla.DataCollectorSet') { throw "Unexpected COM request: $ComObject" }
                $collector = [pscustomobject]@{ Duration = $script:settings.duration; Schedules = @{ Count = $script:settings.scheduled }; Segment = $script:settings.segment; Status = $script:settings.status }
                # Query and Commit leave controlled readback available to real validation.
                $collector | Add-Member -MemberType ScriptMethod -Name Query -Value {
                    param($name, $server)
                    $this.Duration = $script:settings.duration
                    $this.Schedules = @{ Count = $script:settings.scheduled }
                    $this.Segment = $script:settings.segment
                    $this.Status = $script:settings.status
                }
                $collector | Add-Member -MemberType ScriptMethod -Name Commit -Value { param($name, $server, $flags) }
                return $collector
            }

            try { $script:observed.result = start_wake_trace -capture_directory $capture_directory }
            catch { $script:observed.failure = $_.Exception.Message }
            return $script:observed
        } $capture_directory $options)
    }
    finally { Remove-Module $module }
}

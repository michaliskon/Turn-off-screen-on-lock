# Record a screen wake for 20 minutes

Before bed:

1. Double-click **Start-20-Minute-Recording.cmd** in this folder.
2. Accept the Windows administrator prompt.
3. Wait for the green **Recording started** message, then press **Win+L**.
4. Leave the PC on with the same devices connected. You can close the launcher and go to bed.

Windows records for 20 minutes from startup, then stops and closes the trace automatically. There is no recurring schedule. No display timeout or device wake setting is changed. Do not restart or shut down during the capture; full sleep/hibernation can delay Windows' timer until the PC resumes.

The launcher prints the dated save folder under `logs/wake-trace/` at the repository root. It contains `wake*.etl` (the actual event trace), `devices.json` (connected input and USB devices), `capture.json` (start time, expected end, collector name and filters), and `launch-result.json` (startup success or failure). A successful startup is not proof that the full capture finished; inspect the trace after the run. Files stay available for analysis the next morning.

The trace collects Windows power/wake events, HID device information and USB power/transfer headers. It excludes USB transfer payloads. Device identifiers and diagnostic metadata are still personal information; review the files before sharing. A shared wireless receiver may be identifiable without distinguishing the individual mouse or keyboard behind it. Some drivers may not expose enough evidence to identify the source conclusively.

Storage is circular and capped at 512 MB. If the cap is reached, newer events replace the oldest ones. Only run one recording at a time. Each launch creates a separate, uniquely named Windows collector; after the timer expires its inactive definition remains available in Performance Monitor. It does not restart by itself.

To stop early or remove that inactive definition later, open PowerShell as Administrator and use the actual save folder printed by the launcher:

```powershell
$capture = Get-Content -LiteralPath '<save-folder>\capture.json' -Raw | ConvertFrom-Json
logman stop $capture.collector_name
logman delete $capture.collector_name
```

If it has already stopped, the first command reports that it is not running; skip that command when only deleting a stopped definition. Deleting the definition leaves the saved trace files intact.

## Preparation and tests

From the repository root, check installed providers without elevation, files or recording:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\maintainer-tools\wake-trace\src\Start-WakeTrace.ps1 -check_only
```

The separate maintenance-tool suite runs the real recorder logic against in-memory Windows and file boundaries. It does not start a trace, change power settings, or use external APIs:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\maintainer-tools\wake-trace\tests\run_tests.ps1
```

## Windows tracing references

The recorder uses Microsoft's documented [Logman overall runtime option](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/logman-create-trace) on a persisted collector, not a direct `-ets` session. It reads back the saved 1200-second duration and absence of schedules before starting, then checks that Windows reports the collector running. See [USB capture filters](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/how-to-capture-a-usb-event-trace) for the distinction between transfer headers and payloads.

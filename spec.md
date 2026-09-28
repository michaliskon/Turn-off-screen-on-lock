# Turn Off Screen on Lock

**Date:** 2026-04-03

## Brief description

This setup makes the screen turn off quickly after the workstation is locked, but prevents the screen from turning off again almost immediately when you wake the PC and are trying to unlock it.

In practice, it gives you both of these behaviors at the same time:
- fast screen-off after lock
- enough time to wake the display and unlock the PC without the screen going black again after only a few seconds

## Brief technical description

The solution uses `VIDEOCONLOCK`, a controller, three runtime files, and three Scheduled Tasks.

Runtime logic:
- unlocked: `VIDEOCONLOCK` = baseline timeout (default 1 second, configurable)
- locked + system enters Modern Standby: On Wake task asks the controller to promote `VIDEOCONLOCK` to wake timeout (default 300 seconds, configurable)
- unlocked again: controller resets `VIDEOCONLOCK` to baseline timeout

Roles:
- `installer.ps1`: one-time setup
- `LockTimeoutController.ps1`: state and `VIDEOCONLOCK` changes
- `%LOCALAPPDATA%\Turn-off-screen-on-lock\state.json`: per-user runtime state
- `%LOCALAPPDATA%\Turn-off-screen-on-lock\config.json`: user configuration (timeout values)
- On Lock task: marks a new locked cycle
- On Unlock task: restores the baseline timeout
- On Wake task: promotes the timeout when the system exits Modern Standby while locked

## Intended behavior

- Unlocked: `VIDEOCONLOCK` = baseline timeout (default 1 second, configurable via `config.json`)
- Locked + exiting Modern Standby: `VIDEOCONLOCK` promoted to wake timeout (default 300 seconds, configurable via `config.json`)
- Unlocked again: `VIDEOCONLOCK` reset to baseline for the next cycle

---

## Dependency map

What calls what at runtime:

```
Scheduled Tasks
  │
  ├─ On Lock ──────► wscript.exe RunHidden.vbs OnLock
  ├─ On Unlock ────► wscript.exe RunHidden.vbs OnUnlock
  └─ On Wake ──────► wscript.exe RunHidden.vbs PromoteOnWake
                         │
                         ▼
                     RunHidden.vbs
                         │
                         ▼
                     LockTimeoutController.ps1 -Action <action>
                         │
                         ├── reads ──► config.json
                         ├── reads/writes ──► state.json
                         └── writes ──► VIDEOCONLOCK (via powercfg)
```

Release and setup:

```
git push tag v* ──► release.yml (GitHub Actions)
                        │
                        ├── builds ──► Turn-off-screen-on-lock-<tag>.zip
                        ├── generates ──► checksums-sha256.txt
                        └── publishes ──► GitHub Release (zip + checksums + install.ps1)

irm .../install.ps1 | iex
  │
  ├── downloads ──► zip + checksums-sha256.txt
  ├── verifies ──► SHA-256 checksum
  ├── extracts ──► .\Turn-off-screen-on-lock\
  └── runs ──► installer.ps1

installer.ps1
  ├── creates ──► Scheduled Tasks (x3)
  ├── creates (if missing) ──► state.json, config.json, baseline.json
  ├── reads ──► config.json (for baseline value)
  ├── queries + writes ──► baseline.json (original VIDEOCONLOCK)
  └── writes ──► VIDEOCONLOCK (baseline)

uninstaller.ps1
  ├── removes ──► Scheduled Tasks (x3)
  ├── reads ──► baseline.json (original values)
  ├── writes ──► VIDEOCONLOCK (restore originals)
  └── deletes ──► %LOCALAPPDATA%\Turn-off-screen-on-lock\
```

## Dataflow per action

| Action | Reads | Writes | Changes VIDEOCONLOCK |
|---|---|---|---|
| `OnLock` | `config.json` | `state.json` | yes, baseline |
| `OnUnlock` | `config.json` | `state.json` | yes, baseline |
| `PromoteOnWake` | `state.json`, `config.json` | -- | yes, wake (if locked) |

Write directions for the three JSON files:

| File | Written by | Read by |
|---|---|---|
| `state.json` | `OnLock`, `OnUnlock`, installer | `PromoteOnWake` |
| `config.json` | installer (defaults only) | `OnLock`, `OnUnlock`, `PromoteOnWake`, installer |
| `baseline.json` | installer (once, on first install) | uninstaller |

---

## Folder layout

Scripts for this feature live in the `src/` folder of the repository and are placed in a single folder chosen at install time, referred to as `<install-folder>` throughout this document.

Per-user runtime data (`state.json`) is stored under `%LOCALAPPDATA%\Turn-off-screen-on-lock\` so that each user on a shared machine gets an isolated copy.

This spec assumes the following files are present in the install folder.

## File inventory

| File | Purpose |
|---|---|
| `install.ps1` | Bootstrap installer. Downloaded and executed via `irm \| iex` in an elevated shell. Fetches the latest release zip from GitHub, verifies the SHA-256 checksum, extracts files, and runs `installer.ps1`. See the `install.ps1` section below. |
| `.github/workflows/release.yml` | GitHub Actions workflow. Triggered by pushing a `v*` tag on `main`. Builds the release zip, generates checksums, and publishes the GitHub Release. See the Release pipeline section below. |
| `installer.ps1` | One-time setup. Validates prerequisites, initializes runtime files, saves original `VIDEOCONLOCK` values, applies the baseline, removes and recreates the three Scheduled Tasks, sets the uninstaller environment variable, verifies readiness. |
| `uninstaller.ps1` | Reverses the installer. Removes the three tasks, restores original `VIDEOCONLOCK` from `baseline.json`, removes the environment variable, deletes the per-user data directory, verifies cleanup. |
| `LockTimeoutController.ps1` | Core control logic. Owns state transitions, writes `state.json`, reads `config.json`, changes `VIDEOCONLOCK`. |
| `RunHidden.vbs` | VBScript launcher that starts PowerShell with a truly hidden window, avoiding the console-host flash. See the RunHidden.vbs contract section below. |
| `%LOCALAPPDATA%\Turn-off-screen-on-lock\state.json` | Per-user runtime state: lock/unlock status, current generation, last transition timestamp. |
| `%LOCALAPPDATA%\Turn-off-screen-on-lock\config.json` | User configuration: baseline and wake timeout values. Created with defaults by the installer, preserved across re-installs. See Configuration section. |
| `%LOCALAPPDATA%\Turn-off-screen-on-lock\baseline.json` | Original `VIDEOCONLOCK` AC and DC values captured before the installer applies the baseline. Used by the uninstaller to restore. Created once on first install, preserved across re-installs. |

All JSON files are written as UTF-8 without BOM.

---

## Detailed chronological cycle

Full runtime design, one complete lock/unlock cycle.

### 1. PC is unlocked

- `VIDEOCONLOCK` AC and DC: baseline timeout (default `1`)
- `state.json`: `status = "unlocked"`, `generation = <latest>`, `lastActionUtc = <timestamp>`

The baseline is armed for the next lock event.

### 2. PC gets locked

`Win + L` or equivalent. Windows changes session state to locked, triggering `Turn-off screen on lock - On Lock`.

### 3. On Lock task runs

```text
wscript.exe "<install-folder>\RunHidden.vbs" OnLock
```

`LockTimeoutController.ps1 -Action OnLock`:

1. Generates a new GUID for this lock cycle.
2. Writes `state.json`: `status = "locked"`, `generation = <new GUID>`, `lastActionUtc = <now>`.
3. Reads `config.json` for the baseline timeout.
4. Sets `VIDEOCONLOCK` AC and DC to the baseline timeout. Reapplies the active power scheme.

Setting `VIDEOCONLOCK` at lock time forces Windows to re-arm its internal display-off countdown from the moment of lock, preventing stale idle time accumulated before the lock event from causing the screen to turn off earlier than configured.

### 4. Display turns off

Windows turns the display off after the baseline timeout (default 1 second) has elapsed since the lock event.

### 5. System enters Modern Standby

The system enters S0 Low Power Idle. Windows logs Event ID 506 (`Microsoft-Windows-Kernel-Power`).

### 6. User wakes the system

Key press, mouse move, etc. Windows exits Modern Standby and logs Event ID 507 (`Microsoft-Windows-Kernel-Power`), triggering `Turn-off screen on lock - On Wake`.

### 7. On Wake task runs

```text
wscript.exe "<install-folder>\RunHidden.vbs" PromoteOnWake
```

`LockTimeoutController.ps1 -Action PromoteOnWake`:

1. Reads `state.json`.
2. If `status` is not `locked`, exits.
3. Reads `config.json` for the wake timeout.
4. Sets `VIDEOCONLOCK` AC and DC to the wake timeout (default 300).
5. Reapplies the active power scheme.

The display is turning back on. The user now has enough time to unlock.

### 8. PC gets unlocked

Windows changes session state to unlocked, triggering `Turn-off screen on lock - On Unlock`.

### 9. On Unlock task runs

```text
wscript.exe "<install-folder>\RunHidden.vbs" OnUnlock
```

`LockTimeoutController.ps1 -Action OnUnlock`:

1. Generates a new GUID.
2. Writes `state.json`: `status = "unlocked"`, `generation = <new GUID>`, `lastActionUtc = <now>`.
3. Reads `config.json` for the baseline timeout.
4. Sets `VIDEOCONLOCK` AC and DC to the baseline (default 1).
5. Reapplies the active power scheme.

Back to the initial unlocked state. Ready for the next cycle.

---

## Why the On Wake trigger exists

Event ID 507 fires at the OS level via the Task Scheduler service (Session 0), so it is not affected by user-session process suspension. It fires at the right moment: when the user wakes the system and needs the display to stay on long enough to unlock.

## State protection

The `generation` field in `state.json` prevents stale actions from mutating a newer cycle. Each `OnLock` and `OnUnlock` writes a new generation, so if an older event arrives late it sees a different generation and exits without changing anything.

### Concurrency

No file locking on `state.json`. Worst case: one missed promotion cycle. Accepted.

---

## Scheduled Tasks -- exact configuration

The installer creates three Scheduled Tasks using the `Register-ScheduledTask` PowerShell cmdlet.

All three share the same principal and settings listed here. Per-task sections below only specify the trigger and action.

#### Common principal

- User: current interactive user
- Logon type: `InteractiveToken`
- Run level: `HighestAvailable`

#### Common task settings

- Multiple instances policy: `IgnoreNew`
- Disallow start if on batteries: `false`
- Stop if going on batteries: `false`
- Allow hard terminate: `true`
- Start when available: `true`
- Run only if network available: `false`
- Stop on idle end: `false`
- Restart on idle: `false`
- Allow start on demand: `true`
- Enabled: `true`
- Hidden: `false`
- Run only if idle: `false`
- Wake to run: `false`
- Execution time limit: `PT5M`
- Priority: `7` (below normal)

### Task 1 -- `Turn-off screen on lock - On Lock`

#### Purpose

Marks the start of a new lock cycle. Updates `state.json` with a fresh generation ID and `locked` status. Re-applies `VIDEOCONLOCK` to the baseline timeout to re-arm Windows's display-off countdown from the moment of lock.

#### Trigger

- Trigger type: `SessionStateChangeTrigger`
- State change: `SessionLock`
- Enabled: `true`
- User ID: current interactive user

#### Action

- Command: `wscript.exe`
- Arguments:

```text
"<install-folder>\RunHidden.vbs" OnLock
```

### Task 2 -- `Turn-off screen on lock - On Unlock`

#### Purpose

Closes the lock cycle. Writes `unlocked` status and a new generation to `state.json`, resets `VIDEOCONLOCK` to the baseline timeout from `config.json`, and reapplies the active scheme.

#### Trigger

- Trigger type: `SessionStateChangeTrigger`
- State change: `SessionUnlock`
- Enabled: `true`
- User ID: current interactive user

#### Action

- Command: `wscript.exe`
- Arguments:

```text
"<install-folder>\RunHidden.vbs" OnUnlock
```

### Task 3 -- `Turn-off screen on lock - On Wake`

#### Purpose

Promotes `VIDEOCONLOCK` to the wake timeout (from `config.json`, default 300 seconds) when the system exits Modern Standby while still locked. Triggered by Event ID 507 (`Microsoft-Windows-Kernel-Power`). The controller checks `state.json` first, so this is a no-op when the system wakes while already unlocked.

#### Trigger

- Trigger type: `EventTrigger`
- Event log: `System`
- Provider: `Microsoft-Windows-Kernel-Power`
- Event ID: `507`
- Enabled: `true`

#### Action

- Command: `wscript.exe`
- Arguments:

```text
"<install-folder>\RunHidden.vbs" PromoteOnWake
```

---

## `RunHidden.vbs` -- contract

Thin launcher, no real logic:

1. Receives the action name as its first argument (e.g. `OnLock`).
2. Resolves `LockTimeoutController.ps1` relative to its own folder.
3. Launches:
   ```text
   powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "<own-folder>\LockTimeoutController.ps1" -Action <arg>
   ```
4. Exits with PowerShell's exit code.

No logging. No argument validation beyond forwarding.


---

## `install.ps1` -- bootstrap installer spec

`install.ps1` is meant to be run via a one-liner in an elevated shell:

```powershell
irm https://github.com/michaliskon/Turn-off-screen-on-lock/releases/latest/download/install.ps1 | iex
```

It bridges the gap between the GitHub Release and `installer.ps1`.

1. **Resolve the latest release tag.**
   Query the GitHub API (`https://api.github.com/repos/michaliskon/Turn-off-screen-on-lock/releases/latest`) and extract `tag_name`.

2. **Download the release zip and checksum file.**
   Fetch both from `https://github.com/michaliskon/Turn-off-screen-on-lock/releases/download/<tag>/`:
   - `Turn-off-screen-on-lock-<tag>.zip`
   - `checksums-sha256.txt`

3. **Verify the zip checksum.**
   Parse `checksums-sha256.txt` for the line matching the zip filename, compute the SHA-256 hash of the downloaded zip, and compare. If they don't match, delete the zip and throw. Delete `checksums-sha256.txt` after verification either way.

4. **Extract the zip.**
   Extract to `.\Turn-off-screen-on-lock\` in the current directory, overwriting if the folder already exists. Delete the zip after extraction.

5. **Run the installer.**
   Execute `.\Turn-off-screen-on-lock\installer.ps1`. The installer takes over from here.

`install.ps1` does not validate elevation itself -- `installer.ps1` handles that. If the shell is not elevated, the installer will stop and tell the user.

---

## `installer.ps1` -- step-by-step design spec

1. **Validate elevation**  
   Confirm elevated PowerShell session. If not, stop and tell the user to rerun as Administrator.

2. **Resolve the working root**  
   Derive the script folder from the installer's own location. All file references point into that folder.

3. **Validate required files**  
   Confirm these exist in the root folder:
   - `installer.ps1`
   - `uninstaller.ps1`
   - `LockTimeoutController.ps1`
   - `RunHidden.vbs`

4. **Create the per-user data directory if needed**  
   Ensure `%LOCALAPPDATA%\Turn-off-screen-on-lock\` exists.

5. **Initialize `state.json` if needed**  
   If missing, create with default unlocked state. If present but unusable, overwrite with defaults.  
   Unusable means: invalid JSON, any of the three required fields (`status`, `generation`, `lastActionUtc`) missing, or `status` not one of `"locked"` / `"unlocked"`.

6. **Save the original `VIDEOCONLOCK` values to `baseline.json`**  
   If `baseline.json` does not exist or is malformed, query the current values:
   ```
   powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK
   ```
   Parse the hex values after "Current AC Power Setting Index" and "Current DC Power Setting Index", convert to decimal, and write `baseline.json`. If a valid `baseline.json` already exists, preserve it so the true originals are never lost on re-install.

7. **Create or preserve `config.json`**  
   If missing or malformed, create with defaults (`baselineTimeoutSeconds = 1`, `wakeTimeoutSeconds = 300`). If valid, preserve it. Read the effective baseline timeout for the next step.

8. **Apply the baseline `VIDEOCONLOCK` setting**  
   Log the applied value. If the value came from an existing `config.json`, indicate that in the message.
   ```
   powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK <baseline>
   powercfg /setdcvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK <baseline>
   powercfg /setactive SCHEME_CURRENT
   ```

9. **Remove and recreate Task 1**  
   If `Turn-off screen on lock - On Lock` exists, stop any running instance, unregister it, confirm removal. Register the new task.

10. **Remove and recreate Task 2**  
    Same sequence for `Turn-off screen on lock - On Unlock`.

11. **Remove and recreate Task 3**  
    Same sequence for `Turn-off screen on lock - On Wake`.

12. **Verify each task is in the correct state**  
    After registration, enable each task and confirm state is `Ready`.

13. **Set the uninstaller environment variable**  
    Set user-scoped `TURN_OFF_SCREEN_ON_LOCK_UNINSTALL` to the full path of `uninstaller.ps1`.

14. **Run readiness verification**  
    Verify:
    - support files exist
    - `state.json` is valid
    - `VIDEOCONLOCK` AC and DC match the baseline
    - `config.json` is valid
    - `baseline.json` is valid
    - `TURN_OFF_SCREEN_ON_LOCK_UNINSTALL` is set correctly
    - all three tasks are present, enabled, and `Ready`

15. **Write status to the console.**

16. **Exit.** No background processes left behind.

### Re-install behavior

Re-running the installer on an already-configured system must be safe:

- `baseline.json` preserved if valid (true originals never lost).
- `config.json` preserved if valid (user customizations survive).
- `state.json` preserved if valid; overwritten only if missing or unusable.
- All three tasks removed and recreated from scratch.
- `TURN_OFF_SCREEN_ON_LOCK_UNINSTALL` overwritten with current path.

---

## `uninstaller.ps1` -- step-by-step design spec

1. **Validate elevation.**  
   Same check as the installer.

2. **Remove the three Scheduled Tasks.**  
   For each task, stop any running instance, unregister, confirm removal. Skip silently if the task does not exist.

3. **Restore the original `VIDEOCONLOCK` values.**  
   Read `baseline.json`. If valid, restore those exact AC and DC values. If missing or malformed, fall back to 60 seconds for both.
   ```
   powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK <originalAC>
   powercfg /setdcvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK <originalDC>
   powercfg /setactive SCHEME_CURRENT
   ```

4. **Remove the uninstaller environment variable.**  
   Delete user-scoped `TURN_OFF_SCREEN_ON_LOCK_UNINSTALL` and remove from the current process environment.

5. **Remove the per-user data directory.**  
   Delete `%LOCALAPPDATA%\Turn-off-screen-on-lock\` and all contents.

6. **Post-uninstall verification.**  
   Verify: all three tasks gone, `VIDEOCONLOCK` matches restored values, environment variable removed, data directory removed.

7. **Write status to the console.** Exit clean.

---

## `LockTimeoutController.ps1` -- design spec

Central authority for state changes and `VIDEOCONLOCK` writes.

### Responsibility boundary

Responsible for: reading `config.json`, writing/validating `state.json`, changing `VIDEOCONLOCK`, enforcing state checks, exposing the action interface.

Not responsible for: staying resident, detecting display-off, starting at logon. The Scheduled Tasks handle those.

### Supported actions

`OnLock`, `OnUnlock`, `PromoteOnWake`. No others.

### Action contracts

#### `OnLock`

Record a new lock cycle. Leave `VIDEOCONLOCK` unchanged.

1. Generate a new GUID.
2. Write `state.json`: `status = "locked"`, `generation = <GUID>`, `lastActionUtc = <now>`.
3. Exit.

#### `OnUnlock`

Close the lock cycle and restore the baseline.

1. Generate a new GUID.
2. Write `state.json`: `status = "unlocked"`, `generation = <GUID>`, `lastActionUtc = <now>`.
3. Read `config.json` for the baseline timeout.
4. Set `VIDEOCONLOCK` AC and DC to the baseline.
5. Reapply the active power scheme.
6. Exit.

#### `PromoteOnWake`

Promote the timeout if the system is still locked.

1. Read and parse `state.json`.
2. If `status` is not `locked` or `generation` is empty, exit.
3. Read `config.json` for the wake timeout.
4. Set `VIDEOCONLOCK` AC and DC to the wake timeout.
5. Reapply the active power scheme.
6. Exit.

### State model

`state.json` is the source of truth for runtime state.

```json
{
  "status": "locked | unlocked",
  "generation": "<guid>",
  "lastActionUtc": "<UTC timestamp>"
}
```

### `baseline.json` schema

```json
{
  "originalAC": "<integer, seconds>",
  "originalDC": "<integer, seconds>"
}
```

### Generation rule

- `OnLock` generates a new ID
- `OnUnlock` generates a new ID
- `PromoteOnWake` only acts if `status` is `locked` and `generation` is not empty -- it does not compare generations, just confirms the state file is coherent

### Power-setting rule

All `VIDEOCONLOCK` changes use these commands:

```
powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK <seconds>
powercfg /setdcvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK <seconds>
powercfg /setactive SCHEME_CURRENT
```

Each `powercfg` call must check `$LASTEXITCODE` and throw on failure.

### Error handling

Malformed state: fail safely, do not guess and promote blindly. `powercfg` failure (non-zero exit code): throw immediately.

Errors go to stderr. No log file, no Event Log. Tasks run hidden so errors are effectively silent, but stderr is available when running the controller manually for debugging.

### Configuration

The controller reads `%LOCALAPPDATA%\Turn-off-screen-on-lock\config.json` on each invocation.

```json
{
  "baselineTimeoutSeconds": 1,
  "wakeTimeoutSeconds": 300
}
```

| Field | Type | Range | Default | Description |
|---|---|---|---|---|
| `baselineTimeoutSeconds` | integer | 1–86400 | 1 | Seconds before the screen turns off after locking. Also the value restored on unlock. |
| `wakeTimeoutSeconds` | integer | 1–86400 | 300 | Seconds the screen stays on when waking from Modern Standby to unlock. |

Loading rules:

- If the file does not exist, recreate it with defaults.
- If the file is empty or malformed JSON, use defaults.
- If a value is missing, out of range, or non-numeric, use the default for that value.
- If `wakeTimeoutSeconds` < `baselineTimeoutSeconds`, clamp wake to equal baseline.
- Config errors are silent. The controller never fails due to a bad config file.

---

## Verification

### Check current `VIDEOCONLOCK`

```cmd
powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK | findstr /i "Current AC Current DC"
```

- Unlocked: baseline (default `0x00000001` = 1 second).
- After promotion during a locked cycle: wake timeout (default `0x0000012c` = 300 seconds).

### Check the tasks

```powershell
Get-ScheduledTask -TaskName "Turn-off screen on lock*"
```

All three tasks should appear.

---

## Release pipeline -- `.github/workflows/release.yml`

The workflow runs on GitHub Actions when a `v*` tag is pushed.

1. **Checkout the repo** with full history (`fetch-depth: 0`).

2. **Verify the tag is on `main`.**
   If the tagged commit is not reachable from `origin/main`, fail the build. This prevents releases from feature branches or detached commits.

3. **Build the release zip.**
   Copy these files into a flat `release/` directory:
   - `src/installer.ps1`
   - `src/uninstaller.ps1`
   - `src/LockTimeoutController.ps1`
   - `src/RunHidden.vbs`
   - `README.md`
   - `LICENSE`

   Zip the directory as `Turn-off-screen-on-lock-<tag>.zip`. The zip contains the files at the root level (no nested folder inside the archive).

4. **Generate checksums.**
   Run `sha256sum` over the release zip and `src/install.ps1`, write the output to `checksums-sha256.txt`. Format: one `<hash>  <filename>` line per file.

5. **Publish the GitHub Release.**
   Attach three assets to the release:
   - `Turn-off-screen-on-lock-<tag>.zip`
   - `checksums-sha256.txt`
   - `src/install.ps1`

   Release notes are auto-generated by GitHub from the commit history since the previous tag.

### Release artifacts summary

| Asset | Contents |
|---|---|
| `Turn-off-screen-on-lock-<tag>.zip` | `installer.ps1`, `uninstaller.ps1`, `LockTimeoutController.ps1`, `RunHidden.vbs`, `README.md`, `LICENSE` |
| `checksums-sha256.txt` | SHA-256 hashes of the zip and `install.ps1` |
| `install.ps1` | Bootstrap installer, downloadable standalone |

---

## Useful commands

### Last lock / screen-off / wake / unlock (Admin PowerShell)

#### Command
```powershell
$lock   = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4800} -MaxEvents 1
$unlock = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4801} -MaxEvents 1
$enter_modern_standby    = Get-WinEvent -ProviderName 'Microsoft-Windows-Kernel-Power' -FilterXPath '*[System[EventID=506]]' -MaxEvents 1
$exit_modern_standby   = Get-WinEvent -ProviderName 'Microsoft-Windows-Kernel-Power' -FilterXPath '*[System[EventID=507]]' -MaxEvents 1

'{0,-28} {1:yyyy-MM-dd HH:mm:ss}' -f 'Last Lock',                 $lock.TimeCreated
'{0,-28} {1:yyyy-MM-dd HH:mm:ss}' -f 'Last Enter Modern Standby',  $enter_modern_standby.TimeCreated
'{0,-28} {1:yyyy-MM-dd HH:mm:ss}' -f 'Last Exit Modern Standby',   $exit_modern_standby.TimeCreated
'{0,-28} {1:yyyy-MM-dd HH:mm:ss}' -f 'Last Unlock',               $unlock.TimeCreated
```
#### Example output
```
Last Lock                    2026-04-05 06:06:40
Last Enter Modern Standby    2026-04-05 06:06:56
Last Exit Modern Standby     2026-04-05 06:07:03
Last Unlock                  2026-04-05 06:07:12
```


## Notes

- This changes the locked-screen display-off timeout, not the normal unlocked display timeout.
- This does not directly force the display off.
- `VIDEOCONLOCK` uses whole seconds. `0` disables the timeout.
- The logic depends on the active power scheme because `powercfg` writes to `SCHEME_CURRENT`.
- The On Wake trigger depends on Modern Standby (S0 Low Power Idle). On systems without Modern Standby, Event ID 507 will not fire and promotion will not occur.

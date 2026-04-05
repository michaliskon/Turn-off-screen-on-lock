# Turn Off Screen on Lock

**Lock your PC, screen goes dark in 5 seconds. Come back, and you actually have time to type your password.**


## The problem

Let's say that you want your screen to go dark 5 seconds after Windows is locked.
There is only one setting (`VIDEOCONLOCK`) that controls this on both occasions:

1. **After you lock**: you want it short, like 5 seconds, so the screen goes dark quickly
2. **When you want to unlock**: that same 5 seconds is all you get to start typing your password before the screen goes dark again

This can especially useful, if you are using a docking station, which often takes several seconds (up to 10-15) for the whole system to "wake up".


## What this does

Flips `VIDEOCONLOCK` between a short and long value at the right time:

| When | Timeout |
|---|---|
| You lock the PC | **5 seconds** (screen off fast) |
| You wake it to unlock | changed to **5 minutes** (enough time to start typing your password) |
| You unlock | Back to **5 seconds** for next time |

Both values are [configurable](#configuration).

Under the hood it's three scheduled tasks and a PowerShell script that rewrite the setting on lock, wake, and unlock events. Nothing stays running in the background.


## Requirements

- Windows 10 or 11 with Modern Standby (S0 Low Power Idle)
- PowerShell 5.1+
- Admin privileges (one-time, for install)


## Install

1. Open PowerShell as Admin
2. `cd` to where you want the files to live (they stay there):

```powershell
cd <your-folder>
```

3. Download and install the latest release:

```powershell
irm https://github.com/michaliskon/Turn-off-screen-on-lock/releases/latest/download/install.ps1 | iex
```

The script verifies the download checksum before running.

<details>
<summary>Manual installation (inspect before running)</summary>

If you prefer to review the bootstrap script before execution:

```powershell
Invoke-WebRequest https://github.com/michaliskon/Turn-off-screen-on-lock/releases/latest/download/install.ps1 -OutFile install.ps1
Get-Content install.ps1
```
Then:
```
.\install.ps1
```

</details>


## Configuration

Defaults:
- **5 seconds** after lock
- **5 minutes** on wake

Can be adjusted by editing the config file:

```
%LOCALAPPDATA%\Turn-off-screen-on-lock\config.json
```

```json
{
  "baselineTimeoutSeconds": 1,
  "wakeTimeoutSeconds": 300
}
```

| Setting | Default | Description |
|---|---|---|
| `baselineTimeoutSeconds` | 1 | Seconds before the screen turns off after locking |
| `wakeTimeoutSeconds` | 300 | Seconds the screen stays on when waking to unlock |

Both values must be integers between 1 and 86400 (24 hours).

The config file is created automatically during installation. Changes take effect on the next lock, unlock, or wake event -- no reinstall needed.


## Uninstall
In case you want to uninstall:

1. Open PowerShell as Administrator
2. Run:

```powershell
& "$env:TURN_OFF_SCREEN_ON_LOCK_UNINSTALL"
```

3. Once the uninstaller confirms success, you can delete the install folder.


## Security Review

The security and reliability profiles chosen for this project are targeting personal use on trusted home machines.

Enterprise and public device usage have been included in the security review, which concluded that additional hardening is strongly recommended in such cases - see [threat-model-v1.0.1.md](threat-model-v1.0.1.md) for the related risks.


## Documentation

See [spec.md](spec.md) for the full design specification.


## Human / AI 🤖 Contribution in this Project

Based on the project complexity and criticality, human oversight was kept to *low/medium* effort.
|||
|:---|:---:|
| Complexity | Low |
| Criticality | Low |
|||


### Activity split

| Activity | Human | AI |
|:---|:---:|:---:|
| Use case development | ✔️ | ❌ |
| Design | ❌ | ✔️ |
| Design review | ✔️ | ❌ |
| Coding | ❌ | ✔️ |
| Code review | ❌ | ✔️ |
| Functional testing | ✔️ | ❌ |
| Security analysis | ❌ | ✔️ |
| Security risk review | ✔️ | ❌ |
| Security risk remediation | ❌ | ✔️ |
| Deployment | ✔️ | ✔️ |

### LLMs used
| Phase | LLM/coding assistant |
|---|---|
| PoC and initial development | ChatGPT |
| Maturing and release | Claude Code |
| Continuous security reviews and hardening | Claude Code |
| Final security reviews (release) | Claude Code, Codex, Gemini |



## Contributing

### Bugs
Bug reports are welcome - please open an [issue](https://github.com/michaliskon/Turn-off-screen-on-lock/issues) first using the "Bug report" template.
No unsolicited PRs.

### Security Vulnerabilities
Report security vulnerabilities in [GitHub Security Advisories](https://github.com/michaliskon/Turn-off-screen-on-lock/security/advisories/new) - see also [SECURITY.md](SECURITY.md)
- Security hardening for home use will be supported, provided the vulnerability can be demonstrated sufficiently.
- Security hardening relevant only for enterprise use will be supported, if there is enough community interest.
- Critical or high criticality vulnerabilities will always be investigated and responded to (and if possible remediated), regardless of usage or interest.

### Features
All feature requests are welcome - please open an [issue](https://github.com/michaliskon/Turn-off-screen-on-lock/issues) using the "Feature request" template.
- Feature requests for home use will be supported, considering a real use case can be exhibited.
- Feature requests for enterprise use will be supported, if there is enough community interest.



## License

[MIT](LICENSE)

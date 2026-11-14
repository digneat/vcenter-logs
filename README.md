# vcenter-logs

PowerShell script for Windows admins to pull log files from a VMware vCenter Server (and optionally specific ESXi hosts) without clicking through the H5 Client every time. Two modes:

- **Bundle** — generates the same `.tgz` support bundle VMware/Druva/Broadcom support asks for. Drop it on a ticket.
- **Files** — downloads specific named logs (`vpxd`, `hostd`, `vmkernel`, etc.) as plain files for quick grepping locally.

Both modes write a CSV manifest of everything downloaded.

## Quickstart

```powershell
# One-time install on the workstation
Install-Module VMware.PowerCLI -Scope CurrentUser -AllowClobber

# Clone
git clone https://github.com/digneat/vcenter-logs.git
cd vcenter-logs

# Pull a full support bundle from vCenter + 2 ESXi hosts
.\Get-VCenterLogs.ps1 -Server vcenter.example.com `
                      -User 'administrator@vsphere.local' `
                      -Mode Bundle `
                      -VMHost esx1.example.com `
                      -VMHost esx2.example.com `
                      -SkipCertificateCheck
```

Output lands in `.\vc-logs\<vcenter>-<timestamp>\` with a `manifest.csv` alongside it.

## The two modes

### Bundle mode (default)
Wraps PowerCLI's `Get-Log -Bundle`. vCenter generates the `.tgz` server-side and streams it back. Slow (minutes), big (hundreds of MB), and the right answer when you're opening a ticket.

```powershell
# vCenter only
.\Get-VCenterLogs.ps1 -Server vc.example.com -User 'admin@vsphere.local' -SkipCertificateCheck

# vCenter + every ESXi host
.\Get-VCenterLogs.ps1 -Server vc.example.com -User 'admin@vsphere.local' -AllHosts -SkipCertificateCheck

# vCenter + named hosts
.\Get-VCenterLogs.ps1 -Server vc.example.com -User 'admin@vsphere.local' `
                      -VMHost esx1.example.com -VMHost esx2.example.com -SkipCertificateCheck
```

### Files mode
Wraps `Get-Log -Key <name>` and downloads each requested log as a flat file. Fast, small. Right answer for ad-hoc "why did this VM lose its disk yesterday" investigations.

```powershell
# Just vpxd from vCenter — the most useful log for task/operation history
.\Get-VCenterLogs.ps1 -Server vc.example.com -User 'admin@vsphere.local' `
                      -Mode Files -LogKey vpxd -SkipCertificateCheck

# Multiple specific logs from a specific host
.\Get-VCenterLogs.ps1 -Server vc.example.com -User 'admin@vsphere.local' `
                      -Mode Files -VMHost esx1.example.com `
                      -LogKey hostd -LogKey vmkernel -SkipCertificateCheck

# Everything (every log type from every host) — produces a lot of files
.\Get-VCenterLogs.ps1 -Server vc.example.com -User 'admin@vsphere.local' `
                      -Mode Files -AllHosts -SkipCertificateCheck
```

Don't know what `-LogKey` values exist? Connect to vCenter once and ask:

```powershell
Connect-VIServer vc.example.com -User 'admin@vsphere.local'
Get-LogType                                          # vCenter log keys
Get-LogType -VMHost (Get-VMHost esx1.example.com)    # this host's log keys
```

Typical names you'll care about:
- vCenter: `vpxd`, `vpxd-extension`, `vpxd-profiler`, `vmware-vpx`
- ESXi: `hostd`, `vmkernel`, `vmkwarning`, `vobd`, `vpxa`, `fdm`

## Parameters

| Name | Purpose |
|---|---|
| `-Server` | vCenter hostname or IP. **Required.** |
| `-User` | vCenter username. **Required.** |
| `-Password` | SecureString. Prompted if omitted. |
| `-Mode` | `Bundle` (default) or `Files`. |
| `-VMHost` | ESXi host(s) to include. Repeatable. |
| `-AllHosts` | Include every host in the inventory. Mutually exclusive with `-VMHost`. |
| `-LogKey` | Files mode only. Specific log keys. Repeatable. Omit = all available types. |
| `-OutputPath` | Where to save. Default `.\vc-logs`. A timestamped subfolder is created. |
| `-SkipCertificateCheck` | Skip TLS verification (self-signed vCenter certs). |

## What the manifest captures

`manifest.csv` in the run directory has one row per file fetched:

| Column | Meaning |
|---|---|
| `timestamp` | when this row was written |
| `source` | `vCenter hostname` for vCenter, ESXi host name for host logs |
| `key` | log key (e.g. `vpxd`) or literal `bundle` |
| `path` | absolute path of the downloaded file |
| `size_bytes` | file size on disk |
| `result` | `ok` or `failed` |
| `detail` | error message if failed, otherwise empty |

## Common gotchas

- **`Install-Module VMware.PowerCLI` fails with execution policy errors.** Run PowerShell as Administrator once and `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`.
- **First connect prompts about CEIP / cert / SSO.** The script auto-answers these for the session, but you might still see them on first interactive use of PowerCLI on a fresh machine.
- **Bundle generation times out** on very large environments. PowerCLI default timeout is 5 minutes. If your bundle takes longer (rare but possible with 20+ hosts), set `Set-PowerCLIConfiguration -WebOperationTimeoutSeconds 1800` first.
- **Files mode without `-LogKey` on an `-AllHosts` job** pulls ~30 logs per host. 20 hosts = 600 small downloads. Use `-LogKey` to scope down.

## License

[MIT](LICENSE) © 2026 Bryan Elliott

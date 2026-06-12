<#
.SYNOPSIS
    Download log files from a vCenter Server (and optionally selected ESXi hosts)
    using VMware PowerCLI. Two modes: a full support bundle (.tgz) for sending to
    VMware / Druva / Broadcom support, or specific named log files for ad-hoc
    troubleshooting.

.DESCRIPTION
    Bundle mode wraps `Get-Log -Bundle`, which asks vCenter to generate the same
    .tgz support bundle the H5 client produces under "Export Support Bundles".
    Includes vpxd logs, task history, system info, and (if -VMHost specified)
    selected ESXi host logs.

    Files mode iterates over the log types vCenter knows about (or a filtered
    subset you pass with -LogKey) and downloads each as a flat file, suitable
    for grep/select-string. Faster than a full bundle when you just need vpxd.log
    or hostd.log.

    Both modes write a CSV manifest of every file downloaded with timestamp,
    size, and source so you have an audit trail.

.PARAMETER Server
    vCenter hostname or IP. Required.

.PARAMETER User
    vCenter username (e.g. administrator@vsphere.local). Required.

.PARAMETER Password
    SecureString password. If omitted you'll be prompted.

.PARAMETER Mode
    'Bundle' or 'Files'. Default: Bundle.

.PARAMETER VMHost
    Names of ESXi hosts (as seen in vCenter inventory) to include.
    Repeatable: -VMHost esx1.example.com -VMHost esx2.example.com.
    Empty (default) = vCenter only.

.PARAMETER AllHosts
    Include every ESXi host in the inventory. Convenience flag instead of listing
    each host explicitly. Mutually exclusive with -VMHost.

.PARAMETER LogKey
    Files-mode only. Specific log keys to download (e.g. 'vpxd', 'vmware-vpx').
    Repeatable. If omitted, downloads ALL available log types — usually fine
    for vCenter (handful of logs), but produces ~30 files per ESXi host.

.PARAMETER OutputPath
    Where to save downloads. A timestamped subfolder is created here.
    Default: .\vc-logs

.PARAMETER SkipCertificateCheck
    Skip TLS verification (use with self-signed vCenter certs).

.EXAMPLE
    # Full support bundle from vCenter + 2 specific ESXi hosts
    .\Get-VCenterLogs.ps1 -Server vcenter.example.com -User 'admin@vsphere.local' `
        -Mode Bundle -VMHost esx1.example.com -VMHost esx2.example.com `
        -SkipCertificateCheck

.EXAMPLE
    # Just vpxd from vCenter for a quick grep
    .\Get-VCenterLogs.ps1 -Server vcenter.example.com -User 'admin@vsphere.local' `
        -Mode Files -LogKey vpxd -SkipCertificateCheck

.EXAMPLE
    # Every log from every host (verbose — many files)
    .\Get-VCenterLogs.ps1 -Server vcenter.example.com -User 'admin@vsphere.local' `
        -Mode Files -AllHosts -SkipCertificateCheck

.NOTES
    Requires VMware PowerCLI. Install once:
        Install-Module VMware.PowerCLI -Scope CurrentUser -AllowClobber
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Server,

    [Parameter(Mandatory)]
    [string]$User,

    [SecureString]$Password,

    [ValidateSet("Bundle", "Files")]
    [string]$Mode = "Bundle",

    [string[]]$VMHost = @(),

    [switch]$AllHosts,

    [string[]]$LogKey = @(),

    [string]$OutputPath = ".\vc-logs",

    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = "Stop"

# ─── Pre-flight ───────────────────────────────────────────────────────────────

if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    Write-Error @"
VMware PowerCLI is not installed. Install it once with:
    Install-Module VMware.PowerCLI -Scope CurrentUser -AllowClobber
Then re-run this script.
"@
    exit 1
}

if ($AllHosts -and $VMHost.Count -gt 0) {
    Write-Error "Pass either -AllHosts or -VMHost <names>, not both."
    exit 1
}

Import-Module VMware.PowerCLI -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

# Suppress the "Customer Experience Improvement Program" prompt on first run
Set-PowerCLIConfiguration -ParticipateInCEIP $false -Confirm:$false -Scope Session | Out-Null

if ($SkipCertificateCheck) {
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
}

if (-not $Password) {
    $Password = Read-Host -AsSecureString "Password for $User@$Server"
}

$credential = New-Object System.Management.Automation.PSCredential($User, $Password)

# ─── Output directory ────────────────────────────────────────────────────────

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runDir    = Join-Path $OutputPath "$Server-$timestamp"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$manifest  = Join-Path $runDir "manifest.csv"
"timestamp,source,key,path,size_bytes,result,detail" | Out-File $manifest -Encoding utf8

function Add-Manifest {
    param($Source, $Key, $Path, $Size, $Result, $Detail)
    $row = @(
        (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"),
        $Source,
        $Key,
        $Path,
        $Size,
        $Result,
        ($Detail -replace ',', ';')   # keep CSV well-formed
    ) -join ","
    Add-Content -Path $manifest -Value $row
}

Write-Host "→ Connecting to $Server as $User..."
$vc = Connect-VIServer -Server $Server -Credential $credential
Write-Host "  connected. vCenter version: $($vc.Version) build $($vc.Build)"

try {
    # ─── Resolve host list ──────────────────────────────────────────────────
    $targetHosts = @()
    if ($AllHosts) {
        $targetHosts = Get-VMHost
        Write-Host "→ -AllHosts: $($targetHosts.Count) host(s) in inventory"
    } elseif ($VMHost.Count -gt 0) {
        foreach ($name in $VMHost) {
            $h = Get-VMHost -Name $name -ErrorAction SilentlyContinue
            if ($h) { $targetHosts += $h }
            else    { Write-Warning "Host not found: $name" }
        }
        Write-Host "→ Targeting $($targetHosts.Count) host(s)"
    } else {
        Write-Host "→ vCenter only (no -VMHost / -AllHosts specified)"
    }

    # ─── Bundle mode ────────────────────────────────────────────────────────
    if ($Mode -eq "Bundle") {
        Write-Host ""
        Write-Host "=== Generating support bundle (this can take several minutes) ==="
        $bundleArgs = @{
            Bundle          = $true
            DestinationPath = $runDir
            ErrorAction     = "Stop"
        }
        if ($targetHosts.Count -gt 0) { $bundleArgs.VMHost = $targetHosts }

        try {
            $bundle = Get-Log @bundleArgs
            foreach ($b in $bundle) {
                $size = (Get-Item $b.Data).Length
                Write-Host ("  saved {0,12:N0} bytes -> {1}" -f $size, $b.Data)
                Add-Manifest -Source $Server -Key "bundle" -Path $b.Data -Size $size -Result "ok" -Detail ""
            }
        }
        catch {
            Write-Warning "Bundle generation failed: $_"
            Add-Manifest -Source $Server -Key "bundle" -Path "" -Size 0 -Result "failed" -Detail $_.Exception.Message
            throw
        }
    }

    # ─── Files mode ─────────────────────────────────────────────────────────
    if ($Mode -eq "Files") {
        Write-Host ""
        Write-Host "=== Downloading individual log files ==="

        # Build (source, log-type) pairs
        $jobs = @()

        # vCenter logs — pass no -VMHost
        $vcKeys = if ($LogKey.Count -gt 0) {
            $LogKey
        } else {
            (Get-LogType).Key
        }
        foreach ($k in $vcKeys) {
            $jobs += [pscustomobject]@{ Source = $Server; Host = $null; Key = $k }
        }

        # Each ESXi host
        foreach ($h in $targetHosts) {
            $hostKeys = if ($LogKey.Count -gt 0) {
                $LogKey
            } else {
                (Get-LogType -VMHost $h).Key
            }
            foreach ($k in $hostKeys) {
                $jobs += [pscustomobject]@{ Source = $h.Name; Host = $h; Key = $k }
            }
        }

        Write-Host "  $($jobs.Count) log(s) to fetch"

        foreach ($j in $jobs) {
            $hostDir = Join-Path $runDir ($j.Source -replace '[\\/:*?"<>|]', '_')
            New-Item -ItemType Directory -Force -Path $hostDir | Out-Null
            try {
                $args = @{ Key = $j.Key; DestinationPath = $hostDir; ErrorAction = "Stop" }
                if ($j.Host) { $args.VMHost = $j.Host }
                $result = Get-Log @args
                $size = 0
                $path = ""
                if ($result -and $result.Filename) {
                    $path = $result.Filename
                    if (Test-Path $path) { $size = (Get-Item $path).Length }
                }
                Write-Host ("  [{0}] {1,-25} {2,12:N0} bytes" -f $j.Source, $j.Key, $size)
                Add-Manifest -Source $j.Source -Key $j.Key -Path $path -Size $size -Result "ok" -Detail ""
            }
            catch {
                Write-Warning "  [$($j.Source)] $($j.Key) — $_"
                Add-Manifest -Source $j.Source -Key $j.Key -Path "" -Size 0 -Result "failed" -Detail $_.Exception.Message
            }
        }
    }
}
finally {
    Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
}

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Done ==="
Write-Host "  output:   $runDir"
Write-Host "  manifest: $manifest"
$totalBytes = (Import-Csv $manifest | Measure-Object -Property size_bytes -Sum).Sum
if ($totalBytes) {
    Write-Host ("  total:    {0:N0} bytes ({1:N1} MB)" -f $totalBytes, ($totalBytes / 1MB))
}

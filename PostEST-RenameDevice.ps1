<#
  Autopilot rename helper
  - Detects country from public IP, includes it in hostname.
  - Stages the actual rename for first user logon (post-ESP) to avoid provisioning conflicts.

  Customize: $OrgPrefix (optional), $SerialDigits, $UseFormFactor
#>

# ---- Settings you may customize ----
$OrgPrefix      = ""          # e.g. "MSFT-" (keep empty if you don’t want it)
$SerialDigits   = 6           # take last N chars of serial
$UseFormFactor  = $true       # include L/D for Laptop/Desktop
$WorkDir        = "C:\ProgramData\Company\Rename"
$TaskName       = "PostESP-RenameComputer"
# -----------------------------------

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-PublicCountryCode {
    # Tries multiple providers and returns ISO-3166-1 alpha-2 code (e.g., SG, US); returns 'ZZ' on failure
    $providers = @(
        @{ Url = 'https://ipapi.co/json/';      Keys = @('country_code') },      # ipapi.co
        @{ Url = 'https://ipinfo.io/json';      Keys = @('country_code','country') } # IPinfo (new & legacy fields)
    )
    foreach ($p in $providers) {
        try {
            $resp = Invoke-RestMethod -Uri $p.Url -TimeoutSec 6 -ErrorAction Stop
            foreach ($k in $p.Keys) {
                $val = $resp.$k
                if ($val -and $val -match '^[A-Za-z]{2}$') { return $val.ToUpper() }
            }
        } catch { }
    }
    return 'ZZ'
}

function Get-FormFactorToken {
    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
    } catch { $battery = $null }
    return $(if ($battery) {'L'} else {'D'})
}

function Get-SerialSafe([int]$digits) {
    # Use BIOS serial; fallback to ComputerSystemProduct
    $serial = $null
    try { $serial = (Get-CimInstance -Class Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber } catch {}
    if (-not $serial) {
        try { $serial = (Get-CimInstance -Class Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).IdentifyingNumber } catch {}
    }
    if (-not $serial) { $serial = (New-Guid).Guid.Replace('-','') } # ultra-rare fallback
    $serial = ($serial -replace '[^A-Za-z0-9]','').ToUpper()
    if ($serial.Length -gt $digits) { return $serial.Substring($serial.Length - $digits) }
    return $serial
}

function New-TargetName {
    param([string]$Country,[string]$SerialPart,[string]$FormFactor,[string]$Prefix)
    $cc = ($Country -replace '[^A-Z]','').ToUpper()
    if ($cc.Length -ne 2) { $cc = 'ZZ' }

    $parts = @()
    if ($Prefix) { $parts += ($Prefix -replace '[^A-Za-z0-9-]','').ToUpper().Trim('-') }
    $parts += $cc
    if ($UseFormFactor) { $parts += $FormFactor }
    $parts += $SerialPart

    # Join with hyphens, sanitize, enforce 15-char NetBIOS limit, ensure first char not numeric
    $name = ($parts -join '-').ToUpper()
    $name = ($name -replace '[^A-Z0-9-]','')
    if ($name.Length -gt 15) { $name = $name.Substring(0,15) }
    if ($name -match '^[0-9]') { $name = 'Z' + $name.Substring(1) } # avoid all-numeric/DNS edge
    if (-not $name) { $name = 'Z-DEVICE' }
    return $name
}

function Stage-Rename {
    param([string]$TargetName)
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $targetFile  = Join-Path $WorkDir 'targetname.txt'
    $renameFile  = Join-Path $WorkDir 'Do-Rename.ps1'
    Set-Content -Path $targetFile -Value $TargetName -Encoding ASCII

    $script = @"
`$ErrorActionPreference = 'Stop'
`$workDir = '$WorkDir'
`$target  = (Get-Content -Path (Join-Path `$workDir 'targetname.txt') -ErrorAction SilentlyContinue).Trim()
if (-not `$target) { exit 0 }

# Wait a bit after first sign-in to ensure shell & services settle
Start-Sleep -Seconds 30

`$current = (hostname)
if (`$current -ieq `$target) { exit 0 }

try {
    Rename-Computer -NewName `$target -Force  # reboot separately to keep control
    # Mark success then reboot quickly
    New-Item -Path (Join-Path `$workDir 'renamed.stamp') -ItemType File -Force | Out-Null
    shutdown.exe /r /t 5 /c "Applying device name '`$target'"
} catch {
    Add-Content -Path (Join-Path `$workDir 'rename.log') -Value ((Get-Date).ToString('s') + ' ' + `$_)
    exit 1
}
"@
    Set-Content -Path $renameFile -Value $script -Encoding ASCII

    # Create Scheduled Task: at first user logon, run as SYSTEM with highest privileges
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$renameFile`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
}

# -------- main --------
try {
    $country   = Get-PublicCountryCode     # ipapi/ipinfo JSON fields (country_code / country) [6](https://ipapi.co/documentation/)[7](https://ipinfo.io/developers/data-types)
    $ff        = $(if ($UseFormFactor) { Get-FormFactorToken } else { "" })
    $serial    = Get-SerialSafe -digits $SerialDigits
    $target    = New-TargetName -Country $country -SerialPart $serial -FormFactor $ff -Prefix $OrgPrefix

    $current   = (hostname)
    if ($current -ieq $target) { return }  # already named as desired

    Stage-Rename -TargetName $target
} catch {
    Write-Error $_
    # fall through; Intune IME will retry on failure per policy
}

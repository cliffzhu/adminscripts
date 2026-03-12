$ErrorActionPreference = 'SilentlyContinue'

function Get-ProfileList {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    Get-ChildItem $k | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        if ($p.ProfileImagePath -and (Test-Path $p.ProfileImagePath)) {
            [PSCustomObject]@{
                SID         = $_.PSChildName
                ProfilePath = $p.ProfileImagePath
            }
        }
    }
}

function Sid-To-NTAccount {
    param([string]$Sid)
    try {
        return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).
            Translate([System.Security.Principal.NTAccount]).Value
    } catch { return $null }
}

function Ensure-HiveLoaded {
    param([string]$Sid,[string]$ProfilePath)
    $already = Test-Path "Registry::HKEY_USERS\$Sid"
    if (-not $already) {
        $ntUser = Join-Path $ProfilePath 'NTUSER.DAT'
        if (Test-Path $ntUser) { & reg.exe load "HKU\$Sid" "$ntUser" >$null 2>&1 }
    }
    return $already
}

function Unload-HiveIfNeeded {
    param([string]$Sid,[bool]$AlreadyLoaded)
    if (-not $AlreadyLoaded) { & reg.exe unload "HKU\$Sid" >$null 2>&1 }
}

function Try-GetUpnFromUserHive {
    param([string]$Sid)

    $roots = @(
        "Registry::HKEY_USERS\$Sid\Software\Microsoft\Office\16.0\Common\Identity",
        "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\WebAccountManager",
        "Registry::HKEY_USERS\$Sid\Software\Microsoft\IdentityCRL",
        "Registry::HKEY_USERS\$Sid\Software\Microsoft\OneDrive"
    )

    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }

        # Shallow scan: look at a reasonable number of keys/values for @ strings
        $keys = Get-ChildItem $r -Recurse -ErrorAction SilentlyContinue | Select-Object -First 500
        foreach ($k in $keys) {
            $props = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -match '^PS') { continue }
                if ($p.Value -is [string] -and $p.Value -match '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' ) {
                    return $Matches[0]
                }
            }
        }
    }

    return $null
}

function Try-GetUpnFromDeviceCloudAP {
    # Some builds keep user info under CloudAP; not guaranteed.
    $candidates = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Provider Filters'
    )

    $found = @()
    foreach ($c in $candidates) {
        if (Test-Path $c) { $found += $c }
    }
    return ($found -join '; ')
}

$profiles = Get-ProfileList

$out = foreach ($prof in $profiles) {
    $sid  = $prof.SID
    $path = $prof.ProfilePath

    $type =
        if ($sid -like 'S-1-12-1-*') { 'Entra/AAD-like SID' }
        elseif ($sid -like 'S-1-5-21-*') { 'Local/Domain-like SID' }
        elseif ($sid -in @('S-1-5-18','S-1-5-19','S-1-5-20')) { 'Built-in Service' }
        else { 'Other' }

    $nt = Sid-To-NTAccount -Sid $sid

    $already = $false
    $upn = $null

    # Try to extract UPN/email for “real” user profiles only
    if ($type -notmatch 'Built-in Service') {
        $already = Ensure-HiveLoaded -Sid $sid -ProfilePath $path
        $upn = Try-GetUpnFromUserHive -Sid $sid
        Unload-HiveIfNeeded -Sid $sid -AlreadyLoaded $already
    }

    [PSCustomObject]@{
        SID         = $sid
        ProfilePath = $path
        Type        = $type
        NTAccount   = $nt
        UPNorEmail  = $upn
    }
}

$out | Sort-Object ProfilePath | Format-Table -AutoSize


<# 
.SYNOPSIS
  Queue version trim jobs for every document library in a SharePoint Online site.

.REQUIRES
  - Microsoft.Online.SharePoint.PowerShell (SPO Mgmt Shell)
  - Admin rights in SharePoint Online
  - Connect-SPOService to your tenant admin URL first

.PARAMS
  -AdminUrl        The tenant admin URL (e.g., https://yourcorp-admin.sharepoint.com)
  -SiteUrl         The target site URL (e.g., https://yourcorp.sharepoint.com/sites/Projects)
  -Mode            "Age", "Automatic", or "Query" (view existing jobs only)
  -DeleteBeforeDays Required when Mode = "Age" (minimum 30 per Microsoft)
  -IncludeHidden   Include hidden libraries (default: false)
  -WhatIf          Simulate: list libraries that would be processed; do not queue jobs

.NOTES
  - Jobs run asynchronously and may take hours/days depending on volume.
  - Version deletions are permanent and bypass the recycle bin.
  - Retention / eDiscovery holds take precedence; versions under hold won’t be deleted.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$AdminUrl,

    [Parameter(Mandatory=$true)]
    [string]$SiteUrl,

    [Parameter(Mandatory=$true)]
    [ValidateSet("Age","Automatic","Query")]
    [string]$Mode,

    [int]$DeleteBeforeDays = 60,

    [switch]$IncludeHidden,

    [switch]$WhatIf
)

# Import SPO module with compatibility mode if running in PS7
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Host "PowerShell 7+ detected. Loading SPO module in compatibility mode..." -ForegroundColor Yellow
    Import-Module Microsoft.Online.SharePoint.PowerShell -UseWindowsPowerShell -WarningAction SilentlyContinue
}

function Get-SPOWebLists {
    param([string]$SiteUrl)

    # Use PnP to enumerate lists; SPO shell doesn’t enumerate lists easily.
    # PnP is used only to enumerate; trim jobs are queued via SPO cmdlets.
    
    # Check if already connected to this site
    $existingConnection = Get-PnPConnection -ErrorAction SilentlyContinue
    if ($existingConnection -and $existingConnection.Url -eq $SiteUrl) {
        Write-Host "Already connected to $SiteUrl" -ForegroundColor Gray
    } else {
        Connect-PnPOnline -Url $SiteUrl -Interactive
    }

    $lists = Get-PnPList |
        Where-Object {
            # Document libraries only
            $_.BaseTemplate -eq 101 -and
            ($IncludeHidden -or $_.Hidden -eq $false)
        } |
        Select-Object Title, RootFolder, Hidden

    return $lists
}

# 1) Connect to SPO Admin
Write-Host "Connecting to SPO Admin: $AdminUrl" -ForegroundColor Cyan

# Check if already connected to SPO Admin
try {
    $null = Get-SPOTenant -ErrorAction Stop
    Write-Host "Already connected to SPO Admin" -ForegroundColor Gray
}
catch {
    Connect-SPOService -Url $AdminUrl
}

# 2) Discover document libraries in the site
Write-Host "Discovering document libraries in: $SiteUrl" -ForegroundColor Cyan
$libs = Get-SPOWebLists -SiteUrl $SiteUrl

if (!$libs -or $libs.Count -eq 0) {
    Write-Warning "No document libraries found to process."
    return
}

Write-Host ("Found {0} libraries:" -f $libs.Count) -ForegroundColor Green
$libs | ForEach-Object { Write-Host (" - {0}" -f $_.Title) }

# 3) Queue trim jobs per library (skip if Query mode)
if ($Mode -eq "Query") {
    Write-Host "Query mode: Checking existing job status only (not queuing new jobs)" -ForegroundColor Yellow
} else {
    $results = @()
    foreach ($lib in $libs) {
        $libName = $lib.Title

        if ($WhatIf) {
        $results += [pscustomobject]@{
            Library     = $libName
            Mode        = $Mode
            DeleteDays  = if ($Mode -eq "Age") { $DeleteBeforeDays } else { $null }
            Queued      = $false
            Message     = "WHATIF: would queue job"
        }
        continue
    }

    try {
        if ($Mode -eq "Automatic") {
            Write-Host "Queuing AUTOMATIC trim for '$libName'..." -ForegroundColor Yellow
            New-SPOListFileVersionBatchDeleteJob -Site $SiteUrl -List $libName -Automatic -Confirm:$false | Out-Null
        } else {
            # Microsoft Learn warns: age trim has a 30-day minimum and special pre-2023 behavior
            if ($DeleteBeforeDays -lt 30) {
                throw "DeleteBeforeDays must be >= 30 (Microsoft documented minimum)."
            }
            Write-Host "Queuing AGE-based trim ($DeleteBeforeDays days) for '$libName'..." -ForegroundColor Yellow
            New-SPOListFileVersionBatchDeleteJob -Site $SiteUrl -List $libName -DeleteBeforeDays $DeleteBeforeDays -Confirm:$false | Out-Null
        }

        $results += [pscustomobject]@{
            Library     = $libName
            Mode        = $Mode
            DeleteDays  = if ($Mode -eq "Age") { $DeleteBeforeDays } else { $null }
            Queued      = $true
            Message     = "Queued"
        }
    }
    catch {
        $results += [pscustomobject]@{
            Library     = $libName
            Mode        = $Mode
            DeleteDays  = if ($Mode -eq "Age") { $DeleteBeforeDays } else { $null }
            Queued      = $false
            Message     = $_.Exception.Message
        }
    }
    }

    # 4) Report queue results
    Write-Host "`nQueue results:" -ForegroundColor Cyan
    $results | Format-Table -AutoSize
}

# 5) Poll job progress for each library
if (-not $WhatIf) {
    Write-Host "`nJob Status:" -ForegroundColor Cyan
    $statusResults = @()
    foreach ($lib in $libs) {
        try {
            $status = Get-SPOListFileVersionBatchDeleteJobProgress -Site $SiteUrl -List $lib.Title -ErrorAction SilentlyContinue
            if ($status) {
                $storageMB = [math]::Round($status.StorageReleasedInBytes / 1MB, 2)
                $statusResults += [pscustomobject]@{
                    Library          = $lib.Title
                    Status           = $status.Status
                    FilesProcessed   = $status.FilesProcessed
                    VersionsDeleted  = $status.VersionsDeleted
                    VersionsFailed   = $status.VersionsFailed
                    StorageFreedMB   = $storageMB
                    Mode             = $status.BatchDeleteMode
                    Completed        = $status.CompleteTimeInUTC
                }
            } else {
                $statusResults += [pscustomobject]@{
                    Library          = $lib.Title
                    Status           = "NoJob"
                    FilesProcessed   = 0
                    VersionsDeleted  = 0
                    VersionsFailed   = 0
                    StorageFreedMB   = 0
                    Mode             = "-"
                    Completed        = "-"
                }
            }
        }
        catch {
            Write-Host ("{0}: Error reading status: {1}" -f $lib.Title, $_.Exception.Message) -ForegroundColor Red
        }
    }
    $statusResults | Format-Table -AutoSize
    
    # Summary
    $totalVersionsDeleted = ($statusResults | Measure-Object -Property VersionsDeleted -Sum).Sum
    $totalStorageMB = ($statusResults | Measure-Object -Property StorageFreedMB -Sum).Sum
    Write-Host "`nSummary: Deleted $totalVersionsDeleted versions, freed $totalStorageMB MB" -ForegroundColor Green
}

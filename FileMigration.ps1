<#
    Robocopy Migration Script (ASCII Safe Version)
    ----------------------------------------------
    - Supports multiple Source -> Destination pairs
    - Auto-creates destination folders
    - Safety checks to avoid accidental deletion with /MIR
    - Logs written to %PUBLIC%\Logs
    - Multi-threaded Robocopy support
#>

# Ensure log folder exists
$LogRoot = "$env:PUBLIC\Logs"
try {
    if (!(Test-Path $LogRoot)) {
        New-Item -ItemType Directory -Path $LogRoot -ErrorAction Stop | Out-Null
    }
} catch {
    Write-Host "Failed to create log directory: $LogRoot" -ForegroundColor Red
    Write-Host "Error: $_" -ForegroundColor Red
    exit 1
}
function Get-RoboCount {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Run robocopy in list mode and enable file names so we can stop early.
    $process = Start-Process -FilePath "robocopy.exe" `
        -ArgumentList "`"$Path`" NULL /L /S /NJH /NJS /NDL" `
        -NoNewWindow -RedirectStandardOutput "pipe" -PassThru

    $count = 0

    while (-not $process.HasExited) {
        $line = $process.StandardOutput.ReadLine()

        if ($line -match "^\s+\d+\s+(.+)$") {
            # Robocopy file lines start with something like:
            #    123456  file.txt
            $count++

            if ($count -ge 100) {
                # We have enough, kill robocopy to stop scanning
                try { $process.Kill() } catch {}
                break
            }
        }
    }

    return $count
}


Write-Host "=== Robocopy File Server Migration Script ===" -ForegroundColor Cyan
Write-Host "Enter the pairs of Source and Destination paths to migrate." -ForegroundColor Yellow
Write-Host "Type 'done' at Source prompt when finished." -ForegroundColor Yellow

# ============================================================
# EXCLUDED FOLDERS CONFIGURATION
# ============================================================
# Define folders to exclude from the copy (prevents recursive loops)
# These will be passed to robocopy's /XD (exclude directory) flag
$ExcludedFolders = @(
    "Backup*",        # Excludes: Backup, Backup 1, Backup 2, Backup 2023, etc.
    "*Backup*",       # Excludes any folder containing "Backup" in name
    "latest",         # Excludes "latest" folders
    ".git",           # Exclude Git repositories
    ".svn",           # Exclude SVN repositories
    "node_modules",   # Exclude Node.js dependencies
    "$RECYCLE.BIN",   # Exclude recycle bin
    "System Volume Information",  # Exclude system folders
    "@Recycle"
)
# Add more folders as needed, e.g.:
# $ExcludedFolders += "OldBackups"
# $ExcludedFolders += "Archive*"

# ============================================================
# OPTION 1: Predefined pairs (edit as needed)
# ============================================================
if (-not (Get-Variable -Name Pairs -ErrorAction SilentlyContinue)) {
    $Pairs = @(
        @{
            Source      = "c:\it"
            Destination = "c:\Temp\It"
        }
    )
}

# ============================================================

# If Pairs is empty, switch to interactive mode
if (-not $Pairs -or $Pairs.Count -eq 0) {
    $Pairs = @()

    while ($true) {
        $src = Read-Host "Source path"
        if ($src -eq "done") { break }

        if ([string]::IsNullOrWhiteSpace($src)) {
            Write-Host "Source cannot be blank." -ForegroundColor Red
            continue
        }

        if (!(Test-Path $src)) {
            Write-Host "Source does NOT exist. Try again." -ForegroundColor Red
            continue
        }

        $dst = Read-Host "Destination path"

        if ([string]::IsNullOrWhiteSpace($dst)) {
            Write-Host "Destination cannot be blank." -ForegroundColor Red
            continue
        }

        # Normalize paths
        try {
            $srcResolved = (Resolve-Path $src).ProviderPath.TrimEnd('\')

            if (Test-Path $dst) {
                $dstResolved = (Resolve-Path $dst).ProviderPath.TrimEnd('\')
            } else {
                $dstResolved = $dst.TrimEnd('\')
            }

            # Source == Destination check
            if ($srcResolved -eq $dstResolved) {
                Write-Host "Source and Destination cannot be the same path." -ForegroundColor Red
                continue
            }

            # prevent infinite loop (dst inside src)
            if ($dstResolved.StartsWith("$srcResolved\", [StringComparison]::OrdinalIgnoreCase)) {
                Write-Host "Destination cannot be a subdirectory of Source." -ForegroundColor Red
                continue
            }
        } catch {
            Write-Warning "Could not validate path relationship: $_"
        }

        $Pairs += @{ Source = $src; Destination = $dst }
    }
} else {
    Write-Host "Using pre-defined pairs from script..." -ForegroundColor Green
}

if ($Pairs.Count -eq 0) {
    Write-Host "No pairs entered. Exiting." -ForegroundColor Red
    exit
}

Write-Host "Starting migration..." -ForegroundColor Green

$successCount = 0
$failureCount = 0

foreach ($pair in $Pairs) {
    $Source = $pair.Source
    $Dest   = $pair.Destination

    Write-Host ""
    Write-Host "=== Processing ==="
    Write-Host "From: $Source"
    Write-Host "To:   $Dest"

    # SAFETY CHECKS
    Write-Host "Performing safety checks..." -ForegroundColor Cyan

    if (!(Test-Path $Source)) {
        Write-Host "Source does NOT exist: $Source" -ForegroundColor Red
        $failureCount++
        continue
    }

    # Check for suspiciously deep paths (recursive backup loop indicator)
    $sourceDepth = ($Source -split '\\').Count
    if ($sourceDepth -gt 15) {
        Write-Host "⚠️  WARNING: Source path is suspiciously deep ($sourceDepth levels)!" -ForegroundColor Red
        Write-Host "This might indicate a recursive backup loop." -ForegroundColor Red
        Write-Host "Path: $Source" -ForegroundColor Yellow
        $confirm = Read-Host "Continue anyway? (type 'YES' to confirm)"
        if ($confirm -ne "YES") {
            Write-Host "❌ Skipping this pair for safety." -ForegroundColor Yellow
            $failureCount++
            continue
        }
    }

    # Quick root-level check
    $sourceRootItems = @(Get-ChildItem -Path $Source -ErrorAction SilentlyContinue)
    $sourceRootCount = $sourceRootItems.Count

    if ($sourceRootCount -eq 0) {
        Write-Host "WARNING: Source is EMPTY!" -ForegroundColor Red
        Write-Host "Using /MIR will DELETE destination contents." -ForegroundColor Red
        $confirm = Read-Host "Type YES to continue"
        if ($confirm -ne "YES") { 
            $failureCount++
            continue 
        }
    }

    # Quick sample (PowerShell 5 compatible)
    try {
$sourceQuickCount = Get-RoboCount $Source
Write-Host "Source contains at least ~ $sourceQuickCount files (fast check)" -ForegroundColor Cyan


        Write-Host "Source contains at least ~ $sourceQuickCount files (sample)" -ForegroundColor Cyan
    } catch {
        Write-Host "Source quick count unavailable." -ForegroundColor Yellow
    }

    # Destination checks
    if (Test-Path $Dest) {
        try {
$destQuickCount = Get-RoboCount $Dest
Write-Host "Destination contains at least ~ $destQuickCount files (fast check)" -ForegroundColor Cyan


            Write-Host "Destination contains at least ~ $destQuickCount files (sample)" -ForegroundColor Cyan
        } catch {}

        if ($destQuickCount -gt 100 -and $sourceQuickCount -lt 10) {
            Write-Host "WARNING: Destination has much more content than source!" -ForegroundColor Red
            $confirm = Read-Host "Type YES to continue"
            if ($confirm -ne "YES") { 
                $failureCount++
                continue 
            }
        }
    }

    Write-Host "Safety checks passed." -ForegroundColor Green

    # Create destination folder if needed
    if (!(Test-Path $Dest)) {
        try {
            New-Item -ItemType Directory -Path $Dest -Force -EA Stop | Out-Null
        } catch {
            Write-Host "Failed to create destination: $Dest" -ForegroundColor Red
            $failureCount++
            continue
        }
    }

    # LOG FILE
    $timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $safeSrc = ($Source -replace "[:\\\/]", "_")
    $LogFile = "$LogRoot\Robocopy_${safeSrc}_$timestamp.log"

    # ROBOPY OPTIONS
    $RobocopyOptions = @(
        "/MIR",
        "/COPY:DAT",
        "/R:2",
        "/W:2",
        "/MT:16",
        "/Z",
        "/FFT",
        "/V",
        "/TEE",
        "/LOG:$LogFile"
    )
    
    # Add excluded directories if defined
    if ($ExcludedFolders -and $ExcludedFolders.Count -gt 0) {
        $RobocopyOptions += "/XD"
        $RobocopyOptions += $ExcludedFolders
        $RobocopyOptions += $Dest  # Always exclude destination to prevent nested copies
        Write-Host "Excluding $($ExcludedFolders.Count) folder patterns..." -ForegroundColor Yellow
    }

    Write-Host "Running Robocopy..." -ForegroundColor Cyan

    try {
        robocopy $Source $Dest @RobocopyOptions
        $exitCode = $LASTEXITCODE
    } catch {
        Write-Host "Robocopy execution failed: $_" -ForegroundColor Red
        $failureCount++
        continue
    }

    # Exit code analysis
    if ($exitCode -ge 8) {
        Write-Host "FAILURE (exit code $exitCode)" -ForegroundColor Red
        $failureCount++
    } elseif ($exitCode -ge 4) {
        Write-Host "Completed with warnings (exit code $exitCode)" -ForegroundColor Yellow
        $successCount++
    } else {
        Write-Host "Success (exit code $exitCode)" -ForegroundColor Green
        $successCount++
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Green
Write-Host "Total pairs: $($Pairs.Count)"
Write-Host "Successful: $successCount" -ForegroundColor Green
Write-Host "Failed: $failureCount" -ForegroundColor $(if ($failureCount -gt 0) { "Red" } else { "Green" })

if ($failureCount -gt 0) {
    Write-Host ""
    Write-Host "Review log files in: $LogRoot" -ForegroundColor Yellow
    exit 1
} else {
    Write-Host ""
    Write-Host "All migrations completed successfully!" -ForegroundColor Green
    exit 0
}

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

Write-Host "=== Robocopy File Server Migration Script ===" -ForegroundColor Cyan
Write-Host "Enter the pairs of Source and Destination paths to migrate." -ForegroundColor Yellow
Write-Host "Type 'done' at Source prompt when finished." -ForegroundColor Yellow

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
        $sourceQuickCount = (
            Get-ChildItem -Path $Source -Recurse -File -EA SilentlyContinue |
            Where-Object { $_.FullName.Replace($Source, "").Trim('\').Split('\').Count -le 2 } |
            Measure-Object
        ).Count

        Write-Host "Source contains at least ~ $sourceQuickCount files (sample)" -ForegroundColor Cyan
    } catch {
        Write-Host "Source quick count unavailable." -ForegroundColor Yellow
    }

    # Destination checks
    if (Test-Path $Dest) {
        try {
            $destQuickCount = (
                Get-ChildItem -Path $Dest -Recurse -File -EA SilentlyContinue |
                Where-Object { $_.FullName.Replace($Dest, "").Trim('\').Split('\').Count -le 2 } |
                Measure-Object
            ).Count

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

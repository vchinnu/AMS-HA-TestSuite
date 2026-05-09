# ============================================================================
# Run-HAClusterTest.ps1 - Interactive Orchestrator for HA Cluster E2E Testing
# ============================================================================
# Usage: .\Run-HAClusterTest.ps1 [-ConfigPath <path>] [-Phase <1-7|all>]
#
# Interactive menu with phase selection, live status, and HTML report generation.
# ============================================================================

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.yaml'),
    [string]$Phase = ''
)

$ErrorActionPreference = 'Continue'
$script:RootDir = $PSScriptRoot

# Load helpers
. (Join-Path $PSScriptRoot 'helpers\Common.ps1')
. (Join-Path $PSScriptRoot 'helpers\KqlRunner.ps1')
. (Join-Path $PSScriptRoot 'helpers\HtmlReportGenerator.ps1')
. (Join-Path $PSScriptRoot 'helpers\ReportStorage.ps1')

# --- Banner ---
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║          HA Cluster E2E Test Automation Suite               ║" -ForegroundColor Cyan
    Write-Host "  ║          Azure Monitor for SAP Solutions (AMS)              ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

# --- Phase Status Display ---
function Show-PhaseStatus {
    $phases = @(
        @{ Num = 1; Name = 'Install Exporter';      Desc = 'Install HA cluster exporter on nodes' }
        @{ Num = 2; Name = 'Setup AMS';             Desc = 'Create RG, VNet, Subnet, AMS Monitor' }
        @{ Num = 3; Name = 'Create Providers';      Desc = 'Create HA provider per cluster node' }
        @{ Num = 4; Name = 'Validate Data';         Desc = 'Check metrics flow into Log Analytics' }
        @{ Num = 5; Name = 'Workbook & Alerts';     Desc = 'Validate workbook queries and alerts' }
        @{ Num = 6; Name = 'Data Integrity';        Desc = 'Exporter vs workbook comparison (OS cert)' }
        @{ Num = 7; Name = 'Cleanup';               Desc = 'Remove test resources (with consent)' }
    )

    $results = Get-PhaseResults

    Write-Host "  ┌─────┬────────────────────────┬────────────┬──────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │  #  │ Phase                  │ Status     │ Details                              │" -ForegroundColor DarkGray
    Write-Host "  ├─────┼────────────────────────┼────────────┼──────────────────────────────────────┤" -ForegroundColor DarkGray

    foreach ($p in $phases) {
        $result = $results | Where-Object { $_.Phase -match "Phase$($p.Num)" }
        $status = if ($result) { $result.Status } else { 'Not Run' }
        $message = if ($result -and $result.Message) { $result.Message.Substring(0, [Math]::Min($result.Message.Length, 36)) } else { $p.Desc.Substring(0, [Math]::Min($p.Desc.Length, 36)) }
        
        $statusColor = switch ($status) {
            'Passed'  { 'Green' }
            'Failed'  { 'Red' }
            'Running' { 'Yellow' }
            'Skipped' { 'DarkYellow' }
            default   { 'Gray' }
        }
        $icon = switch ($status) {
            'Passed'  { '[OK]' }
            'Failed'  { '[XX]' }
            'Running' { '[>>]' }
            'Skipped' { '[--]' }
            default   { '[  ]' }
        }

        $num = "  $($p.Num)".PadLeft(3)
        $name = $p.Name.PadRight(22)
        $statusStr = "$icon $status".PadRight(10)

        Write-Host "  │ " -NoNewline -ForegroundColor DarkGray
        Write-Host "$num" -NoNewline -ForegroundColor White
        Write-Host " │ " -NoNewline -ForegroundColor DarkGray
        Write-Host "$name" -NoNewline -ForegroundColor White
        Write-Host " │ " -NoNewline -ForegroundColor DarkGray
        Write-Host "$statusStr" -NoNewline -ForegroundColor $statusColor
        Write-Host " │ " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($message.PadRight(36))" -NoNewline -ForegroundColor DarkGray
        Write-Host " │" -ForegroundColor DarkGray
    }
    
    Write-Host "  └─────┴────────────────────────┴────────────┴──────────────────────────────────────┘" -ForegroundColor DarkGray
    Write-Host ""
}

# --- Interactive Menu ---
function Show-Menu {
    param([hashtable]$Config)

    Write-Host "  Config: $ConfigPath" -ForegroundColor DarkGray
    Write-Host "  OS: $($Config['os_type']) $($Config['os_version']) | SID: $($Config['sap_sid']) | Cluster: $($Config['cluster_name']) | Nodes: $($Config['nodes'].Count)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Commands:" -ForegroundColor White
    Write-Host "    [T]    Start full test (Phase 1→6, auto)     [7] Run cleanup (Phase 7)" -ForegroundColor Cyan
    Write-Host "    [1-6]  Run specific phase                    [R] Generate/view report" -ForegroundColor Cyan
    Write-Host "    [S]    Show status                           [L] Show recent logs" -ForegroundColor Cyan
    Write-Host "    [Q]    Quit" -ForegroundColor Cyan
    Write-Host ""
}

# --- Run a Phase ---
function Invoke-PhaseByNumber {
    param([int]$PhaseNum, [hashtable]$Config)

    $phaseScript = switch ($PhaseNum) {
        1 { 'Phase1-InstallExporter.ps1' }
        2 { 'Phase2-SetupAMS.ps1' }
        3 { 'Phase3-CreateProviders.ps1' }
        4 { 'Phase4-ValidateData.ps1' }
        5 { 'Phase5-ValidateWorkbookAlerts.ps1' }
        6 { 'Phase6-DataIntegrityValidation.ps1' }
        7 { 'Phase7-Cleanup.ps1' }
    }

    $scriptPath = Join-Path $PSScriptRoot "phases\$phaseScript"
    if (-not (Test-Path $scriptPath)) {
        Write-PhaseLog -Phase "Phase$PhaseNum" -Level 'ERROR' -Message "Script not found: $scriptPath"
        return
    }

    Write-Host ""
    Write-Host "  ━━━ Running Phase $PhaseNum ━━━" -ForegroundColor Yellow
    Write-Host ""

    # Dot-source and invoke
    . $scriptPath
    $functionName = "Invoke-Phase$PhaseNum"
    & $functionName -Config $Config
}

# --- Phase Time Estimates (minutes) ---
$script:PhaseEstimates = @{
    1 = @{ Name = 'Install Exporter';    MinMin = 2; MaxMin = 5;  Desc = 'SSH + install packages on each node' }
    2 = @{ Name = 'Setup AMS';           MinMin = 3; MaxMin = 8;  Desc = 'Create RG, VNet, Subnet, AMS Monitor' }
    3 = @{ Name = 'Create Providers';    MinMin = 2; MaxMin = 5;  Desc = 'Register HA provider per node' }
    4 = @{ Name = 'Validate Data';       MinMin = 5; MaxMin = 25; Desc = 'Wait for data in Log Analytics (polling)' }
    5 = @{ Name = 'Workbook & Alerts';   MinMin = 1; MaxMin = 3;  Desc = 'Validate workbook KQL queries' }
    6 = @{ Name = 'Data Integrity';      MinMin = 2; MaxMin = 5;  Desc = 'Exporter vs workbook comparison (OS cert)' }
}

function Show-TimeEstimate {
    $totalMin = ($script:PhaseEstimates.Values | Measure-Object -Property MinMin -Sum).Sum
    $totalMax = ($script:PhaseEstimates.Values | Measure-Object -Property MaxMin -Sum).Sum
    
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │  ESTIMATED TIME: $totalMin - $totalMax minutes total (depends on LA data ingestion)      │" -ForegroundColor DarkGray
    Write-Host "  ├─────┬──────────────────────┬───────────┬──────────────────────────────────┤" -ForegroundColor DarkGray
    Write-Host "  │  #  │ Phase                │ Est. Time │ What It Does                     │" -ForegroundColor DarkGray
    Write-Host "  ├─────┼──────────────────────┼───────────┼──────────────────────────────────┤" -ForegroundColor DarkGray
    foreach ($num in 1..6) {
        $est = $script:PhaseEstimates[$num]
        $numStr = "  $num".PadLeft(3)
        $nameStr = $est.Name.PadRight(20)
        $timeStr = "$($est.MinMin)-$($est.MaxMin) min".PadRight(9)
        $descStr = $est.Desc.PadRight(32)
        Write-Host "  │ $numStr │ $nameStr │ $timeStr │ $descStr │" -ForegroundColor DarkGray
    }
    Write-Host "  └─────┴──────────────────────┴───────────┴──────────────────────────────────┘" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-PhaseProgress {
    param([int]$CurrentPhase, [datetime]$StartTime)
    
    $elapsed = (Get-Date) - $StartTime
    $elapsedStr = "{0:mm\:ss}" -f $elapsed
    
    # Remaining estimate
    $remainingMin = 0
    foreach ($num in $CurrentPhase..6) {
        $remainingMin += $script:PhaseEstimates[$num].MaxMin
    }
    
    $progressBar = ""
    for ($i = 1; $i -le 6; $i++) {
        $result = (Get-PhaseResults) | Where-Object { $_.Phase -match "Phase$i" }
        if ($result -and $result.Status -eq 'Passed') { $progressBar += "█" }
        elseif ($i -eq $CurrentPhase) { $progressBar += "▓" }
        else { $progressBar += "░" }
    }
    
    Write-Host "  [$progressBar] Phase $CurrentPhase/6 | Elapsed: $elapsedStr | Remaining: ~${remainingMin}min max" -ForegroundColor Cyan
}

function Invoke-FullTestRun {
    param([hashtable]$Config)

    # --- Show Input Summary & Get Consent ---
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║              TEST CONFIGURATION SUMMARY                     ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  ┌─ Cluster Details ──────────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │  SAP SID:        $($Config['sap_sid'])" -ForegroundColor White
    Write-Host "  │  Cluster Name:   $($Config['cluster_name'])" -ForegroundColor White
    Write-Host "  │  OS:             $($Config['os_type']) $($Config['os_version'])" -ForegroundColor White
    Write-Host "  │  Nodes:          $(($Config['nodes'] | ForEach-Object { $_['hostname'] }) -join ', ')" -ForegroundColor White
    Write-Host "  │  VM Names:       $(($Config['nodes'] | ForEach-Object { $_['vm_name'] }) -join ', ')" -ForegroundColor White
    Write-Host "  └────────────────────────────────────────────────────────────┘" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  ┌─ Azure Resources ──────────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │  Subscription:   $($Config['subscription_id'])" -ForegroundColor White
    Write-Host "  │  Resource Group:  $($Config['resource_group'])" -ForegroundColor White
    Write-Host "  │  Location:       $($Config['location'])" -ForegroundColor White
    Write-Host "  │  AMS Monitor:    $($Config['ams_monitor_name'])" -ForegroundColor White
    Write-Host "  │  LA Workspace:   $($Config['log_analytics_workspace_name'])" -ForegroundColor White
    Write-Host "  │  Exec Method:    $($Config['execution_method'])" -ForegroundColor White
    Write-Host "  └────────────────────────────────────────────────────────────┘" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  ┌─ Network ──────────────────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │  VNet:           $($Config['vnet']['name']) (RG: $($Config['vnet']['resource_group']))" -ForegroundColor White
    Write-Host "  │  Subnet:         $($Config['subnet']['name']) ($($Config['subnet']['cidr']))" -ForegroundColor White
    Write-Host "  └────────────────────────────────────────────────────────────┘" -ForegroundColor DarkGray

    Show-TimeEstimate

    Write-Host "  This will:" -ForegroundColor Yellow
    Write-Host "    • Install exporter on cluster nodes (Phase 1)" -ForegroundColor Yellow
    Write-Host "    • Create AMS monitor, subnet, providers (Phase 2-3)" -ForegroundColor Yellow
    Write-Host "    • Wait for data ingestion into Log Analytics (Phase 4)" -ForegroundColor Yellow
    Write-Host "    • Validate workbook & alert queries (Phase 5)" -ForegroundColor Yellow
    Write-Host "    • Run OS certification comparison (Phase 6)" -ForegroundColor Yellow
    Write-Host ""
    $consent = Read-Host "  Proceed with test? [y/N]"
    if ($consent -ne 'y' -and $consent -ne 'Y') {
        Write-Host "  Test cancelled." -ForegroundColor DarkGray
        return
    }

    $startTime = Get-Date
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "  ║          STARTING FULL TEST RUN (Phase 1 → 6)              ║" -ForegroundColor Green
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green

    $allPassed = $true
    foreach ($num in 1..6) {
        Show-PhaseProgress -CurrentPhase $num -StartTime $startTime
        
        $phaseStart = Get-Date
        Invoke-PhaseByNumber -PhaseNum $num -Config $Config
        $phaseDuration = ((Get-Date) - $phaseStart).TotalSeconds
        
        $lastResult = (Get-PhaseResults) | Where-Object { $_.Phase -match "Phase$num" }
        if ($lastResult.Status -eq 'Failed') {
            Write-Host ""
            Write-Host "  ✗ Phase $num FAILED after $([int]$phaseDuration)s" -ForegroundColor Red
            Write-Host "    $($lastResult.Message)" -ForegroundColor Red
            $allPassed = $false
            break
        } else {
            Write-Host "  ✓ Phase $num completed in $([int]$phaseDuration)s" -ForegroundColor Green
        }
    }

    $totalDuration = ((Get-Date) - $startTime).TotalSeconds
    Write-Host ""
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    if ($allPassed) {
        Write-Host "  ALL 6 PHASES PASSED in $([int]$totalDuration)s" -ForegroundColor Green
    } else {
        Write-Host "  TEST RUN STOPPED (failure detected) after $([int]$totalDuration)s" -ForegroundColor Red
    }
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    # Auto-generate report
    Write-Host ""
    Write-Host "  Generating HTML report..." -ForegroundColor DarkGray
    $reportDir = Join-Path $PSScriptRoot 'reports'
    $reportFile = New-TestReport -PhaseResults (Get-PhaseResults) -LogEntries (Get-LogEntries) `
        -Config $Config -OutputPath $reportDir `
        -Phase6ComparisonData $script:Phase6ComparisonData `
        -Phase6Summary $script:Phase6Summary
    Write-Host "  Report: $reportFile" -ForegroundColor Green

    # Upload to persistent storage
    try {
        $storageInfo = Initialize-ReportStorage -Config $Config
        $blobUrl = Upload-TestReport -StorageInfo $storageInfo -ReportFilePath $reportFile
        $phaseResults = Get-PhaseResults
        Save-TestRunMetadata -StorageInfo $storageInfo -RunData @{
            RunId         = (Get-Date -Format 'yyyyMMdd_HHmmss')
            Timestamp     = (Get-Date -Format 'o')
            SID           = $Config['sap_sid']
            ClusterName   = $Config['cluster_name']
            OS            = "$($Config['os_type']) $($Config['os_version'])"
            OverallStatus = if ($allPassed) { 'PASSED' } else { 'FAILED' }
            PhasesRun     = $phaseResults.Count
            PassCount     = ($phaseResults | Where-Object { $_.Status -eq 'Passed' }).Count
            FailCount     = ($phaseResults | Where-Object { $_.Status -eq 'Failed' }).Count
            ReportBlobUrl = $blobUrl
            DurationSec   = [int]$totalDuration
        }
        Write-Host "  Persisted to Azure: $blobUrl" -ForegroundColor Cyan
    } catch {
        Write-Host "  Storage upload skipped (report saved locally): $_" -ForegroundColor Yellow
    }

    # Open report in browser
    Start-Process $reportFile

    # Prompt for Phase 7 cleanup
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
    Write-Host "  │  Would you like to run Phase 7 (Cleanup AMS resources)?      │" -ForegroundColor Yellow
    Write-Host "  │  This will DELETE the AMS monitor, providers, subnet, etc.   │" -ForegroundColor Yellow
    Write-Host "  │  Reports are already persisted and will NOT be affected.     │" -ForegroundColor Yellow
    Write-Host "  └──────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
    $cleanup = Read-Host "  Run cleanup? [y/N]"
    if ($cleanup -eq 'y' -or $cleanup -eq 'Y') {
        Invoke-PhaseByNumber -PhaseNum 7 -Config $Config
    } else {
        Write-Host "  Skipped cleanup. Run Phase 7 later from the menu or: .\Run-HAClusterTest.ps1 -Phase 7" -ForegroundColor DarkGray
    }
}

# --- Main ---
function Main {
    Show-Banner

    # Load config
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "  ERROR: Config file not found: $ConfigPath" -ForegroundColor Red
        Write-Host "  Copy config.template.yaml to config.yaml and fill in your values." -ForegroundColor Yellow
        return
    }

    $config = Read-TestConfig -ConfigPath $ConfigPath
    Write-PhaseLog -Phase 'Setup' -Level 'INFO' -Message "Config loaded from $ConfigPath"

    # Ensure Azure context
    Confirm-AzureContext -SubscriptionId $config['subscription_id']

    # Non-interactive mode: run specific phase or all
    if ($Phase) {
        if ($Phase -eq 'all') {
            Invoke-FullTestRun -Config $config
        } else {
            Invoke-PhaseByNumber -PhaseNum ([int]$Phase) -Config $config
            # Generate report for single phase run too
            $reportDir = Join-Path $PSScriptRoot 'reports'
            $reportFile = New-TestReport -PhaseResults (Get-PhaseResults) -LogEntries (Get-LogEntries) `
                -Config $config -OutputPath $reportDir `
                -Phase6ComparisonData $script:Phase6ComparisonData `
                -Phase6Summary $script:Phase6Summary
            Write-Host "`n  Report: $reportFile" -ForegroundColor Green
        }
        return
    }

    # Interactive mode
    while ($true) {
        Show-Banner
        Show-PhaseStatus
        Show-Menu -Config $config

        $choice = Read-Host "  Enter command"

        switch ($choice.ToUpper()) {
            'T' {
                Invoke-FullTestRun -Config $config
                Write-Host "`n  Press Enter to continue..." -ForegroundColor DarkGray
                Read-Host | Out-Null
            }
            { $_ -in '1','2','3','4','5','6' } {
                Invoke-PhaseByNumber -PhaseNum ([int]$choice) -Config $config
                Write-Host "`n  Press Enter to continue..." -ForegroundColor DarkGray
                Read-Host | Out-Null
            }
            '7' {
                Write-Host ""
                Write-Host "  ⚠ Phase 7 will DELETE AMS resources (monitor, providers, subnet)." -ForegroundColor Yellow
                Write-Host "  Reports are persisted separately and will NOT be affected." -ForegroundColor DarkGray
                $confirm = Read-Host "  Proceed with cleanup? [y/N]"
                if ($confirm -eq 'y' -or $confirm -eq 'Y') {
                    Invoke-PhaseByNumber -PhaseNum 7 -Config $config
                } else {
                    Write-Host "  Cleanup skipped." -ForegroundColor DarkGray
                }
                Write-Host "`n  Press Enter to continue..." -ForegroundColor DarkGray
                Read-Host | Out-Null
            }
            'S' {
                # Status is shown in the loop
            }
            'R' {
                $reportDir = Join-Path $PSScriptRoot 'reports'
                $reportFile = New-TestReport -PhaseResults (Get-PhaseResults) -LogEntries (Get-LogEntries) `
                    -Config $config -OutputPath $reportDir `
                    -Phase6ComparisonData $script:Phase6ComparisonData `
                    -Phase6Summary $script:Phase6Summary
                Write-Host "  Report generated: $reportFile" -ForegroundColor Green
                Start-Process $reportFile  # Open in default browser

                # Upload to Azure Storage
                try {
                    $storageInfo = Initialize-ReportStorage -Config $config
                    $blobUrl = Upload-TestReport -StorageInfo $storageInfo -ReportFilePath $reportFile
                    Save-TestRunMetadata -StorageInfo $storageInfo -RunData @{
                        RunId = (Get-Date -Format 'yyyyMMdd_HHmmss')
                        Timestamp = (Get-Date -Format 'o')
                        SID = $config['sap_sid']
                        ClusterName = $config['cluster_name']
                        OS = "$($config['os_type']) $($config['os_version'])"
                        OverallStatus = 'MANUAL_RUN'
                        PhasesRun = (Get-PhaseResults).Count
                        PassCount = ((Get-PhaseResults) | Where-Object { $_.Status -eq 'Passed' }).Count
                        FailCount = ((Get-PhaseResults) | Where-Object { $_.Status -eq 'Failed' }).Count
                        ReportBlobUrl = $blobUrl
                        DurationSec = 0
                    }
                    Write-Host "  Uploaded to Azure: $blobUrl" -ForegroundColor Cyan
                } catch {
                    Write-Host "  Upload failed (local report still available): $_" -ForegroundColor Yellow
                }

                Write-Host "`n  Press Enter to continue..." -ForegroundColor DarkGray
                Read-Host | Out-Null
            }
            'L' {
                Write-Host ""
                $logs = Get-LogEntries
                $recent = $logs | Select-Object -Last 20
                foreach ($le in $recent) {
                    $color = switch ($le.Level) {
                        'INFO'    { 'Cyan' }
                        'WARN'    { 'Yellow' }
                        'ERROR'   { 'Red' }
                        'SUCCESS' { 'Green' }
                    }
                    Write-Host "  [$($le.Timestamp)] [$($le.Phase)] " -NoNewline -ForegroundColor DarkGray
                    Write-Host "$($le.Level): $($le.Message)" -ForegroundColor $color
                }
                Write-Host "`n  Press Enter to continue..." -ForegroundColor DarkGray
                Read-Host | Out-Null
            }
            'Q' {
                Write-Host "  Exiting." -ForegroundColor Gray
                return
            }
            default {
                Write-Host "  Invalid choice. Use 1-6, A, S, R, L, or Q." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

Main

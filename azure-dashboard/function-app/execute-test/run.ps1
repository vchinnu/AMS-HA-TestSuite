param($QueueItem, $TriggerMetadata)

# ============================================================================
# execute-test - Queue-triggered function that runs phases 1-6 asynchronously
# ============================================================================
# Triggered by start-test via the 'ha-test-execute' queue.
# Input: JSON message with { runId, sid, config }
# ============================================================================

$ErrorActionPreference = 'Continue'

$runId = $QueueItem.runId
$sid   = $QueueItem.sid
$body  = $QueueItem.config

Write-Information "execute-test: Starting run $runId for SID $sid"

# ---------------------------------------------------------------------------
# 1. CONNECT TO STORAGE
# ---------------------------------------------------------------------------
$storageCtx = New-AzStorageContext -ConnectionString $env:REPORT_STORAGE_CONNSTR
$table = (Get-AzStorageTable -Name 'HaClusterTestRuns' -Context $storageCtx).CloudTable

# ---------------------------------------------------------------------------
# 2. AUTHENTICATE & SET SUBSCRIPTION
# ---------------------------------------------------------------------------
$subscriptionId = "$($body.subscription_id)".Trim()

try {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -Subscription $subscriptionId -ErrorAction Stop | Out-Null
    Write-Information "Successfully connected to subscription $subscriptionId"
} catch {
    $authError = "Failed to authenticate to subscription '$subscriptionId': $($_.Exception.Message)"
    Write-Warning $authError
    try {
        $entity = Get-AzTableRow -Table $table -PartitionKey $sid -RowKey $runId
        $entity.Status = 'Failed'
        $entity.OverallStatus = 'Failed'
        $entity.ErrorMessage = $authError
        $entity | Update-AzTableRow -Table $table | Out-Null
    } catch { }
    return
}

# ---------------------------------------------------------------------------
# 3. BUILD CONFIG HASHTABLE
# ---------------------------------------------------------------------------
$config = @{
    subscription_id              = $subscriptionId
    resource_group               = $body.resource_group
    location                     = $body.location
    os_type                      = $body.os_type ?? 'SUSE'
    os_version                   = $body.os_version ?? ''
    sap_sid                      = $body.sap_sid
    cluster_name                 = $body.cluster_name
    nodes                        = $body.nodes
    vnet                         = $body.vnet ?? @{ name = ''; resource_group = '' }
    vnet_resource_id             = $body.vnet_resource_id ?? ''
    subnet                       = @{
        name = if ($body.subnet.name) { $body.subnet.name } else { 'ams-ha-test-subnet' }
        cidr = if ($body.subnet.cidr) { $body.subnet.cidr } else { '/28' }
    }
    cluster_vnet                 = $body.cluster_vnet ?? @{ name = ''; resource_group = '' }
    ams_monitor_name             = if ($body.ams_monitor_name) { $body.ams_monitor_name } else { "AMS-HA-Test-$($body.sap_sid)_1" }
    managed_resource_group       = $body.managed_resource_group ?? ''
    log_analytics_workspace_id   = $body.log_analytics_workspace_id ?? ''
    log_analytics_workspace_name = $body.log_analytics_workspace_name ?? ''
    execution_method             = $body.execution_method ?? 'vm_run_command'
    bastion                      = $body.bastion ?? @{}
    poll_interval_seconds        = $body.poll_interval_seconds ?? 120
    poll_max_wait_minutes        = $body.poll_max_wait_minutes ?? 20
}

# ---------------------------------------------------------------------------
# 4. EXECUTE PHASES 1-6
# ---------------------------------------------------------------------------
$phaseResults = @()
$script:dashboardLogs = [System.Collections.ArrayList]::new()
$allPassed = $true
$finalStatus = 'Failed'
$totalDuration = 0
$reportUrl = ''
$blobName = ''
$startTime = Get-Date

# Helper to sanitize entity - replace nulls with empty strings for AzTable compatibility
function Sanitize-Entity {
    param($Entity)
    $props = $Entity | Get-Member -MemberType Properties | Where-Object { $_.Name -notin @('PartitionKey','RowKey','TableTimestamp','Etag') }
    foreach ($p in $props) {
        if ($null -eq $Entity.($p.Name)) {
            $Entity.($p.Name) = ''
        }
    }
    return $Entity
}

function Update-RunStatus {
    param([int]$Phase, [string]$Status, [string]$Message)
    $updateProps = @{
        CurrentPhase = $Phase
        Status       = $Status
        PhaseResults = ($phaseResults | ConvertTo-Json -Depth 3 -Compress)
        LogEntries   = ($script:dashboardLogs | ConvertTo-Json -Depth 3 -Compress)
    }
    if ($Message) { $updateProps['ErrorMessage'] = $Message }
    try {
        $entity = Get-AzTableRow -Table $table -PartitionKey $sid -RowKey $runId
        foreach ($key in $updateProps.Keys) { $entity.$key = $updateProps[$key] }
        $entity = Sanitize-Entity -Entity $entity
        $entity | Update-AzTableRow -Table $table | Out-Null
    } catch {
        Write-Warning "Update-RunStatus failed: $_"
    }
}

function Write-DashboardLog {
    param([string]$Message, [int]$Phase = 0)
    [void]$script:dashboardLogs.Add(@{
        time    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        phase   = $Phase
        message = $Message
    })
    Flush-LogsToTable
}

function Flush-LogsToTable {
    try {
        $entity = Get-AzTableRow -Table $table -PartitionKey $sid -RowKey $runId
        $entity.LogEntries = ($script:dashboardLogs | ConvertTo-Json -Depth 3 -Compress)
        $entity = Sanitize-Entity -Entity $entity
        $entity | Update-AzTableRow -Table $table | Out-Null
    } catch { }
}

function Sync-PhaseLogs-ToDashboard {
    $phaseLogs = Get-LogEntries
    if (-not $phaseLogs -or $phaseLogs.Count -eq 0) { return }
    $lastSyncCount = if ($script:lastPhaseLogCount) { $script:lastPhaseLogCount } else { 0 }
    if ($phaseLogs.Count -le $lastSyncCount) { return }
    $newLogs = @($phaseLogs | Select-Object -Skip $lastSyncCount)
    foreach ($pl in $newLogs) {
        [void]$script:dashboardLogs.Add(@{
            time    = if ($pl.Timestamp) { $pl.Timestamp } else { (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
            phase   = $script:currentPhaseNum
            message = "[$($pl.Level)] $($pl.Message)"
        })
    }
    $script:lastPhaseLogCount = $phaseLogs.Count
    Flush-LogsToTable
}

# Load helpers
$phasesDir = Join-Path $PSScriptRoot '..\phases'
$helpersDir = Join-Path $PSScriptRoot '..\helpers'

. (Join-Path $helpersDir 'Common.ps1')
. (Join-Path $helpersDir 'KqlRunner.ps1')
. (Join-Path $helpersDir 'PrometheusParser.ps1')

$global:DashboardFlushEnabled = $true
$script:currentPhaseNum = 0

$phaseScripts = @{
    1 = 'Phase1-InstallExporter.ps1'
    2 = 'Phase2-SetupAMS.ps1'
    3 = 'Phase3-CreateProviders.ps1'
    4 = 'Phase4-ValidateData.ps1'
    5 = 'Phase5-ValidateWorkbookAlerts.ps1'
    6 = 'Phase6-DataIntegrityValidation.ps1'
    7 = 'Phase7-Cleanup.ps1'
}

try {

# Phase 7 (Cleanup) runs only on manual trigger from the dashboard
foreach ($num in 1..6) {
    $script:currentPhaseNum = $num
    Write-DashboardLog -Message "Starting Phase $num ($($phaseScripts[$num]))" -Phase $num
    Update-RunStatus -Phase $num -Status 'Running' -Message "Running Phase $num..."

    $phaseStart = Get-Date
    try {
        $scriptPath = Join-Path $phasesDir $phaseScripts[$num]
        . $scriptPath
        $functionName = "Invoke-Phase$num"
        & $functionName -Config $config

        Sync-PhaseLogs-ToDashboard

        $result = Get-PhaseResults | Where-Object { $_.Phase -match "Phase$num" } | Select-Object -Last 1
        $phaseDuration = [int]((Get-Date) - $phaseStart).TotalSeconds

        $phaseResults += @{
            Phase           = "Phase$num"
            Status          = $result.Status ?? 'Passed'
            Message         = $result.Message ?? "Completed"
            DurationSeconds = $phaseDuration
            Timestamp       = (Get-Date -Format 'HH:mm:ss')
        }

        Write-DashboardLog -Message "Phase $num completed: $($result.Status ?? 'Passed') ($($phaseDuration)s)" -Phase $num

        if ($result.Status -eq 'Failed') {
            $allPassed = $false
            Write-DashboardLog -Message "Phase $num FAILED: $($result.Message)" -Phase $num
            Update-RunStatus -Phase $num -Status 'Failed' -Message $result.Message
            break
        }
    }
    catch {
        Sync-PhaseLogs-ToDashboard
        $phaseDuration = [int]((Get-Date) - $phaseStart).TotalSeconds
        $phaseResults += @{
            Phase           = "Phase$num"
            Status          = 'Failed'
            Message         = $_.Exception.Message
            DurationSeconds = $phaseDuration
            Timestamp       = (Get-Date -Format 'HH:mm:ss')
        }
        $allPassed = $false
        Write-DashboardLog -Message "Phase $num EXCEPTION: $($_.Exception.Message)" -Phase $num
        Update-RunStatus -Phase $num -Status 'Failed' -Message $_.Exception.Message
        break
    }
}

# Collect all accumulated phase logs for the HTML report
$logEntries = Get-LogEntries

$totalDuration = [int]((Get-Date) - $startTime).TotalSeconds
$finalStatus = if ($allPassed) { 'Passed' } else { 'Failed' }

# Generate HTML report
. (Join-Path $helpersDir 'HtmlReportGenerator.ps1')
$reportDir = $env:TEMP
$reportFile = New-TestReport -PhaseResults $phaseResults -LogEntries $logEntries `
    -Config $config -OutputPath $reportDir `
    -Phase6ComparisonData $script:Phase6ComparisonData `
    -Phase6Summary $script:Phase6Summary

# Upload report to Blob Storage
$container = Get-AzStorageContainer -Name 'ha-test-reports' -Context $storageCtx -ErrorAction SilentlyContinue
if (-not $container) { New-AzStorageContainer -Name 'ha-test-reports' -Context $storageCtx -Permission Off | Out-Null }

$blobName = Split-Path $reportFile -Leaf
Set-AzStorageBlobContent -File $reportFile -Container 'ha-test-reports' -Blob $blobName -Context $storageCtx -Force | Out-Null
$reportUrl = "proxy:$blobName"

} catch {
    $finalStatus = 'Failed'
    $totalDuration = [int]((Get-Date) - $startTime).TotalSeconds
    Write-Warning "execute-test top-level error: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 5. UPDATE FINAL ENTITY
# ---------------------------------------------------------------------------
try {
    # Trim dashboard logs to last 150 entries to stay within Azure Table Storage entity size limits (~32KB)
    if ($script:dashboardLogs.Count -gt 150) {
        $trimmed = [System.Collections.ArrayList]::new()
        # Keep first 10 (start context) + last 140 (most recent)
        $first10 = @($script:dashboardLogs | Select-Object -First 10)
        $last140 = @($script:dashboardLogs | Select-Object -Last 140)
        foreach ($e in $first10) { [void]$trimmed.Add($e) }
        [void]$trimmed.Add(@{ time = '---'; phase = 0; message = "... trimmed $($script:dashboardLogs.Count - 150) older entries ..." })
        foreach ($e in $last140) { [void]$trimmed.Add($e) }
        $script:dashboardLogs = $trimmed
    }

    $entity = Get-AzTableRow -Table $table -PartitionKey $sid -RowKey $runId
    $entity.Status = $finalStatus
    $entity.OverallStatus = $finalStatus
    $entity.PhaseResults = ($phaseResults | ConvertTo-Json -Depth 3 -Compress)
    $entity.LogEntries = ($script:dashboardLogs | ConvertTo-Json -Depth 3 -Compress)
    $entity.ReportUrl = $reportUrl ?? ''
    $entity.ReportBlobName = $blobName ?? ''
    $entity.DurationSec = $totalDuration
    $entity.ErrorMessage = if ($finalStatus -eq 'Failed') { ($phaseResults | Where-Object { $_.Status -eq 'Failed' } | Select-Object -First 1).Message ?? 'Unknown error' } else { '' }
    $entity = Sanitize-Entity -Entity $entity
    $entity | Update-AzTableRow -Table $table | Out-Null
} catch {
    Write-Warning "Final entity update failed: $_"
}

Write-Information "execute-test: Run $runId completed with status: $finalStatus ($($totalDuration)s)"

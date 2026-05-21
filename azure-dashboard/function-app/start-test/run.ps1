using namespace System.Net

param($Request, $TriggerMetadata)

# ============================================================================
# start-test - Accepts test config, validates inputs, kicks off Phase 1-6
# ============================================================================
# Input: POST body with test configuration (same fields as config.yaml)
# Output: RunId for tracking progress
# ============================================================================

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# 1. PARSE & VALIDATE REQUEST
# ---------------------------------------------------------------------------
$body = $Request.Body
if (-not $body) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = (@{ error = "Request body is required with test configuration" } | ConvertTo-Json)
        ContentType = "application/json"
    })
    return
}

# Validate required fields
$requiredFields = @('subscription_id', 'resource_group', 'location', 'sap_sid', 'cluster_name', 'nodes')
$missing = $requiredFields | Where-Object { -not $body.$_ }
if ($missing) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = (@{ error = "Missing required fields: $($missing -join ', ')" } | ConvertTo-Json)
        ContentType = "application/json"
    })
    return
}

# Validate nodes array
if ($body.nodes.Count -lt 2) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = (@{ error = "At least 2 cluster nodes are required" } | ConvertTo-Json)
        ContentType = "application/json"
    })
    return
}

# Generate run ID
$runId = (Get-Date -Format 'yyyyMMdd_HHmmss') + "_" + [guid]::NewGuid().ToString().Substring(0,8)

# ---------------------------------------------------------------------------
# 2. CONNECT TO HOME SUBSCRIPTION (for internal storage) THEN GET STORAGE
# ---------------------------------------------------------------------------
# Use connection string for internal storage — independent of Az subscription context
$storageCtx = New-AzStorageContext -ConnectionString $env:REPORT_STORAGE_CONNSTR
$table = (Get-AzStorageTable -Name 'HaClusterTestRuns' -Context $storageCtx).CloudTable

# Save initial status
$runEntry = @{
    RunId         = $runId
    Status        = 'Running'
    CurrentPhase  = 1
    TotalPhases   = 6
    StartTime     = (Get-Date -Format 'o')
    SID           = $body.sap_sid
    ClusterName   = $body.cluster_name
    OS            = "$($body.os_type ?? 'SUSE') $($body.os_version ?? '')"
    Config        = ($body | ConvertTo-Json -Depth 5 -Compress)
    PhaseResults  = '[]'
    LogEntries    = '[]'
    OverallStatus = 'Running'
    ErrorMessage  = ''
    ReportUrl     = ''
    ReportBlobName = ''
    DurationSec   = 0
}

Add-AzTableRow -Table $table -PartitionKey $body.sap_sid -RowKey $runId -property $runEntry | Out-Null

# ---------------------------------------------------------------------------
# 3. AUTHENTICATE & SET SUBSCRIPTION (with diagnostics)
# ---------------------------------------------------------------------------
$subscriptionId = "$($body.subscription_id)".Trim()
Write-Information "Target subscription: $subscriptionId"

try {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -Subscription $subscriptionId -ErrorAction Stop | Out-Null
    Write-Information "Successfully connected to subscription $subscriptionId"
} catch {
    $authError = "Failed to authenticate to subscription '$subscriptionId': $($_.Exception.Message)"
    Write-Warning $authError
    # Mark the run as Failed so it doesn't stay stuck as Running
    try {
        $entity = Get-AzTableRow -Table $table -PartitionKey $body.sap_sid -RowKey $runId
        $entity.Status = 'Failed'
        $entity.OverallStatus = 'Failed'
        $entity.ErrorMessage = $authError
        $entity | Update-AzTableRow -Table $table | Out-Null
    } catch { }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = (@{ error = $authError; runId = $runId } | ConvertTo-Json)
        ContentType = "application/json"
    })
    return
}

# ---------------------------------------------------------------------------
# 4. BUILD CONFIG HASHTABLE
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
    subnet                       = $body.subnet ?? @{ name = ''; cidr = '' }
    cluster_vnet                 = $body.cluster_vnet ?? @{ name = ''; resource_group = '' }
    ams_monitor_name             = $body.ams_monitor_name ?? "AMS-HA-Test-$($body.sap_sid)"
    managed_resource_group       = $body.managed_resource_group ?? ''
    log_analytics_workspace_id   = $body.log_analytics_workspace_id ?? ''
    log_analytics_workspace_name = $body.log_analytics_workspace_name ?? ''
    execution_method             = $body.execution_method ?? 'vm_run_command'
    bastion                      = $body.bastion ?? @{}
    poll_interval_seconds        = $body.poll_interval_seconds ?? 120
    poll_max_wait_minutes        = $body.poll_max_wait_minutes ?? 20
}

# ---------------------------------------------------------------------------
# 5. EXECUTE PHASES 1-6
# ---------------------------------------------------------------------------
$phaseResults = @()
# Use a distinct name to avoid collision with Common.ps1's $script:LogEntries (case-insensitive!)
$script:dashboardLogs = [System.Collections.ArrayList]::new()
$allPassed = $true
$finalStatus = 'Failed'
$totalDuration = 0
$reportUrl = ''
$blobName = ''

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

# Helper to log and update status
function Update-RunStatus {
    param([int]$Phase, [string]$Status, [string]$Message)
    
    $updateProps = @{
        CurrentPhase = $Phase
        Status       = $Status
        PhaseResults = ($phaseResults | ConvertTo-Json -Depth 3 -Compress)
        LogEntries   = ($script:dashboardLogs | ConvertTo-Json -Depth 3 -Compress)
    }
    if ($Message) { $updateProps['ErrorMessage'] = $Message }
    
    # Update table row
    try {
        $entity = Get-AzTableRow -Table $table -PartitionKey $body.sap_sid -RowKey $runId
        foreach ($key in $updateProps.Keys) {
            $entity.$key = $updateProps[$key]
        }
        $entity = Sanitize-Entity -Entity $entity
        $entity | Update-AzTableRow -Table $table | Out-Null
    } catch {
        Write-Warning "Update-RunStatus failed: $_"
    }
}

# Helper to append a timestamped log line and persist it
function Write-DashboardLog {
    param([string]$Message, [int]$Phase = 0)
    $entry = @{
        time    = (Get-Date -Format 'HH:mm:ss')
        phase   = $Phase
        message = $Message
    }
    [void]$script:dashboardLogs.Add($entry)
    Flush-LogsToTable
}

# Flush current log entries to table so polling picks them up live
function Flush-LogsToTable {
    try {
        $entity = Get-AzTableRow -Table $table -PartitionKey $body.sap_sid -RowKey $runId
        $entity.LogEntries = ($script:dashboardLogs | ConvertTo-Json -Depth 3 -Compress)
        $entity = Sanitize-Entity -Entity $entity
        $entity | Update-AzTableRow -Table $table | Out-Null
    } catch { }
}

# Merge phase-script logs (from Common.ps1) into dashboard log entries and flush to table
function Sync-PhaseLogs-ToDashboard {
    $phaseLogs = Get-LogEntries
    if (-not $phaseLogs -or $phaseLogs.Count -eq 0) { return }
    $lastSyncCount = if ($script:lastPhaseLogCount) { $script:lastPhaseLogCount } else { 0 }
    if ($phaseLogs.Count -le $lastSyncCount) { return }
    $newLogs = @($phaseLogs | Select-Object -Skip $lastSyncCount)
    foreach ($pl in $newLogs) {
        [void]$script:dashboardLogs.Add(@{
            time    = if ($pl.Timestamp) { ($pl.Timestamp -split ' ')[-1] } else { (Get-Date -Format 'HH:mm:ss') }
            phase   = $script:currentPhaseNum
            message = "[$($pl.Level)] $($pl.Message)"
        })
    }
    $script:lastPhaseLogCount = $phaseLogs.Count
    Flush-LogsToTable
}

# Phase scripts are bundled with the Function App
$phasesDir = Join-Path $PSScriptRoot '..\phases'
$helpersDir = Join-Path $PSScriptRoot '..\helpers'

# Load helpers
. (Join-Path $helpersDir 'Common.ps1')
. (Join-Path $helpersDir 'KqlRunner.ps1')
. (Join-Path $helpersDir 'PrometheusParser.ps1')

# Enable live log flushing from phase scripts (Common.ps1 checks this flag)
$global:DashboardFlushEnabled = $true
$script:currentPhaseNum = 0

$phaseScripts = @{
    1 = 'Phase1-InstallExporter.ps1'
    2 = 'Phase2-SetupAMS.ps1'
    3 = 'Phase3-CreateProviders.ps1'
    4 = 'Phase4-ValidateData.ps1'
    5 = 'Phase5-ValidateWorkbookAlerts.ps1'
    6 = 'Phase6-DataIntegrityValidation.ps1'
}

try {

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
        
        # Sync phase-script logs to dashboard before processing result
        Sync-PhaseLogs-ToDashboard
        
        $result = Get-PhaseResults | Where-Object { $_.Phase -match "Phase$num" } | Select-Object -Last 1
        $phaseDuration = [int]((Get-Date) - $phaseStart).TotalSeconds
        
        $phaseResults += @{
            Phase          = "Phase$num"
            Status         = $result.Status ?? 'Passed'
            Message        = $result.Message ?? "Completed"
            DurationSeconds = $phaseDuration
            Timestamp      = (Get-Date -Format 'HH:mm:ss')
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
        # Sync any partial logs from the phase before recording failure
        Sync-PhaseLogs-ToDashboard
        
        $phaseDuration = [int]((Get-Date) - $phaseStart).TotalSeconds
        $phaseResults += @{
            Phase          = "Phase$num"
            Status         = 'Failed'
            Message        = $_.Exception.Message
            DurationSeconds = $phaseDuration
            Timestamp      = (Get-Date -Format 'HH:mm:ss')
        }
        $allPassed = $false
        Write-DashboardLog -Message "Phase $num EXCEPTION: $($_.Exception.Message)" -Phase $num
        Update-RunStatus -Phase $num -Status 'Failed' -Message $_.Exception.Message
        break
    }
    
    # Capture log entries from the phase
    $logEntries = Get-LogEntries
}

# Final status update
$totalDuration = [int]((Get-Date) - [datetime]$runEntry['StartTime']).TotalSeconds
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

# Store blob name for proxy-based retrieval (no SAS tokens needed)
$reportUrl = "proxy:$blobName"

} catch {
    # Top-level crash safety — mark run as Failed so it doesn't stay stuck as Running
    $finalStatus = 'Failed'
    $totalDuration = [int]((Get-Date) - [datetime]$runEntry['StartTime']).TotalSeconds
    Write-Warning "start-test top-level error: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 6. UPDATE FINAL ENTITY & RETURN RESPONSE (always runs)
# ---------------------------------------------------------------------------
try {
    $entity = Get-AzTableRow -Table $table -PartitionKey $body.sap_sid -RowKey $runId
    $entity.Status = $finalStatus
    $entity.OverallStatus = $finalStatus
    $entity.PhaseResults = ($phaseResults | ConvertTo-Json -Depth 3 -Compress)
    $entity.LogEntries = ($script:logEntries | ConvertTo-Json -Depth 3 -Compress)
    $entity.ReportUrl = $reportUrl ?? ''
    $entity.ReportBlobName = $blobName ?? ''
    $entity.DurationSec = $totalDuration
    $entity.ErrorMessage = if ($finalStatus -eq 'Failed') { ($phaseResults | Where-Object { $_.Status -eq 'Failed' } | Select-Object -First 1).Message ?? 'Unknown error' } else { '' }
    $entity = Sanitize-Entity -Entity $entity
    $entity | Update-AzTableRow -Table $table | Out-Null
} catch {
    Write-Warning "Final entity update failed: $_"
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = (@{
        runId      = $runId
        status     = $finalStatus
        duration   = $totalDuration
        reportUrl  = $reportUrl
        phases     = $phaseResults
    } | ConvertTo-Json -Depth 5)
    ContentType = "application/json"
})

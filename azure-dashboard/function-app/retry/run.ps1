using namespace System.Net

param($Request, $TriggerMetadata)

# ============================================================================
# retry - Retry a failed/abandoned phase or resume from a phase onwards
# ============================================================================
# Input: POST body with { runId, phase (int), resumeAll (bool) }
#   - resumeAll = false: retry only that single phase
#   - resumeAll = true: retry from that phase through Phase 6
# ============================================================================

$ErrorActionPreference = 'Continue'

$body = $Request.Body
if (-not $body -or -not $body.runId -or -not $body.phase) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = (@{ error = "Request body must include runId and phase" } | ConvertTo-Json)
        ContentType = "application/json"
    })
    return
}

$runId = $body.runId
$startPhase = [int]$body.phase
$resumeAll = [bool]$body.resumeAll

if ($startPhase -lt 1 -or $startPhase -gt 6) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = (@{ error = "Phase must be between 1 and 6" } | ConvertTo-Json)
        ContentType = "application/json"
    })
    return
}

# Load run from storage table
$storageCtx = New-AzStorageContext -ConnectionString $env:REPORT_STORAGE_CONNSTR
$table = (Get-AzStorageTable -Name 'HaClusterTestRuns' -Context $storageCtx).CloudTable

$allRows = Get-AzTableRow -Table $table
$run = $allRows | Where-Object { $_.RowKey -eq $runId } | Select-Object -First 1

if (-not $run) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::NotFound
        Body = (@{ error = "Run not found: $runId" } | ConvertTo-Json)
        ContentType = "application/json"
    })
    return
}

# Restore config and phase results
$config = $run.Config | ConvertFrom-Json -AsHashtable
$phaseResults = if ($run.PhaseResults) { @($run.PhaseResults | ConvertFrom-Json) } else { @() }
$partitionKey = $run.PartitionKey

# ---------------------------------------------------------------------------
# DASHBOARD LOGGING INFRASTRUCTURE (mirrors start-test)
# ---------------------------------------------------------------------------
$script:dashboardLogs = [System.Collections.ArrayList]::new()

# Restore existing log entries so we don't lose Phase 1 logs etc.
if ($run.LogEntries -and $run.LogEntries -ne '[]') {
    try {
        $existingLogs = $run.LogEntries | ConvertFrom-Json
        foreach ($el in $existingLogs) {
            [void]$script:dashboardLogs.Add(@{
                time    = $el.time
                phase   = $el.phase
                message = $el.message
            })
        }
    } catch { }
}

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

function Write-DashboardLog {
    param([string]$Message, [int]$Phase = 0)
    $entry = @{
        time    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        phase   = $Phase
        message = $Message
    }
    [void]$script:dashboardLogs.Add($entry)
    Flush-LogsToTable
}

function Flush-LogsToTable {
    try {
        $entity = Get-AzTableRow -Table $table -PartitionKey $partitionKey -RowKey $runId
        $entity.LogEntries = ($script:dashboardLogs | ConvertTo-Json -Depth 3 -Compress)
        $entity = Sanitize-Entity -Entity $entity
        $entity | Update-AzTableRow -Table $table | Out-Null
    } catch { }
}

function Update-RetryRunStatus {
    param([int]$Phase, [string]$Status, [string]$Message)
    try {
        $entity = Get-AzTableRow -Table $table -PartitionKey $partitionKey -RowKey $runId
        $entity.CurrentPhase = $Phase
        $entity.Status = $Status
        $entity.PhaseResults = ($phaseResults | ConvertTo-Json -Depth 3 -Compress)
        $entity.LogEntries = ($script:dashboardLogs | ConvertTo-Json -Depth 3 -Compress)
        if ($Message) { $entity.ErrorMessage = $Message }
        $entity = Sanitize-Entity -Entity $entity
        $entity | Update-AzTableRow -Table $table | Out-Null
    } catch {
        Write-Warning "Update-RetryRunStatus failed: $_"
    }
}

# Merge phase-script logs (from Common.ps1) into dashboard log entries
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

# ---------------------------------------------------------------------------
# AUTHENTICATE
# ---------------------------------------------------------------------------
try {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -Subscription $config['subscription_id'] -ErrorAction Stop | Out-Null
} catch {
    $authError = "Failed to authenticate: $($_.Exception.Message)"
    Write-DashboardLog -Message $authError -Phase $startPhase
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = (@{ error = $authError; runId = $runId } | ConvertTo-Json)
        ContentType = "application/json"
    })
    return
}

# Load helpers and phases
$helpersDir = Join-Path $PSScriptRoot '..\helpers'
$phasesDir = Join-Path $PSScriptRoot '..\phases'
. (Join-Path $helpersDir 'Common.ps1')

# Enable live log flushing from phase scripts (Common.ps1 checks this flag)
$global:DashboardFlushEnabled = $true
$script:currentPhaseNum = 0
$script:lastPhaseLogCount = 0

# Determine which phases to run
$endPhase = if ($resumeAll) { 6 } else { $startPhase }

# Update status to Running and reset StartTime so abandon detection doesn't kill us
Write-DashboardLog -Message "Retry: resuming from Phase $startPhase (through Phase $endPhase)" -Phase $startPhase
try {
    $entity = Get-AzTableRow -Table $table -PartitionKey $partitionKey -RowKey $runId
    $entity.Status = 'Running'
    $entity.CurrentPhase = $startPhase
    $entity.StartTime = (Get-Date -Format 'o')
    $entity.ErrorMessage = ''
    $entity.PhaseResults = ($phaseResults | ConvertTo-Json -Depth 3 -Compress)
    $entity.LogEntries = ($script:dashboardLogs | ConvertTo-Json -Depth 3 -Compress)
    $entity = Sanitize-Entity -Entity $entity
    $entity | Update-AzTableRow -Table $table | Out-Null
} catch {
    Write-Warning "Failed to update run status: $_"
}

# Return 202 Accepted immediately so the dashboard gets a response
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::Accepted
    Body = (@{
        runId = $runId
        status = 'Running'
        message = "Retry started from Phase $startPhase through Phase $endPhase"
    } | ConvertTo-Json)
    ContentType = "application/json"
})

# ---------------------------------------------------------------------------
# PHASE EXECUTION LOOP (mirrors start-test pattern)
# ---------------------------------------------------------------------------
$phaseScripts = @{
    1 = 'Phase1-InstallExporter.ps1'
    2 = 'Phase2-SetupAMS.ps1'
    3 = 'Phase3-CreateProviders.ps1'
    4 = 'Phase4-ValidateData.ps1'
    5 = 'Phase5-ValidateWorkbookAlerts.ps1'
    6 = 'Phase6-DataIntegrityValidation.ps1'
}

$allPassed = $true
$startTime = Get-Date

try {

for ($p = $startPhase; $p -le $endPhase; $p++) {
    $script:currentPhaseNum = $p
    $script:lastPhaseLogCount = 0
    # Reset Common.ps1 log entries for this phase
    $script:LogEntries = [System.Collections.ArrayList]::new()
    $script:PhaseResults = [System.Collections.ArrayList]::new()

    Write-DashboardLog -Message "Starting Phase $p ($($phaseScripts[$p]))" -Phase $p
    Update-RetryRunStatus -Phase $p -Status 'Running' -Message "Running Phase $p..."

    $phaseStart = Get-Date
    $scriptPath = Join-Path $phasesDir $phaseScripts[$p]

    if (-not (Test-Path $scriptPath)) {
        $phaseResults = @($phaseResults | Where-Object { $_.Phase -ne "Phase$p" })
        $phaseResults += @{ Phase = "Phase$p"; Status = "Failed"; Message = "Phase script not found"; DurationSeconds = 0 }
        Write-DashboardLog -Message "Phase $p FAILED: script not found" -Phase $p
        Update-RetryRunStatus -Phase $p -Status 'Failed' -Message "Phase script not found"
        $allPassed = $false
        break
    }

    try {
        . $scriptPath
        & "Invoke-Phase$p" -Config $config

        # Sync phase-script logs to dashboard
        Sync-PhaseLogs-ToDashboard

        # Check actual phase result (phases use Set-PhaseResult, not exceptions)
        $result = Get-PhaseResults | Where-Object { $_.Phase -match "Phase$p" } | Select-Object -Last 1
        $phaseDuration = [int]((Get-Date) - $phaseStart).TotalSeconds

        # Remove old result for this phase and add new one
        $phaseResults = @($phaseResults | Where-Object { $_.Phase -ne "Phase$p" })
        $phaseResults += @{
            Phase           = "Phase$p"
            Status          = $result.Status ?? 'Passed'
            Message         = $result.Message ?? 'Completed'
            DurationSeconds = $phaseDuration
            Timestamp       = (Get-Date -Format 'HH:mm:ss')
        }

        Write-DashboardLog -Message "Phase $p completed: $($result.Status ?? 'Passed') ($($phaseDuration)s)" -Phase $p

        if ($result.Status -eq 'Failed') {
            $allPassed = $false
            Write-DashboardLog -Message "Phase $p FAILED: $($result.Message)" -Phase $p
            Update-RetryRunStatus -Phase $p -Status 'Failed' -Message $result.Message
            break
        }
    }
    catch {
        Sync-PhaseLogs-ToDashboard

        $phaseDuration = [int]((Get-Date) - $phaseStart).TotalSeconds
        $phaseResults = @($phaseResults | Where-Object { $_.Phase -ne "Phase$p" })
        $phaseResults += @{
            Phase           = "Phase$p"
            Status          = 'Failed'
            Message         = $_.Exception.Message
            DurationSeconds = $phaseDuration
            Timestamp       = (Get-Date -Format 'HH:mm:ss')
        }
        $allPassed = $false
        Write-DashboardLog -Message "Phase $p EXCEPTION: $($_.Exception.Message)" -Phase $p
        Update-RetryRunStatus -Phase $p -Status 'Failed' -Message $_.Exception.Message
        break
    }
}

} catch {
    $allPassed = $false
    Write-DashboardLog -Message "Unexpected error: $($_.Exception.Message)" -Phase $script:currentPhaseNum
    # Record as failed phase result so finalize picks it up
    $phaseResults = @($phaseResults | Where-Object { $_.Phase -ne "Phase$($script:currentPhaseNum)" })
    $phaseResults += @{
        Phase           = "Phase$($script:currentPhaseNum)"
        Status          = 'Failed'
        Message         = "Unexpected: $($_.Exception.Message)"
        DurationSeconds = 0
        Timestamp       = (Get-Date -Format 'HH:mm:ss')
    }
}

# ---------------------------------------------------------------------------
# FINALIZE
# ---------------------------------------------------------------------------
$totalDuration = [int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds
$finalStatus = if ($allPassed -and $endPhase -eq 6) { 'Passed' } elseif ($allPassed) { 'Partial' } else { 'Failed' }

Write-DashboardLog -Message "Retry complete: $finalStatus ($($totalDuration)s)" -Phase $script:currentPhaseNum

try {
    $entity = Get-AzTableRow -Table $table -PartitionKey $partitionKey -RowKey $runId
    $entity.Status = $finalStatus
    $entity.PhaseResults = ($phaseResults | ConvertTo-Json -Depth 3 -Compress)
    $entity.LogEntries = ($script:dashboardLogs | ConvertTo-Json -Depth 3 -Compress)
    $entity.DurationSec = $totalDuration
    $entity.ErrorMessage = if ($finalStatus -eq 'Failed') { ($phaseResults | Where-Object { $_.Status -eq 'Failed' } | Select-Object -Last 1).Message } else { '' }
    $entity = Sanitize-Entity -Entity $entity
    $entity | Update-AzTableRow -Table $table | Out-Null
} catch {
    Write-Warning "Final status update failed: $_"
}

# Regenerate report with final results
try {
    . (Join-Path $helpersDir 'HtmlReportGenerator.ps1')
    # Convert dashboard logs (all phases) to the format expected by New-TestReport
    $logEntries = $script:dashboardLogs | ForEach-Object {
        $msg = $_.message
        $level = 'INFO'
        if ($msg -match '^\[(INFO|WARN|ERROR|SUCCESS)\]\s*(.*)$') {
            $level = $Matches[1]
            $msg = $Matches[2]
        }
        @{ Timestamp = $_.time; Phase = "Phase$($_.phase)"; Level = $level; Message = $msg }
    }
    $reportDir = $env:TEMP
    $reportFile = New-TestReport -PhaseResults $phaseResults -LogEntries $logEntries `
        -Config $config -OutputPath $reportDir

    # Upload report to Blob Storage
    $container = Get-AzStorageContainer -Name 'ha-test-reports' -Context $storageCtx -ErrorAction SilentlyContinue
    if (-not $container) { New-AzStorageContainer -Name 'ha-test-reports' -Context $storageCtx -Permission Off | Out-Null }

    $blobName = Split-Path $reportFile -Leaf
    Set-AzStorageBlobContent -File $reportFile -Container 'ha-test-reports' -Blob $blobName -Context $storageCtx -Force | Out-Null

    # Update entity with new report blob name
    $entity = Get-AzTableRow -Table $table -PartitionKey $partitionKey -RowKey $runId
    $entity.ReportUrl = "proxy:$blobName"
    $entity.ReportBlobName = $blobName
    $entity = Sanitize-Entity -Entity $entity
    $entity | Update-AzTableRow -Table $table | Out-Null
    Write-DashboardLog -Message "Report regenerated: $blobName" -Phase 6
} catch {
    Write-Warning "Report regeneration failed: $_"
}

using namespace System.Net

param($Request, $TriggerMetadata)

# ============================================================================
# get-status - Returns current status of a test run (for live progress polling)
# ============================================================================

$runId = $Request.Params.runId
if (-not $runId) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = (@{ error = "runId parameter is required" } | ConvertTo-Json)
        ContentType = "application/json"
    })
    return
}

$storageCtx = New-AzStorageContext -ConnectionString $env:REPORT_STORAGE_CONNSTR
$table = (Get-AzStorageTable -Name 'HaClusterTestRuns' -Context $storageCtx).CloudTable

# Direct RowKey filter — avoids loading all rows (was the main perf bottleneck)
$run = Get-AzTableRow -Table $table -CustomFilter "RowKey eq '$runId'" | Select-Object -First 1

if (-not $run) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::NotFound
        Body = (@{ error = "Run not found: $runId" } | ConvertTo-Json)
        ContentType = "application/json"
    })
    return
}

$response = @{
    runId        = $run.RowKey
    sid          = $run.PartitionKey
    status       = $run.Status
    currentPhase = [int]$run.CurrentPhase
    totalPhases  = 6
    startTime    = $run.StartTime
    os           = $run.OS
    clusterName  = $run.ClusterName
    phaseResults = if ($run.PhaseResults) { $run.PhaseResults | ConvertFrom-Json } else { @() }
    logEntries   = if ($run.LogEntries) { $run.LogEntries | ConvertFrom-Json } else { @() }
    reportUrl    = $run.ReportUrl ?? ''
    duration     = [int]($run.DurationSec ?? 0)
    error        = $run.ErrorMessage ?? ''
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = ($response | ConvertTo-Json -Depth 5)
    ContentType = "application/json"
})

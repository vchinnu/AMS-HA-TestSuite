using namespace System.Net

param($Request, $TriggerMetadata)

# ============================================================================
# get-runs - Returns all historical test runs (for dashboard listing)
# ============================================================================

$storageCtx = New-AzStorageContext -ConnectionString $env:REPORT_STORAGE_CONNSTR
$table = (Get-AzStorageTable -Name 'HaClusterTestRuns' -Context $storageCtx).CloudTable

# Optional SID filter
$sid = $Request.Query.sid

if ($sid) {
    $runs = Get-AzTableRow -Table $table -PartitionKey $sid
} else {
    $runs = Get-AzTableRow -Table $table
}

$response = $runs | Sort-Object { $_.StartTime } -Descending | ForEach-Object {
    # Use Status (updated by phase loop) over OverallStatus (only updated at end)
    $effectiveStatus = $_.Status ?? $_.OverallStatus ?? 'Unknown'

    # Auto-mark stale "Running" entries (>120 min old) as Abandoned
    if ($effectiveStatus -eq 'Running' -and $_.StartTime) {
        $age = (Get-Date) - [datetime]$_.StartTime
        if ($age.TotalMinutes -gt 120) {
            $effectiveStatus = 'Abandoned'
            try {
                $_.Status = 'Abandoned'
                $_.ErrorMessage = 'Run was abandoned (likely killed by deployment or timeout)'
                $_ | Update-AzTableRow -Table $table | Out-Null
            } catch { }
        }
    }

    @{
        runId       = $_.RowKey
        sid         = $_.PartitionKey
        status      = $effectiveStatus
        clusterName = $_.ClusterName
        os          = $_.OS
        startTime   = $_.StartTime
        duration    = [int]($_.DurationSec ?? 0)
        reportUrl   = $_.ReportUrl ?? ''
        error       = $_.ErrorMessage ?? ''
        currentPhase = [int]($_.CurrentPhase ?? 0)
    }
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = (@{ runs = @($response) } | ConvertTo-Json -Depth 5)
    ContentType = "application/json"
})

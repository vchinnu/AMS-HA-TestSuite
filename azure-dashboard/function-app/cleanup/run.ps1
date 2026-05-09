using namespace System.Net

param($Request, $TriggerMetadata)

# ============================================================================
# cleanup - Runs Phase 7 cleanup for a completed test run
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

# Restore config from stored run
$config = $run.Config | ConvertFrom-Json -AsHashtable

# Set subscription context
Set-AzContext -SubscriptionId $config['subscription_id'] | Out-Null

# Load helpers and Phase 7
$helpersDir = Join-Path $PSScriptRoot '..\helpers'
$phasesDir = Join-Path $PSScriptRoot '..\phases'
. (Join-Path $helpersDir 'Common.ps1')
. (Join-Path $phasesDir 'Phase7-Cleanup.ps1')

try {
    Invoke-Phase7 -Config $config
    
    $run.Status = 'Cleaned'
    # Sanitize nulls for AzTable
    $props = $run | Get-Member -MemberType Properties | Where-Object { $_.Name -notin @('PartitionKey','RowKey','TableTimestamp','Etag') }
    foreach ($p in $props) { if ($null -eq $run.($p.Name)) { $run.($p.Name) = '' } }
    $run | Update-AzTableRow -Table $table | Out-Null

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = (@{ status = "Cleanup completed"; runId = $runId } | ConvertTo-Json)
        ContentType = "application/json"
    })
}
catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = (@{ error = "Cleanup failed: $($_.Exception.Message)"; runId = $runId } | ConvertTo-Json)
        ContentType = "application/json"
    })
}

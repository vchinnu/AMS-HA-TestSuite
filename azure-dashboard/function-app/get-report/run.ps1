using namespace System.Net

param($Request, $TriggerMetadata)

# ============================================================================
# get-report - Proxy endpoint to serve HTML reports from Blob Storage
# Uses managed identity - no SAS tokens or public blob access needed
# ============================================================================

$runId = $Request.Params.runId

if (-not $runId) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = "Missing runId"
        ContentType = "text/plain"
    })
    return
}

try {
    $storageCtx = New-AzStorageContext -ConnectionString $env:REPORT_STORAGE_CONNSTR

    # Look up blob name from Table Storage
    $table = (Get-AzStorageTable -Name 'HaClusterTestRuns' -Context $storageCtx).CloudTable
    $entity = Get-AzTableRow -Table $table -ColumnName 'RowKey' -Value $runId -Operator Equal

    if (-not $entity) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body = "Run not found: $runId"
            ContentType = "text/plain"
        })
        return
    }

    $blobName = $entity.ReportBlobName
    if (-not $blobName) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body = "No report available for this run"
            ContentType = "text/plain"
        })
        return
    }

    # Download blob content via managed identity (no SAS needed)
    $tempFile = Join-Path $env:TEMP "report_$runId.html"
    Get-AzStorageBlobContent -Container 'ha-test-reports' -Blob $blobName -Destination $tempFile -Context $storageCtx -Force | Out-Null
    $htmlContent = Get-Content -Path $tempFile -Raw -Encoding UTF8
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = $htmlContent
        ContentType = "text/html; charset=utf-8"
    })
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = "Failed to retrieve report: $_"
        ContentType = "text/plain"
    })
}

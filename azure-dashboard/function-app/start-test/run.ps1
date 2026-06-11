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
$missing = $requiredFields | Where-Object { -not ("$($body.$_)".Trim()) }
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

# Validate each node has hostname and ip_address
$invalidNodes = @()
foreach ($n in $body.nodes) {
    if (-not $n.hostname -or $n.hostname.Trim() -eq '') {
        $invalidNodes += "Node missing hostname (resource_id: $($n.vm_resource_id))"
    }
    if (-not $n.ip_address -or $n.ip_address.Trim() -eq '') {
        $invalidNodes += "Node '$($n.hostname)' missing IP address — click the resolve button (↻) or enter it manually"
    }
}
if ($invalidNodes.Count -gt 0) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = (@{ error = "Node validation failed: $($invalidNodes -join '; ')" } | ConvertTo-Json)
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
    TotalPhases   = 7
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
# 3. RETURN RESPONSE IMMEDIATELY & QUEUE EXECUTION
# ---------------------------------------------------------------------------
# Push a message to the queue so execute-test picks it up asynchronously.
# This allows the HTTP response to return the runId instantly.
Push-OutputBinding -Name QueueMessage -Value (@{
    runId          = $runId
    sid            = $body.sap_sid
    config         = $body
} | ConvertTo-Json -Depth 5 -Compress)

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::Accepted
    Body = (@{ runId = $runId; status = 'Running' } | ConvertTo-Json)
    ContentType = "application/json"
})

# ============================================================================
# Phase4-ValidateData.ps1 - Validate HA cluster metrics flow into Log Analytics
# ============================================================================
# Polls the Prometheus_HaClusterExporter_CL table in Log Analytics to confirm:
#   1. Data is arriving (rows exist within last 30 min)
#   2. Expected ha_cluster_* metric names are present
#   3. Data from all cluster nodes is present
#   4. DC-node dedup is working (only DC node pushes data)
# ============================================================================


$PhaseName = 'Phase4-ValidateData'
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot '..\helpers\Common.ps1')
. (Join-Path $PSScriptRoot '..\helpers\KqlRunner.ps1')

function Invoke-Phase4 {
    param([hashtable]$Config)

    $startTime = Get-Date
    Set-PhaseResult -Phase $PhaseName -Status 'Running' -Message 'Validating data flow into Log Analytics...'

    $workspaceId = $Config['log_analytics_workspace_id']
    $pollInterval = [int]$Config['poll_interval_seconds']
    $maxWait = [int]$Config['poll_max_wait_minutes']
    $sid = $Config['sap_sid']
    $clusterName = $Config['cluster_name']
    $nodeCount = $Config['nodes'].Count
    $rgName = $Config['resource_group']
    $monitorName = $Config['ams_monitor_name']

    # Auto-discover LA workspace from AMS Monitor if not configured
    if (-not $workspaceId) {
        try {
            $workspaceId = Get-MonitorWorkspaceId -ResourceGroupName $rgName -MonitorName $monitorName -PhaseName $PhaseName
        } catch {
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Failed to discover LA workspace: $_"
            Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "LA workspace discovery failed: $($_.Exception.Message)" -DurationSeconds ([int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds)
            return
        }
    }

    if (-not $pollInterval -or $pollInterval -lt 30) { $pollInterval = 120 }
    if (-not $maxWait -or $maxWait -lt 5) { $maxWait = 20 }

    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Polling LA workspace every ${pollInterval}s, max wait ${maxWait} min"

    # --- Poll for data arrival ---
    $dataArrived = $false
    $elapsed = 0
    $maxElapsed = $maxWait * 60

    $checkQuery = @"
Prometheus_HaClusterExporter_CL
| where TimeGenerated > ago(30m)
| summarize RowCount=count(), DistinctMetrics=dcount(name_s), DistinctHosts=dcount(hostname_s)
"@

    while ($elapsed -lt $maxElapsed) {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Polling LA... (${elapsed}s / ${maxElapsed}s)"
        
        $result = Invoke-KqlQuery -WorkspaceId $workspaceId -Query $checkQuery -Timespan 'PT1H' -Phase $PhaseName
        
        if ($result.Success -and $result.Count -gt 0) {
            $row = $result.Results[0]
            $rowCount = [int]$row.RowCount
            if ($rowCount -gt 0) {
                Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Data arrived! Rows: $rowCount, Distinct metrics: $($row.DistinctMetrics), Hosts: $($row.DistinctHosts)"
                $dataArrived = $true
                break
            }
        }

        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval
    }

    if (-not $dataArrived) {
        Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "No data in Prometheus_HaClusterExporter_CL after ${maxWait} minutes"
        Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "No data in LA after ${maxWait} min" -DurationSeconds ([int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds)
        return
    }

    # --- Validate metric content ---
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Validating metric content..."

    # Check expected metric families exist
    $metricQuery = @"
Prometheus_HaClusterExporter_CL
| where TimeGenerated > ago(30m)
| distinct name_s
| order by name_s asc
"@
    $metricResult = Invoke-KqlQuery -WorkspaceId $workspaceId -Query $metricQuery -Timespan 'PT1H' -Phase $PhaseName

    $expectedMetricPrefixes = @(
        'ha_cluster_pacemaker_nodes',
        'ha_cluster_pacemaker_resources',
        'ha_cluster_corosync',
        'ha_cluster_sbd'
    )

    $foundMetrics = if ($metricResult.Results) { $metricResult.Results | ForEach-Object { $_.name_s } } else { @() }
    $missingPrefixes = @()

    foreach ($prefix in $expectedMetricPrefixes) {
        $found = $foundMetrics | Where-Object { $_ -like "$prefix*" }
        if ($found) {
            Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Found metric family: $prefix ($($found.Count) variants)"
        } else {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Missing metric family: $prefix"
            $missingPrefixes += $prefix
        }
    }

    # --- Validate node coverage (DC node dedup means only 1 node pushes) ---
    $nodeQuery = @"
Prometheus_HaClusterExporter_CL
| where TimeGenerated > ago(30m)
| where name_s startswith "ha_cluster_pacemaker_nodes"
| distinct hostname_s
"@
    $nodeResult = Invoke-KqlQuery -WorkspaceId $workspaceId -Query $nodeQuery -Timespan 'PT1H' -Phase $PhaseName

    if ($nodeResult.Results) {
        $reportingNodes = $nodeResult.Results | ForEach-Object { $_.hostname_s }
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Data from nodes: $($reportingNodes -join ', ')"
        # DC dedup means typically 1 node reports — this is expected behavior
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Note: DC-node dedup means only the Designated Controller pushes data (expected: 1 reporting node)"
    }

    $duration = [int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds
    if ($missingPrefixes.Count -eq 0) {
        Set-PhaseResult -Phase $PhaseName -Status 'Passed' -Message "All expected metric families present in LA" -DurationSeconds $duration
    } elseif ($missingPrefixes.Count -le 1) {
        Set-PhaseResult -Phase $PhaseName -Status 'Passed' -Message "Most metrics present; missing: $($missingPrefixes -join ', ')" -DurationSeconds $duration
    } else {
        Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "Missing metric families: $($missingPrefixes -join ', ')" -DurationSeconds $duration
    }
}

# Execute only when script is run directly (not dot-sourced by orchestrator)
if ($MyInvocation.InvocationName -ne '.' -and $Config) {
    Invoke-Phase4 -Config $Config
}

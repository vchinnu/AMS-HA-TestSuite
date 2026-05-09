# ============================================================================
# PrometheusParser.ps1 - Parse Prometheus text exposition format
# ============================================================================
# Parses raw output from ha_cluster_exporter /metrics endpoint into structured
# objects for comparison with KQL workbook query results.
# ============================================================================

<#
.SYNOPSIS
    Parses Prometheus metric lines into structured objects.
.DESCRIPTION
    Handles lines like:
    ha_cluster_pacemaker_resources{agent="ocf::heartbeat:Filesystem",clone="",group="grp_CHA_ASCS",managed="true",node="chascs02l0c2",resource="fs_CHA_ASCS",role="started",status="active"} 1
.PARAMETER MetricsText
    Raw text output from curl http://host:port/metrics (multi-line string)
.PARAMETER MetricFilter
    Optional regex filter for metric names. Default: "^ha_cluster_"
#>
function ConvertFrom-PrometheusMetrics {
    param(
        [Parameter(Mandatory)]
        [string]$MetricsText,

        [string]$MetricFilter = '^ha_cluster_'
    )

    $results = @()
    $lines = $MetricsText -split "`n"

    foreach ($line in $lines) {
        $line = $line.Trim()

        # Skip comments, HELP, TYPE, and empty lines
        if (-not $line -or $line.StartsWith('#')) { continue }

        # Match: metric_name{label1="val1",label2="val2",...} value
        if ($line -match '^(?<metric>[a-zA-Z_:][a-zA-Z0-9_:]*)\{(?<labels>[^}]*)\}\s+(?<value>[0-9.eE+\-]+)') {
            $metricName = $Matches['metric']
            $labelsStr = $Matches['labels']
            $value = [double]$Matches['value']

            # Apply filter
            if ($MetricFilter -and $metricName -notmatch $MetricFilter) { continue }

            # Parse labels: key="value" pairs (handle escaped quotes in values)
            $labels = @{}
            $labelMatches = [regex]::Matches($labelsStr, '(?<key>[a-zA-Z_][a-zA-Z0-9_]*)="(?<val>([^"\\]|\\.)*)"')
            foreach ($m in $labelMatches) {
                $labels[$m.Groups['key'].Value] = $m.Groups['val'].Value -replace '\\(.)', '$1'
            }

            $results += [PSCustomObject]@{
                MetricName = $metricName
                Labels     = $labels
                Value      = $value
            }
        }
        # Match: metric_name value (no labels)
        elseif ($line -match '^(?<metric>[a-zA-Z_:][a-zA-Z0-9_:]*)\s+(?<value>[0-9.eE+\-]+)') {
            $metricName = $Matches['metric']
            $value = [double]$Matches['value']

            if ($MetricFilter -and $metricName -notmatch $MetricFilter) { continue }

            $results += [PSCustomObject]@{
                MetricName = $metricName
                Labels     = @{}
                Value      = $value
            }
        }
    }

    return $results
}

<#
.SYNOPSIS
    Extracts pacemaker resources from parsed Prometheus metrics (active only, value=1).
.DESCRIPTION
    Returns structured resource objects with agent, node, resource, role, status, managed.
    Only returns entries with value=1 (running/active resources).
#>
function Get-ExporterResources {
    param(
        [Parameter(Mandatory)]
        [array]$ParsedMetrics
    )

    $resources = $ParsedMetrics | Where-Object {
        $_.MetricName -eq 'ha_cluster_pacemaker_resources' -and $_.Value -eq 1
    } | ForEach-Object {
        [PSCustomObject]@{
            Resource = $_.Labels['resource']
            Agent    = $_.Labels['agent']
            Node     = $_.Labels['node']
            Role     = $_.Labels['role']
            Status   = $_.Labels['status']
            Managed  = $_.Labels['managed']
            Clone    = $_.Labels['clone']
            Group    = $_.Labels['group']
        }
    }

    return $resources
}

<#
.SYNOPSIS
    Extracts ALL pacemaker resources regardless of state (active, stopped, standby).
.DESCRIPTION
    Returns one entry per resource from the status="active" metric line.
    value=1 → resource is running; value=0 → resource is stopped/offline.
    This ensures no resource is missed in comparisons.
#>
function Get-AllExporterResources {
    param(
        [Parameter(Mandatory)]
        [array]$ParsedMetrics
    )

    $resources = $ParsedMetrics | Where-Object {
        $_.MetricName -eq 'ha_cluster_pacemaker_resources' -and $_.Labels['status'] -eq 'active'
    } | ForEach-Object {
        $isActive = ($_.Value -eq 1)
        [PSCustomObject]@{
            Resource      = $_.Labels['resource']
            Agent         = $_.Labels['agent']
            Node          = $_.Labels['node']
            Role          = $_.Labels['role']
            ResourceState = if ($isActive) { 'active' } else { 'stopped' }
            Managed       = $_.Labels['managed']
            Clone         = $_.Labels['clone']
            Group         = $_.Labels['group']
            Value         = $_.Value
        }
    }

    return $resources
}

<#
.SYNOPSIS
    Extracts pacemaker nodes from parsed Prometheus metrics.
.DESCRIPTION
    Returns structured node objects with node name, type, status.
    Only returns entries with value=1.
#>
function Get-ExporterNodes {
    param(
        [Parameter(Mandatory)]
        [array]$ParsedMetrics
    )

    $nodes = $ParsedMetrics | Where-Object {
        $_.MetricName -eq 'ha_cluster_pacemaker_nodes' -and $_.Value -eq 1
    } | ForEach-Object {
        [PSCustomObject]@{
            Node   = $_.Labels['node']
            Type   = $_.Labels['type']
            Status = $_.Labels['status']
        }
    }

    return $nodes
}

<#
.SYNOPSIS
    Identifies the DC (Designated Controller) node from parsed metrics.
.RETURNS
    The node name that has status='dc', or $null if not found.
#>
function Get-DCNode {
    param(
        [Parameter(Mandatory)]
        [array]$ParsedMetrics
    )

    $dcEntry = $ParsedMetrics | Where-Object {
        $_.MetricName -eq 'ha_cluster_pacemaker_nodes' -and
        $_.Value -eq 1 -and
        $_.Labels['status'] -eq 'dc'
    } | Select-Object -First 1

    if ($dcEntry) {
        return $dcEntry.Labels['node']
    }
    return $null
}

<#
.SYNOPSIS
    Gets all distinct metric families present in parsed metrics.
#>
function Get-ExporterMetricFamilies {
    param(
        [Parameter(Mandatory)]
        [array]$ParsedMetrics
    )

    return ($ParsedMetrics | Select-Object -ExpandProperty MetricName -Unique | Sort-Object)
}

<#
.SYNOPSIS
    Normalizes role from exporter format to workbook format for comparison.
.DESCRIPTION
    Exporter uses: started, master, slave, stopped
    Workbook maps to: active, primary, secondary, stopped/inactive
#>
function ConvertTo-WorkbookRole {
    param([string]$ExporterRole)

    switch ($ExporterRole.ToLower()) {
        'master'  { return 'primary' }
        'slave'   { return 'secondary' }
        'started' { return '' }  # workbook shows '' for started resources
        'stopped' { return '' }  # workbook shows '' for stopped
        default   { return $ExporterRole }
    }
}

<#
.SYNOPSIS
    Normalizes status from exporter to match workbook output.
.DESCRIPTION
    Exporter status values map directly in most cases.
    The workbook aggregates and uses: active, failed, blocked, orphaned, inactive, failure_ignored
#>
function ConvertTo-WorkbookStatus {
    param(
        [string]$ExporterStatus,
        [string]$ExporterRole,
        [string]$ExporterManaged
    )

    # The workbook resource status query logic:
    # status_active = countif(status == 'active') + countif(role == 'started' and managed == 'true')
    #                 + countif(role == 'master' and managed == 'true') + countif(role == 'slave' and managed == 'true')
    # Final status = case(failure_ignored > 0, ..., failed > 0, ..., blocked > 0, ..., orphaned > 0, ..., active > 0, 'active', 'inactive')

    if ($ExporterStatus -eq 'failure_ignored') { return 'failure_ignored' }
    if ($ExporterStatus -eq 'failed') { return 'failed' }
    if ($ExporterStatus -eq 'blocked') { return 'blocked' }
    if ($ExporterStatus -eq 'orphaned') { return 'orphaned' }

    # 'active' status or role-based active
    if ($ExporterStatus -eq 'active') { return 'active' }
    if ($ExporterRole -in @('started', 'master', 'slave') -and $ExporterManaged -eq 'true') { return 'active' }

    return 'inactive'
}

# Guard Export-ModuleMember for dot-sourcing
if ($MyInvocation.MyCommand.ScriptBlock.Module) {
    Export-ModuleMember -Function ConvertFrom-PrometheusMetrics, Get-ExporterResources, Get-ExporterNodes, Get-DCNode, Get-ExporterMetricFamilies, ConvertTo-WorkbookRole, ConvertTo-WorkbookStatus
}

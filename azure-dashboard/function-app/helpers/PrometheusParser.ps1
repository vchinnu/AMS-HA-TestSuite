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

    # SUSE format: ha_cluster_pacemaker_resources{status="active",resource="xxx",...} 1/0
    $suseResources = $ParsedMetrics | Where-Object {
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

    # RHEL/PCP format: ha_cluster_pacemaker_resources_status_active{instname="xxx",...} 1/0
    # instname format: "resource_name:node_name" (active) or just "resource_name" (no node assignment)
    # When no colon, AMS stores hostname as node in LA, so we do the same for consistent comparison
    $pcpResources = $ParsedMetrics | Where-Object {
        $_.MetricName -eq 'ha_cluster_pacemaker_resources_status_active'
    } | ForEach-Object {
        $isActive = ($_.Value -eq 1)
        $instname = $_.Labels['instname']
        # Split on FIRST colon only — resource names can contain colons
        $colonIdx = if ($instname) { $instname.IndexOf(':') } else { -1 }
        if ($colonIdx -gt 0) {
            $resourceName = $instname.Substring(0, $colonIdx)
            $nodeName = $instname.Substring($colonIdx + 1)
        } else {
            $resourceName = $instname
            # Use hostname label as node (matches AMS LA normalization)
            $nodeName = $_.Labels['hostname']
        }
        [PSCustomObject]@{
            Resource      = $resourceName
            Agent         = ''
            Node          = $nodeName
            Role          = ''  # AMS normalizes RHEL/PCP data with empty role in LA
            ResourceState = if ($isActive) { 'active' } else { 'stopped' }
            Managed       = ''
            Clone         = ''
            Group         = ''
            Value         = $_.Value
        }
    }

    $resources = @($suseResources) + @($pcpResources) | Where-Object { $_ }
    return $resources
}

<#
.SYNOPSIS
    Extracts pacemaker nodes from parsed Prometheus metrics.
.DESCRIPTION
    Returns structured node objects with node name, type, status.
    Handles both SUSE (labels) and RHEL/PCP (metric name suffix) formats.
#>
function Get-ExporterNodes {
    param(
        [Parameter(Mandatory)]
        [array]$ParsedMetrics
    )

    # SUSE format: ha_cluster_pacemaker_nodes{node="xxx",type="member",status="online"} 1
    $suseNodes = $ParsedMetrics | Where-Object {
        $_.MetricName -eq 'ha_cluster_pacemaker_nodes' -and $_.Value -eq 1
    } | ForEach-Object {
        [PSCustomObject]@{
            Node   = $_.Labels['node']
            Type   = $_.Labels['type']
            Status = $_.Labels['status']
        }
    }

    # RHEL/PCP format: ha_cluster_pacemaker_nodes_status_dc{instname="xxx",...} 1
    $pcpNodes = $ParsedMetrics | Where-Object {
        $_.MetricName -match '^ha_cluster_pacemaker_nodes_status_' -and $_.Value -eq 1
    } | ForEach-Object {
        # Extract status from metric name suffix
        $status = if ($_.MetricName -match '_status_(.+)$') { $Matches[1] } else { 'unknown' }
        [PSCustomObject]@{
            Node   = $_.Labels['instname'] ?? $_.Labels['hostname']
            Type   = 'member'
            Status = $status
        }
    }

    $nodes = @($suseNodes) + @($pcpNodes) | Where-Object { $_ }
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

    # Method 1: SUSE format - ha_cluster_pacemaker_nodes{status="dc"} 1
    $dcEntry = $ParsedMetrics | Where-Object {
        $_.MetricName -eq 'ha_cluster_pacemaker_nodes' -and
        $_.Value -eq 1 -and
        ($_.Labels['status'] -eq 'dc' -or $_.Labels['type'] -eq 'dc')
    } | Select-Object -First 1

    if ($dcEntry) {
        $nodeName = $dcEntry.Labels['node']
        if (-not $nodeName) { $nodeName = $dcEntry.Labels['hostname'] }
        if (-not $nodeName) { $nodeName = $dcEntry.Labels['instance'] }
        return $nodeName
    }

    # Method 2: RHEL/PCP format - ha_cluster_pacemaker_nodes_status_dc{instname="nodeX"} 1
    $dcPcp = $ParsedMetrics | Where-Object {
        $_.MetricName -eq 'ha_cluster_pacemaker_nodes_status_dc' -and
        $_.Value -eq 1
    } | Select-Object -First 1

    if ($dcPcp) {
        $nodeName = $dcPcp.Labels['instname']
        if (-not $nodeName) { $nodeName = $dcPcp.Labels['node'] }
        if (-not $nodeName) { $nodeName = $dcPcp.Labels['hostname'] }
        return $nodeName
    }

    # Fallback: any metric with 'nodes' and 'dc' in the name, value=1
    $dcFallback = $ParsedMetrics | Where-Object {
        $_.MetricName -match 'pacemaker_nodes.*dc' -and $_.Value -eq 1
    } | Select-Object -First 1

    if ($dcFallback) {
        foreach ($key in @('instname', 'node', 'hostname', 'instance', 'name')) {
            if ($dcFallback.Labels[$key]) { return $dcFallback.Labels[$key] }
        }
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

<#
.SYNOPSIS
    Extracts location constraints (cli-ban, cli-prefer) from parsed Prometheus metrics.
.DESCRIPTION
    Returns constraint names from ha_cluster_pacemaker_location_constraints where value=1.
    Handles both SUSE (constraint label) and RHEL/PCP (instname label) formats.
    Only returns constraints starting with 'cli-ban' or 'cli-prefer' (matching workbook filter).
#>
function Get-ExporterLocationConstraints {
    param(
        [Parameter(Mandatory)]
        [array]$ParsedMetrics
    )

    $constraints = $ParsedMetrics | Where-Object {
        $_.MetricName -eq 'ha_cluster_pacemaker_location_constraints' -and $_.Value -eq 1
    } | ForEach-Object {
        # SUSE format: ha_cluster_pacemaker_location_constraints{constraint="cli-ban-xxx",node="...",resource="...",role="...",score="..."} 1
        # RHEL/PCP format: ha_cluster_pacemaker_location_constraints{instname="cli-ban-xxx"} 1
        $constraint = $_.Labels['constraint']
        if (-not $constraint) { $constraint = $_.Labels['instname'] }
        if ($constraint -and ($constraint -match '^cli-ban' -or $constraint -match '^cli-prefer')) {
            [PSCustomObject]@{
                Constraint = $constraint
                Node       = $_.Labels['node']
                Resource   = $_.Labels['resource']
                Role       = $_.Labels['role']
                Score      = $_.Labels['score']
            }
        }
    } | Where-Object { $_ }

    return $constraints
}

# Guard Export-ModuleMember for dot-sourcing
if ($MyInvocation.MyCommand.ScriptBlock.Module) {
    Export-ModuleMember -Function ConvertFrom-PrometheusMetrics, Get-ExporterResources, Get-AllExporterResources, Get-ExporterNodes, Get-DCNode, Get-ExporterMetricFamilies, Get-ExporterLocationConstraints, ConvertTo-WorkbookRole, ConvertTo-WorkbookStatus
}

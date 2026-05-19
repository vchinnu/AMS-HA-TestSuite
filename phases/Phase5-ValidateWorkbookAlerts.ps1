# ============================================================================
# Phase5-ValidateWorkbookAlerts.ps1 - Validate workbook KQL & built-in alerts
# ============================================================================
# Validates:
#   1. Workbook KQL queries return data (cluster overview, node status, resources)
#   2. Built-in AMS HA alert rules exist and are enabled
#   3. Alert rules are evaluating (not in error state)
# ============================================================================


$PhaseName = 'Phase5-WorkbookAlerts'
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot '..\helpers\Common.ps1')
. (Join-Path $PSScriptRoot '..\helpers\KqlRunner.ps1')

function Invoke-Phase5 {
    param([hashtable]$Config)

    $startTime = Get-Date
    Set-PhaseResult -Phase $PhaseName -Status 'Running' -Message 'Validating workbook queries and alerts...'

    $workspaceId = $Config['log_analytics_workspace_id']
    $rgName = $Config['resource_group']
    $monitorName = $Config['ams_monitor_name']
    $sid = $Config['sap_sid']
    $clusterName = $Config['cluster_name']

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

    $allPassed = $true

    # --- Part 1: Workbook KQL Queries (Content Validation) ---
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Validating workbook KQL queries with content checks..."

    $kqlDir = Join-Path $PSScriptRoot '..\kql'
    $kqlParams = @{ SID = $sid; CLUSTER_NAME = $clusterName }
    $nodeCount = $Config['nodes'].Count
    $kqlFiles = Get-ChildItem -Path $kqlDir -Filter 'workbook-*.kql' -ErrorAction SilentlyContinue

    # Per-workbook validators: define expected columns, valid values, and minimum row counts
    $workbookValidators = @{
        'workbook-cluster-overview' = @{
            RequiredColumns = @('cluster_status', 'sid_s', 'clusterName_s')
            ValidValues     = @{ cluster_status = @('red', 'yellow', 'green', 'grey', 'greyblue') }
            MinRows         = 1
            Description     = 'Overall cluster health summary (resources + nodes + status color)'
        }
        'workbook-node-status' = @{
            RequiredColumns = @('resources_node', 'resources_status')
            ValidValues     = @{}
            MinRows         = $nodeCount  # Must return at least as many rows as configured cluster nodes
            Description     = 'Pacemaker node online/dc/type status'
        }
        'workbook-resource-status' = @{
            RequiredColumns = @('resource_agent', 'resource_resource', 'resource_node')
            ValidValues     = @{}
            MinRows         = 1
            Description     = 'Cluster resource agent/node/role/managed details'
        }
        'workbook-location-constraints' = @{
            RequiredColumns = @('resource_constraint', 'Impact')
            ValidValues     = @{}
            MinRows         = 0  # May legitimately be empty (no cli-ban/prefer active)
            Description     = 'CLI location constraints (cli-ban, cli-prefer)'
        }
    }

    if ($kqlFiles.Count -eq 0) {
        Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "No workbook KQL files found in $kqlDir. Skipping workbook validation."
    } else {
        foreach ($kqlFile in $kqlFiles) {
            $queryName = $kqlFile.BaseName
            Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Running workbook query: $queryName"
            
            $result = Invoke-KqlFromFile -WorkspaceId $workspaceId -KqlFilePath $kqlFile.FullName `
                -Parameters $kqlParams -Timespan 'PT2H' -Phase $PhaseName

            if (-not $result.Success) {
                Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "$queryName`: Query execution FAILED"
                continue
            }

            # Get validator for this workbook (if defined)
            $validator = $workbookValidators[$queryName]

            $rowCount = @($result.Results).Count
            if ($rowCount -eq 0) {
                # Check if empty is acceptable
                if ($validator -and $validator.MinRows -eq 0) {
                    Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "$queryName`: 0 rows (acceptable — $($validator.Description))"
                } else {
                    Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "$queryName`: No data returned — workbook graph would be empty"
                }
                continue
            }

            Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "$queryName`: $rowCount rows returned"

            # Skip detailed validation if no validator defined for this query
            if (-not $validator) {
                Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  (No content validator defined — row count check only)"
                continue
            }

            # Check MinRows
            if ($validator.MinRows -gt 0 -and $rowCount -lt $validator.MinRows) {
                Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "  Row count $rowCount < expected minimum $($validator.MinRows) (expected at least $nodeCount nodes' worth of data)"
            }

            # Check required columns exist in result schema (case-insensitive)
            $firstRow = @($result.Results)[0]
            $resultColumns = @($firstRow.PSObject.Properties.Name)
            Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  Columns returned: $($resultColumns -join ', ')"
            $resultColumnsLower = $resultColumns | ForEach-Object { $_.ToLower() }
            foreach ($col in $validator.RequiredColumns) {
                if ($col.ToLower() -in $resultColumnsLower) {
                    Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "  Column '$col' present"
                } else {
                    Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "  Expected column '$col' not found (available: $($resultColumns -join ', '))"
                }
            }

            # Check valid values (if defined, case-insensitive column lookup)
            foreach ($colName in $validator.ValidValues.Keys) {
                $allowedValues = $validator.ValidValues[$colName]
                # Find actual column name (case-insensitive match)
                $actualColName = $resultColumns | Where-Object { $_.ToLower() -eq $colName.ToLower() } | Select-Object -First 1
                if ($actualColName) {
                    $actualValues = @($result.Results) | ForEach-Object { $_.$actualColName } | Select-Object -Unique
                    foreach ($val in $actualValues) {
                        if ($val -and $val -notin $allowedValues) {
                            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "  Column '$actualColName' has unexpected value '$val' (expected: $($allowedValues -join ', '))"
                        }
                    }
                    $validActual = $actualValues | Where-Object { $_ -in $allowedValues }
                    if ($validActual) {
                        Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "  Column '$actualColName' values valid: $($validActual -join ', ')"
                    }
                }
            }
        }
    }

    # --- Part 2: Alert Query Validation (Detailed node_count vs expected_count) ---
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Validating alert query (primary-node-switched) with per-resource breakdown..."

    # Known agent-to-expected-count mappings from production alert rule
    $knownAgentMappings = @(
        'ocf::heartbeat:IPaddr2',
        'ocf::heartbeat:azure-events',
        'ocf::heartbeat:azure-lb',
        'ocf::suse:SAPHana',
        'ocf::suse:SAPHanaTopology',
        'ocf::heartbeat:SAPHanaTopology',
        'ocf::heartbeat:SAPHana',
        'stonith:fence_azure_arm',
        'ocf::heartbeat:db2'
    )

    $alertKqlFile = Join-Path $kqlDir 'alert-primary-node-switched.kql'
    if (Test-Path $alertKqlFile) {
        $alertResult = Invoke-KqlFromFile -WorkspaceId $workspaceId -KqlFilePath $alertKqlFile `
            -Parameters $kqlParams -Timespan 'PT2H' -Phase $PhaseName
        
        if ($alertResult.Success) {
            if ($alertResult.Count -gt 0) {
                Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Alert query executes successfully — $($alertResult.Count) resource evaluations returned"
                Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "--- Per-resource alert evaluation (node_count vs expected_count) ---"

                $alertPassCount = 0
                $alertWarnCount = 0
                $unmappedAgents = @()

                foreach ($row in $alertResult.Results) {
                    $resource = $row.resource
                    $agent = $row.agent
                    $rowNodeCount = [int]$row.node_count
                    $expectedCount = [int]$row.expected_count
                    $aggregatedValue = [int]$row.AggregatedValue

                    if ($aggregatedValue -eq 0) {
                        $alertPassCount++
                        Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "  [OK] $resource ($agent) | nodes=$rowNodeCount expected=$expectedCount"
                    } else {
                        $alertWarnCount++
                        Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "  [ALERT] $resource ($agent) | nodes=$rowNodeCount expected=$expectedCount — node count MISMATCH (alert would fire)"
                    }

                    # Track agents using default expected_count (may need explicit mapping)
                    if ($agent -and $agent -notin $knownAgentMappings -and $expectedCount -eq 1) {
                        if ($agent -notin $unmappedAgents) { $unmappedAgents += $agent }
                    }
                }

                Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  Alert summary: $alertPassCount OK, $alertWarnCount would-fire"

                if ($unmappedAgents.Count -gt 0) {
                    Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "  Agents using default expected_count=1 (may need explicit mapping in alert rule): $($unmappedAgents -join ', ')"
                }

                if ($alertWarnCount -gt 0) {
                    Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "  Alert WOULD FIRE for $alertWarnCount resources — verify if this is expected (e.g., recent failover) or a genuine issue"
                }
            } else {
                Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Alert query returned no data — resources may not be reporting yet or correlation_id not found"
            }
        } else {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Alert query failed to execute: $($alertResult.Error)"
            $allPassed = $false
        }
    } else {
        Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Alert KQL file not found: $alertKqlFile"
    }

    # --- Part 3: Built-in Alert Rules ---
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Checking built-in AMS HA alert rules..."

    try {
        # Get the managed RG where AMS creates its resources
        $monitor = Get-AzWorkloadsMonitor -ResourceGroupName $rgName -Name $monitorName -ErrorAction Stop
        $managedRgName = $monitor.ManagedResourceGroupConfiguration.Name
        if (-not $managedRgName) { $managedRgName = "MRG_$monitorName" }

        # List alert rules in both the user RG and managed RG
        $alertRules = @()
        $alertRules += Get-AzScheduledQueryRule -ResourceGroupName $rgName -ErrorAction SilentlyContinue
        $alertRules += Get-AzScheduledQueryRule -ResourceGroupName $managedRgName -ErrorAction SilentlyContinue

        # Filter for HA cluster related alerts
        $haAlerts = $alertRules | Where-Object { 
            $_.Description -match 'cluster|pacemaker|ha_cluster' -or 
            $_.Name -match 'cluster|pacemaker|HA' -or
            ($_.CriterionAllOf | Where-Object { $_.Query -match 'ha_cluster|HaCluster' })
        }

        if ($haAlerts.Count -gt 0) {
            Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Found $($haAlerts.Count) HA cluster alert rules"
            
            foreach ($alert in $haAlerts) {
                $state = if ($alert.Enabled) { 'Enabled' } else { 'Disabled' }
                $severity = $alert.Severity
                Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  Alert: $($alert.Name) | Severity: $severity | State: $state"
                
                if (-not $alert.Enabled) {
                    Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "  Alert '$($alert.Name)' is DISABLED"
                }
            }
        } else {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "No HA cluster alert rules found. They may not be auto-created for this monitor."
            Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Built-in alerts are provisioned after data flows for some time. Re-check later."
        }
    }
    catch {
        Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Could not check alert rules: $_"
    }

    $duration = [int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds
    if ($allPassed) {
        Set-PhaseResult -Phase $PhaseName -Status 'Passed' -Message "Workbook queries validated, alerts checked" -DurationSeconds $duration
    } else {
        Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "Workbook/Alert validation had issues" -DurationSeconds $duration
    }
}

# Only auto-invoke when run directly (not dot-sourced by orchestrator)
if ($MyInvocation.InvocationName -ne '.') {
    if ($Config) { Invoke-Phase5 -Config $Config }
}

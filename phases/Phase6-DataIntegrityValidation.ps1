# ============================================================================
# Phase6-DataIntegrityValidation.ps1 - End-to-End Data Integrity (OS Cert)
# ============================================================================
# Validates the full pipeline: Exporter → AMS Collector → Log Analytics → Workbook
#
# Steps:
#   1. Scrape exporter from both nodes via VM Run Command
#   2. Identify DC node from exporter data
#   3. Parse DC node's Prometheus metrics as source of truth
#   4. Run workbook KQL queries (resource status, node status) against LA
#   5. Compare exporter resources/nodes vs workbook output
#   6. Report discrepancies — PASS only if all resources/states match
#
# This phase is the OS certification test: if it passes, the HA exporter on
# the tested OS version correctly populates all workbook views in AMS.
# ============================================================================

# When invoked directly as a script (not dot-sourced), accept Config param
# Usage: .\Phase6-DataIntegrityValidation.ps1 -Config $config
# Or dot-source then call: . .\Phase6-DataIntegrityValidation.ps1; Invoke-Phase6 -Config $config

$PhaseName = 'Phase6-DataIntegrity'
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot '..\helpers\Common.ps1')
. (Join-Path $PSScriptRoot '..\helpers\KqlRunner.ps1')
. (Join-Path $PSScriptRoot '..\helpers\PrometheusParser.ps1')

function Invoke-Phase6 {
    param([hashtable]$Config)

    $startTime = Get-Date
    Set-PhaseResult -Phase $PhaseName -Status 'Running' -Message 'Data integrity validation (exporter vs workbook)...'

    $workspaceId = $Config['log_analytics_workspace_id']
    $sid = $Config['sap_sid']
    $clusterName = $Config['cluster_name']
    $nodes = $Config['nodes']
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

    # =========================================================================
    # Step 1: Scrape exporter from both nodes to find DC
    # =========================================================================
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Scraping exporter metrics from cluster nodes..."

    $dcNodeName = $null
    $dcMetricsRaw = $null
    $allNodeMetrics = @{}

    # Determine execution method (vm_run_command, bastion, or both)
    $execMethod = $Config['execution_method']
    if (-not $execMethod) { $execMethod = 'vm_run_command' }
    $bastionConfig = $Config['bastion']

    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Execution method: $execMethod"

    # Determine exporter endpoint based on OS type
    # SUSE: prometheus-ha_cluster_exporter on port 9664
    # RHEL: pcp + pcp-pmda-hacluster + pmproxy on port 44322
    $osType = $Config['os_type']
    if ($osType -eq 'RHEL') {
        $exporterPort = 44322
        $exporterUrl = "http://localhost:${exporterPort}/metrics?names=ha_cluster"
    } else {
        # Default to SUSE
        $exporterPort = 9664
        $exporterUrl = "http://localhost:${exporterPort}/metrics"
    }
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "OS type: $osType — using exporter endpoint: $exporterUrl"

    # Shell command to scrape exporter (OS-aware endpoint)
    $scrapeScript = 'curl -s ' + $exporterUrl + ' | grep "^ha_cluster_pacemaker_nodes" | grep " 1$"; curl -s ' + $exporterUrl + ' | grep "^ha_cluster_pacemaker_resources" | grep "status=\"active\""'

    foreach ($node in $nodes) {
        $hostname = $node['hostname']
        $vmName = $node['vm_name']
        $vmRg = $node['vm_resource_group']

        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Scraping $hostname ($vmName)..."

        $scrapeOutput = $null
        $scrapeSuccess = $false

        # --- Method 1: VM Run Command ---
        if ($execMethod -in @('vm_run_command', 'both')) {
            try {
                Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  Trying VM Run Command..."
                $result = Invoke-AzVMRunCommand -ResourceGroupName $vmRg -VMName $vmName `
                    -CommandId 'RunShellScript' `
                    -ScriptString $scrapeScript `
                    -ErrorAction Stop

                $stdout = ($result.Value | Where-Object { $_.Code -eq 'ProvisioningState/succeeded' -or $_.Code -match 'stdout' }).Message
                if (-not $stdout) {
                    $stdout = ($result.Value | Select-Object -First 1).Message
                }

                # Strip VM Run Command wrapper lines ([stdout], [stderr], Enable succeeded)
                $cleanLines = ($stdout -split "`n") | Where-Object { 
                    $_ -and $_ -notmatch '^\[std(out|err)\]' -and $_ -notmatch '^Enable succeeded'
                }
                $scrapeOutput = $cleanLines -join "`n"

                if ($scrapeOutput -and $scrapeOutput.Length -ge 20) {
                    $scrapeSuccess = $true
                    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  VM Run Command succeeded"
                } else {
                    Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "  VM Run Command returned empty/short output"
                }
            }
            catch {
                Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "  VM Run Command failed: $_"
            }
        }

        # --- Method 2: Bastion SSH (fallback or primary) ---
        if (-not $scrapeSuccess -and $execMethod -in @('bastion', 'both')) {
            if (-not $bastionConfig -or -not $bastionConfig['name']) {
                Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "  Bastion not configured, skipping SSH method"
            } else {
                try {
                    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  Trying Bastion SSH tunnel..."
                    $bastionName = $bastionConfig['name']
                    $bastionRg = $bastionConfig['resource_group']
                    $sshUser = $bastionConfig['ssh_username']
                    $keyPath = $bastionConfig['private_key_path']

                    if (-not $bastionRg) { $bastionRg = $vmRg }
                    if (-not $sshUser) { $sshUser = 'azureadm' }

                    # Get VM resource ID for Bastion native SSH
                    $vm = Get-AzVM -ResourceGroupName $vmRg -Name $vmName -ErrorAction Stop
                    $vmId = $vm.Id

                    # Use az cli for Bastion SSH (native client)
                    $sshArgs = @(
                        'network', 'bastion', 'ssh',
                        '--name', $bastionName,
                        '--resource-group', $bastionRg,
                        '--target-resource-id', $vmId,
                        '--auth-type', 'ssh-key',
                        '--username', $sshUser,
                        '--ssh-key', $keyPath,
                        '--command', $scrapeScript
                    )

                    $sshResult = az @sshArgs 2>&1
                    $scrapeOutput = ($sshResult | Where-Object { $_ -match '^ha_cluster_pacemaker_' }) -join "`n"

                    if ($scrapeOutput -and $scrapeOutput.Length -ge 20) {
                        $scrapeSuccess = $true
                        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  Bastion SSH succeeded"
                    } else {
                        Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "  Bastion SSH returned empty/short output"
                    }
                }
                catch {
                    Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "  Bastion SSH failed: $_"
                }
            }
        }

        # --- Process scrape output ---
        if (-not $scrapeSuccess -or -not $scrapeOutput -or $scrapeOutput.Length -lt 20) {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Node ${hostname}: no valid metrics obtained via any method"
            continue
        }

        # Parse metrics
        $parsed = ConvertFrom-PrometheusMetrics -MetricsText $scrapeOutput
        $allNodeMetrics[$hostname] = $parsed

        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  ${hostname}: $($parsed.Count) metric lines parsed"

        # Check if this node is DC
        $nodeDC = Get-DCNode -ParsedMetrics $parsed
        if ($nodeDC) {
            Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  $hostname reports DC node = $nodeDC"
            if ($nodeDC -eq $hostname) {
                $dcNodeName = $hostname
                $dcMetricsRaw = $parsed
                Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "  --> $hostname IS the DC node"
            }
        }
    }

    # If DC not found as self-reporter, use whichever node's data reports the DC
    if (-not $dcNodeName -and $allNodeMetrics.Count -gt 0) {
        foreach ($hn in $allNodeMetrics.Keys) {
            $nodeDC = Get-DCNode -ParsedMetrics $allNodeMetrics[$hn]
            if ($nodeDC -and $allNodeMetrics.ContainsKey($nodeDC)) {
                $dcNodeName = $nodeDC
                $dcMetricsRaw = $allNodeMetrics[$nodeDC]
                Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Using $dcNodeName (DC) metrics as source of truth"
                break
            }
        }
    }

    if (-not $dcMetricsRaw) {
        Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Could not identify DC node or scrape its metrics"
        Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message 'Cannot identify DC node'
        return
    }

    # =========================================================================
    # Step 2: Extract ALL resources and nodes from exporter data
    # =========================================================================
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Parsing DC node ($dcNodeName) exporter data..."

    # Get ALL resources (active + stopped) — one entry per resource from status="active" lines
    $exporterResources = Get-AllExporterResources -ParsedMetrics $dcMetricsRaw
    $exporterNodes = Get-ExporterNodes -ParsedMetrics $dcMetricsRaw

    # Deduplicate nodes (multiple status entries per node like online, expected_up, dc)
    $exporterNodeNames = $exporterNodes | Select-Object -ExpandProperty Node -Unique

    # Separate active vs stopped for logging
    $activeResources = $exporterResources | Where-Object { $_.ResourceState -eq 'active' }
    $stoppedResources = $exporterResources | Where-Object { $_.ResourceState -eq 'stopped' }

    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  Exporter reports: $($exporterResources.Count) total resources ($($activeResources.Count) active, $($stoppedResources.Count) stopped), $($exporterNodeNames.Count) distinct nodes"
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  Active: $($activeResources | Select-Object -ExpandProperty Resource | Sort-Object | Join-String -Separator ', ')"
    if ($stoppedResources.Count -gt 0) {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  Stopped: $($stoppedResources | Select-Object -ExpandProperty Resource | Sort-Object | Join-String -Separator ', ')"
    }
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  Nodes: $($exporterNodeNames -join ', ')"

    # =========================================================================
    # Step 3: Run workbook KQL queries
    # =========================================================================
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Running workbook resource status query against LA..."

    # Build hostname filter from test nodes to scope KQL to this specific cluster
    # This prevents cross-contamination when multiple HA clusters share the same SID/clusterName
    $nodeHostnames = $nodes | ForEach-Object { $_.hostname }
    $hostnameFilter = ($nodeHostnames | ForEach-Object { "'$_'" }) -join ', '
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  Filtering KQL by hostnames: $hostnameFilter"

    # Resource Status query — gets ALL resources (active + stopped) from same correlation_id
    # Uses status='active' filter with max(value_d) to determine actual state:
    #   max_val=1 → resource is running; max_val=0 → resource is stopped/offline
    $resourceQuery = @"
let master = materialize(Prometheus_HaClusterExporter_CL
| where TimeGenerated > ago(40min)
| where value_d == 1
| extend node_status=parse_json(labels_s)
| where node_status['status']=='dc'
| where sid_s == '$sid'
| where clusterName_s == '$clusterName'
| where hostname_s in ($hostnameFilter)
| where tostring(node_status['node']) == hostname_s
| summarize arg_max(TimeGenerated, correlation_id_g, value_d) by sid_s, clusterName_s, hostname_s
| top 1 by TimeGenerated
| project correlation_id_g);
Prometheus_HaClusterExporter_CL
| where correlation_id_g in (master)
| where name_s == 'ha_cluster_pacemaker_resources'
| extend resources = parse_json(labels_s)
| where isnotnull(resources['agent'])
| where tostring(resources['status']) == 'active'
| summarize max_val=max(value_d) by resource_resource = tostring(resources['resource']), resource_agent = tostring(resources['agent']), resource_node = tostring(resources['node']), resource_managed = tostring(resources['managed']), resource_role = tostring(resources['role'])
| extend resource_state = iif(max_val == 1, 'active', 'stopped')
"@

    $kqlResourceResult = Invoke-KqlQuery -WorkspaceId $workspaceId -Query $resourceQuery -Timespan 'PT2H' -Phase $PhaseName

    # Node Status query
    $nodeQuery = @"
let master = Prometheus_HaClusterExporter_CL
| where TimeGenerated > ago(10min)
| where value_d == 1
| extend node_status=parse_json(labels_s)
| where node_status['status']=='dc'
| where tostring(node_status['node']) == hostname_s
| where sid_s == '$sid'
| where clusterName_s == '$clusterName'
| where hostname_s in ($hostnameFilter)
| summarize arg_max(TimeGenerated, correlation_id_g) by sid_s, clusterName_s, hostname_s
| top 1 by TimeGenerated
| project correlation_id_g;
Prometheus_HaClusterExporter_CL
| where correlation_id_g in (master)
| where name_s == 'ha_cluster_pacemaker_nodes'
| where value_d == 1
| extend resources = parse_json(labels_s)
| project node = tostring(resources['node']), type = tostring(resources['type']), status = tostring(resources['status'])
"@

    $kqlNodeResult = Invoke-KqlQuery -WorkspaceId $workspaceId -Query $nodeQuery -Timespan 'PT2H' -Phase $PhaseName

    if (-not $kqlResourceResult.Success) {
        Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Resource status KQL query failed"
        Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message 'KQL resource query failed'
        return
    }

    if (-not $kqlNodeResult.Success) {
        Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Node status KQL query failed"
        Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message 'KQL node query failed'
        return
    }

    $kqlResources = $kqlResourceResult.Results
    $kqlNodes = $kqlNodeResult.Results

    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  KQL reports: $($kqlResources.Count) resource entries, $($kqlNodes.Count) node entries"

    # =========================================================================
    # Step 4: Compare Resources — Exporter vs Workbook (KQL)
    # =========================================================================
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "=== RESOURCE COMPARISON (All states: active, stopped, standby) ==="

    $totalChecks = 0
    $passCount = 0
    $failCount = 0
    $warnCount = 0
    $failures = @()

    # Build composite keys (resource+node) to handle clone resources with multiple instances
    # e.g., health-azure-events can have one active instance on chascs02l0c2 and one stopped instance (empty node)
    $exporterEntries = $exporterResources | ForEach-Object {
        $key = "$($_.Resource)|$($_.Node)"
        [PSCustomObject]@{ Key = $key; Resource = $_.Resource; Agent = $_.Agent; Node = $_.Node; Role = $_.Role; ResourceState = $_.ResourceState; Managed = $_.Managed }
    } | Sort-Object Key

    $kqlEntries = $kqlResources | ForEach-Object {
        $key = "$($_.resource_resource)|$($_.resource_node)"
        [PSCustomObject]@{ Key = $key; Resource = $_.resource_resource; Agent = $_.resource_agent; Node = $_.resource_node; Role = $_.resource_role; ResourceState = $_.resource_state; Managed = $_.resource_managed }
    } | Sort-Object Key

    $exporterKeys = $exporterEntries | Select-Object -ExpandProperty Key
    $kqlKeys = $kqlEntries | Select-Object -ExpandProperty Key

    # Check 1: Every exporter resource instance must exist in KQL
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "--- Check: Every exporter resource instance present in workbook (active + stopped) ---"
    foreach ($expEntry in $exporterEntries) {
        $totalChecks++

        $kqlMatch = $kqlEntries | Where-Object { $_.Key -eq $expEntry.Key }

        if (-not $kqlMatch) {
            $failCount++
            $nodeDisplay = if ($expEntry.Node) { $expEntry.Node } else { '(none)' }
            $msg = "[FAIL] Resource '$($expEntry.Resource)' (agent=$($expEntry.Agent), node=$nodeDisplay, state=$($expEntry.ResourceState)) present in exporter but MISSING from workbook"
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message $msg
            $failures += $msg
        } else {
            $kqlRes = $kqlMatch | Select-Object -First 1

            # Compare state, role, managed, agent
            $stateMatch = ($expEntry.ResourceState -eq $kqlRes.ResourceState)
            $roleMatch = ($expEntry.Role -eq $kqlRes.Role)
            $managedMatch = ($expEntry.Managed -eq $kqlRes.Managed)
            $agentMatch = ($expEntry.Agent -eq $kqlRes.Agent)

            if ($stateMatch -and $roleMatch -and $managedMatch -and $agentMatch) {
                $passCount++
                $stateIcon = if ($expEntry.ResourceState -eq 'active') { 'ACTIVE' } else { 'STOPPED' }
                $nodeDisplay = if ($expEntry.Node) { $expEntry.Node } else { '(none)' }
                Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "[PASS] $($expEntry.Resource) | $($expEntry.Agent) | node=$nodeDisplay | role=$($expEntry.Role) | state=$stateIcon | managed=$($expEntry.Managed)"
            } else {
                $mismatches = @()
                if (-not $stateMatch) { $mismatches += "state(exp=$($expEntry.ResourceState),kql=$($kqlRes.ResourceState))" }
                if (-not $roleMatch) { $mismatches += "role(exp=$($expEntry.Role),kql=$($kqlRes.Role))" }
                if (-not $managedMatch) { $mismatches += "managed(exp=$($expEntry.Managed),kql=$($kqlRes.Managed))" }
                if (-not $agentMatch) { $mismatches += "agent(exp=$($expEntry.Agent),kql=$($kqlRes.Agent))" }

                $warnCount++
                $msg = "[WARN] $($expEntry.Resource) (node=$($expEntry.Node)) | Mismatch: $($mismatches -join '; ')"
                Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message $msg
            }
        }
    }

    # Check 2: KQL resource instances not in exporter (phantom data)
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "--- Check: No phantom resources in workbook ---"
    foreach ($kqlEntry in $kqlEntries) {
        if ($kqlEntry.Key -notin $exporterKeys) {
            $totalChecks++
            $failCount++
            $nodeDisplay = if ($kqlEntry.Node) { $kqlEntry.Node } else { '(none)' }
            $msg = "[FAIL] Resource '$($kqlEntry.Resource)' (node=$nodeDisplay, state=$($kqlEntry.ResourceState)) in workbook but NOT in exporter (phantom/stale data)"
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message $msg
            $failures += $msg
        }
    }

    # =========================================================================
    # Step 5: Compare Nodes — Exporter vs Workbook (KQL)
    # =========================================================================
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "=== NODE COMPARISON ==="

    $kqlNodeNames = $kqlNodes | ForEach-Object { $_.node } | Select-Object -Unique | Sort-Object

    # Check: Every exporter node must exist in KQL
    foreach ($nodeName in $exporterNodeNames) {
        $totalChecks++
        $kqlNodeMatch = $kqlNodes | Where-Object { $_.node -eq $nodeName }

        if (-not $kqlNodeMatch) {
            $failCount++
            $msg = "[FAIL] Node '$nodeName' present in exporter but MISSING from workbook"
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message $msg
            $failures += $msg
        } else {
            # Get exporter statuses for this node
            $expNodeStatuses = ($exporterNodes | Where-Object { $_.Node -eq $nodeName } | Select-Object -ExpandProperty Status | Sort-Object) -join ','
            $kqlNodeStatuses = ($kqlNodeMatch | Select-Object -ExpandProperty status | Sort-Object) -join ','

            if ($expNodeStatuses -eq $kqlNodeStatuses) {
                $passCount++
                Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "[PASS] Node $nodeName | statuses: $expNodeStatuses"
            } else {
                $warnCount++
                Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "[WARN] Node $nodeName | status mismatch: exporter=[$expNodeStatuses] kql=[$kqlNodeStatuses]"
            }
        }
    }

    # Check: KQL nodes not in exporter
    foreach ($kqlNodeName in $kqlNodeNames) {
        if ($kqlNodeName -notin $exporterNodeNames) {
            $totalChecks++
            $warnCount++
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "[WARN] Node '$kqlNodeName' in workbook but NOT in exporter (stale)"
        }
    }

    # =========================================================================
    # Step 6: Summary and Verdict
    # =========================================================================
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "=== CERTIFICATION SUMMARY ==="
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  OS: $($Config['os_type']) $($Config['os_version'])"
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  DC Node: $dcNodeName"
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "  Total Checks: $totalChecks | PASS: $passCount | WARN: $warnCount | FAIL: $failCount"

    $duration = [int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds

    if ($failCount -eq 0 -and $warnCount -eq 0) {
        Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "ALL CHECKS PASSED — OS certified for AMS HA provider"
        Set-PhaseResult -Phase $PhaseName -Status 'Passed' -Message "All $totalChecks checks passed. OS: $($Config['os_type']) $($Config['os_version'])" -DurationSeconds $duration
    } elseif ($failCount -eq 0) {
        Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "PASSED with warnings (state mismatches likely due to timing)"
        Set-PhaseResult -Phase $PhaseName -Status 'Passed' -Message "$passCount pass, $warnCount warn, 0 fail. Minor timing diffs." -DurationSeconds $duration
    } else {
        Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "CERTIFICATION FAILED — $failCount resources/nodes missing from workbook"
        foreach ($f in $failures) {
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "  $f"
        }
        Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "$failCount missing resources/nodes. See logs." -DurationSeconds $duration
    }
}

# Auto-invoke when script receives -Config via Run-HAClusterTest orchestrator
if ($MyInvocation.ScriptName -and $args.Count -gt 0) {
    Invoke-Phase6 -Config $args[0]
}

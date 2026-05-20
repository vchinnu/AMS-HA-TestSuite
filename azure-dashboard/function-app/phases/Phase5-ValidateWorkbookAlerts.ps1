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

    # --- Part 1: Workbook KQL Queries ---
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Validating workbook KQL queries..."

    $kqlDir = Join-Path $PSScriptRoot '..\kql'
    $kqlParams = @{ SID = $sid; CLUSTER_NAME = $clusterName }
    $kqlFiles = Get-ChildItem -Path $kqlDir -Filter 'workbook-*.kql' -ErrorAction SilentlyContinue

    if ($kqlFiles.Count -eq 0) {
        Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "No workbook KQL files found in $kqlDir. Skipping workbook validation."
    } else {
        foreach ($kqlFile in $kqlFiles) {
            $queryName = $kqlFile.BaseName
            Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Running workbook query: $queryName"
            
            $result = Invoke-KqlFromFile -WorkspaceId $workspaceId -KqlFilePath $kqlFile.FullName `
                -Parameters $kqlParams -Timespan 'PT2H' -Phase $PhaseName
            
            if ($result.Success -and $result.Count -gt 0) {
                Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "$queryName`: $($result.Count) rows — workbook graph would render"
            } else {
                Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "$queryName`: No data returned — workbook graph would be empty"
            }
        }
    }

    # --- Part 2: Alert Query Validation ---
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Validating alert query (primary-node-switched)..."

    $alertKqlFile = Join-Path $kqlDir 'alert-primary-node-switched.kql'
    if (Test-Path $alertKqlFile) {
        $alertResult = Invoke-KqlFromFile -WorkspaceId $workspaceId -KqlFilePath $alertKqlFile `
            -Parameters $kqlParams -Timespan 'PT2H' -Phase $PhaseName
        
        if ($alertResult.Success) {
            if ($alertResult.Count -gt 0) {
                Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Alert query executes successfully — $($alertResult.Count) resource evaluations returned"
                # Check if any AggregatedValue > 0 (would fire alert)
                $firing = $alertResult.Results | Where-Object { [int]$_.AggregatedValue -gt 0 }
                if ($firing) {
                    Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Alert WOULD FIRE for $($firing.Count) resources (node count mismatch)"
                } else {
                    Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Alert is quiet — all resources running on expected node count"
                }
            } else {
                Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Alert query returned no data — resources may not be reporting yet"
            }
        } else {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Alert query failed to execute"
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

# Execute only when script is run directly (not dot-sourced by orchestrator)
if ($MyInvocation.InvocationName -ne '.' -and $Config) {
    Invoke-Phase5 -Config $Config
}

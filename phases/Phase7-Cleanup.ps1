# ============================================================================
# Phase7-Cleanup.ps1 - Remove test resources (with user consent)
# ============================================================================
# Cleanup order (reverse of creation):
#   1. Delete provider instances
#   2. Delete AMS Monitor
#   3. Remove VNet peering (if created)
#   4. Remove subnet
#   5. Delete resource group (optional, requires explicit consent)
# ============================================================================


$PhaseName = 'Phase7-Cleanup'
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot '..\helpers\Common.ps1')

function Invoke-Phase7 {
    param([hashtable]$Config)

    $startTime = Get-Date
    Set-PhaseResult -Phase $PhaseName -Status 'Running' -Message 'Cleaning up test resources...'

    $rgName = $Config['resource_group']
    $monitorName = $Config['ams_monitor_name']
    $subscriptionId = $Config['subscription_id']
    $autoConfirm = $Config['auto_confirm_destructive'] -eq $true

    if (-not $autoConfirm) {
        $consentGranted = Request-UserConsent -Action "Delete ALL test resources (providers, monitor, subnet, peering) in RG: $rgName" -Phase $PhaseName
        if (-not $consentGranted) {
            Set-PhaseResult -Phase $PhaseName -Status 'Skipped' -Message 'User declined cleanup'
            return
        }
    }

    # --- Step 1: Delete providers ---
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Deleting HA cluster providers..."
    try {
        $providers = Get-AzWorkloadsProviderInstance -ResourceGroupName $rgName -MonitorName $monitorName -ErrorAction SilentlyContinue
        $haProviders = $providers | Where-Object { $_.Name -match '-HA-' }
        
        foreach ($provider in $haProviders) {
            Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Deleting provider: $($provider.Name)"
            Remove-AzWorkloadsProviderInstance -MonitorName $monitorName -Name $provider.Name `
                -ResourceGroupName $rgName -SubscriptionId $subscriptionId | Out-Null
        }
        
        if ($haProviders.Count -gt 0) {
            Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Deleted $($haProviders.Count) providers"
            # Wait for deletion
            Start-Sleep -Seconds 30
        }
    }
    catch {
        Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Error deleting providers: $_"
    }

    # --- Step 2: Delete AMS Monitor ---
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Deleting AMS Monitor: $monitorName"
    try {
        Remove-AzWorkloadsMonitor -Name $monitorName -ResourceGroupName $rgName `
            -SubscriptionId $subscriptionId | Out-Null
        Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "AMS Monitor deleted"
        # Wait for async deletion
        Start-Sleep -Seconds 60
    }
    catch {
        Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Error deleting monitor: $_"
    }

    # --- Step 3: Remove VNet peering ---
    $clusterVnet = $Config['cluster_vnet']
    if ($clusterVnet -and $clusterVnet['name']) {
        $amsVnetRg = if ($Config['vnet']['resource_group']) { $Config['vnet']['resource_group'] } else { $rgName }
        $amsVnetName = $Config['vnet']['name']
        $clusterVnetRg = $clusterVnet['resource_group']
        $clusterVnetName = $clusterVnet['name']

        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Removing VNet peering..."
        try {
            Remove-AzVirtualNetworkPeering -VirtualNetworkName $amsVnetName `
                -ResourceGroupName $amsVnetRg -Name "ams-to-cluster" -Force -ErrorAction SilentlyContinue
            Remove-AzVirtualNetworkPeering -VirtualNetworkName $clusterVnetName `
                -ResourceGroupName $clusterVnetRg -Name "cluster-to-ams" -Force -ErrorAction SilentlyContinue
            Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "VNet peering removed"
        }
        catch {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Error removing peering (may not have existed): $_"
        }
    }

    # --- Step 4: Remove subnet ---
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Removing AMS subnet..."
    try {
        $vnetRg = if ($Config['vnet']['resource_group']) { $Config['vnet']['resource_group'] } else { $rgName }
        $vnet = Get-AzVirtualNetwork -Name $Config['vnet']['name'] -ResourceGroupName $vnetRg -ErrorAction SilentlyContinue
        if ($vnet) {
            $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $Config['subnet']['name'] }
            if ($subnet) {
                Remove-AzVirtualNetworkSubnetConfig -Name $Config['subnet']['name'] -VirtualNetwork $vnet | Out-Null
                $vnet | Set-AzVirtualNetwork | Out-Null
                Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Subnet removed: $($Config['subnet']['name'])"
            }
        }
    }
    catch {
        Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Error removing subnet: $_"
    }

    # --- Step 5: Resource group (only if it was created by us and user confirms) ---
    if (-not $autoConfirm) {
        $deleteRg = Request-UserConsent -Action "DELETE entire resource group '$rgName'? (This removes ALL resources in it)" -Phase $PhaseName
        if ($deleteRg) {
            Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Deleting resource group: $rgName"
            Remove-AzResourceGroup -Name $rgName -Force | Out-Null
            Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Resource group deleted: $rgName"
        } else {
            Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Resource group preserved: $rgName"
        }
    }

    $duration = [int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds
    Set-PhaseResult -Phase $PhaseName -Status 'Passed' -Message "Cleanup completed" -DurationSeconds $duration
}

# Only auto-invoke when run directly (not dot-sourced by orchestrator)
if ($MyInvocation.InvocationName -ne '.') {
    if ($Config) { Invoke-Phase7 -Config $Config }
}

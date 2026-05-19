# ============================================================================
# Phase3-CreateProviders.ps1 - Create HA Cluster provider for each node
# ============================================================================
# Creates a PrometheusHaCluster provider instance per cluster node using:
#   New-AzWorkloadsProviderPrometheusHaClusterInstanceObject
#   New-AzWorkloadsProviderInstance
#
# SUSE endpoint: http://<ip>:9664/metrics
# RHEL endpoint: http://<ip>:44322/metrics?names=ha_cluster
# ============================================================================


$PhaseName = 'Phase3-CreateProviders'
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot '..\helpers\Common.ps1')

function Get-PrometheusUrl {
    param([string]$IpAddress, [string]$OsType)
    
    if ($OsType -eq 'SUSE') {
        return "http://${IpAddress}:9664/metrics"
    } else {
        return "http://${IpAddress}:44322/metrics?names=ha_cluster"
    }
}

function Invoke-Phase3 {
    param([hashtable]$Config)

    $startTime = Get-Date
    Set-PhaseResult -Phase $PhaseName -Status 'Running' -Message 'Creating HA cluster providers...'

    $rgName = $Config['resource_group']
    $monitorName = $Config['ams_monitor_name']
    $subscriptionId = $Config['subscription_id']
    $osType = $Config['os_type']
    $sid = $Config['sap_sid']
    $clusterName = $Config['cluster_name']
    $nodes = $Config['nodes']

    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Creating providers for $($nodes.Count) nodes (OS: $osType, SID: $sid)"

    # Check existing providers
    $existingProviders = Get-AzWorkloadsProviderInstance -ResourceGroupName $rgName -MonitorName $monitorName -ErrorAction SilentlyContinue

    $allSuccess = $true
    $createdCount = 0

    foreach ($node in $nodes) {
        $hostname = $node['hostname']
        $ipAddress = $node['ip_address']
        # Provider name: "HA-<SID>-<full_hostname>" — use full hostname to ensure uniqueness
        $providerName = "HA-$sid-$hostname"
        $prometheusUrl = Get-PrometheusUrl -IpAddress $ipAddress -OsType $osType

        # Check if provider already exists
        $existing = $existingProviders | Where-Object { $_.Name -eq $providerName }
        if ($existing) {
            Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Provider already exists: $providerName (state: $($existing.ProvisioningState))"
            if ($existing.ProvisioningState -eq 'Succeeded') {
                $createdCount++
                continue
            }
        }

        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Creating provider: $providerName -> $prometheusUrl"

        try {
            # Create provider settings object
            $providerSetting = New-AzWorkloadsProviderPrometheusHaClusterInstanceObject `
                -ClusterName $clusterName `
                -Hostname $hostname `
                -PrometheusUrl $prometheusUrl `
                -Sid $sid `
                -SslPreference 'Disabled'

            # Create the provider instance
            New-AzWorkloadsProviderInstance -MonitorName $monitorName `
                -Name $providerName -ResourceGroupName $rgName `
                -SubscriptionId $subscriptionId -ProviderSetting $providerSetting | Out-Null

            Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Provider created: $providerName"
            $createdCount++
        }
        catch {
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Failed to create provider for $hostname`: $_"
            $allSuccess = $false
        }
    }

    # Wait for all providers to provision
    if ($createdCount -gt 0) {
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Waiting for providers to provision..."
        $maxWait = 600  # 10 min
        $elapsed = 0
        $allProvisioned = $false

        while ($elapsed -lt $maxWait) {
            Start-Sleep -Seconds 20
            $elapsed += 20

            $providers = Get-AzWorkloadsProviderInstance -ResourceGroupName $rgName -MonitorName $monitorName -ErrorAction SilentlyContinue
            $haProviders = $providers | Where-Object { $_.Name -match '^HA-' }
            
            $succeeded = ($haProviders | Where-Object { $_.ProvisioningState -eq 'Succeeded' }).Count
            $failed = ($haProviders | Where-Object { $_.ProvisioningState -eq 'Failed' }).Count
            
            Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Provisioning: $succeeded/$($nodes.Count) succeeded, $failed failed (${elapsed}s elapsed)"

            if ($failed -gt 0) {
                foreach ($fp in ($haProviders | Where-Object { $_.ProvisioningState -eq 'Failed' })) {
                    Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Provider FAILED: $($fp.Name)"
                }
                $allSuccess = $false
                break
            }

            if ($succeeded -ge $nodes.Count) {
                $allProvisioned = $true
                break
            }
        }

        if (-not $allProvisioned -and $allSuccess) {
            Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Timeout waiting for all providers to provision"
            $allSuccess = $false
        }
    }

    $duration = [int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds
    if ($allSuccess) {
        Set-PhaseResult -Phase $PhaseName -Status 'Passed' -Message "All $createdCount providers created and provisioned" -DurationSeconds $duration
    } else {
        Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message "Provider creation/provisioning had failures" -DurationSeconds $duration
    }
}

# Only auto-invoke when run directly (not dot-sourced by orchestrator)
if ($MyInvocation.InvocationName -ne '.') {
    if ($Config) { Invoke-Phase3 -Config $Config }
}

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
        $ipAddress = if ($node['ip_address']) { $node['ip_address'].Trim() } else { '' }

        # Validate IP address is present
        if (-not $ipAddress -or $ipAddress -eq '') {
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Node '$hostname' has no IP address configured. Please resolve the VM IP from the resource ID before starting the test."
            $allSuccess = $false
            continue
        }

        # Provider name: "HA-<SID>-<full_hostname>" — use full hostname to ensure uniqueness
        $providerName = "HA-$sid-$hostname"
        $prometheusUrl = Get-PrometheusUrl -IpAddress $ipAddress -OsType $osType

        # Check if provider already exists
        $existing = $existingProviders | Where-Object { $_.Name -eq $providerName }
        if ($existing) {
            # Verify the existing provider's cluster name matches the current config
            # Provider settings (clusterName) are baked at creation — if different, must recreate
            $needsRecreate = $false
            try {
                $detail = Get-AzWorkloadsProviderInstance -ResourceGroupName $rgName -MonitorName $monitorName -Name $providerName -ErrorAction SilentlyContinue
                $existingClusterName = $detail.ProviderSetting.ClusterName
                if ($existingClusterName -and $existingClusterName -ne $clusterName) {
                    Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Provider '$providerName' has clusterName='$existingClusterName' but config says '$clusterName'. Recreating..."
                    $needsRecreate = $true
                }
            } catch {
                Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Could not read provider settings for '$providerName': $_"
            }

            if ($needsRecreate) {
                try {
                    Remove-AzWorkloadsProviderInstance -ResourceGroupName $rgName -MonitorName $monitorName -Name $providerName -ErrorAction Stop | Out-Null
                    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Deleted stale provider: $providerName"
                } catch {
                    Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Failed to delete provider '$providerName': $_"
                    $allSuccess = $false
                    continue
                }
            } elseif ($existing.ProvisioningState -eq 'Succeeded') {
                Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Provider already exists: $providerName (state: $($existing.ProvisioningState))"
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
                    # Extract detailed error from the provider object
                    $errorDetail = ''
                    try {
                        $detail = Get-AzWorkloadsProviderInstance -ResourceGroupName $rgName -MonitorName $monitorName -Name $fp.Name -ErrorAction SilentlyContinue
                        if ($detail.ProvisioningError) {
                            $errorDetail = $detail.ProvisioningError
                        } elseif ($detail.Error) {
                            $errorDetail = $detail.Error | ConvertTo-Json -Depth 2 -Compress
                        } elseif ($detail.Property.Error) {
                            $errorDetail = $detail.Property.Error | ConvertTo-Json -Depth 2 -Compress
                        }
                    } catch { }
                    if (-not $errorDetail) { $errorDetail = 'No additional error details available from Azure' }
                    Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Provider FAILED: $($fp.Name) — $errorDetail"
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
        # Collect failure summary from logs
        $failedLogs = Get-LogEntries | Where-Object { $_.Phase -eq $PhaseName -and $_.Level -eq 'ERROR' } | Select-Object -Last 3
        $failSummary = ($failedLogs | ForEach-Object { $_.Message }) -join '; '
        if (-not $failSummary) { $failSummary = 'Provider creation/provisioning had failures' }
        Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message $failSummary -DurationSeconds $duration
    }
}

# Execute only when script is run directly (not dot-sourced by orchestrator)
if ($MyInvocation.InvocationName -ne '.' -and $Config) {
    Invoke-Phase3 -Config $Config
}

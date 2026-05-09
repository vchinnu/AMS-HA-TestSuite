# ============================================================================
# Phase1-InstallExporter.ps1 - Install HA Cluster Exporter on each node
# ============================================================================
# Supports:
#   SUSE  → prometheus-ha_cluster_exporter (port 9664)
#   RHEL  → pcp + pcp-pmda-hacluster + pmproxy (port 44322)
# Execution: Azure VM Run Command (primary) or Azure Bastion SSH (fallback)
# ============================================================================


$PhaseName = 'Phase1-InstallExporter'
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot '..\helpers\Common.ps1')

function Get-InstallScript {
    param([string]$OsType)

    if ($OsType -eq 'SUSE') {
        return @'
#!/bin/bash
echo "=== Installing HA Cluster Exporter (SUSE) ==="

# Install prometheus-ha_cluster_exporter (suppress verbose output to avoid 4KB truncation)
if rpm -q prometheus-ha_cluster_exporter >/dev/null 2>&1; then
    echo "INFO: prometheus-ha_cluster_exporter already installed"
else
    echo "INFO: Installing prometheus-ha_cluster_exporter via zypper..."
    sudo zypper install -y prometheus-ha_cluster_exporter > /dev/null 2>&1
    echo "INFO: zypper install completed"
fi

# Enable and start the service
sudo systemctl enable prometheus-ha_cluster_exporter 2>/dev/null || true
sudo systemctl restart prometheus-ha_cluster_exporter 2>/dev/null || true
echo "INFO: Service enabled and restarted"

# Check service status
SVC_STATUS=$(sudo systemctl is-active prometheus-ha_cluster_exporter 2>/dev/null || echo "unknown")
echo "INFO: Service status: $SVC_STATUS"

# Verify metrics endpoint
echo "=== Verifying metrics endpoint on port 9664 ==="
sleep 5
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9664/metrics 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    echo "SUCCESS: Metrics endpoint responding (HTTP $HTTP_CODE)"
    METRIC_COUNT=$(curl -s http://localhost:9664/metrics 2>/dev/null | grep -c "^ha_cluster_" || echo "0")
    echo "SUCCESS: Found $METRIC_COUNT ha_cluster metrics"
else
    echo "WARNING: Metrics endpoint returned HTTP $HTTP_CODE"
    sudo systemctl status prometheus-ha_cluster_exporter --no-pager 2>&1 | tail -10 || true
    echo "INFO: Listening ports:"
    ss -tlnp | grep -E '9664|ha_cluster' || echo "No listener on 9664"
fi
echo "=== Phase 1 Complete (SUSE) ==="
'@
    }
    else {
        # RHEL
        return @'
#!/bin/bash
echo "=== Installing HA Cluster Exporter (RHEL via PCP) ==="

# Install PCP and hacluster PMDA (suppress verbose output to avoid 4KB truncation)
if rpm -q pcp pcp-pmda-hacluster >/dev/null 2>&1; then
    echo "INFO: pcp and pcp-pmda-hacluster already installed"
else
    echo "INFO: Installing pcp and pcp-pmda-hacluster via yum..."
    sudo yum install -y pcp pcp-pmda-hacluster > /dev/null 2>&1
    echo "INFO: yum install completed"
fi

# Enable and start PCP collector
sudo systemctl enable pmcd 2>/dev/null || true
sudo systemctl start pmcd

# Install hacluster PMDA
echo "INFO: Installing hacluster PMDA..."
PCP_PMDAS_DIR=$(find /var/lib/pcp/pmdas -name "hacluster" -type d 2>/dev/null | head -1)
if [ -z "$PCP_PMDAS_DIR" ]; then
    PCP_PMDAS_DIR="/var/lib/pcp/pmdas/hacluster"
fi
if [ -d "$PCP_PMDAS_DIR" ]; then
    cd "$PCP_PMDAS_DIR"
    echo | sudo ./Install > /dev/null 2>&1
    echo "INFO: hacluster PMDA installed"
else
    echo "ERROR: hacluster PMDA directory not found"
    exit 1
fi

# Enable and start pmproxy
sudo systemctl enable pmproxy 2>/dev/null || true
sudo systemctl start pmproxy

# Verify metrics endpoint
echo "=== Verifying metrics endpoint on port 44322 ==="
sleep 5
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:44322/metrics?names=ha_cluster" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    echo "SUCCESS: Metrics endpoint responding (HTTP $HTTP_CODE)"
    METRIC_COUNT=$(curl -s "http://localhost:44322/metrics?names=ha_cluster" 2>/dev/null | grep -c "^ha_cluster_" || echo "0")
    echo "SUCCESS: Found $METRIC_COUNT ha_cluster metrics"
else
    echo "WARNING: Metrics endpoint returned HTTP $HTTP_CODE"
    sudo systemctl status pmproxy --no-pager 2>&1 | tail -5 || true
    sudo systemctl status pmcd --no-pager 2>&1 | tail -5 || true
    echo "INFO: Listening ports:"
    ss -tlnp | grep -E '44322|pmproxy' || echo "No listener on 44322"
fi
echo "=== Phase 1 Complete (RHEL) ==="
'@
    }
}

function Get-VerifyScript {
    param([string]$OsType)

    $port = if ($OsType -eq 'SUSE') { '9664' } else { '44322' }
    $url = if ($OsType -eq 'SUSE') { "http://localhost:$port/metrics" } else { "http://localhost:$port/metrics?names=ha_cluster" }

    return @"
#!/bin/bash
HTTP_CODE=`$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
if [ "`$HTTP_CODE" = "200" ]; then
    METRIC_COUNT=`$(curl -s "$url" | grep -c "^ha_cluster_" || echo "0")
    echo "OK|`$METRIC_COUNT"
else
    echo "FAIL|`$HTTP_CODE"
fi
"@
}

function Invoke-Phase1 {
    param([hashtable]$Config)

    $startTime = Get-Date
    Set-PhaseResult -Phase $PhaseName -Status 'Running' -Message 'Installing HA exporter on cluster nodes...'

    $osType = $Config['os_type']
    $nodes = $Config['nodes']
    $installScript = Get-InstallScript -OsType $osType

    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "OS Type: $osType | Nodes: $($nodes.Count)"
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Execution method: $($Config['execution_method'])"

    # Request user consent before installing on VMs
    $nodeNames = ($nodes | ForEach-Object { $_['hostname'] }) -join ', '
    $consentGranted = Request-UserConsent -Action "Install HA cluster exporter on nodes: $nodeNames" -Phase $PhaseName
    if (-not $consentGranted) {
        Set-PhaseResult -Phase $PhaseName -Status 'Skipped' -Message 'User declined installation'
        return
    }

    $allSuccess = $true
    foreach ($node in $nodes) {
        $hostname = $node['hostname']
        Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Installing on node: $hostname ($($node['ip_address']))"

        $result = Invoke-VMCommand -Config $Config -Node $node -ScriptContent $installScript -Phase $PhaseName

        if ($result.Success) {
            # Check output for SUCCESS markers
            if ($result.Output -match 'SUCCESS:') {
                Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Installation succeeded on $hostname via $($result.Method)"
            } else {
                Write-PhaseLog -Phase $PhaseName -Level 'WARN' -Message "Installation completed on $hostname but verification unclear"
            }
        } else {
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Installation FAILED on $hostname`: $($result.Error)"
            $allSuccess = $false
        }
    }

    # Post-install verification (give services time to stabilize)
    Write-PhaseLog -Phase $PhaseName -Level 'INFO' -Message "Waiting 10 seconds for services to stabilize..."
    Start-Sleep -Seconds 10

    foreach ($node in $nodes) {
        $hostname = $node['hostname']
        $verifyScript = Get-VerifyScript -OsType $osType
        $result = Invoke-VMCommand -Config $Config -Node $node -ScriptContent $verifyScript -Phase $PhaseName

        if ($result.Success -and $result.Output -match 'OK\|(\d+)') {
            $metricCount = $Matches[1]
            Write-PhaseLog -Phase $PhaseName -Level 'SUCCESS' -Message "Verified ${hostname}: $metricCount ha_cluster metrics exposed"
        } else {
            Write-PhaseLog -Phase $PhaseName -Level 'ERROR' -Message "Verification FAILED on ${hostname}: endpoint not responding"
            $allSuccess = $false
        }
    }

    $duration = [int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds
    if ($allSuccess) {
        Set-PhaseResult -Phase $PhaseName -Status 'Passed' -Message "Exporter installed and verified on all $($nodes.Count) nodes" -DurationSeconds $duration
    } else {
        Set-PhaseResult -Phase $PhaseName -Status 'Failed' -Message 'One or more nodes failed installation/verification' -DurationSeconds $duration
    }
}

# Execute if called directly
if ($Config) {
    Invoke-Phase1 -Config $Config
}

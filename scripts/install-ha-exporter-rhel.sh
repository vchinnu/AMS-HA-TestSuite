#!/bin/bash
# ============================================================================
# install-ha-exporter-rhel.sh
# Installs PCP + pcp-pmda-hacluster + pmproxy on RHEL nodes
# Run on each cluster node via VM Run Command or Bastion SSH
# ============================================================================
set -e

echo "================================================================"
echo "  HA Cluster Exporter Installation - RHEL"
echo "  Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "  Hostname: $(hostname)"
echo "  OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
echo "================================================================"

# Check if already installed and running
if systemctl is-active --quiet pmproxy 2>/dev/null; then
    echo "INFO: pmproxy is already running"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:44322/metrics?names=ha_cluster" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        METRIC_COUNT=$(curl -s "http://localhost:44322/metrics?names=ha_cluster" | grep -c "^ha_cluster_" || echo "0")
        echo "SUCCESS: Service active, exposing $METRIC_COUNT ha_cluster metrics"
        exit 0
    fi
fi

# Install PCP packages
echo "STEP 1: Installing pcp and pcp-pmda-hacluster..."
sudo yum install -y pcp pcp-pmda-hacluster

# Enable and start pmcd
echo "STEP 2: Enabling and starting pmcd..."
sudo systemctl enable pmcd
sudo systemctl start pmcd

# Install hacluster PMDA
echo "STEP 3: Installing hacluster PMDA..."
PCP_PMDAS_DIR=$(find /var/lib/pcp/pmdas -name "hacluster" -type d 2>/dev/null | head -1)
if [ -z "$PCP_PMDAS_DIR" ]; then
    PCP_PMDAS_DIR="/var/lib/pcp/pmdas/hacluster"
fi

if [ -d "$PCP_PMDAS_DIR" ]; then
    cd "$PCP_PMDAS_DIR"
    echo | sudo ./Install
    echo "SUCCESS: hacluster PMDA installed from $PCP_PMDAS_DIR"
else
    echo "ERROR: hacluster PMDA directory not found at $PCP_PMDAS_DIR"
    echo "Searching for hacluster..."
    find / -name "hacluster" -type d 2>/dev/null || true
    exit 1
fi

# Enable and start pmproxy
echo "STEP 4: Enabling and starting pmproxy..."
sudo systemctl enable pmproxy
sudo systemctl start pmproxy

# Wait for service to stabilize
sleep 5

# Verify
echo "STEP 5: Verifying metrics endpoint (port 44322)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:44322/metrics?names=ha_cluster" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    METRIC_COUNT=$(curl -s "http://localhost:44322/metrics?names=ha_cluster" | grep -c "^ha_cluster_" || echo "0")
    echo "SUCCESS: Endpoint responding, $METRIC_COUNT ha_cluster metrics available"
else
    echo "ERROR: Endpoint returned HTTP $HTTP_CODE"
    echo "--- pmproxy Status ---"
    sudo systemctl status pmproxy --no-pager 2>&1 || true
    echo "--- pmcd Status ---"
    sudo systemctl status pmcd --no-pager 2>&1 || true
    echo "--- Journal Logs ---"
    sudo journalctl -u pmproxy --no-pager -n 20 2>&1 || true
    exit 1
fi

# Check firewall
echo "STEP 6: Checking firewall for port 44322..."
if command -v firewall-cmd &> /dev/null; then
    if ! sudo firewall-cmd --list-ports | grep -q "44322"; then
        echo "INFO: Opening port 44322 in firewall..."
        sudo firewall-cmd --add-port=44322/tcp --permanent
        sudo firewall-cmd --reload
        echo "SUCCESS: Firewall port 44322 opened"
    else
        echo "INFO: Port 44322 already open in firewall"
    fi
else
    echo "INFO: firewall-cmd not found, skipping firewall check"
fi

echo "================================================================"
echo "  Installation Complete"
echo "  Endpoint: http://$(hostname -I | awk '{print $1}'):44322/metrics?names=ha_cluster"
echo "================================================================"

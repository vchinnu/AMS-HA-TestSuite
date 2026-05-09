#!/bin/bash
# ============================================================================
# install-ha-exporter-suse.sh
# Installs prometheus-ha_cluster_exporter on SUSE/SLES nodes
# Run on each cluster node via VM Run Command or Bastion SSH
# ============================================================================
set -e

echo "================================================================"
echo "  HA Cluster Exporter Installation - SUSE/SLES"
echo "  Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "  Hostname: $(hostname)"
echo "  OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
echo "================================================================"

# Check if already installed and running
if systemctl is-active --quiet prometheus-ha_cluster_exporter 2>/dev/null; then
    echo "INFO: prometheus-ha_cluster_exporter is already running"
    METRIC_COUNT=$(curl -s http://localhost:9664/metrics | grep -c "^ha_cluster_" || echo "0")
    echo "SUCCESS: Service active, exposing $METRIC_COUNT ha_cluster metrics"
    exit 0
fi

# Install
echo "STEP 1: Installing prometheus-ha_cluster_exporter..."
sudo zypper refresh
sudo zypper install -y prometheus-ha_cluster_exporter

# Enable and start
echo "STEP 2: Enabling and starting service..."
sudo systemctl enable prometheus-ha_cluster_exporter
sudo systemctl start prometheus-ha_cluster_exporter

# Wait for service to stabilize
sleep 5

# Verify
echo "STEP 3: Verifying metrics endpoint (port 9664)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9664/metrics 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    METRIC_COUNT=$(curl -s http://localhost:9664/metrics | grep -c "^ha_cluster_" || echo "0")
    echo "SUCCESS: Endpoint responding, $METRIC_COUNT ha_cluster metrics available"
else
    echo "ERROR: Endpoint returned HTTP $HTTP_CODE"
    echo "--- Service Status ---"
    sudo systemctl status prometheus-ha_cluster_exporter --no-pager 2>&1 || true
    echo "--- Journal Logs ---"
    sudo journalctl -u prometheus-ha_cluster_exporter --no-pager -n 20 2>&1 || true
    exit 1
fi

# Check firewall
echo "STEP 4: Checking firewall for port 9664..."
if command -v firewall-cmd &> /dev/null; then
    if ! sudo firewall-cmd --list-ports | grep -q "9664"; then
        echo "INFO: Opening port 9664 in firewall..."
        sudo firewall-cmd --add-port=9664/tcp --permanent
        sudo firewall-cmd --reload
        echo "SUCCESS: Firewall port 9664 opened"
    else
        echo "INFO: Port 9664 already open in firewall"
    fi
else
    echo "INFO: firewall-cmd not found, skipping firewall check"
fi

echo "================================================================"
echo "  Installation Complete"
echo "  Endpoint: http://$(hostname -I | awk '{print $1}'):9664/metrics"
echo "================================================================"

# HA Cluster E2E Test Automation Suite

**Azure Monitor for SAP Solutions (AMS) — OS Certification Testing**

Automated end-to-end validation that the HA Cluster Exporter on a given OS version correctly feeds data through the full AMS pipeline into workbook views and alerts.

---

## End-to-End Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        HA Cluster E2E Test Flow                              │
└─────────────────────────────────────────────────────────────────────────────┘

  ┌────────────┐     ┌────────────────┐     ┌───────────────┐     ┌──────────┐
  │  Cluster   │────▶│  AMS Provider  │────▶│ Log Analytics │────▶│ Workbook │
  │  Exporter  │     │  (Collector)   │     │     Table     │     │ & Alerts │
  │ Port 9664  │     │   (Azure)      │     │               │     │          │
  └────────────┘     └────────────────┘     └───────────────┘     └──────────┘
     SUSE/RHEL         Phase 3 creates        Phase 4 validates     Phase 5 validates
     Phase 1 installs                         data flow             KQL queries

                          Phase 6: Data Integrity Validation
                    ┌───────────────────────────────────────────┐
                    │  Scrape exporter → Parse → Run KQL →      │
                    │  Compare resource/node state → PASS/FAIL  │
                    └───────────────────────────────────────────┘
```

### Data Pipeline Detail

```
Node (SLES/RHEL)                       Azure
━━━━━━━━━━━━━━━━                       ━━━━━
Pacemaker Cluster                      AMS Monitor
    │                                      │
    ▼                                      ▼
ha_cluster_exporter                    Provider Instance (per node)
(port 9664 / 44322)                        │
    │                                      ▼
    │  ◄─── HTTP scrape ───           AMS Collector Function
    │                                      │
    │                                      ▼
    │                              Prometheus_HaClusterExporter_CL
    │                              (Log Analytics table)
    │                                      │
    │                              ┌───────┴────────┐
    │                              ▼                ▼
    │                         Workbook Queries   Alert Rules
    │                         (resource/node     (node-switched,
    │                          status views)      resource-down)
    │
    ▼
Metrics exposed (Prometheus text format):
  ha_cluster_pacemaker_resources{agent, resource, node, status, role, managed} 0|1
  ha_cluster_pacemaker_nodes{node, status, type} 0|1
```

---

## Project Structure

```
HAClusterTesting/
├── Run-HAClusterTest.ps1          # Interactive orchestrator (menu-driven or CLI)
├── config.template.yaml           # Configuration template
├── config.yaml                    # Active config (not checked in)
│
├── phases/                        # Phase scripts (run sequentially)
│   ├── Phase1-InstallExporter.ps1       # Install exporter on cluster nodes
│   ├── Phase2-SetupAMS.ps1             # Create RG, VNet, subnet, AMS Monitor
│   ├── Phase3-CreateProviders.ps1       # Create HA provider per node
│   ├── Phase4-ValidateData.ps1          # Poll LA for data arrival
│   ├── Phase5-ValidateWorkbookAlerts.ps1 # Validate workbook KQL & alert rules
│   ├── Phase6-DataIntegrityValidation.ps1 # Exporter vs workbook comparison
│   └── Phase7-Cleanup.ps1              # Remove test resources
│
├── helpers/                       # Shared utility functions
│   ├── Common.ps1                 # Config reader, logging, phase state
│   ├── KqlRunner.ps1              # Execute KQL against Log Analytics
│   ├── PrometheusParser.ps1       # Parse Prometheus text exposition format
│   └── HtmlReportGenerator.ps1    # Generate HTML test report dashboard
│
├── kql/                           # KQL queries (same as production workbook)
│   ├── validate-data-flow.kql
│   ├── workbook-cluster-overview.kql
│   ├── workbook-node-status.kql
│   ├── workbook-resource-status.kql
│   ├── workbook-location-constraints.kql
│   └── alert-primary-node-switched.kql
│
├── scripts/                       # Shell scripts for node-side installation
│   ├── install-ha-exporter-suse.sh
│   └── install-ha-exporter-rhel.sh
│
└── reports/                       # Generated HTML reports (gitignored)
```

---

## Phase Descriptions

### Phase 1 — Install Exporter

| Item | Detail |
|------|--------|
| **Purpose** | Install and start the HA cluster exporter on each cluster node |
| **SUSE** | `prometheus-ha_cluster_exporter` on port 9664 |
| **RHEL** | `pcp` + `pcp-pmda-hacluster` + `pmproxy` on port 44322 |
| **Method** | `Invoke-AzVMRunCommand` (no SSH keys required) |
| **Pass Criteria** | HTTP 200 from `/metrics`, `ha_cluster_*` metrics present |

### Phase 2 — Setup AMS Infrastructure

| Item | Detail |
|------|--------|
| **Purpose** | Create Azure resources needed for the AMS Monitor |
| **Creates** | Resource Group → VNet (optional) → Subnet (/28, delegated) → VNet peering (if needed) → AMS Monitor |
| **Cmdlet** | `New-AzWorkloadsMonitor` |
| **Pass Criteria** | Monitor provisioning state = `Succeeded` |

### Phase 3 — Create Providers

| Item | Detail |
|------|--------|
| **Purpose** | Register one PrometheusHaCluster provider per node |
| **Cmdlet** | `New-AzWorkloadsProviderInstance` with `New-AzWorkloadsProviderPrometheusHaClusterInstanceObject` |
| **Config** | SID, cluster name, hostname, Prometheus URL |
| **Pass Criteria** | All provider instances reach `Succeeded` state |

### Phase 4 — Validate Data Flow

| Item | Detail |
|------|--------|
| **Purpose** | Confirm metrics arrive in Log Analytics |
| **Table** | `Prometheus_HaClusterExporter_CL` |
| **Checks** | Rows exist (last 30 min), expected metric names present, all nodes reporting |
| **Method** | KQL polling with configurable interval + timeout |
| **Pass Criteria** | Data from all nodes, 15+ distinct metrics |

### Phase 5 — Validate Workbook & Alerts

| Item | Detail |
|------|--------|
| **Purpose** | Confirm workbook queries return meaningful data and alert rules exist |
| **Part 1** | Run each `workbook-*.kql` file against LA — must return ≥1 row |
| **Part 2** | Run `alert-*.kql` file — validate alert query logic |
| **Part 3** | Check built-in AMS HA alert rules are enabled and evaluating |
| **Pass Criteria** | All queries return data, alert rules active |

### Phase 6 — Data Integrity Validation (OS Certification)

| Item | Detail |
|------|--------|
| **Purpose** | End-to-end comparison: exporter source of truth vs workbook output |
| **Step 1** | Scrape exporter from both nodes via VM Run Command |
| **Step 2** | Identify DC node (status="dc"), use DC node's data as ground truth |
| **Step 3** | Parse Prometheus metrics using `PrometheusParser.ps1` |
| **Step 4** | Run resource-status and node-status KQL queries against LA |
| **Step 5** | Compare each resource: name, agent, node, status, managed |
| **Step 6** | Compare each node: name, status set (dc, expected_up, online) |
| **Verdict** | PASS = all resources and nodes match between exporter and workbook |

### Phase 7 — Cleanup

| Item | Detail |
|------|--------|
| **Purpose** | Remove test infrastructure (reverse order of creation) |
| **Order** | Providers → Monitor → VNet peering → Subnet → RG (with consent) |
| **Safety** | Interactive confirmation required before destructive actions |

---

## Usage

### Prerequisites

- PowerShell 7+
- Azure PowerShell modules: `Az.Accounts`, `Az.Resources`, `Az.Network`, `Az.Workloads`, `Az.OperationalInsights`
- Authenticated Azure session (`Connect-AzAccount`)
- Access to the cluster VMs (for VM Run Command)

### Quick Start

```powershell
# 1. Copy and edit config
Copy-Item config.template.yaml config.yaml
# Edit config.yaml with your cluster details

# 2. Run all phases
.\Run-HAClusterTest.ps1 -Phase all

# 3. Or run interactively
.\Run-HAClusterTest.ps1
# Use menu: [1-7] individual phases, [A] run all, [R] generate report
```

### Run a Single Phase

```powershell
.\Run-HAClusterTest.ps1 -Phase 6    # Just run Phase 6 (OS certification test)
```

### Configuration

Key fields in `config.yaml`:

```yaml
subscription_id: "..."              # Azure subscription
resource_group: "AMS-HATest-RG"     # RG for AMS Monitor
os_type: "SUSE"                     # SUSE or RHEL
os_version: "15 SP5"                # For reporting
sap_sid: "CHA"                      # SAP SID
cluster_name: "ha_ascs_cluster"     # Pacemaker cluster name

nodes:
  - hostname: "node1"
    vm_name: "SAP-VM-node1"
    vm_resource_group: "sap-rg"
  - hostname: "node2"
    vm_name: "SAP-VM-node2"
    vm_resource_group: "sap-rg"

log_analytics_workspace_id: "..."   # LA workspace GUID
```

---

## Certification Flow (Phase 6 Detail)

```
                    ┌─────────────────────┐
                    │  Scrape Node 1      │
                    │  (VM Run Command)   │
                    └────────┬────────────┘
                             │
                    ┌────────▼────────────┐
                    │  Scrape Node 2      │
                    │  (VM Run Command)   │
                    └────────┬────────────┘
                             │
                    ┌────────▼────────────┐
                    │  Identify DC Node   │
                    │  (status="dc")      │
                    └────────┬────────────┘
                             │
              ┌──────────────┴──────────────┐
              ▼                              ▼
    ┌──────────────────┐          ┌──────────────────────┐
    │  Parse Exporter  │          │  KQL Query (LA)      │
    │  (Source of      │          │  Same correlation_id │
    │   Truth)         │          │  as DC node          │
    └────────┬─────────┘          └──────────┬───────────┘
             │                               │
             └──────────────┬────────────────┘
                            ▼
              ┌──────────────────────────┐
              │    COMPARE                │
              │  Resource by resource:    │
              │    name, agent, node,     │
              │    status, managed        │
              │  Node by node:            │
              │    name, status set       │
              └──────────────┬────────────┘
                             ▼
              ┌──────────────────────────┐
              │  VERDICT                  │
              │  0 FAIL → CERTIFIED       │
              │  FAIL > 0 → NOT CERTIFIED │
              └───────────────────────────┘
```

### Sample Output (SLES 15 SP5 — Passed)

```
=== RESOURCE COMPARISON ===
  [PASS] fs_CHA_ASCS         | node=chascs02l0c2 | status=active | managed=true
  [PASS] fs_CHA_ERS          | node=chascs02l0c2 | status=active | managed=true
  [PASS] vip_CHA_ASCS        | node=chascs02l0c2 | status=active | managed=true
  [PASS] vip_CHA_ERS         | node=chascs02l0c2 | status=active | managed=true
  [PASS] rsc_sap_CHA_ASCS00  | node=chascs02l0c2 | status=active | managed=true
  [PASS] health-azure-events | node=chascs02l0c2 | status=active | managed=true
  [PASS] nc_CHA_ASCS         | node=chascs02l0c2 | status=active | managed=true
  [PASS] nc_CHA_ERS          | node=chascs02l0c2 | status=active | managed=true
  [PASS] rsc_st_azure        | node=chascs02l0c2 | status=active | managed=true

=== NODE COMPARISON ===
  [PASS] Node chascs01l0c2 | statuses: expected_up,online
  [PASS] Node chascs02l0c2 | statuses: dc,expected_up,online

=== CERTIFICATION SUMMARY ===
  OS: SLES 15 SP5
  DC Node: chascs02l0c2
  Total Checks: 11 | PASS: 11 | WARN: 0 | FAIL: 0

  *** ALL CHECKS PASSED — OS CERTIFIED FOR AMS HA PROVIDER ***
```

---

## Supported OS Versions

| OS | Version | Exporter | Port | Status |
|----|---------|----------|------|--------|
| SLES | 15 SP5 | prometheus-ha_cluster_exporter | 9664 | Certified |
| SLES | 15 SP4 | prometheus-ha_cluster_exporter | 9664 | Pending |
| RHEL | 8.8 | pcp + pcp-pmda-hacluster | 44322 | Pending |
| RHEL | 9.2 | pcp + pcp-pmda-hacluster | 44322 | Pending |

---

## Key Technical Details

### Log Analytics Table

- **Table**: `Prometheus_HaClusterExporter_CL`
- **Key columns**: `TimeGenerated`, `name_s`, `hostname_s`, `value_d`, `labels_s`, `sid_s`, `clusterName_s`, `correlation_id_g`

### DC Node Selection (KQL Pattern)

The workbook queries find the Designated Controller (DC) node's latest correlation ID to ensure consistent point-in-time view:

```kusto
let master = Prometheus_HaClusterExporter_CL
| where TimeGenerated > ago(40min)
| where value_d == 1
| extend node_status = parse_json(labels_s)
| where node_status['status'] == 'dc'
| where tostring(node_status['node']) == hostname_s
| where sid_s == '<SID>'
| where clusterName_s == '<CLUSTER>'
| summarize arg_max(TimeGenerated, correlation_id_g) by sid_s, clusterName_s, hostname_s
| top 1 by TimeGenerated
| project correlation_id_g;
```

### Exporter Metric Format

```
ha_cluster_pacemaker_resources{agent="ocf::heartbeat:Filesystem",node="node1",resource="fs_SID_ASCS",role="started",status="active",managed="true"} 1
ha_cluster_pacemaker_nodes{node="node1",status="online",type="member"} 1
```

- `value=1` → resource/node is in that state
- `value=0` → resource/node is NOT in that state (filtered out during comparison)

---

## Troubleshooting

| Issue | Cause | Resolution |
|-------|-------|------------|
| VM Run Command 409 Conflict | Prior Run Command still executing | Wait 60s, retry |
| KQL returns 0 rows | Data ingestion delay | Increase `ago()` window or wait longer in Phase 4 |
| Exporter HTTP 000 | Service not running | Check `systemctl status prometheus-ha_cluster_exporter` |
| Provider stuck in Creating | Subnet delegation or peering issue | Verify subnet has `Microsoft.Web/serverFarms` delegation |
| Phase 6 WARN (timing) | Exporter scraped at different time than LA data | Normal if resource state changed between scrape and LA query |

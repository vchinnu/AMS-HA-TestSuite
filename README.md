# AMS HA Cluster E2E Test Automation Suite

**Azure Monitor for SAP Solutions (AMS) — HA Provider OS Certification Testing**

Automated end-to-end validation that the HA Cluster Exporter on a given OS version correctly feeds data through the full AMS pipeline into workbook views and alerts. Includes an **Azure-hosted dashboard** (Function App + Static Web App) for triggering tests, monitoring progress in real time, retrying failed phases, and viewing HTML reports — all from a browser.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        HA Cluster E2E Test Architecture                         │
└─────────────────────────────────────────────────────────────────────────────────┘

  ┌──────────────────┐     ┌──────────────────────┐     ┌─────────────────────┐
  │  Static Web App  │────▶│  Function App (API)   │────▶│  Azure Table/Blob   │
  │  (Dashboard UI)  │     │  PowerShell 7.4       │     │  (Run History +     │
  │  Free tier       │     │  Managed Identity     │     │   HTML Reports)     │
  └──────────────────┘     └──────────┬────────────┘     └─────────────────────┘
                                      │
                    Orchestrates Phases 1–7 against:
                                      │
  ┌────────────┐     ┌────────────────▼┐     ┌───────────────┐     ┌──────────┐
  │  Cluster   │────▶│  AMS Provider   │────▶│ Log Analytics │────▶│ Workbook │
  │  Exporter  │     │  (per node)     │     │     Table     │     │ & Alerts │
  │ Port 9664  │     │                 │     │               │     │          │
  └────────────┘     └─────────────────┘     └───────────────┘     └──────────┘
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
(port 9664 / 44322)                    Naming: HA-<SID>-<full-hostname>
    │                                      │
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
├── Run-HAClusterTest.ps1          # Interactive local orchestrator (menu-driven or CLI)
├── run-local-phase1.ps1           # Dev/test helper: run Phase 1 locally without dashboard
├── config.template.yaml           # Configuration template (copy to config.yaml)
├── config.yaml                    # Active config (gitignored)
├── .gitignore                     # Ignores config.yaml, reports/, logs/, *.zip, keys
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
│   ├── Common.ps1                 # Config reader, logging, phase state, LA auto-discovery
│   ├── KqlRunner.ps1              # Execute KQL against Log Analytics
│   ├── PrometheusParser.ps1       # Parse Prometheus text exposition format
│   ├── HtmlReportGenerator.ps1    # Generate HTML test report
│   └── ReportStorage.ps1          # Provision & manage Azure Storage for reports
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
├── azure-dashboard/               # Cloud-hosted dashboard & API
│   ├── deploy.ps1                 # One-click deployment orchestrator
│   ├── infra/
│   │   ├── main.bicep             # Infrastructure-as-Code (all Azure resources)
│   │   └── main.json              # Compiled ARM template
│   ├── function-app/              # Azure Function App (PowerShell 7.4)
│   │   ├── host.json              # Function runtime config (2h timeout)
│   │   ├── requirements.psd1      # Managed dependencies (Az modules)
│   │   ├── profile.ps1            # Startup: managed identity auth
│   │   ├── start-test/            # POST /api/start-test — trigger full test run
│   │   ├── get-status/            # GET  /api/status/{runId} — live progress polling
│   │   ├── get-runs/              # GET  /api/runs — list all runs (with stale detection)
│   │   ├── retry/                 # POST /api/retry — resume from failed phase
│   │   ├── get-report/            # GET  /api/report/{runId} — serve HTML report
│   │   ├── cleanup/               # POST /api/cleanup/{runId} — trigger Phase 7
│   │   ├── helpers/               # Copies of shared helpers (deployed with zip)
│   │   └── phases/                # Copies of phase scripts (deployed with zip)
│   └── static-webapp/             # Azure Static Web App (dashboard frontend)
│       ├── index.html             # Single-page dashboard UI
│       └── staticwebapp.config.json # SPA routing + security headers
│
├── Test/                          # Test scripts (placeholder)
└── reports/                       # Generated HTML reports (gitignored)
```

---

## Azure Dashboard

The cloud-hosted dashboard provides a browser UI to run and monitor tests without needing a local PowerShell session.

### Infrastructure (deployed via Bicep)

| Resource | Details |
|----------|---------|
| **Function App** | PowerShell 7.4, Functions v4, system-assigned managed identity |
| **Static Web App** | Free tier, SPA with security headers (CSP, X-Frame-Options: DENY) |
| **Storage Account** | StorageV2/LRS — Table (`HaClusterTestRuns`) + Blob container (`ha-test-reports`) |
| **App Insights** | Performance monitoring for the Function App |
| **App Service Plan** | Consumption (Y1) or B1 depending on deployment |

### API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/start-test` | POST | Start a new test run (accepts full config JSON) |
| `/api/status/{runId}` | GET | Real-time status with phase results and live logs |
| `/api/runs` | GET | List all runs (optional `?sid=` filter). Auto-marks runs >120 min as Abandoned |
| `/api/retry` | POST | Resume a failed/abandoned run from a specific phase. Body: `{ runId, phase, resumeAll }` |
| `/api/report/{runId}` | GET | Serve HTML report from Blob Storage (via managed identity, no SAS) |
| `/api/cleanup/{runId}` | POST | Trigger Phase 7 cleanup for a run |

### Dashboard Features

- Real-time progress polling (5-second intervals)
- Retry button for Failed/Abandoned runs
- Loading indicators during phase execution
- Auto-detect abandoned runs (>120 minutes threshold)
- HTML report viewer (served via managed identity proxy)

### Deployment

```powershell
# One-click deployment (creates all infrastructure + deploys code)
.\azure-dashboard\deploy.ps1

# Manual deployment (code only, after infra exists)
$src = "C:\path\to\HAClusterTesting"
$funcApp = "$src\azure-dashboard\function-app"
Copy-Item "$src\phases\*" "$funcApp\phases\" -Force
Copy-Item "$src\helpers\*" "$funcApp\helpers\" -Force
cd "$src\azure-dashboard"
Compress-Archive -Path "function-app\*" -DestinationPath "deploy-final.zip" -Force
az functionapp deployment source config-zip `
    --name "<function-app-name>" `
    --resource-group "<resource-group>" `
    --src "deploy-final.zip" --timeout 180
```

### Managed Identity Permissions

The Function App's system-assigned managed identity requires:
- **Contributor** on the target subscription (to create AMS resources, run VM commands)
- **Storage Blob Data Contributor** on the report storage account (auto-granted)

### Managed Dependencies (Function App)

```
Az.Accounts            2.*
Az.Compute             7.*
Az.Monitor             5.*
Az.Network             7.*
Az.OperationalInsights 3.*
Az.Storage             6.*
Az.Resources           6.*
Az.Workloads           1.*
AzTable                2.*
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
| **Naming** | `HA-<SID>-<full-hostname>` (e.g., `HA-CHA-chascs01l0c2`) — uses full hostname to avoid collisions |
| **Cmdlet** | `New-AzWorkloadsProviderInstance` with `New-AzWorkloadsProviderPrometheusHaClusterInstanceObject` |
| **Config** | SID, cluster name, hostname, Prometheus URL |
| **Polling** | Waits up to 10 min for provisioning (polls every 20s) |
| **Pass Criteria** | All provider instances reach `Succeeded` state |

### Phase 4 — Validate Data Flow

| Item | Detail |
|------|--------|
| **Purpose** | Confirm metrics arrive in Log Analytics |
| **Table** | `Prometheus_HaClusterExporter_CL` |
| **LA Auto-Discovery** | If `log_analytics_workspace_id` is empty, auto-discovers via `Get-MonitorWorkspaceId` (AMS Monitor → LA ARM ID → workspace GUID) |
| **Checks** | Rows exist (last 30 min), expected metric names present, all nodes reporting |
| **Method** | KQL polling with configurable interval (default 120s) + timeout (default 20 min) |
| **Pass Criteria** | Data from all nodes, 15+ distinct metrics |

### Phase 5 — Validate Workbook & Alerts

| Item | Detail |
|------|--------|
| **Purpose** | Confirm workbook queries return meaningful data and alert rules exist |
| **LA Auto-Discovery** | Same as Phase 4 — uses `Get-MonitorWorkspaceId` when workspace ID not in config |
| **Part 1** | Run each `workbook-*.kql` file against LA — must return ≥1 row |
| **Part 2** | Run `alert-*.kql` file — validate alert query logic |
| **Part 3** | Check built-in AMS HA alert rules are enabled and evaluating |
| **Pass Criteria** | All queries return data, alert rules active |

### Phase 6 — Data Integrity Validation (OS Certification)

| Item | Detail |
|------|--------|
| **Purpose** | End-to-end comparison: exporter source of truth vs workbook output |
| **LA Auto-Discovery** | Same as Phases 4/5 |
| **Hostname Filtering** | KQL queries include `where hostname_s in (...)` filter using test node hostnames to prevent cross-cluster contamination when multiple HA clusters share the same SID/clusterName |
| **Step 1** | Scrape exporter from both nodes via VM Run Command |
| **Step 2** | Identify DC node (status="dc"), use DC node's data as ground truth |
| **Step 3** | Parse Prometheus metrics using `PrometheusParser.ps1` |
| **Step 4** | Run resource-status and node-status KQL queries against LA (filtered by hostname) |
| **Step 5** | Compare each resource: name, agent, node, status, managed |
| **Step 6** | Compare each node: name, status set (dc, expected_up, online) |
| **Verdict** | PASS = all resources and nodes match between exporter and workbook |

### Phase 7 — Cleanup

| Item | Detail |
|------|--------|
| **Purpose** | Remove test infrastructure (reverse order of creation) |
| **Order** | Providers → Monitor → VNet peering → Subnet → RG (with consent) |
| **Safety** | Interactive confirmation required before destructive actions |
| **Dashboard** | Can also be triggered via `/api/cleanup/{runId}` endpoint |

---

## Key Implementation Details

### LA Workspace Auto-Discovery

Phases 4, 5, and 6 share a common `Get-MonitorWorkspaceId` function (in `helpers/Common.ps1`) that eliminates the need to manually provide a Log Analytics workspace ID:

1. Calls `Get-AzWorkloadsMonitor` to get the AMS Monitor object
2. Extracts `LogAnalyticsWorkspaceArmId` from the monitor
3. Parses the ARM ID via regex to extract workspace RG and name
4. Calls `Get-AzOperationalInsightsWorkspace` to get the `CustomerId` (workspace GUID)

If `log_analytics_workspace_id` is provided in config, auto-discovery is skipped.

### Provider Naming

Provider names use the format `HA-<SID>-<full-hostname>` (e.g., `HA-CHA-chascs01l0c2`). The full hostname is used to prevent naming collisions when nodes share a common prefix (e.g., `chadcha01l10c` vs `chadcha01l00c` would both truncate to the same name).

### Phase 6 Hostname Filtering

KQL queries in Phase 6 filter by `hostname_s in (...)` using the test node hostnames. This prevents cross-cluster contamination when multiple HA clusters in the same AMS monitor share the same SID or cluster name.

### Report Persistence

- HTML reports are generated by `HtmlReportGenerator.ps1` and uploaded to Azure Blob Storage
- Run metadata is stored in Azure Table Storage (`HaClusterTestRuns`)
- Storage is managed by `ReportStorage.ps1` — auto-creates storage account, container, and table
- Reports survive AMS cleanup (Phase 7) since they're in a separate storage account

### Performance: get-status Endpoint

The `/api/status/{runId}` endpoint uses a direct Table Storage filter (`RowKey eq '$runId'`) instead of loading all rows. This reduces response time from 60+ seconds to ~1 second, critical for the dashboard's 5-second polling interval.

### Stale Run Detection

The `/api/runs` endpoint auto-marks runs with status "Running" that are older than 120 minutes as "Abandoned". This handles cases where the Function App was restarted mid-test (e.g., during deployment).

---

## Usage

### Prerequisites

- PowerShell 7+
- Azure PowerShell modules: `Az.Accounts`, `Az.Resources`, `Az.Network`, `Az.Workloads`, `Az.OperationalInsights`
- Authenticated Azure session (`Connect-AzAccount`)
- Access to the cluster VMs (for VM Run Command)
- For dashboard deployment: Azure CLI (`az`), Contributor role

### Quick Start (Local)

```powershell
# 1. Copy and edit config
Copy-Item config.template.yaml config.yaml
# Edit config.yaml with your cluster details

# 2. Run all phases interactively
.\Run-HAClusterTest.ps1
# Menu: [T] full test, [1-7] individual phases, [7] cleanup

# 3. Or run a specific phase via CLI
.\Run-HAClusterTest.ps1 -Phase 6    # Just run Phase 6 (OS certification)
```

### Quick Start (Dashboard)

```powershell
# 1. Deploy dashboard infrastructure
.\azure-dashboard\deploy.ps1

# 2. Open the Static Web App URL in browser
# 3. Click "New Test" → paste config JSON → Start
# 4. Monitor progress in real time
# 5. Click "Retry" on any failed phase
# 6. View HTML report when complete
```

### Configuration

Key fields in `config.yaml` / JSON body for dashboard:

```yaml
subscription_id: "..."                # [REQUIRED] Azure subscription ID
resource_group: "AMS-HATest-RG"       # RG for AMS Monitor (created if not exists)
location: "eastus"                    # Azure region
os_type: "SUSE"                       # [REQUIRED] SUSE or RHEL
os_version: "15 SP5"                  # For reporting
sap_sid: "CHA"                        # [REQUIRED] SAP SID
cluster_name: "ha_ascs_cluster"       # Pacemaker cluster name

nodes:                                # [REQUIRED] At least 2 nodes
  - hostname: "node1"
    vm_name: "SAP-VM-node1"
    vm_resource_group: "sap-rg"
    ip_address: "10.0.1.5"
    fqdn: "node1.sap.contoso.com"
  - hostname: "node2"
    vm_name: "SAP-VM-node2"
    vm_resource_group: "sap-rg"
    ip_address: "10.0.1.6"
    fqdn: "node2.sap.contoso.com"

# Optional — auto-discovered from AMS Monitor if empty
log_analytics_workspace_id: ""

# VNet/Subnet for AMS Monitor
vnet:
  name: "ams-ha-test-vnet"
  create_new: false
subnet:
  name: "ams-ha-test-subnet"
  cidr: "10.1.0.240/28"

# Execution method (vm_run_command recommended)
execution_method: "vm_run_command"    # vm_run_command | bastion | both

# Report storage (separate from AMS resources)
report_storage:
  resource_group: ""                  # Dedicated RG (defaults to main RG)
  storage_account_name: ""            # Auto-generated if empty
  container_name: "ha-test-reports"
  table_name: "HaClusterTestRuns"

# Test behavior
poll_interval_seconds: 120            # LA polling interval (min 30s)
poll_max_wait_minutes: 20             # Max wait for data in Phase 4
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
    │  (Source of      │          │  Filtered by         │
    │   Truth)         │          │  hostname_s + DC     │
    └────────┬─────────┘          │  correlation_id      │
             │                    └──────────┬───────────┘
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

### Sample Output (SLES 15 SP5 — Certified)

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
| SLES | 15 SP5 | prometheus-ha_cluster_exporter | 9664 | **Certified** |
| SLES | 15 SP4 | prometheus-ha_cluster_exporter | 9664 | Pending |
| RHEL | 8.8 | pcp + pcp-pmda-hacluster | 44322 | Pending |
| RHEL | 9.2 | pcp + pcp-pmda-hacluster | 44322 | Pending |

---

## Key Technical Details

### Log Analytics Table

- **Table**: `Prometheus_HaClusterExporter_CL`
- **Key columns**: `TimeGenerated`, `name_s`, `hostname_s`, `value_d`, `labels_s`, `sid_s`, `clusterName_s`, `correlation_id_g`

### DC Node Selection (KQL Pattern)

The workbook queries find the Designated Controller (DC) node's latest correlation ID to ensure a consistent point-in-time view. Phase 6 adds a `hostname_s` filter for cluster isolation:

```kusto
let master = Prometheus_HaClusterExporter_CL
| where TimeGenerated > ago(40min)
| where value_d == 1
| where hostname_s in ('node1','node2')     // hostname filter (Phase 6)
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
| Phase 6 cross-cluster data | Multiple clusters share same SID/clusterName | Already handled: hostname_s filter isolates test nodes |
| Provider name collision | Nodes with similar hostname prefixes | Already handled: full hostname used in naming (`HA-<SID>-<hostname>`) |
| get-status timeout/slow | Loading all table rows on each poll | Already handled: direct `RowKey eq` filter for O(1) lookup |
| Run stuck as "Running" | Function App restarted mid-test (e.g., redeployment) | Automatically marked "Abandoned" after 120 min; use Retry to resume |
| Deployment kills active run | Zip deploy restarts Function App process | Do not deploy while a test is running |

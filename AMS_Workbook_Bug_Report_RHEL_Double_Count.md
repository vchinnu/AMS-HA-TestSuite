# AMS HA Cluster Workbook Bug Report
## RHEL/PCP Resources Double-Counted as "Failed" in Cluster Overview

---

## Bug Summary

The AMS High-Availability Cluster workbook incorrectly double-counts stopped resources for RHEL/PCP-based clusters in the "Cluster Status" overview and "Resource Status" detail views. This causes customer confusion by showing inflated "resources failed" counts.

**Example:** A RHEL HANA cluster with 8 stopped resources shows `resources_failed = 16` instead of the correct value of `8`.

---

## Environment

| Field | Value |
|-------|-------|
| **AMS Monitor** | AMS-HA-RHEL-SUSE |
| **Subscription** | e663cc2d-722b-4be1-b636-bbd9e4c60fd9 |
| **LA Workspace ID** | 35fa0146-8ee1-406f-9b6e-0efd872ec2be |
| **Affected Clusters** | RH6 - ha_hana_rh6_cluster (RHEL 10.2), RH7 - ha_HANA_RH7_cluster (RHEL 10.2) |
| **Working Clusters** | S03 - sles_ha_ascs_cluster (SUSE), S03 - ascs-S03 (SUSE), RH9 - ha_rhel9.8_hana_cluster (RHEL 9.8, healthy - no stopped resources) |

---

## Symptoms

1. **Cluster Overview row** shows `resources_failed = 16` for RHEL HANA cluster that has only 8 stopped resources
2. **SUSE cluster** with 1 stopped resource correctly shows `resources_failed = 1`
3. The issue affects ANY RHEL/PCP cluster with stopped resources (e.g., HANA clusters with stopped clone/multi-state resources)
4. Clusters without stopped resources are unaffected

---

## Root Cause

### Data Format Difference (SUSE vs RHEL/PCP)

The SUSE and RHEL exporters store resource state differently in the `Prometheus_HaClusterExporter_CL` table:

**SUSE Exporter:**
- Each resource has **5 entries** in LA (one per status: active, blocked, failed, failure_ignored, orphaned)
- `value_d = 1` means "YES, this state is true"; `value_d = 0` means "NO"
- A stopped resource: ALL 5 entries have `value_d = 0`
- `role = 'stopped'`, `status = 'active'` with `value_d = 0` (meaning "not active")

**RHEL/PCP Exporter:**
- Each resource has **1 entry** in LA
- `value_d = 1` always (indicates the resource exists)
- `role = 'started'` or `role = 'stopped'` indicates the state
- `status` label is always **empty**

### The Query Bug

The "Cluster status" workbook query has two parts UNIONed together:

```kql
// Part 1: Gets all entries where value_d == 1
( Prometheus_HaClusterExporter_CL
| where correlation_id_g in (dcstatus)
| where name_s == "ha_cluster_pacemaker_resources" 
| where value_d == 1                              // ← RHEL stopped resources PASS this (value_d=1)
| extend resources = parse_json(labels_s)
| project resource_status=..., resource_role=..., ...
| union (
    // Part 2: Separately catches role='stopped' (NO value_d filter)
    Prometheus_HaClusterExporter_CL
    | where correlation_id_g in (dcstatus)
    | where name_s == "ha_cluster_pacemaker_resources"
    | extend resources = parse_json(labels_s)
    | where resources['role'] == 'stopped'         // ← RHEL stopped resources ALSO appear here
    | summarize count() by ...))
| summarize 
    resources_failed = countif(resource_status == 'failed' or resource_status == 'failed_ignored' 
                               or resource_role == 'stopped'),   // ← Counts from BOTH parts!
```

**For SUSE:** Part 1 excludes stopped resources (they have `value_d = 0`). Part 2 catches them once. Total = correct.

**For RHEL:** Part 1 INCLUDES stopped resources (they have `value_d = 1`). Part 2 catches them AGAIN. Total = doubled.

| | Part 1 (value_d==1) | Part 2 (union role='stopped') | resources_failed total |
|---|---|---|---|
| **SUSE** (1 stopped) | 0 (excluded, value_d=0) | 1 | **1** ✓ |
| **RHEL** (8 stopped) | 8 (included, value_d=1) | 8 (same ones again!) | **16** ✗ |

---

## Affected Queries

### 1. Cluster Status Overview (`Cluster status.txt`)

**Issue:** Double-counts stopped resources for RHEL in `resources_failed` count.

**Fix:** Add `where tostring(resources['role']) != 'stopped'` in Part 1 to prevent stopped resources from being counted there. The UNION (Part 2) will handle ALL stopped resources uniformly for both OS types.

**Current (lines 22-25):**
```kql
( Prometheus_HaClusterExporter_CL
| where correlation_id_g in (dcstatus)
| where name_s == "ha_cluster_pacemaker_resources" 
| where value_d == 1
| extend  resources = parse_json(labels_s)
| project resource_status=tostring(resources['status']), resource_role=tostring(resources['role']), resource_managed=tostring(resources['managed']), sid_s, clusterName_s
```

**Fixed:**
```kql
( Prometheus_HaClusterExporter_CL
| where correlation_id_g in (dcstatus)
| where name_s == "ha_cluster_pacemaker_resources" 
| where value_d == 1
| extend  resources = parse_json(labels_s)
| where tostring(resources['role']) != 'stopped'    // ← ADD: exclude stopped (handled by union)
| project resource_status=tostring(resources['status']), resource_role=tostring(resources['role']), resource_managed=tostring(resources['managed']), sid_s, clusterName_s
```

### 2. Resource Status Detail (`resourcestatus-query.txt`)

**Issue:** The main query filters `where strlen(resources['node']) > 0` which excludes RHEL stopped resources (empty node). Then `union stoppedResources` adds them back. No double-count here, but it means RHEL stopped resources only show via the stoppedResources let-variable path. The detail view correctly shows "stopped" status but the node column is empty (which is accurate for RHEL data).

**Assessment:** This query does NOT double-count (the `strlen(node) > 0` filter prevents it). However, the stopped resources show with an empty Node column for RHEL, which matches the LA data format. No fix required for this query.

---

## Verification Steps

Run the following KQL in the LA workspace (35fa0146-8ee1-406f-9b6e-0efd872ec2be) to verify the data format difference:

```kql
// Shows SUSE stopped resources have value_d=0, RHEL have value_d=1
let upstatus = Prometheus_HaClusterExporter_CL
| where TimeGenerated > ago(10min)
| where name_s == 'sapmon'
| summarize arg_max(TimeGenerated, correlation_id_g, value_d) by sid_s, clusterName_s, hostname_s
| project correlation_id_g;
let dcstatus = materialize(Prometheus_HaClusterExporter_CL
| where correlation_id_g in (upstatus)
| where name_s == 'ha_cluster_pacemaker_nodes'
| where value_d == 1
| extend node_status=parse_json(labels_s)
| where node_status['status']=='dc'
| where tostring(node_status['node']) == hostname_s
| summarize arg_max(TimeGenerated, correlation_id_g) by sid_s, clusterName_s, hostname_s
| project correlation_id_g);
Prometheus_HaClusterExporter_CL
| where correlation_id_g in (dcstatus)
| where name_s == 'ha_cluster_pacemaker_resources'
| extend resources = parse_json(labels_s)
| summarize 
    entries=count(), 
    role_stopped_entries=countif(tostring(resources['role'])=='stopped') 
    by sid_s, clusterName_s, value_d
```

**Expected Result:**
- SUSE clusters: stopped entries only appear with `value_d = 0`
- RHEL clusters: stopped entries appear with `value_d = 1`

---

## Impact

- **Customer Confusion:** Inflated "failed" resource count alarm customers unnecessarily
- **All RHEL HANA clusters affected:** Any RHEL HA cluster with stopped/inactive resources (common for HANA clone resources like SAPHana, SAPHanaTopology, filesystems)
- **ASCS clusters unaffected:** ASCS clusters typically have all resources running on specific nodes (no stopped resources)
- **SUSE clusters unaffected:** Correctly handled by current query logic

---

## Recommended Fix Summary

| Query | Fix | Impact |
|-------|-----|--------|
| **Cluster status** (overview) | Add `where tostring(resources['role']) != 'stopped'` in Part 1 before the UNION | Prevents double-count; stopped resources counted once via UNION only |
| **Resource status** (detail) | No change needed | Already handles correctly via `strlen(node) > 0` filter + stoppedResources union |

The fix is backward-compatible — SUSE behavior remains unchanged since SUSE stopped resources already have `value_d = 0` and never appear in Part 1.

---

## Additional Notes

- The `status` label is always **empty** for RHEL/PCP data in LA. This means `countif(resource_status == 'failed')` can never match RHEL resources. The only way to detect a stopped RHEL resource is via `role == 'stopped'`.
- This bug was introduced when RHEL/PCP support was added to the AMS HA Cluster exporter without corresponding updates to the workbook queries, which were originally designed only for the SUSE exporter data format.
- Tested and verified against LA workspace 35fa0146-8ee1-406f-9b6e-0efd872ec2be on 2026-07-26.

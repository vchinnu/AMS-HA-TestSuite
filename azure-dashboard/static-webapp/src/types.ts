// ---------------------------------------------------------------------------
// Shared TypeScript interfaces for the HA Cluster Test Dashboard
// ---------------------------------------------------------------------------

/** A single cluster node entry in the test config form. */
export interface ClusterNode {
  hostname: string;
  ip_address: string;
  fqdn: string;
  vm_resource_id: string;
}

/** VNet reference (name + resource group). */
export interface VnetRef {
  name: string;
  resource_group: string;
}

/** Subnet config. */
export interface SubnetRef {
  name: string;
  cidr: string;
}

/** Report storage config. */
export interface ReportStorageRef {
  storage_account: string;
  resource_group: string;
}

/** Full test configuration submitted to POST /api/start-test. */
export interface TestConfig {
  subscription_id: string;
  resource_group: string;
  location: string;
  sap_sid: string;
  cluster_name: string;
  os_type: 'SUSE' | 'RHEL';
  os_version: string;
  ams_monitor_name: string;
  rg_resource_id: string;
  vnet_resource_id: string;
  cluster_vnet: VnetRef;
  ams_same_vnet: boolean;
  vnet: VnetRef;
  subnet: SubnetRef;
  log_analytics_workspace_id: string;
  log_analytics_workspace_name: string;
  report_storage: ReportStorageRef;
  nodes: ClusterNode[];
  execution_method: 'vm_run_command' | 'bastion' | 'both';
  poll_interval_seconds: number;
}

/** Result of a single phase execution. */
export interface PhaseResult {
  Phase: string;       // e.g. "Phase1"
  Status: string;      // "Passed" | "Failed" | "Skipped"
  DurationSeconds: number;
  Message: string;
}

/** A single log entry. */
export interface LogEntry {
  time: string;
  phase: number;
  level: string;
  message: string;
}

/** Response from GET /api/status/{runId}. */
export interface RunStatus {
  runId: string;
  sid: string;
  status: RunStatusValue;
  currentPhase: number;
  startTime: string;
  os: string;
  clusterName: string;
  phaseResults: PhaseResult[];
  logEntries: LogEntry[];
  reportUrl: string;
  duration: number;
  error: string;
}

/** Response from POST /api/start-test. */
export interface StartTestResponse {
  runId: string;
  status: string;
  error?: string;
}

/** A run summary in the history list. */
export interface RunSummary {
  runId: string;
  sid: string;
  status: RunStatusValue;
  clusterName: string;
  os: string;
  startTime: string;
  duration: number;
  reportUrl: string;
  error: string;
  currentPhase: number;
}

/** Response from GET /api/runs. */
export interface RunsResponse {
  runs: RunSummary[];
}

/** Union of possible run status values. */
export type RunStatusValue =
  | 'Running'
  | 'Passed'
  | 'Failed'
  | 'Abandoned'
  | 'Cleaned';

/** Toast notification. */
export interface Toast {
  id: number;
  message: string;
  type: 'success' | 'error';
}

/** Tab identifiers. */
export type TabId = 'new-test' | 'progress' | 'history';

/** Phase metadata (static). */
export interface PhaseMeta {
  num: number;
  name: string;
}

export const PHASES: PhaseMeta[] = [
  { num: 1, name: 'Install Exporter' },
  { num: 2, name: 'Setup AMS' },
  { num: 3, name: 'Create Providers' },
  { num: 4, name: 'Validate Data' },
  { num: 5, name: 'Workbook & Alerts' },
  { num: 6, name: 'Data Integrity' },
];

// ---------------------------------------------------------------------------
// Centralized API client — all fetch calls to the Function App
// ---------------------------------------------------------------------------
import type {
  TestConfig,
  StartTestResponse,
  RunStatus,
  RunsResponse,
  PhaseResult,
  LogEntry,
} from './types';

const API_BASE = import.meta.env.VITE_API_BASE as string;

/** Ensure arrays that PowerShell may serialize as single objects. */
function ensureArray<T>(v: T | T[] | undefined | null): T[] {
  if (v == null) return [];
  return Array.isArray(v) ? v : [v];
}

// ── Start Test ──────────────────────────────────────────────────────────────

export async function startTest(config: TestConfig): Promise<StartTestResponse> {
  const resp = await fetch(`${API_BASE}/start-test`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(config),
  });
  const data = await resp.json();
  if (!resp.ok && !data.runId) {
    throw new Error(data.error || `HTTP ${resp.status}`);
  }
  return data as StartTestResponse;
}

// ── Get Status ──────────────────────────────────────────────────────────────

export async function getStatus(runId: string): Promise<RunStatus> {
  const resp = await fetch(`${API_BASE}/status/${runId}`);
  if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
  const data = await resp.json();
  // Normalize arrays (PowerShell may return single-item as object)
  data.phaseResults = ensureArray<PhaseResult>(data.phaseResults);
  data.logEntries = ensureArray<LogEntry>(data.logEntries);
  return data as RunStatus;
}

// ── Get Runs ────────────────────────────────────────────────────────────────

export async function getRuns(sid?: string): Promise<RunsResponse> {
  const url = sid ? `${API_BASE}/runs?sid=${encodeURIComponent(sid)}` : `${API_BASE}/runs`;
  const resp = await fetch(url);
  if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
  return (await resp.json()) as RunsResponse;
}

// ── Retry ───────────────────────────────────────────────────────────────────

export async function retryPhase(
  runId: string,
  phase: number,
  resumeAll: boolean,
): Promise<void> {
  const resp = await fetch(`${API_BASE}/retry`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ runId, phase, resumeAll }),
  });
  if (!resp.ok) {
    const data = await resp.json().catch(() => ({}));
    throw new Error((data as { error?: string }).error || `HTTP ${resp.status}`);
  }
}

// ── Cleanup ─────────────────────────────────────────────────────────────────

export async function runCleanup(runId: string): Promise<void> {
  const resp = await fetch(`${API_BASE}/cleanup/${runId}`, { method: 'POST' });
  if (!resp.ok) {
    const data = await resp.json().catch(() => ({}));
    throw new Error((data as { error?: string }).error || `HTTP ${resp.status}`);
  }
}

// ── Report URL ──────────────────────────────────────────────────────────────

export function getReportUrl(runId: string): string {
  return `${API_BASE}/report/${runId}`;
}

// ── Resolve VM ──────────────────────────────────────────────────────────────

export interface ResolveVmResult {
  vm_name: string;
  hostname: string;
  ip_address: string;
  resource_group: string;
  subscription_id: string;
  error?: string;
}

export async function resolveVm(vmResourceId: string): Promise<ResolveVmResult> {
  const resp = await fetch(`${API_BASE}/resolve-vm`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ vm_resource_id: vmResourceId }),
  });
  const data = await resp.json();
  if (!resp.ok) {
    throw new Error(data.error || `HTTP ${resp.status}`);
  }
  return data as ResolveVmResult;
}

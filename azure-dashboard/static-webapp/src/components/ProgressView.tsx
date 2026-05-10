import { useState, useCallback, useEffect } from 'react';
import { useApp } from '../context/AppContext';
import { usePolling } from '../hooks/usePolling';
import PhaseCard from './PhaseCard';
import LogPanel from './LogPanel';
import * as api from '../api';
import type { RunStatus } from '../types';
import { PHASES } from '../types';

export default function ProgressView() {
  const { currentRunId, setCurrentRunId, showToast, setActiveTab } = useApp();
  const [data, setData] = useState<RunStatus | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isTerminal = data?.status === 'Passed' || data?.status === 'Failed' || data?.status === 'Abandoned' || data?.status === 'Cleaned';
  const isRunning = data?.status === 'Running';

  // ── Fetch status ──────────────────────────────────────────────────────────

  const fetchStatus = useCallback(async () => {
    if (!currentRunId) return;
    try {
      const result = await api.getStatus(currentRunId);
      setData(result);
      setError(null);
    } catch (err) {
      setError((err as Error).message);
    }
  }, [currentRunId]);

  // Poll every 5s while running
  usePolling(fetchStatus, 5000, !!currentRunId && !isTerminal);

  // Initial fetch on mount or runId change
  useEffect(() => {
    if (currentRunId) {
      setLoading(true);
      fetchStatus().finally(() => setLoading(false));
    }
  }, [currentRunId, fetchStatus]);

  // ── Auto-detect running test if no runId set ──────────────────────────────

  useEffect(() => {
    if (currentRunId) return;
    (async () => {
      try {
        const runs = await api.getRuns();
        const now = Date.now();
        const running = runs.runs?.find((r) => {
          if (r.status !== 'Running') return false;
          if (r.startTime) {
            const age = now - new Date(r.startTime).getTime();
            if (age > 120 * 60 * 1000) return false;
          }
          return true;
        });
        if (running) {
          setCurrentRunId(running.runId);
        }
      } catch { /* ignore */ }
    })();
  }, [currentRunId, setCurrentRunId]);

  // ── Actions ───────────────────────────────────────────────────────────────

  const handleRetryPhase = async (phaseNum: number) => {
    if (!currentRunId || !confirm(`Retry Phase ${phaseNum} for run ${currentRunId}?`)) return;
    try {
      await api.retryPhase(currentRunId, phaseNum, false);
      showToast(`Retrying Phase ${phaseNum}...`, 'success');
      setData(null);
      fetchStatus();
    } catch (err) {
      showToast(`Retry failed: ${(err as Error).message}`, 'error');
    }
  };

  const handleResumeFrom = async (fromPhase: number) => {
    if (!currentRunId || !confirm(`Resume from Phase ${fromPhase} through Phase 6?`)) return;
    try {
      await api.retryPhase(currentRunId, fromPhase, true);
      showToast(`Resuming from Phase ${fromPhase}...`, 'success');
      setData(null);
      fetchStatus();
    } catch (err) {
      showToast(`Resume failed: ${(err as Error).message}`, 'error');
    }
  };

  const handleCleanup = async () => {
    if (!currentRunId || !confirm('This will DELETE all AMS resources (monitor, providers, subnet). Reports are preserved. Continue?')) return;
    try {
      await api.runCleanup(currentRunId);
      showToast('Cleanup completed', 'success');
      fetchStatus();
    } catch (err) {
      showToast(`Cleanup error: ${(err as Error).message}`, 'error');
    }
  };

  // ── Render: empty state ───────────────────────────────────────────────────

  if (!currentRunId) {
    return (
      <div className="empty-state">
        <h3>No Active Test Run</h3>
        <p>Start a new test from the "New Test" tab to see live progress here.</p>
      </div>
    );
  }

  if (loading && !data) {
    return (
      <div className="empty-state">
        <span className="live-dot" />
        <span style={{ fontSize: 16 }}>Loading run {currentRunId}...</span>
      </div>
    );
  }

  if (error && !data) {
    return (
      <div className="empty-state">
        <h3 style={{ color: '#f87171' }}>Error loading run</h3>
        <p>{error}</p>
        <button className="btn-secondary" onClick={fetchStatus}>Retry</button>
      </div>
    );
  }

  if (!data) return null;

  // ── Render: progress ──────────────────────────────────────────────────────

  const phaseResults = data.phaseResults || [];
  const pct = Math.min(100, ((data.currentPhase - 1) / 6) * 100 + (data.status === 'Passed' ? 100 / 6 : 0));
  const elapsed = data.duration ? `${Math.floor(data.duration / 60)}m ${data.duration % 60}s` : '...';
  const statusColor = data.status === 'Passed' ? '#22c55e' : data.status === 'Failed' ? '#ef4444' : '#f59e0b';

  // Retry logic
  const failedPhases = phaseResults.filter((r) => r.Status === 'Failed');
  const hasAllPassed = phaseResults.length >= 6 && phaseResults.every((r) => r.Status === 'Passed');
  const showRetry = data.status === 'Failed' || data.status === 'Abandoned' || (data.status === 'Passed' && !hasAllPassed);

  const completedPhaseNums = phaseResults.filter((r) => r.Status === 'Passed').map((r) => parseInt(r.Phase.replace('Phase', '')));
  const resumePhase = completedPhaseNums.length > 0 ? Math.max(...completedPhaseNums) + 1 : data.currentPhase || 1;

  return (
    <div className="progress-panel">
      {/* Header */}
      <div className="progress-header">
        <h3>Test Run: {data.runId}</h3>
        <span style={{ color: statusColor, fontWeight: 600 }}>
          {data.status} | {elapsed}
        </span>
      </div>

      {/* Progress bar */}
      <div className="progress-bar-container">
        <div className="progress-bar" style={{ width: `${data.status === 'Passed' ? 100 : pct}%` }} />
      </div>

      {/* Error banner */}
      {data.status === 'Failed' && data.error && (
        <div className="error-banner">
          <div className="error-label">Phase {data.currentPhase} Error:</div>
          <div className="error-text">{data.error}</div>
        </div>
      )}

      {/* Phase cards */}
      <div className="progress-phases">
        {PHASES.map((p) => {
          const result = phaseResults.find((r) => r.Phase === `Phase${p.num}`);
          return (
            <PhaseCard
              key={p.num}
              num={p.num}
              name={p.name}
              result={result}
              isCurrent={p.num === data.currentPhase}
              isRunning={isRunning}
            />
          );
        })}
      </div>

      {/* Log panel */}
      <LogPanel entries={data.logEntries || []} isRunning={isRunning} />

      {/* Retry panel */}
      {showRetry && (
        <div className={`retry-panel ${failedPhases.length > 0 ? 'failed-retry' : 'abandoned-retry'}`}>
          <div className={`retry-label ${failedPhases.length > 0 ? 'failed' : 'abandoned'}`}>
            {failedPhases.length > 0
              ? 'Failed Phase(s) — Retry after fixing the issue:'
              : data.status === 'Abandoned'
                ? 'Run was abandoned — Resume execution:'
                : 'Run incomplete — Resume execution:'}
          </div>
          <div className="retry-buttons">
            {failedPhases.map((f) => {
              const num = parseInt(f.Phase.replace('Phase', ''));
              const phaseMeta = PHASES.find((p) => p.num === num);
              return (
                <button key={f.Phase} className="btn-retry-failed" onClick={() => handleRetryPhase(num)}>
                  Retry {f.Phase} ({phaseMeta?.name})
                </button>
              );
            })}
            {failedPhases.length > 0 && (
              <button className="btn-retry-resume" onClick={() => handleResumeFrom(Math.min(...failedPhases.map((f) => parseInt(f.Phase.replace('Phase', '')))))}>
                Retry from Phase {Math.min(...failedPhases.map((f) => parseInt(f.Phase.replace('Phase', ''))))} onwards
              </button>
            )}
            {failedPhases.length > 0 && (() => {
              const lastFailedNum = Math.max(...failedPhases.map((f) => parseInt(f.Phase.replace('Phase', ''))));
              return lastFailedNum < 6 ? (
                <button className="btn-retry-skip" onClick={() => handleResumeFrom(lastFailedNum + 1)}>
                  Skip to Phase {lastFailedNum + 1} onwards
                </button>
              ) : null;
            })()}
            {failedPhases.length === 0 && (
              <button className="btn-retry-resume" onClick={() => handleResumeFrom(resumePhase)}>
                Resume from Phase {resumePhase} onwards
              </button>
            )}
          </div>
        </div>
      )}

      {/* Action buttons */}
      <div className="progress-actions">
        {isTerminal && (
          <button className="btn-secondary" onClick={() => setActiveTab('new-test')}>
            Start New Test
          </button>
        )}
        {data.reportUrl && (
          <a
            href={api.getReportUrl(data.runId)}
            target="_blank"
            rel="noopener noreferrer"
            className="btn-primary"
            style={{ padding: '10px 20px', fontSize: 13 }}
          >
            View Full Report
          </a>
        )}
        {isTerminal && (
          <button className="btn-danger" onClick={handleCleanup}>
            Run Cleanup (Phase 7)
          </button>
        )}
      </div>
    </div>
  );
}

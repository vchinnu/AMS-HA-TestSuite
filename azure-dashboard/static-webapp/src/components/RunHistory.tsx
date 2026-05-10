import { useState, useEffect } from 'react';
import { useApp } from '../context/AppContext';
import StatusBadge from './StatusBadge';
import * as api from '../api';
import type { RunSummary } from '../types';

export default function RunHistory() {
  const { setCurrentRunId, setActiveTab } = useApp();
  const [runs, setRuns] = useState<RunSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [expandedRunId, setExpandedRunId] = useState<string | null>(null);

  useEffect(() => {
    loadRuns();
  }, []);

  const loadRuns = async () => {
    setLoading(true);
    try {
      const data = await api.getRuns();
      setRuns(data.runs || []);
      setError(null);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  };

  const handleRowClick = (run: RunSummary) => {
    if (run.status === 'Running') {
      // Navigate to progress view
      setCurrentRunId(run.runId);
      setActiveTab('progress');
    } else if (run.error) {
      // Toggle inline error
      setExpandedRunId((prev) => (prev === run.runId ? null : run.runId));
    } else {
      // View in progress tab
      setCurrentRunId(run.runId);
      setActiveTab('progress');
    }
  };

  const formatDate = (iso: string) => {
    if (!iso) return '-';
    const d = new Date(iso);
    return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  };

  const formatDuration = (sec: number | undefined) => {
    if (!sec) return '-';
    return `${Math.floor(sec / 60)}m`;
  };

  return (
    <div className="form-section">
      <h3>
        Test Run History
        <button
          className="btn-secondary"
          style={{ float: 'right', padding: '4px 12px', fontSize: 11 }}
          onClick={loadRuns}
        >
          Refresh
        </button>
      </h3>
      <table className="runs-table">
        <thead>
          <tr>
            <th>Run ID</th>
            <th>SID</th>
            <th>Cluster</th>
            <th>OS</th>
            <th>Status</th>
            <th>Duration</th>
            <th>Date &amp; Time</th>
            <th>Report</th>
          </tr>
        </thead>
        <tbody>
          {loading && (
            <tr>
              <td colSpan={8} style={{ textAlign: 'center', color: '#64748b', padding: 40 }}>
                Loading...
              </td>
            </tr>
          )}
          {!loading && error && (
            <tr>
              <td colSpan={8} style={{ color: '#f87171' }}>
                Error loading runs: {error}
              </td>
            </tr>
          )}
          {!loading && !error && runs.length === 0 && (
            <tr>
              <td colSpan={8} style={{ textAlign: 'center', color: '#64748b', padding: 40 }}>
                No test runs yet
              </td>
            </tr>
          )}
          {!loading &&
            !error &&
            runs.map((run) => (
              <>
                <tr
                  key={run.runId}
                  onClick={() => handleRowClick(run)}
                  title={
                    run.status === 'Running'
                      ? 'Click to view live progress'
                      : run.error
                        ? 'Click to view error details'
                        : 'Click to view details'
                  }
                >
                  <td className="run-id-cell">{run.runId}</td>
                  <td>{run.sid}</td>
                  <td>{run.clusterName}</td>
                  <td>{run.os}</td>
                  <td><StatusBadge status={run.status} /></td>
                  <td>{formatDuration(run.duration)}</td>
                  <td>{formatDate(run.startTime)}</td>
                  <td>
                    {run.reportUrl ? (
                      <a
                        href={api.getReportUrl(run.runId)}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="report-link"
                        onClick={(e) => e.stopPropagation()}
                      >
                        View Report
                      </a>
                    ) : (
                      '-'
                    )}
                  </td>
                </tr>
                {expandedRunId === run.runId && run.error && (
                  <tr key={`${run.runId}-err`} className="error-detail-row">
                    <td colSpan={8}>
                      <div className="error-detail-text">
                        <strong>Phase {run.currentPhase || '?'} Error:</strong> {run.error}
                      </div>
                      <button
                        className="btn-secondary"
                        style={{ marginTop: 8, fontSize: 11, padding: '4px 12px' }}
                        onClick={(e) => {
                          e.stopPropagation();
                          setCurrentRunId(run.runId);
                          setActiveTab('progress');
                        }}
                      >
                        View Full Details
                      </button>
                    </td>
                  </tr>
                )}
              </>
            ))}
        </tbody>
      </table>
    </div>
  );
}

import type { PhaseResult } from '../types';

interface Props {
  num: number;
  name: string;
  result?: PhaseResult;
  isCurrent: boolean;
  isRunning: boolean;
}

export default function PhaseCard({ num, name, result, isCurrent, isRunning }: Props) {
  let cls = '';
  let statusText = 'Pending';

  if (result) {
    cls = result.Status.toLowerCase();
    statusText = `${result.Status} (${result.DurationSeconds}s)`;
  } else if (isCurrent && isRunning) {
    cls = 'running';
    statusText = 'Running...';
  }

  return (
    <div className={`phase-card ${cls}`}>
      <div className="phase-num">Phase {num}</div>
      <div className="phase-name">{name}</div>
      <div className="phase-status">{statusText}</div>
      {result?.Status === 'Failed' && result.Message && (
        <div className="phase-error">
          {result.Message.substring(0, 120)}
        </div>
      )}
    </div>
  );
}

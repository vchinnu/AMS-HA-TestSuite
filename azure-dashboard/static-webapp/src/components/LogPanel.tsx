import { useEffect, useRef, useState } from 'react';
import type { LogEntry } from '../types';

interface Props {
  entries: LogEntry[];
  isRunning: boolean;
}

export default function LogPanel({ entries, isRunning }: Props) {
  const [expanded, setExpanded] = useState(isRunning);
  const scrollRef = useRef<HTMLDivElement>(null);

  // Auto-expand when running
  useEffect(() => {
    if (isRunning) setExpanded(true);
  }, [isRunning]);

  // Auto-scroll to bottom when new entries arrive and running
  useEffect(() => {
    if (isRunning && scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [entries.length, isRunning]);

  if (entries.length === 0) return null;

  return (
    <div className="log-panel">
      <div className="log-toggle" onClick={() => setExpanded((e) => !e)}>
        {isRunning && <span className="live-dot" />}
        {isRunning ? 'Live ' : ''}▶ Execution Log ({entries.length} entries)
      </div>
      <div
        ref={scrollRef}
        className={`log-content ${expanded ? '' : 'collapsed'}`}
      >
        {entries.map((entry, i) => {
          let msgClass = 'log-msg';
          if (entry.message?.includes('FAILED') || entry.message?.includes('[FAIL]') || entry.message?.includes('[ERROR]') || entry.message?.includes('EXCEPTION')) {
            msgClass += ' error';
          } else if (entry.message?.includes('completed') || entry.message?.includes('[SUCCESS]')) {
            msgClass += ' success';
          }
          return (
            <div className="log-line" key={i}>
              <span className="log-time">{entry.time}</span>
              <span className="log-phase">P{entry.phase}</span>
              <span className={msgClass}>{entry.message}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

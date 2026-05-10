import { useEffect, useRef } from 'react';

/**
 * Polls a callback at a fixed interval with proper cleanup.
 * Automatically stops when `enabled` is false.
 */
export function usePolling(
  callback: () => void | Promise<void>,
  intervalMs: number,
  enabled: boolean,
): void {
  const savedCallback = useRef(callback);

  // Always keep the latest callback ref
  useEffect(() => {
    savedCallback.current = callback;
  }, [callback]);

  useEffect(() => {
    if (!enabled) return;

    // Fire immediately on enable
    savedCallback.current();

    const id = setInterval(() => {
      savedCallback.current();
    }, intervalMs);

    return () => clearInterval(id);
  }, [intervalMs, enabled]);
}

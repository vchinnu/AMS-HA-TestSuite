import { useState, useRef, useCallback } from 'react';
import type { ClusterNode } from '../types';
import { useApp } from '../context/AppContext';
import * as api from '../api';

interface Props {
  nodes: ClusterNode[];
  onChange: (nodes: ClusterNode[]) => void;
}

const EMPTY_NODE: ClusterNode = {
  hostname: '',
  ip_address: '',
  fqdn: '',
  vm_resource_id: '',
};

const RESOURCE_ID_PATTERN = /\/subscriptions\/[^/]+\/resourceGroups\/[^/]+\/providers\/Microsoft\.Compute\/virtualMachines\/[^/]+$/i;

export default function NodeEditor({ nodes, onChange }: Props) {
  const { showToast } = useApp();
  const [resolving, setResolving] = useState<Record<number, boolean>>({});
  const debounceTimers = useRef<Record<number, ReturnType<typeof setTimeout>>>({});
  const nodesRef = useRef(nodes);
  nodesRef.current = nodes;

  const updateNode = (index: number, field: keyof ClusterNode, value: string) => {
    const updated = nodes.map((n, i) =>
      i === index ? { ...n, [field]: value } : n,
    );
    onChange(updated);
  };

  /** Auto-resolve IP from Azure after a valid resource ID is detected */
  const autoResolve = useCallback(async (index: number, resourceId: string) => {
    if (!RESOURCE_ID_PATTERN.test(resourceId)) return;
    setResolving((prev) => ({ ...prev, [index]: true }));
    try {
      const result = await api.resolveVm(resourceId);
      const current = nodesRef.current;
      const updated = [...current];
      updated[index] = {
        ...updated[index],
        hostname: result.hostname || updated[index].hostname,
        ip_address: result.ip_address || updated[index].ip_address,
        fqdn: result.hostname || updated[index].fqdn,
      };
      onChange(updated);
      if (result.ip_address) {
        showToast(`Resolved: ${result.hostname} (${result.ip_address})`, 'success');
      }
    } catch {
      // Silent fail for auto-resolve — user can still click ↻ manually
    } finally {
      setResolving((prev) => ({ ...prev, [index]: false }));
    }
  }, [onChange, showToast]);

  /** When vm_resource_id is pasted/changed, auto-fill hostname from the last segment */
  const handleResourceIdChange = (index: number, value: string) => {
    const updated = [...nodes];
    updated[index] = { ...updated[index], vm_resource_id: value };

    // Auto-extract VM name from resource ID
    const match = value.match(/\/virtualMachines\/([^/]+)$/i);
    if (match) {
      updated[index].hostname = match[1];
      updated[index].fqdn = match[1];
    }
    onChange(updated);

    // Debounced auto-resolve of IP from Azure (triggers 800ms after last change)
    if (debounceTimers.current[index]) {
      clearTimeout(debounceTimers.current[index]);
    }
    debounceTimers.current[index] = setTimeout(() => {
      autoResolve(index, value);
    }, 800);
  };

  /** Resolve hostname + IP from Azure via the function app */
  const resolveVm = async (index: number) => {
    const resourceId = nodes[index].vm_resource_id;
    if (!resourceId) {
      showToast('Enter a VM Resource ID first', 'error');
      return;
    }
    setResolving((prev) => ({ ...prev, [index]: true }));
    try {
      const result = await api.resolveVm(resourceId);
      const updated = [...nodes];
      updated[index] = {
        ...updated[index],
        hostname: result.hostname || updated[index].hostname,
        ip_address: result.ip_address || updated[index].ip_address,
        fqdn: result.hostname || updated[index].fqdn,
      };
      onChange(updated);
      showToast(`Resolved: ${result.hostname} (${result.ip_address})`, 'success');
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      showToast(`Resolve failed: ${msg}`, 'error');
    } finally {
      setResolving((prev) => ({ ...prev, [index]: false }));
    }
  };

  const addNode = () => {
    onChange([...nodes, { ...EMPTY_NODE }]);
  };

  const removeNode = (index: number) => {
    if (nodes.length <= 2) {
      showToast('Minimum 2 nodes required', 'error');
      return;
    }
    onChange(nodes.filter((_, i) => i !== index));
  };

  return (
    <>
      <div className="node-editor">
        <div className="node-row node-header">
          <span>VM Resource ID</span>
          <span>Hostname</span>
          <span>IP Address</span>
          <span />
        </div>
        {nodes.map((node, i) => (
          <div className="node-row" key={i}>
            <input
              type="text"
              placeholder="/subscriptions/.../virtualMachines/vm-name"
              value={node.vm_resource_id}
              onChange={(e) => handleResourceIdChange(i, e.target.value)}
              required
              className="wide-input"
            />
            <input
              type="text"
              placeholder={`node${i + 1}`}
              value={node.hostname}
              onChange={(e) => updateNode(i, 'hostname', e.target.value)}
              required
            />
            <input
              type="text"
              placeholder={`10.0.1.${5 + i}`}
              value={node.ip_address}
              onChange={(e) => updateNode(i, 'ip_address', e.target.value)}
              required
            />
            <button
              type="button"
              className="btn-resolve"
              onClick={() => resolveVm(i)}
              disabled={resolving[i] || !node.vm_resource_id}
              title="Resolve hostname &amp; IP from Azure"
            >
              {resolving[i] ? '...' : '↻'}
            </button>
            <button
              type="button"
              className="btn-remove"
              onClick={() => removeNode(i)}
            >
              ✕
            </button>
          </div>
        ))}
      </div>
      <button type="button" className="btn-add-node" onClick={addNode}>
        + Add Node
      </button>
    </>
  );
}

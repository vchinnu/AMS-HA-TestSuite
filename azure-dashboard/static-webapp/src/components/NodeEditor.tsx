import type { ClusterNode } from '../types';
import { useApp } from '../context/AppContext';

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

export default function NodeEditor({ nodes, onChange }: Props) {
  const { showToast } = useApp();

  const updateNode = (index: number, field: keyof ClusterNode, value: string) => {
    const updated = nodes.map((n, i) =>
      i === index ? { ...n, [field]: value } : n,
    );
    onChange(updated);
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
          <span>Hostname</span>
          <span>IP Address</span>
          <span>VM Resource ID</span>
          <span />
        </div>
        {nodes.map((node, i) => (
          <div className="node-row" key={i}>
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
            <input
              type="text"
              placeholder="/subscriptions/.../resourceGroups/.../providers/Microsoft.Compute/virtualMachines/vm-name"
              value={node.vm_resource_id}
              onChange={(e) => updateNode(i, 'vm_resource_id', e.target.value)}
              required
              className="wide-input"
            />
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

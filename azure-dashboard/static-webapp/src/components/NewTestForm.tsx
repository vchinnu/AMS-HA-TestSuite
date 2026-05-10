import { useState } from 'react';
import { useApp } from '../context/AppContext';
import NodeEditor from './NodeEditor';
import * as api from '../api';
import type { TestConfig, ClusterNode } from '../types';

// ── Empty / Sample configs ──────────────────────────────────────────────────

const EMPTY_NODES: ClusterNode[] = [
  { hostname: '', ip_address: '', fqdn: '', vm_name: '', vm_resource_group: '' },
  { hostname: '', ip_address: '', fqdn: '', vm_name: '', vm_resource_group: '' },
];

const SAMPLE: Partial<TestConfig> & { nodes: ClusterNode[] } = {
  sap_sid: 'CHA',
  cluster_name: 'ha_ascs_cluster',
  os_type: 'SUSE',
  os_version: 'SLES 15 SP5',
  rg_resource_id:
    '/subscriptions/2b331373-3d36-4585-bdb9-d3364786e775/resourceGroups/PADM-AMS-RCA',
  subscription_id: '2b331373-3d36-4585-bdb9-d3364786e775',
  resource_group: 'PADM-AMS-RCA',
  location: 'northeurope',
  ams_monitor_name: 'PADM-AMS-HA-Test-Monitor',
  vnet_resource_id:
    '/subscriptions/2b331373-3d36-4585-bdb9-d3364786e775/resourceGroups/ContosoVNETRG/providers/Microsoft.Network/virtualNetworks/CONTOSO-VNET-NE',
  cluster_vnet: { name: 'CONTOSO-VNET-NE', resource_group: 'ContosoVNETRG' },
  ams_same_vnet: true,
  vnet: { name: 'CONTOSO-VNET-NE', resource_group: 'ContosoVNETRG' },
  subnet: { name: 'padm-ha-test-subnet', cidr: '/28' },
  nodes: [
    { hostname: 'chascs01l0c2', ip_address: '10.8.1.41', fqdn: 'chascs01l0c2', vm_name: 'LAB-NOEU-SAP01-CHA_chascs01l0c2', vm_resource_group: 'lab-noeu-sap01-cha' },
    { hostname: 'chascs02l0c2', ip_address: '10.8.1.39', fqdn: 'chascs02l0c2', vm_name: 'LAB-NOEU-SAP01-CHA_chascs02l0c2', vm_resource_group: 'lab-noeu-sap01-cha' },
  ],
};

// ── Azure region list ───────────────────────────────────────────────────────

const AZURE_LOCATIONS = [
  'northeurope', 'westeurope', 'eastus', 'eastus2', 'westus2', 'centralus',
  'southeastasia', 'australiaeast', 'uksouth', 'japaneast', 'southcentralus',
  'canadacentral', 'brazilsouth', 'koreacentral', 'francecentral',
  'germanywestcentral', 'norwayeast', 'switzerlandnorth', 'uaenorth',
  'southafricanorth', 'centralindia',
];

// ── Helpers ─────────────────────────────────────────────────────────────────

function parseRgResourceId(id: string) {
  const m = id.match(/\/subscriptions\/([^/]+)\/resourceGroups\/([^/]+)/i);
  return m ? { subscription_id: m[1], resource_group: m[2] } : null;
}

function parseVnetResourceId(id: string) {
  const m = id.match(
    /\/subscriptions\/[^/]+\/resourceGroups\/([^/]+)\/providers\/Microsoft\.Network\/virtualNetworks\/([^/]+)/i,
  );
  return m ? { resource_group: m[1], name: m[2] } : null;
}

// ── Component ───────────────────────────────────────────────────────────────

export default function NewTestForm() {
  const { showToast, setActiveTab, setCurrentRunId } = useApp();

  // Form state
  const [sapSid, setSapSid] = useState('');
  const [clusterName, setClusterName] = useState('');
  const [osType, setOsType] = useState<'SUSE' | 'RHEL'>('SUSE');
  const [osVersion, setOsVersion] = useState('');
  const [rgResourceId, setRgResourceId] = useState('');
  const [subscriptionId, setSubscriptionId] = useState('');
  const [resourceGroup, setResourceGroup] = useState('');
  const [location, setLocation] = useState('');
  const [amsMonitorName, setAmsMonitorName] = useState('');
  const [reportStorageAccount, setReportStorageAccount] = useState('');
  const [reportStorageRg, setReportStorageRg] = useState('');
  const [clusterVnetResourceId, setClusterVnetResourceId] = useState('');
  const [clusterVnetName, setClusterVnetName] = useState('');
  const [clusterVnetRg, setClusterVnetRg] = useState('');
  const [amsSameVnet, setAmsSameVnet] = useState(true);
  const [amsVnetResourceId, setAmsVnetResourceId] = useState('');
  const [amsVnetName, setAmsVnetName] = useState('');
  const [amsVnetRg, setAmsVnetRg] = useState('');
  const [subnetName, setSubnetName] = useState('');
  const [subnetCidr, setSubnetCidr] = useState('/28');
  const [executionMethod, setExecutionMethod] = useState<'vm_run_command' | 'bastion' | 'both'>('vm_run_command');
  const [pollInterval, setPollInterval] = useState(120);
  const [nodes, setNodes] = useState<ClusterNode[]>(() => EMPTY_NODES.map((n) => ({ ...n })));
  const [submitting, setSubmitting] = useState(false);

  // ── Auto-parse resource IDs ───────────────────────────────────────────────

  const handleRgResourceIdChange = (value: string) => {
    setRgResourceId(value);
    const parsed = parseRgResourceId(value);
    if (parsed) {
      setSubscriptionId(parsed.subscription_id);
      setResourceGroup(parsed.resource_group);
      showToast('Auto-filled Subscription ID & Resource Group', 'success');
    }
  };

  const handleClusterVnetIdChange = (value: string) => {
    setClusterVnetResourceId(value);
    const parsed = parseVnetResourceId(value);
    if (parsed) {
      setClusterVnetName(parsed.name);
      setClusterVnetRg(parsed.resource_group);
      showToast('Auto-filled Cluster VNet Name & Resource Group', 'success');
    }
  };

  const handleAmsVnetIdChange = (value: string) => {
    setAmsVnetResourceId(value);
    const parsed = parseVnetResourceId(value);
    if (parsed) {
      setAmsVnetName(parsed.name);
      setAmsVnetRg(parsed.resource_group);
      showToast('Auto-filled AMS VNet Name & Resource Group', 'success');
    }
  };

  // ── Load sample ───────────────────────────────────────────────────────────

  const loadSample = () => {
    setSapSid(SAMPLE.sap_sid!);
    setClusterName(SAMPLE.cluster_name!);
    setOsType(SAMPLE.os_type!);
    setOsVersion(SAMPLE.os_version!);
    setRgResourceId(SAMPLE.rg_resource_id!);
    setSubscriptionId(SAMPLE.subscription_id!);
    setResourceGroup(SAMPLE.resource_group!);
    setLocation(SAMPLE.location!);
    setAmsMonitorName(SAMPLE.ams_monitor_name!);
    setClusterVnetResourceId(SAMPLE.vnet_resource_id!);
    setClusterVnetName(SAMPLE.cluster_vnet!.name);
    setClusterVnetRg(SAMPLE.cluster_vnet!.resource_group);
    setAmsSameVnet(true);
    setSubnetName(SAMPLE.subnet!.name);
    setSubnetCidr(SAMPLE.subnet!.cidr);
    setNodes(SAMPLE.nodes.map((n) => ({ ...n })));
    setReportStorageAccount('');
    setReportStorageRg('');
    showToast('Sample config loaded', 'success');
  };

  // ── Clear form ────────────────────────────────────────────────────────────

  const clearForm = () => {
    setSapSid(''); setClusterName(''); setOsType('SUSE'); setOsVersion('');
    setRgResourceId(''); setSubscriptionId(''); setResourceGroup(''); setLocation('');
    setAmsMonitorName(''); setReportStorageAccount(''); setReportStorageRg('');
    setClusterVnetResourceId(''); setClusterVnetName(''); setClusterVnetRg('');
    setAmsSameVnet(true); setAmsVnetResourceId(''); setAmsVnetName(''); setAmsVnetRg('');
    setSubnetName(''); setSubnetCidr('/28'); setExecutionMethod('vm_run_command');
    setPollInterval(120);
    setNodes(EMPTY_NODES.map((n) => ({ ...n })));
    showToast('Form cleared', 'success');
  };

  // ── Submit ────────────────────────────────────────────────────────────────

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    const validNodes = nodes.filter((n) => n.hostname.trim());
    if (validNodes.length < 2) {
      showToast('Add at least 2 cluster nodes', 'error');
      return;
    }

    const config: TestConfig = {
      subscription_id: subscriptionId,
      resource_group: resourceGroup,
      location,
      sap_sid: sapSid.toUpperCase(),
      cluster_name: clusterName,
      os_type: osType,
      os_version: osVersion,
      ams_monitor_name: amsMonitorName,
      rg_resource_id: rgResourceId,
      vnet_resource_id: clusterVnetResourceId,
      cluster_vnet: { name: clusterVnetName, resource_group: clusterVnetRg },
      ams_same_vnet: amsSameVnet,
      vnet: {
        name: amsSameVnet ? clusterVnetName : amsVnetName,
        resource_group: amsSameVnet ? clusterVnetRg : amsVnetRg,
      },
      subnet: { name: subnetName, cidr: subnetCidr },
      log_analytics_workspace_id: '',
      log_analytics_workspace_name: '',
      report_storage: { storage_account: reportStorageAccount, resource_group: reportStorageRg },
      nodes: validNodes.map((n) => ({ ...n, fqdn: n.fqdn || n.hostname })),
      execution_method: executionMethod,
      poll_interval_seconds: pollInterval,
    };

    setSubmitting(true);
    try {
      const result = await api.startTest(config);
      if (result.runId) {
        setCurrentRunId(result.runId);
        showToast(`Test started: ${result.runId}`, 'success');
        setActiveTab('progress');
      }
      if (result.error) {
        showToast(result.error, 'error');
      }
    } catch (err) {
      showToast(`Error: ${(err as Error).message}`, 'error');
    } finally {
      setSubmitting(false);
    }
  };

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <form onSubmit={handleSubmit}>
      {/* Top action bar */}
      <div className="form-actions" style={{ marginBottom: 20, justifyContent: 'flex-start' }}>
        <button type="button" className="btn-secondary" onClick={loadSample}>Load Sample</button>
        <button type="button" className="btn-outline" onClick={clearForm}>Clear Form</button>
        <div style={{ flex: 1 }} />
        <button type="submit" className="btn-primary" disabled={submitting}>
          {submitting ? 'Starting...' : 'Start Test (Phase 1→6)'}
        </button>
      </div>

      {/* Cluster Details */}
      <div className="form-section">
        <h3>Cluster Details</h3>
        <div className="form-grid">
          <div className="form-group">
            <label>SAP SID *</label>
            <input type="text" placeholder="CHA" required maxLength={3} value={sapSid} onChange={(e) => setSapSid(e.target.value)} />
          </div>
          <div className="form-group">
            <label>Cluster Name *</label>
            <input type="text" placeholder="ha_ascs_cluster" required value={clusterName} onChange={(e) => setClusterName(e.target.value)} />
          </div>
          <div className="form-group">
            <label>OS Type *</label>
            <select required value={osType} onChange={(e) => setOsType(e.target.value as 'SUSE' | 'RHEL')}>
              <option value="SUSE">SUSE</option>
              <option value="RHEL">RHEL</option>
            </select>
          </div>
          <div className="form-group">
            <label>OS Version</label>
            <input type="text" placeholder="SLES 15 SP5" value={osVersion} onChange={(e) => setOsVersion(e.target.value)} />
          </div>
        </div>
      </div>

      {/* Azure Subscription & Resources */}
      <div className="form-section">
        <h3>Azure Subscription &amp; Resources</h3>
        <div className="form-grid">
          <div className="form-group full-width">
            <label>Resource Group Resource ID <span className="checkbox-hint">(paste to auto-fill Subscription, RG)</span></label>
            <input type="text" placeholder="/subscriptions/.../resourceGroups/..." value={rgResourceId} onChange={(e) => handleRgResourceIdChange(e.target.value)} />
          </div>
          <div className="form-group">
            <label>Subscription ID *</label>
            <input type="text" placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" required value={subscriptionId} onChange={(e) => setSubscriptionId(e.target.value)} />
          </div>
          <div className="form-group">
            <label>Resource Group *</label>
            <input type="text" placeholder="AMS-HACluster-Test-RG" required value={resourceGroup} onChange={(e) => setResourceGroup(e.target.value)} />
          </div>
          <div className="form-group">
            <label>Location *</label>
            <input type="text" list="locationList" placeholder="e.g. northeurope" required value={location} onChange={(e) => setLocation(e.target.value)} />
            <datalist id="locationList">
              {AZURE_LOCATIONS.map((loc) => <option key={loc} value={loc} />)}
            </datalist>
          </div>
          <div className="form-group">
            <label>AMS Monitor Name</label>
            <input type="text" placeholder="Auto-generated if empty" value={amsMonitorName} onChange={(e) => setAmsMonitorName(e.target.value)} />
          </div>
          <div className="form-group">
            <label>LA Workspace ID</label>
            <input type="text" placeholder="Auto-created by AMS" disabled />
          </div>
          <div className="form-group">
            <label>LA Workspace Name</label>
            <input type="text" placeholder="Auto-created by AMS" disabled />
          </div>
        </div>
        <p className="form-hint">LA Workspace is auto-created and managed by AMS. It will be auto-resolved during data validation steps.</p>
      </div>

      {/* Report Storage */}
      <div className="form-section">
        <h3>Report Storage <span className="checkbox-hint">(persists even after cleanup)</span></h3>
        <div className="form-grid">
          <div className="form-group">
            <label>Storage Account Name</label>
            <input type="text" placeholder="Auto-created: hatest<sid><random>" value={reportStorageAccount} onChange={(e) => setReportStorageAccount(e.target.value)} />
          </div>
          <div className="form-group">
            <label>Storage Resource Group</label>
            <input type="text" placeholder="Same as above RG if empty" value={reportStorageRg} onChange={(e) => setReportStorageRg(e.target.value)} />
          </div>
        </div>
        <p className="form-hint">A storage account is auto-created to persist HTML reports and execution history. NOT deleted during cleanup.</p>
      </div>

      {/* Network — Cluster VM VNet */}
      <div className="form-section">
        <h3>Network — Cluster VM VNet</h3>
        <div className="form-grid">
          <div className="form-group full-width">
            <label>Cluster VNet Resource ID <span className="checkbox-hint">(paste to auto-fill)</span></label>
            <input type="text" placeholder="/subscriptions/.../Microsoft.Network/virtualNetworks/..." value={clusterVnetResourceId} onChange={(e) => handleClusterVnetIdChange(e.target.value)} />
          </div>
          <div className="form-group">
            <label>Cluster VNet Name *</label>
            <input type="text" placeholder="VNet where cluster VMs reside" value={clusterVnetName} onChange={(e) => setClusterVnetName(e.target.value)} />
          </div>
          <div className="form-group">
            <label>Cluster VNet Resource Group *</label>
            <input type="text" placeholder="VNet's resource group" value={clusterVnetRg} onChange={(e) => setClusterVnetRg(e.target.value)} />
          </div>
        </div>
        <p className="form-hint">The VNet where your HA cluster VMs are running.</p>
      </div>

      {/* Network — AMS Managed Subnet */}
      <div className="form-section">
        <h3>Network — AMS Managed Subnet</h3>
        <div className="form-grid">
          <div className="form-group full-width">
            <label className="checkbox-label">
              <span>Use same VNet as cluster VMs?</span>
              <input type="checkbox" checked={amsSameVnet} onChange={(e) => setAmsSameVnet(e.target.checked)} />
              <span className="checkbox-hint">If unchecked, specify a different VNet for AMS (peering will be auto-created)</span>
            </label>
          </div>

          {!amsSameVnet && (
            <>
              <div className="form-group full-width">
                <label>AMS VNet Resource ID <span className="checkbox-hint">(paste to auto-fill)</span></label>
                <input type="text" placeholder="/subscriptions/.../Microsoft.Network/virtualNetworks/..." value={amsVnetResourceId} onChange={(e) => handleAmsVnetIdChange(e.target.value)} />
              </div>
              <div className="form-group">
                <label>AMS VNet Name</label>
                <input type="text" placeholder="VNet for AMS subnet" value={amsVnetName} onChange={(e) => setAmsVnetName(e.target.value)} />
              </div>
              <div className="form-group">
                <label>AMS VNet Resource Group</label>
                <input type="text" placeholder="AMS VNet resource group" value={amsVnetRg} onChange={(e) => setAmsVnetRg(e.target.value)} />
              </div>
            </>
          )}

          <div className="form-group">
            <label>AMS Subnet Name</label>
            <input type="text" placeholder="ams-ha-test-subnet" value={subnetName} onChange={(e) => setSubnetName(e.target.value)} />
          </div>
          <div className="form-group">
            <label>AMS Subnet CIDR</label>
            <input type="text" placeholder="/28" value={subnetCidr} onChange={(e) => setSubnetCidr(e.target.value)} />
          </div>
        </div>

        {!amsSameVnet && (
          <div className="peering-notice">
            ⚠️ Different VNets detected. Bidirectional VNet peering will be auto-created during AMS setup and removed during cleanup.
          </div>
        )}
        <p className="form-hint">AMS requires a dedicated /28 subnet. If using a different VNet, bidirectional peering is auto-configured.</p>
      </div>

      {/* Cluster Nodes */}
      <div className="form-section">
        <h3>Cluster Nodes (min 2) *</h3>
        <NodeEditor nodes={nodes} onChange={setNodes} />
      </div>

      {/* Execution Options */}
      <div className="form-section">
        <h3>Execution Options <span className="checkbox-hint">(how the tool connects to your cluster VMs)</span></h3>
        <div className="form-grid">
          <div className="form-group">
            <label>Execution Method</label>
            <select value={executionMethod} onChange={(e) => setExecutionMethod(e.target.value as typeof executionMethod)}>
              <option value="vm_run_command">VM Run Command (recommended)</option>
              <option value="bastion">Azure Bastion SSH</option>
              <option value="both">Both (fallback)</option>
            </select>
          </div>
          <div className="form-group">
            <label>Poll Interval (seconds)</label>
            <input type="number" value={pollInterval} min={30} max={600} onChange={(e) => setPollInterval(Number(e.target.value))} />
          </div>
        </div>
        <div className="form-hint-block">
          <div style={{ marginBottom: 6 }}><strong>VM Run Command</strong> — Executes commands via Azure API (no SSH needed). Requires VM Agent.</div>
          <div style={{ marginBottom: 6 }}><strong>Azure Bastion SSH</strong> — Connects via Bastion host using SSH tunneling.</div>
          <div><strong>Both (fallback)</strong> — Tries VM Run Command first; falls back to Bastion SSH if it fails.</div>
        </div>
      </div>

      {/* Bottom action bar */}
      <div className="form-actions">
        <button type="button" className="btn-secondary" onClick={loadSample}>Load Sample</button>
        <button type="button" className="btn-outline" onClick={clearForm}>Clear Form</button>
        <div style={{ flex: 1 }} />
        <button type="submit" className="btn-primary" disabled={submitting}>
          {submitting ? 'Starting...' : 'Start Test (Phase 1→6)'}
        </button>
      </div>
    </form>
  );
}

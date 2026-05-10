import type { TabId } from '../types';
import { useApp } from '../context/AppContext';

const TABS: { id: TabId; label: string }[] = [
  { id: 'new-test', label: 'New Test' },
  { id: 'progress', label: 'Live Status' },
  { id: 'history', label: 'All Runs' },
];

export default function Header() {
  const { activeTab, setActiveTab } = useApp();

  return (
    <div className="header">
      <div>
        <h1>AMS HA Provider — OS Compatibility Test Suite</h1>
        <div className="subtitle">
          Validate new OS versions for HA Cluster provider support in Azure Monitor for SAP
        </div>
      </div>
      <div className="nav-tabs">
        {TABS.map((tab) => (
          <button
            key={tab.id}
            className={activeTab === tab.id ? 'active' : ''}
            onClick={() => setActiveTab(tab.id)}
          >
            {tab.label}
          </button>
        ))}
      </div>
    </div>
  );
}

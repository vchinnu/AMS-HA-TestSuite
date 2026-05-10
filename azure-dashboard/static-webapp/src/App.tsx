import { useState, useCallback } from 'react';
import { AppContext } from './context/AppContext';
import { useToast } from './hooks/useToast';
import Header from './components/Header';
import ToastContainer from './components/Toast';
import ErrorBoundary from './components/ErrorBoundary';
import NewTestForm from './components/NewTestForm';
import ProgressView from './components/ProgressView';
import RunHistory from './components/RunHistory';
import type { TabId } from './types';

export default function App() {
  const [activeTab, setActiveTabState] = useState<TabId>(
    () => (sessionStorage.getItem('activeTab') as TabId) || 'new-test',
  );
  const [currentRunId, setCurrentRunIdState] = useState<string | null>(
    () => sessionStorage.getItem('currentRunId'),
  );
  const { toasts, showToast, dismissToast } = useToast();

  const setActiveTab = useCallback((tab: TabId) => {
    setActiveTabState(tab);
    sessionStorage.setItem('activeTab', tab);
  }, []);

  const setCurrentRunId = useCallback((id: string | null) => {
    setCurrentRunIdState(id);
    if (id) sessionStorage.setItem('currentRunId', id);
    else sessionStorage.removeItem('currentRunId');
  }, []);

  return (
    <AppContext.Provider
      value={{ activeTab, setActiveTab, currentRunId, setCurrentRunId, showToast }}
    >
      <Header />
      <div className="container">
        <ErrorBoundary>
          {activeTab === 'new-test' && <NewTestForm />}
          {activeTab === 'progress' && <ProgressView />}
          {activeTab === 'history' && <RunHistory />}
        </ErrorBoundary>
      </div>
      <ToastContainer toasts={toasts} onDismiss={dismissToast} />
    </AppContext.Provider>
  );
}

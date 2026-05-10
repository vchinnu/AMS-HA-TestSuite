import { createContext, useContext } from 'react';
import type { TabId } from '../types';

export interface AppContextValue {
  activeTab: TabId;
  setActiveTab: (tab: TabId) => void;
  currentRunId: string | null;
  setCurrentRunId: (id: string | null) => void;
  showToast: (message: string, type: 'success' | 'error') => void;
}

export const AppContext = createContext<AppContextValue>(null!);

export function useApp(): AppContextValue {
  return useContext(AppContext);
}

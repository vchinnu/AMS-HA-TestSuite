interface Props {
  status: string;
}

export default function StatusBadge({ status }: Props) {
  const cls = status.toLowerCase();
  return <span className={`status-badge ${cls}`}>{status}</span>;
}

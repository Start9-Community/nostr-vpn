export function shortMiddle(value: string, max = 20): string {
  if (value.length <= max) {
    return value;
  }
  const edge = Math.max(4, Math.floor((max - 3) / 2));
  return `${value.slice(0, edge)}...${value.slice(-edge)}`;
}

export function nonEmpty(value: string | null | undefined, fallback = '-'): string {
  const trimmed = value?.trim() ?? '';
  return trimmed.length > 0 ? trimmed : fallback;
}

export function formatBytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) {
    return '0 B';
  }
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let amount = value;
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit += 1;
  }
  const digits = amount >= 10 || unit === 0 ? 0 : 1;
  return `${amount.toFixed(digits)} ${units[unit]}`;
}

export function routeList(value: string[]): string {
  return value.length > 0 ? value.join(', ') : '-';
}

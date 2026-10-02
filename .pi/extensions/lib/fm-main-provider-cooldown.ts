// The primary Pi's automatic-wake gate. The status is home-local and expires;
// the durable wake queue remains the owner of work awaiting recovery.
import { readFileSync, renameSync, writeFileSync } from "node:fs";

export type ProviderCooldown = { until: number; failures: number; reason: "quota" | "provider" };
export type ProviderSelection = { provider: string; id: string };
export const FM_MAIN_PROVIDER_RECOVERED_EVENT = "firstmate:pi-main-provider-recovered";
export const FM_MAIN_PROVIDER_COOLDOWN_EVENT = "firstmate:pi-main-provider-cooldown";

function readRecords(path: string): Record<string, ProviderCooldown> {
  try {
    const records = JSON.parse(readFileSync(path, "utf8"));
    if (records && typeof records === "object" && !Array.isArray(records)) return records;
    throw new Error(`invalid Pi provider cooldown record: ${path}`);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return {};
    throw error;
  }
}

function key(selection: ProviderSelection): string { return `${selection.provider}/${selection.id}`; }

export function readProviderCooldown(path: string, selection: ProviderSelection | null, now = Date.now(), includeExpired = false): ProviderCooldown | null {
  if (!selection) return null;
  const record = readRecords(path)[key(selection)] as Partial<ProviderCooldown> | undefined;
  if (!record) return null;
  if (typeof record.until !== "number" || !Number.isFinite(record.until) ||
      typeof record.failures !== "number" || !Number.isInteger(record.failures) ||
      record.failures < 1 || record.failures > 100 ||
      (record.reason !== "quota" && record.reason !== "provider")) {
    throw new Error(`invalid Pi provider cooldown entry: ${key(selection)}`);
  }
  if (!includeExpired && record.until <= now) return null;
  return record as ProviderCooldown;
}

function resetHorizon(error: string, now: number): number | null {
  const retryAfter = error.match(/retry[- ]after\s*:?\s*(\d{1,7})\s*(?:seconds?|s)\b/i);
  if (retryAfter) return now + Number(retryAfter[1]) * 1000;
  const relative = error.match(/(?:resets?|try again)\s*(?:in|after)\s*:?\s*([\d,]+)\s*(seconds?|minutes?|hours?|days?|[smhd])\b/i);
  if (relative) {
    const amount = Number(relative[1].replaceAll(",", ""));
    const unit = relative[2].toLowerCase()[0];
    const milliseconds = ({ s: 1_000, m: 60_000, h: 3_600_000, d: 86_400_000 } as Record<string, number>)[unit];
    if (Number.isFinite(amount) && amount > 0 && milliseconds) return now + amount * milliseconds;
  }
  const timestamp = error.match(/(?:resets?|try again)\s*(?:at|on|after)\s*:?\s*(\d{4}-\d\d-\d\d[T ]\d\d:\d\d(?::\d\d)?(?:Z|[+-]\d\d:?\d\d))/i);
  if (!timestamp) return null;
  const parsed = Date.parse(timestamp[1]);
  return Number.isFinite(parsed) && parsed > now ? parsed : null;
}

export function providerFailureCooldown(error: string, previous: ProviderCooldown | null, now = Date.now()): ProviderCooldown | null {
  const quota = /(?:usage limit|quota|rate limit|insufficient credits|too many requests|\b429\b)/i.test(error);
  const provider = /(?:<!doctype html|<html\b|text\/html|fetch failed|timed? out|\b50[0234]\b|service unavailable)/i.test(error);
  if (!quota && !provider) return null;
  const failures = Math.min((previous?.failures ?? 0) + 1, 100);
  const minimum = quota ? 60 * 60_000 : Math.min(5 * 60_000 * 2 ** Math.min(failures - 1, 4), 60 * 60_000);
  return { until: Math.max(now + minimum, resetHorizon(error, now) ?? 0), failures, reason: quota ? "quota" : "provider" };
}

function writeRecords(path: string, records: Record<string, ProviderCooldown>): void {
  const temporary = `${path}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(records)}\n`, { mode: 0o600 });
  renameSync(temporary, path);
}

export function writeProviderCooldown(path: string, selection: ProviderSelection, record: ProviderCooldown): void {
  const records = readRecords(path);
  records[key(selection)] = record;
  writeRecords(path, records);
}

export function clearProviderCooldown(path: string, selection: ProviderSelection): boolean {
  const records = readRecords(path);
  const selectedKey = key(selection);
  if (!Object.hasOwn(records, selectedKey)) return false;
  delete records[selectedKey];
  writeRecords(path, records);
  return true;
}

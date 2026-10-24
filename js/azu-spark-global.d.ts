// Types of the browser global the script installs (window.AzuSpark, alias window.Spark). The shipped
// script is a classic IIFE, so its API cannot come from azu-spark.d.ts; this file is written by hand
// and test/globals.test.mjs fails when it misses a member of window.AzuSpark.
import type { SparkOptions, SparkStats, SparkStatus, SparkTelemetry } from "./azu-spark";

/** The details of the events that are not telemetry. */
export interface SparkEvents extends SparkTelemetry {
  open: { attempts: number };
  close: { code: number; reason: string };
  backoff: { delay: number; attempts: number };
  error: { code: string; message?: string; id?: number };
  expired: { code: string };
  offline: { event: string };
  queued: { event: string; size: number };
  event_dropped: { event: string; reason: "queue_full" | "expired" | "disconnect" | "stale" | "rate_limited" | "stopped" };
  patch: { id: string };
  connecting: { attempts: number };
  connected: { attempts: number };
  reconnecting: { attempts: number };
  disconnected: { attempts: number };
}

export interface AzuSpark {
  readonly status: SparkStatus;
  /** Events waiting to be sent. */
  readonly queued: number;
  /** Events sent and not yet answered. */
  readonly unacked: number;
  /** Starts again after disconnect(). */
  connect(): void;
  disconnect(): void;
  /** Subscribes; an event the server pushes to a component is any other name, with its payload. */
  on<K extends keyof SparkEvents>(name: K, fn: (detail: SparkEvents[K]) => void): AzuSpark;
  on(name: string, fn: (detail: any) => void): AzuSpark;
  off(name: string, fn: (detail: any) => void): AzuSpark;
  /** Sends an event of the component around *element*, as if the user had triggered it. */
  push(element: Element, event: string, payload?: Record<string, unknown>): void;
  /** A snapshot of the counters. */
  stats(): SparkStats;
  configure(options: SparkOptions): AzuSpark;
}

declare global {
  interface Window {
    AzuSpark: AzuSpark;
    Spark: AzuSpark;
  }
}

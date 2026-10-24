// Shared by the unit tests: the client module loaded in a happy-dom page, and a fake clock.
import { Window } from "happy-dom";

let loaded;

/** Loads azu-spark.js once, in a DOM without a Spark root (so it opens no socket). */
export async function loadSpark() {
  if (!loaded) {
    const window = new Window({ url: "http://localhost/" });
    for (const name of ["window", "document", "location", "navigator", "DOMParser", "CustomEvent", "URL", "URLSearchParams", "MutationObserver", "Node", "Element"]) {
      if (name === "window") globalThis.window = window;
      else Object.defineProperty(globalThis, name, { value: window[name], configurable: true, writable: true });
    }
    loaded = import("../azu-spark.js");
  }
  return loaded;
}

/** A clock and timers that only move when the test says so. */
export class FakeClock {
  constructor() {
    this.time = 0;
    this.nextId = 1;
    this.scheduled = new Map(); // id -> {due, work, every}
    this.timers = {
      setTimeout: (work, ms) => this.add(work, ms, 0),
      clearTimeout: (id) => this.scheduled.delete(id),
      setInterval: (work, ms) => this.add(work, ms, ms),
      clearInterval: (id) => this.scheduled.delete(id),
    };
  }

  now() { return this.time; }

  add(work, ms, every) {
    const id = this.nextId++;
    this.scheduled.set(id, { due: this.time + ms, work, every });
    return id;
  }

  /** The number of timers that have not fired (intervals count until cleared). */
  pending() { return this.scheduled.size; }

  fire(id) {
    const timer = this.scheduled.get(id);
    if (timer.every) timer.due = this.time + timer.every;
    else this.scheduled.delete(id);
    timer.work();
  }

  /** Moves time forward, running every timer at the moment it is due. */
  advance(ms) {
    const end = this.time + ms;
    for (;;) {
      let next = null;
      for (const [id, timer] of this.scheduled) if (timer.due <= end && (!next || timer.due < next.due)) next = { id, due: timer.due };
      if (!next) break;
      this.time = next.due;
      this.fire(next.id);
    }
    this.time = end;
  }

  /** Moves time forward in one step, the way a throttled or frozen tab does: each due timer runs once, late. */
  jump(ms) {
    this.time += ms;
    for (const [id, timer] of [...this.scheduled]) if (timer.due <= this.time && this.scheduled.has(id)) this.fire(id);
  }
}

/** A machine wired to a fake clock; `log` records the host effects, `sent` the heartbeats. */
export function harness(spark, { settings, random = () => 0.5 } = {}) {
  const clock = new FakeClock();
  const log = [];
  const status = { online: true, canSend: true, beats: 0, slept: 0 };
  const record = (name) => (effect) => log.push({ name, ...effect });
  const machine = spark.createMachine({
    timers: clock.timers,
    now: () => clock.now(),
    wall: () => 1.7e12 + clock.now() + status.slept,
    random,
    online: () => status.online,
    interval: () => 1000,
    beat: () => { if (status.canSend) status.beats++; return status.canSend; },
    tick: () => {},
    status: (name, state) => log.push({ name: "status", status: name, state: state.name }),
    open: record("open"),
    close: record("close"),
    teardown: record("teardown"),
    opened: record("opened"),
    backingOff: (delay, attempts) => log.push({ name: "backingOff", delay, attempts }),
  }, settings);
  const sleep = (ms) => { status.slept += ms; }; // the machine slept: wall time passes, the monotonic clock stops
  const names = () => log.map((entry) => entry.name);
  return { clock, machine, log, status, names, sleep };
}

/** Walks a fresh machine to `open`. */
export function open(h) {
  h.machine.dispatch({ type: "connect" });
  h.machine.frame();
  h.machine.dispatch({ type: "hello" });
  h.machine.dispatch({ type: "joins_settled" });
}

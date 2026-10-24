/*! Azu Spark client. No dependencies; served by the application itself (see Azu::Spark::Client). */
/**
 * Source of truth of the Spark browser client (ES2022 module, JSDoc types). It is not served as is:
 * `node build.mjs` bundles it into the minified script under src/azu/spark/client/azu_spark.js,
 * which the shard embeds. Edit this file, rebuild, commit both. See docs/reference/spark-client.md.
 *
 * Importing the module boots the client (it is a script, not a library); the exports exist for the
 * unit tests in test/ and are dropped from the shipped script.
 */
export type SparkStatus = "connecting" | "connected" | "reconnecting" | "disconnected";
export type QueuedEvent = {
    message: Record<string, unknown>;
    undo?: (() => void) | null;
    key?: string | null;
    at: number;
};
export type SparkMessage = {
    v: number;
    type: string;
    id?: number;
    [field: string]: unknown;
};
export declare var STATES: string[];
export declare var EVENTS: string[];
declare function connectFresh(): {
    state: any;
    effects: any;
};
declare function stopped(state: any): {
    state: any;
    effects: any;
};
declare function paused(state: any): {
    state: any;
    effects: any;
};
declare function afterClose(state: any, event: any): {
    state: any;
    effects: any;
};
declare function retry(state: any): {
    state: any;
    effects: any;
};
declare function networkBack(state: any): {
    state: any;
    effects: any;
};
declare function resume(state: any, event: any): {
    state: any;
    effects: any;
};
/** The transition table: TRANSITIONS[state][event] is (state, event) -> {state, effects}. A missing entry ignores the event. */
export declare var TRANSITIONS: {
    idle: {
        connect: typeof connectFresh;
        pageshow: typeof connectFresh;
        stop: typeof stopped;
    };
    connecting: any;
    joining: any;
    open: any;
    closing: {
        closed: typeof afterClose;
        dead: typeof afterClose;
        stop: (state: any) => {
            state: any;
            effects: any;
        };
        pagehide: (state: any) => {
            state: any;
            effects: any;
        };
        connect: (state: any) => {
            state: any;
            effects: any;
        };
        pageshow: (state: any) => {
            state: any;
            effects: any;
        };
    };
    backoff: {
        backoff_elapsed: typeof retry;
        connect: typeof retry;
        visible: typeof resume;
        online: typeof networkBack;
        offline: (state: any) => {
            state: any;
            effects: any;
        };
        hide_idle: (state: any) => {
            state: any;
            effects: any;
        };
        stop: typeof stopped;
        pagehide: typeof paused;
    };
    offline: {
        online: typeof networkBack;
        connect: typeof retry;
        visible: typeof resume;
        stop: typeof stopped;
        pagehide: typeof paused;
    };
    "hidden-idle": {
        visible: typeof connectFresh;
        connect: typeof connectFresh;
        stop: typeof stopped;
        pagehide: typeof paused;
    };
    stopped: {
        connect: typeof connectFresh;
    };
};
/**
 * The pure transition function.
 * @param {{name: string, attempts: number, then?: string}} state
 * @param {{type: string, online?: boolean, code?: number, reason?: string}} event
 * @returns {{state: object, effects: object[]}}
 */
export declare function next(state: {
    name: string;
    attempts: number;
    then?: string;
}, event: {
    type: string;
    online?: boolean;
    code?: number;
    reason?: string;
}): {
    state: object;
    effects: object[];
};
/**
 * The public status (data-spark-status) of a state.
 * @param {{name: string, attempts: number}} state
 * @returns {SparkStatus}
 */
export declare function statusOf(state: {
    name: string;
    attempts: number;
}): SparkStatus;
/**
 * Delay before reconnect attempt number *attempt* (0 based), in milliseconds.
 * @param {number} attempt
 * @param {() => number} [random] uniform in [0, 1)
 * @returns {number}
 */
export declare function backoff(attempt: number, random?: () => number): number;
/**
 * The supported heartbeat interval for the server's proposal, in milliseconds.
 * @param {unknown} proposed
 * @returns {number}
 */
export declare function heartbeatInterval(proposed: unknown): number;
/**
 * Whether a connection that has been silent for *silence* ms is dead. A half open connection never
 * fires `close`, so silence is the only sign. But a throttled or frozen tab runs its watchdog late
 * (*gap* is the time since its previous run, *period* how often it should run), and frames may sit
 * unread behind it: then the silence proves nothing and the server is asked instead. After a
 * system sleep the monotonic clock may not have advanced at all; *jumped* is how much more the wall
 * clock advanced than the monotonic one, and a large jump also means the server is asked.
 * @param {{silence: number, gap: number, interval: number, period: number, jumped?: number}} measure all in milliseconds
 * @returns {"alive" | "suspect" | "dead"}
 */
export declare function heartbeatVerdict(measure: {
    silence: number;
    gap: number;
    interval: number;
    period: number;
    jumped?: number;
}): "alive" | "suspect" | "dead";
/**
 * Runs the machine: executes the effects of each transition and owns the timers. Everything it
 * touches comes in through *deps*, so it runs against a fake clock in tests.
 * @param {object} deps timers {setTimeout, clearTimeout, setInterval, clearInterval}, now() (monotonic), wall() (Date.now),
 *   random(), online(),
 *   interval() (heartbeat ms), beat() (sends a heartbeat, true when sent), tick(), status(name, state),
 *   and the host effects open, close, teardown, opened, backingOff
 * @param {object} [settings] backoffMin, backoffMax, probeTimeout, stableAfter (ms)
 */
export declare function createMachine(deps: object, settings?: object): {
    readonly state: {
        name: any;
        attempts: any;
    };
    /** Feeds an event to the machine (events raised by effects wait until the current one is done). */
    dispatch: (event: any) => void;
    /** Records that a frame arrived: the proof of life the heartbeat looks for. */
    frame: () => void;
    /** The number of timers that are running. */
    timers: () => number;
};
/**
 * Takes a diff frame: snapshots are kept at once, patches and pushed events wait for the next frame.
 * @param {{ patches?: {id: string, html: string}[], snapshots?: Record<string, string>, events?: {target: string, name: string, payload: unknown}[] }} message
 * @returns {void}
 */
export declare function applyDiff(message: {
    patches?: {
        id: string;
        html: string;
    }[];
    snapshots?: Record<string, string>;
    events?: {
        target: string;
        name: string;
        payload: unknown;
    }[];
}): void;
/**
 * Queues a patch for the component *id*: its content becomes *html*.
 * @param {string} id
 * @param {string} html
 * @returns {void}
 */
export declare function applyPatch(id: string, html: string): void;
/**
 * Runs the queued jobs: reads first, then every write, then restores focus, selection and scroll.
 * @returns {void}
 */
export declare function flushPatches(): void;
/**
 * Parses a patch into an inert fragment.
 * @param {string} html
 * @returns {DocumentFragment}
 */
export declare function parsePatch(html: string): DocumentFragment;
/**
 * Whether an attribute value is a URL that would run script (or load data) when followed.
 * @param {unknown} value
 * @param {string} name attribute name, lower case
 * @returns {boolean}
 */
export declare function scriptUrl(value: unknown, name: string): boolean;
/**
 * Removes blocked elements, event handler attributes and script URLs from *root*, in place.
 * @param {ParentNode} root
 * @param {boolean} [scripts] keep scripts, as copies that can run (the root opted in)
 * @returns {void}
 */
export declare function sanitize(root: ParentNode, scripts?: boolean): void;
export {};

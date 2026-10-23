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
/**
 * Delay before reconnect attempt number *attempt* (0 based), in milliseconds.
 * @param {number} attempt
 * @returns {number}
 */
export declare function backoff(attempt: number): number;
/**
 * The supported heartbeat interval for the server's proposal, in milliseconds.
 * @param {unknown} proposed
 * @returns {number}
 */
export declare function heartbeatInterval(proposed: unknown): number;
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
 * @returns {void}
 */
export declare function sanitize(root: ParentNode): void;

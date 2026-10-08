/**
 * Uppercase error codes carried by Result.err.
 *
 * Each is its own name, a string: a Result's `error`. What each means for a
 * user, and what its details say, is docs/reference/error-codes.md's.
 *
 * @module prometheus_exporter_errors
 */

'use strict';

// Collectors and their sources

/**
 * A file the collector reads is not there or cannot be read.
 *
 * @type {string}
 */
export const SOURCE_UNREADABLE    = 'SOURCE_UNREADABLE';

/**
 * What the collector read (a file, a ubus reply, a program's output) is not
 * what it expects.
 *
 * @type {string}
 */
export const SOURCE_INVALID       = 'SOURCE_INVALID';

/**
 * The collector died with an exception.
 *
 * @type {string}
 */
export const COLLECTOR_CRASHED    = 'COLLECTOR_CRASHED';

/**
 * The collector returned something other than a Result.
 *
 * @type {string}
 */
export const COLLECTOR_NO_RESULT  = 'COLLECTOR_NO_RESULT';

/**
 * A collector module that is not a valid one, or a query that names a
 * collector not installed or disabled.
 *
 * @type {string}
 */
export const COLLECTOR_INVALID    = 'COLLECTOR_INVALID';

// Configuration

/**
 * An option has a value the exporter does not take, or options that go
 * together are not set together.
 *
 * @type {string}
 */
export const CONFIG_INVALID       = 'CONFIG_INVALID';

/**
 * A file the exporter writes (uhttpd's basic auth file) could not be written
 * or removed.
 *
 * @type {string}
 */
export const FILE_UNWRITABLE      = 'FILE_UNWRITABLE';

// Capabilities

/**
 * A capability the collector needs is not installed (nl80211, socket).
 *
 * @type {string}
 */
export const NEED_MISSING         = 'NEED_MISSING';

/**
 * The exporter could not connect to ubus.
 *
 * @type {string}
 */
export const UBUS_CONNECT_FAILED  = 'UBUS_CONNECT_FAILED';

/**
 * A ubus call failed; its data is { status }, libubus's text.
 *
 * @type {string}
 */
export const UBUS_CALL_FAILED     = 'UBUS_CALL_FAILED';

/**
 * An nl80211 request failed.
 *
 * @type {string}
 */
export const NL80211_FAILED       = 'NL80211_FAILED';

/**
 * An rtnetlink request failed.
 *
 * @type {string}
 */
export const RTNL_FAILED          = 'RTNL_FAILED';

/**
 * A Unix socket is missing, refused the connection, or sent no more of its
 * reply in time.
 *
 * @type {string}
 */
export const SOCKET_FAILED        = 'SOCKET_FAILED';

/**
 * The collector ran a program its meta.commands does not list.
 *
 * @type {string}
 */
export const COMMAND_NOT_ALLOWED  = 'COMMAND_NOT_ALLOWED';

/**
 * A program could not start, or exited with a status other than 0.
 *
 * @type {string}
 */
export const COMMAND_FAILED       = 'COMMAND_FAILED';

/**
 * A program was still running when the collector's seconds for programs were
 * spent, and was killed; or one was asked to run after they were.
 *
 * @type {string}
 */
export const COMMAND_TIMEOUT      = 'COMMAND_TIMEOUT';

// The scrape

/**
 * The scrape's time was nearly spent: the collector was not run, or was
 * stopped, or a program it ran was killed, at the deadline.
 *
 * @type {string}
 */
export const SCRAPE_DEADLINE      = 'SCRAPE_DEADLINE';

/**
 * The collector's circuit breaker is open: it was not run in this scrape.
 *
 * @type {string}
 */
export const COLLECTOR_QUARANTINED = 'COLLECTOR_QUARANTINED';

/**
 * What tripped a breaker: the collector took longer than its budget.
 *
 * @type {string}
 */
export const COLLECTOR_OVERRUN    = 'COLLECTOR_OVERRUN';

// What the exporter enforces of a collector

/**
 * The collector was still running at the end of its budget, and was stopped
 * with the process it ran in.
 *
 * @type {string}
 */
export const COLLECTOR_CANCELLED  = 'COLLECTOR_CANCELLED';

/**
 * The process the collector ran in ended while it ran.
 *
 * @type {string}
 */
export const COLLECTOR_KILLED     = 'COLLECTOR_KILLED';

/**
 * The collector wrote more samples than its max_samples, and was stopped there.
 *
 * @type {string}
 */
export const SAMPLE_LIMIT         = 'SAMPLE_LIMIT';

/**
 * The collector wrote a family another collector of the reply wrote first, or
 * one the exporter keeps for itself.
 *
 * @type {string}
 */
export const FAMILY_CONFLICT      = 'FAMILY_CONFLICT';

// Exposition text

/**
 * Text that is not valid Prometheus exposition format.
 *
 * @type {string}
 */
export const EXPOSITION_INVALID   = 'EXPOSITION_INVALID';

/**
 * Uppercase error codes carried by Result.err.
 *
 * @module prometheus_exporter_errors
 */

'use strict';

/** A file the collector reads is not there or cannot be read. */
export const SOURCE_UNREADABLE    = 'SOURCE_UNREADABLE';

/** What the collector read is not what it expects. */
export const SOURCE_INVALID       = 'SOURCE_INVALID';

/** The collector died with an exception. */
export const COLLECTOR_CRASHED    = 'COLLECTOR_CRASHED';

/** The collector returned no Result, or a failure without an error code. */
export const COLLECTOR_NO_RESULT  = 'COLLECTOR_NO_RESULT';

/** An invalid collector module, or a query naming a collector not installed or disabled. */
export const COLLECTOR_INVALID    = 'COLLECTOR_INVALID';

/** A collector module whose top level does more than declare. */
export const COLLECTOR_IMPURE     = 'COLLECTOR_IMPURE';

/** An option has a value the exporter does not take. */
export const CONFIG_INVALID       = 'CONFIG_INVALID';

/** A file the exporter writes could not be written or removed. */
export const FILE_UNWRITABLE      = 'FILE_UNWRITABLE';

/** A capability the collector needs is not installed (nl80211, socket). */
export const NEED_MISSING         = 'NEED_MISSING';

/** The exporter could not connect to ubus. */
export const UBUS_CONNECT_FAILED  = 'UBUS_CONNECT_FAILED';

/** A ubus call failed; its data is { status }, libubus's text. */
export const UBUS_CALL_FAILED     = 'UBUS_CALL_FAILED';

/** An nl80211 request failed. */
export const NL80211_FAILED       = 'NL80211_FAILED';

/** An rtnetlink request failed. */
export const RTNL_FAILED          = 'RTNL_FAILED';

/** A Unix socket is missing, refused the connection, or sent no more of its reply in time. */
export const SOCKET_FAILED        = 'SOCKET_FAILED';

/** The collector ran a program its meta.commands does not list. */
export const COMMAND_NOT_ALLOWED  = 'COMMAND_NOT_ALLOWED';

/** A program could not start, or exited with a status other than 0. */
export const COMMAND_FAILED       = 'COMMAND_FAILED';

/** A program outlived the collector's seconds for programs and was killed. */
export const COMMAND_TIMEOUT      = 'COMMAND_TIMEOUT';

/** The collector called a ubus object or method its meta.ubus does not list. */
export const UBUS_NOT_ALLOWED     = 'UBUS_NOT_ALLOWED';

/** The system refused the service's user what the collector declared. */
export const PERMISSION_DENIED    = 'PERMISSION_DENIED';

/** The scrape's time was nearly spent: the collector was not run, or was stopped. */
export const SCRAPE_DEADLINE      = 'SCRAPE_DEADLINE';

/** The collector's circuit breaker is open: it was not run in this scrape. */
export const COLLECTOR_QUARANTINED = 'COLLECTOR_QUARANTINED';

/** What tripped a breaker: the collector took longer than its budget. */
export const COLLECTOR_OVERRUN    = 'COLLECTOR_OVERRUN';

/** The collector was stopped at the end of its budget. */
export const COLLECTOR_CANCELLED  = 'COLLECTOR_CANCELLED';

/** The process the collector ran in ended while it ran. */
export const COLLECTOR_KILLED     = 'COLLECTOR_KILLED';

/** The collector was not run: the scrape's processes died before running it. */
export const COLLECTOR_NOT_RUN    = 'COLLECTOR_NOT_RUN';

/** The collector wrote more samples than its max_samples, and was stopped there. */
export const SAMPLE_LIMIT         = 'SAMPLE_LIMIT';

/** The collector wrote a family another collector, or the exporter, wrote first. */
export const FAMILY_CONFLICT      = 'FAMILY_CONFLICT';

/** Text that is not valid Prometheus exposition format. */
export const EXPOSITION_INVALID   = 'EXPOSITION_INVALID';

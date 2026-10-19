/**
 * The error codes a collector and its capabilities fail with, a namespace ucode keeps constant.
 *
 * @module prometheus_exporter_api_errors
 */

'use strict';

import * as codes from 'prometheus.exporter.errors';

/**
 * codes.SOURCE_UNREADABLE
 *
 * @type {string}
 */
export const SOURCE_UNREADABLE = codes.SOURCE_UNREADABLE;

/**
 * codes.SOURCE_INVALID
 *
 * @type {string}
 */
export const SOURCE_INVALID = codes.SOURCE_INVALID;

/**
 * codes.CONFIG_INVALID
 *
 * @type {string}
 */
export const CONFIG_INVALID = codes.CONFIG_INVALID;

/**
 * codes.UBUS_CONNECT_FAILED
 *
 * @type {string}
 */
export const UBUS_CONNECT_FAILED = codes.UBUS_CONNECT_FAILED;

/**
 * codes.UBUS_CALL_FAILED
 *
 * @type {string}
 */
export const UBUS_CALL_FAILED = codes.UBUS_CALL_FAILED;

/**
 * codes.NL80211_FAILED
 *
 * @type {string}
 */
export const NL80211_FAILED = codes.NL80211_FAILED;

/**
 * codes.RTNL_FAILED
 *
 * @type {string}
 */
export const RTNL_FAILED = codes.RTNL_FAILED;

/**
 * codes.SOCKET_FAILED
 *
 * @type {string}
 */
export const SOCKET_FAILED = codes.SOCKET_FAILED;

/**
 * codes.COMMAND_NOT_ALLOWED
 *
 * @type {string}
 */
export const COMMAND_NOT_ALLOWED = codes.COMMAND_NOT_ALLOWED;

/**
 * codes.COMMAND_FAILED
 *
 * @type {string}
 */
export const COMMAND_FAILED = codes.COMMAND_FAILED;

/**
 * codes.COMMAND_TIMEOUT
 *
 * @type {string}
 */
export const COMMAND_TIMEOUT = codes.COMMAND_TIMEOUT;

/**
 * codes.UBUS_NOT_ALLOWED
 *
 * @type {string}
 */
export const UBUS_NOT_ALLOWED = codes.UBUS_NOT_ALLOWED;

/**
 * codes.PERMISSION_DENIED
 *
 * @type {string}
 */
export const PERMISSION_DENIED = codes.PERMISSION_DENIED;

/**
 * codes.SCRAPE_DEADLINE
 *
 * @type {string}
 */
export const SCRAPE_DEADLINE = codes.SCRAPE_DEADLINE;

/**
 * codes.EXPOSITION_INVALID
 *
 * @type {string}
 */
export const EXPOSITION_INVALID = codes.EXPOSITION_INVALID;

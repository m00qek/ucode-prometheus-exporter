/**
 * The error codes a collector and its capabilities fail with, a namespace ucode keeps constant.
 *
 * @module prometheus_exporter_api_errors
 */

'use strict';

import * as codes from 'prometheus.exporter.errors';

/** codes.SOURCE_UNREADABLE */
export const SOURCE_UNREADABLE = codes.SOURCE_UNREADABLE;

/** codes.SOURCE_INVALID */
export const SOURCE_INVALID = codes.SOURCE_INVALID;

/** codes.CONFIG_INVALID */
export const CONFIG_INVALID = codes.CONFIG_INVALID;

/** codes.UBUS_CONNECT_FAILED */
export const UBUS_CONNECT_FAILED = codes.UBUS_CONNECT_FAILED;

/** codes.UBUS_CALL_FAILED */
export const UBUS_CALL_FAILED = codes.UBUS_CALL_FAILED;

/** codes.NL80211_FAILED */
export const NL80211_FAILED = codes.NL80211_FAILED;

/** codes.RTNL_FAILED */
export const RTNL_FAILED = codes.RTNL_FAILED;

/** codes.SOCKET_FAILED */
export const SOCKET_FAILED = codes.SOCKET_FAILED;

/** codes.COMMAND_NOT_ALLOWED */
export const COMMAND_NOT_ALLOWED = codes.COMMAND_NOT_ALLOWED;

/** codes.COMMAND_FAILED */
export const COMMAND_FAILED = codes.COMMAND_FAILED;

/** codes.COMMAND_TIMEOUT */
export const COMMAND_TIMEOUT = codes.COMMAND_TIMEOUT;

/** codes.UBUS_NOT_ALLOWED */
export const UBUS_NOT_ALLOWED = codes.UBUS_NOT_ALLOWED;

/** codes.PERMISSION_DENIED */
export const PERMISSION_DENIED = codes.PERMISSION_DENIED;

/** codes.SCRAPE_DEADLINE */
export const SCRAPE_DEADLINE = codes.SCRAPE_DEADLINE;

/** codes.EXPOSITION_INVALID */
export const EXPOSITION_INVALID = codes.EXPOSITION_INVALID;

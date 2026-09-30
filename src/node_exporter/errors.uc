'use strict';

// Uppercase error codes carried by Result.err.

// Collectors and their sources
export const SOURCE_UNREADABLE    = 'SOURCE_UNREADABLE';
export const SOURCE_INVALID       = 'SOURCE_INVALID';
export const COLLECTOR_CRASHED    = 'COLLECTOR_CRASHED';
export const COLLECTOR_NO_RESULT  = 'COLLECTOR_NO_RESULT';
export const COLLECTOR_INVALID    = 'COLLECTOR_INVALID';

// Configuration
export const CONFIG_INVALID       = 'CONFIG_INVALID';

// Capabilities
export const NEED_MISSING         = 'NEED_MISSING';
export const UBUS_CONNECT_FAILED  = 'UBUS_CONNECT_FAILED';
export const UBUS_CALL_FAILED     = 'UBUS_CALL_FAILED';
export const NL80211_FAILED       = 'NL80211_FAILED';
export const COMMAND_NOT_ALLOWED  = 'COMMAND_NOT_ALLOWED';
export const COMMAND_FAILED       = 'COMMAND_FAILED';

// Exposition text
export const EXPOSITION_INVALID   = 'EXPOSITION_INVALID';

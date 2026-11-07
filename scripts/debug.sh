#!/bin/bash
# Sends a debug command to Perch started with PERCH_DEBUG=1.
# ./scripts/debug.sh expand | collapse | drop | toast | loading | draghint | cancel | state | ask:<question> | shot:/path/to/file.png
CMD="$1" osascript -l JavaScript -e '
ObjC.import("Foundation");
const cmd = $.NSProcessInfo.processInfo.environment.objectForKey("CMD").js;
$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("perch.debug", cmd, $(), true);' >/dev/null

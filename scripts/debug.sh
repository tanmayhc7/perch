#!/bin/bash
# Sends a debug command to a claude-notch started with CLAUDE_NOTCH_DEBUG=1.
# ./scripts/debug.sh expand | collapse | drop | toast | shot:/path/to/file.png
CMD="$1" osascript -l JavaScript -e '
ObjC.import("Foundation");
const cmd = $.NSProcessInfo.processInfo.environment.objectForKey("CMD").js;
$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("claude-notch.debug", cmd, $(), true);' >/dev/null

#!/usr/bin/env bash
# hermes-desktop [status|off|on] [--for 4h] - take the desktop's models out of Hermes's loop while you use the desktop
# for something else, and put them back afterwards. The work is done by the kit copy in @@HS_SHARED@@.
exec bash "@@HS_SHARED@@/tools/desktop-loop.sh" "$@"

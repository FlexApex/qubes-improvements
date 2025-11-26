#!/bin/sh

# Read the last Qubes global clipboard contents in dom0 from
# /run/qubes/qubes-clipboard.bin, strip everything except basic ASCII
# and copy the sanitized result into the dom0 X clipboard via xclip.
# Keeps user informed via notify-send (same as qubes clipboard)
#
# Security considerations:
# - Script removes EVERYTHING except for these allowed characters:
#   tab, newline, carriage return, ASCII printable chars 0x20-0x7E
# - Removal includes all terminal control / escape sequences and non-ASCII bytes
# - Removes trailing newline (helps avoid immediate execution)
# - Verifies the source clipboard file exists and is non-empty, checks
#   that xclip is available, and refuses to proceed if sanitization
#   yields an empty result
# - Keeps user informed via notify-send and warns if filtering was performed
#
# Remaining risks:
# - The tr utility handles the unfiltered clipboard. It could have a vulnerability.
#   Care is taken to not feed other tools with unfiltered content
# - This script won't save you from copying malicious commands. It only ensures
#   that you receive only visible ASCII in dom0 clipboard.
#
# Further reading:
# - Demo site showing danger of copy-pasting from browser:
#   https://thejh.net/misc/website-terminal-copy-paste

CLIPFILE=/run/qubes/qubes-clipboard.bin
SOURCEFILE=/run/qubes/qubes-clipboard.bin.source
NOTIFY_TIMEOUT=7500 # Notification duration (in ms). Long enough to keep user informed
MAX_CLIPBOARD_SIZE=$((10*1024*1024)) # 10 MiB

# Behavior when filtering removed any characters:
#   0 - Abort with error
#   1 - warn and copy sanitized content (content might be incomplete)
ALLOW_FILTERED=1

# Check that xclip is available
if ! command -v xclip >/dev/null 2>&1; then
    notify-send -t $NOTIFY_TIMEOUT "Dom0 clipboard" "ERROR: Package xclip is not installed in dom0"
    exit 1
fi

# Check if clipboard file exists and is non-empty
if [ ! -f "$CLIPFILE" ] || [ ! -s "$CLIPFILE" ]; then
    notify-send -t $NOTIFY_TIMEOUT "Dom0 clipboard" "Global clipboard empty"
    exit 1
fi

# Sanitize source qube name, even though it's set by dom0 (trusted). We don't want any fancy chars in our notification
source_qube=$(LC_ALL=C tr -cd '\t -~' < "$SOURCEFILE")

# Original size in bytes from filesystem metadata, avoid feeding it to a tool such as wc
orig_bytes=$(stat -c '%s' -- "$CLIPFILE") || exit 1

if [ "$orig_bytes" -gt "$MAX_CLIPBOARD_SIZE" ]; then
    notify-send -t $NOTIFY_TIMEOUT "Dom0 clipboard" "ERROR: Clipboard from '$source_qube' is too large ($orig_bytes bytes)"
    exit 1
fi

# Sanitize clipboard. Keep only:
#   \t  = tab           0x09, octal 011
#   \n  = newline       0x0A, octal 012
#   \r  = carriage ret  0x0D, octal 015
#   Safe ASCII Range	space (0x20, octal 040) to tilde (0x7E, octal 176)
sanitized=$(LC_ALL=C tr -cd '\t\n\r -~' < "$CLIPFILE")

# Check if anything is left after filtering
if [ -z "$sanitized" ]; then
    notify-send -t $NOTIFY_TIMEOUT "Dom0 clipboard" "Clipboard from '$source_qube' contained no safe ASCII characters after filtering"
    exit 1
fi

# Size of sanitized content in bytes
sanitized_bytes=$(printf '%s' "$sanitized" | LC_ALL=C wc -c)

# Detect if any bytes were removed (sanitization changed content size)
# Note: This detects any removal, not just non-ASCII; but thats what we want.
removed_bytes=$((orig_bytes - sanitized_bytes))
if [ "$removed_bytes" -gt 0 ]; then
    # Abort if filtering occurred?
    if [ "$ALLOW_FILTERED" -ne 1 ]; then
    	notify-send -t $NOTIFY_TIMEOUT "Dom0 clipboard" "ERROR: Clipboard from '$source_qube' contained unsafe characters. You can set ALLOW_FILTERED=1"
        exit 0
    fi

    # Show the warning longer, it's important to read
    notify-send -t $((NOTIFY_TIMEOUT*2)) "Dom0 clipboard" "WARNING: $removed_bytes unsafe bytes from '$source_qube' removed. Copied content is incomplete, check before use"
fi

# For information only (does not affect behavior)
chars=$(printf '%s' "$sanitized" | LC_ALL=C wc -m)

# Copy sanitized content into dom0 clipboard
printf '%s' "$sanitized" | xclip -rmlastnl -selection clipboard
notify-send -t $NOTIFY_TIMEOUT "Dom0 clipboard" "Copied $chars safe ASCII chars from '$source_qube'"

# Wipe the global clipboard like qubes does
: > "$CLIPFILE"
: > "$SOURCEFILE"

exit 0

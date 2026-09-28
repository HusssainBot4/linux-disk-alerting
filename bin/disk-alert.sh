#!/usr/bin/env bash
#
# disk-alert.sh
# Threshold-based disk and inode alerting with de-duplication.
#
# Exit codes:
#   0 = all clear
#   1 = warnings sent
#   2 = critical alerts sent
#   3 = script failure
#

set -euo pipefail

SCRIPT_NAME="disk-alert"

BASE_DIR="/opt/project-2-disk-usage"
CONFIG="${BASE_DIR}/conf/disk-alert.conf"
LOG_FILE="${BASE_DIR}/logs/${SCRIPT_NAME}.log"

HOST="$(hostname -f 2>/dev/null || hostname)"
NOW="$(date +%s)"

OVERALL=0

# Load configuration if it exists.
if [[ -f "$CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG"
fi

# Apply defaults if configuration did not define these.
STATE_DIR="${STATE_DIR:-${BASE_DIR}/state/disk}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-3600}"

# Make sure required runtime directories exist.
mkdir -p "$STATE_DIR" "${BASE_DIR}/logs"

# Write a timestamped message to the log.
log() {
    printf '%s [%-8s] %s\n' \
        "$(date '+%F %T')" \
        "$1" \
        "${*:2}" >> "$LOG_FILE"
}

# Raise the overall severity if this check is worse
# than anything we have seen so far.
escalate() {
    (( $1 > OVERALL )) && OVERALL=$1
    return 0
}

# thresholds_for <mount>
#
# Prints:
#     warning critical
#
# Example:
#     thresholds_for "/var"
#     -> 70 85
#
# If the mount is not explicitly configured,
# DEFAULT_WARN and DEFAULT_CRIT are used.
thresholds_for() {
    local mount="$1"
    local line m w c

    while read -r line; do
        [[ -z "$line" ]] && continue

        IFS=':' read -r m w c <<< "$line"

        if [[ "$m" == "$mount" ]]; then
            echo "$w $c"
            return 0
        fi
    done <<< "${MOUNT_THRESHOLDS:-}"

    echo "${DEFAULT_WARN:-80} ${DEFAULT_CRIT:-90}"
}

# Convert a mount path into a filesystem-safe state key.
#
# Example:
#   /var/log -> _var_log
#
state_key() {
    echo "${1//\//_}"
}


echo "BASE_DIR=$BASE_DIR"
echo "CONFIG=$CONFIG"
echo "LOG_FILE=$LOG_FILE"
echo "STATE_DIR=$STATE_DIR"
echo "HOST=$HOST"
echo "NOW=$NOW"

echo
echo "Threshold tests:"
echo "/      -> $(thresholds_for "/")"
echo "/var   -> $(thresholds_for "/var")"
echo "/home  -> $(thresholds_for "/home")"
echo "/tmp   -> $(thresholds_for "/tmp")"

echo
echo "State key tests:"
echo "/      -> $(state_key "/")"
echo "/var   -> $(state_key "/var")"
echo "/var/log -> $(state_key "/var/log")"

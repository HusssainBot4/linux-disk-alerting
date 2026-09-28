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

# should_alert <mount> <severity>
#
# Returns:
#   0 = yes, send an alert
#   1 = no, suppress the alert
#
should_alert() {
    local mount="$1"
    local sev="$2"
    local key state_file last_time last_sev age

    key="$(state_key "$mount")"
    state_file="${STATE_DIR}/${key}.state"

    # We have never alerted for this mount.
    if [[ ! -f "$state_file" ]]; then
        return 0
    fi

    read -r last_time last_sev < "$state_file"

    last_time="${last_time:-0}"
    last_sev="${last_sev:-0}"

    # A severity escalation always bypasses cooldown.
    if (( sev > last_sev )); then
        log INFO "escalation on ${mount}: ${last_sev} -> ${sev}, alerting"
        return 0
    fi

    age=$(( NOW - last_time ))

    # Cooldown has expired.
    if (( age >= COOLDOWN_SECONDS )); then
        return 0
    fi

    # Still inside cooldown.
    log INFO "suppressed ${mount} sev=${sev}, ${age}s into ${COOLDOWN_SECONDS}s cooldown"
    return 1
}

record_alert() {
    local mount="$1"
    local sev="$2"

    printf '%s %s\n' "$NOW" "$sev" \
        > "${STATE_DIR}/$(state_key "$mount").state"
}


# Called when a previously-alerting mount
# returns below the warning threshold.
clear_alert() {
    local mount="$1"
    local state_file="${STATE_DIR}/$(state_key "$mount").state"

    if [[ -f "$state_file" ]]; then
        rm -f "$state_file"

        log OK "${mount} recovered below threshold"

        send_alert "RECOVERED" "$mount" \
            "Disk usage on ${mount} has returned below the warning threshold on ${HOST}."
    fi
}

# growth_for <mount> <current_used_kb>
#
# Compares the current used space with the previous reading.
# Stores the current reading for the next run.
growth_for() {
    local mount="$1"
    local used_kb="$2"

    local hist="${STATE_DIR}/$(state_key "$mount").history"
    local prev_time prev_used delta_kb delta_sec rate

    if [[ -f "$hist" ]]; then
        read -r prev_time prev_used < "$hist"

        delta_sec=$(( NOW - prev_time ))
        delta_kb=$(( used_kb - prev_used ))

        if (( delta_sec > 0 )); then
            rate=$(awk \
                -v k="$delta_kb" \
                -v s="$delta_sec" \
                'BEGIN { printf "%.2f", (k/1048576) / (s/3600) }')

            printf 'changed %+.2f GB in %d min (%.2f GB/hour)' \
                "$(awk -v k="$delta_kb" 'BEGIN { print k/1048576 }')" \
                "$(( delta_sec / 60 ))" \
                "$rate"
        fi
    else
        printf 'no previous reading'
    fi

    printf '%s %s\n' "$NOW" "$used_kb" > "$hist"
}

# top_consumers <mount>
#
# Shows the largest directories and files under a mount,
# plus deleted-but-open files that still consume disk space.
top_consumers() {
    local mount="$1"

    echo " Largest directories under ${mount}:"

    du -xh --max-depth=2 "$mount" 2>/dev/null \
        | sort -rh \
        | head -n "${TOP_DIRS:-5}" \
        | while read -r size path; do
            printf ' %-8s %s\n' "$size" "$path"
        done

    echo
    echo " Largest files under ${mount}:"

    find "$mount" -xdev -type f -printf '%s\t%p\n' 2>/dev/null \
        | sort -rn \
        | head -n "${TOP_FILES:-5}" \
        | while IFS=$'\t' read -r bytes path; do
            printf ' %-8s %s\n' \
                "$(numfmt --to=iec --suffix=B "$bytes")" \
                "$path"
        done

    echo
    echo " Deleted files still held open (space not yet reclaimed):"

    lsof -nP +L1 2>/dev/null \
        | awk -v m="$mount" \
            'NR>1 && $0 ~ m {
                printf " %-10s %-8s %s\n", $1, $2, $NF
            }' \
        | head -n 5 \
        || echo " none"
}

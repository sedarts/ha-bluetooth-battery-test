#!/usr/bin/env bash
# Execute an explicit wake's Classic/A2DP recovery callbacks within one
# absolute deadline. Dependency-free so retry bounds can be smoke-tested.
run_classic_wake_retries() {
    local maximum="$1" deadline="$2" attempt_callback="$3" ready_callback="$4" failure_callback="$5"
    local attempt ran=0
    for ((attempt = 1; attempt <= maximum; attempt++)); do
        if [ "${deadline}" -gt 0 ] && [ "$(date +%s)" -ge "${deadline}" ]; then
            break
        fi
        "${attempt_callback}" "${attempt}" "${maximum}" || true
        ran=$((ran + 1))
        if "${ready_callback}"; then
            return 0
        fi
        if [ "${attempt}" -lt "${maximum}" ] && { [ "${deadline}" -le 0 ] || [ "$(date +%s)" -lt "${deadline}" ]; }; then
            sleep 1
        fi
    done
    "${failure_callback}" "${ran}" "${maximum}"
    return 1
}

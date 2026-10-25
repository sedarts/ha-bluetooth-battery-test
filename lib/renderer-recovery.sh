#!/usr/bin/env bash
# Small bounded readiness check and single-flight guard shared by run.sh and
# the dependency-free renderer recovery smoke test.

wait_for_a2dp_sink() {
    local mac="$1" sink="$2" card="$3" pause_file="$4" attempts="${5:-5}"
    local attempt info sinks

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if [ -e "${pause_file}" ]; then
            bashio::log.info "A2DP readiness wait cancelled because ${mac} is paused." || true
            return 2
        fi

        ensure_audio_sink "${sink}" "${card}"
        info=$(bluetoothctl info "${mac}" 2>/dev/null) || true
        sinks=$(pactl list short sinks 2>/dev/null) || true
        if grep -q '^[[:space:]]*Connected: yes' <<<"${info}" \
            && grep -Fq "${sink}" <<<"${sinks}"; then
            bashio::log.info "Bluetooth and A2DP sink are ready for ${mac}." || true
            return 0
        fi

        if [ "${attempt}" -lt "${attempts}" ]; then
            sleep 1
        fi
    done

    bashio::log.warning "A2DP sink for ${mac} did not become ready within ${attempts} checks; reconnect monitor will retry." || true
    return 1
}

wait_for_reconnect_or_wake() {
    local wake_request="$1" pause_file="$2" interval="$3" elapsed=0
    while [ "${elapsed}" -lt "${interval}" ]; do
        if [ ! -e "${wake_request}" ]; then
            wake_request_consumed=false
        elif [ ! -e "${pause_file}" ] && [ "${wake_request_consumed:-false}" != true ]; then
            wake_request_consumed=true
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 0
}

acquire_reconnect_lock() {
    local lock_dir="$1"
    mkdir -p "$(dirname "${lock_dir}")" || return 1

    if mkdir "${lock_dir}" 2>/dev/null; then
        printf '%s\n' "${BASHPID:-$$}" > "${lock_dir}/pid"
        return 0
    fi

    # Treat any existing directory as busy. Removing it here could race a
    # process that has created the directory but not yet written its pid.
    return 1
}

release_reconnect_lock() {
    local lock_dir="$1" owner=""
    [ -r "${lock_dir}/pid" ] && owner=$(<"${lock_dir}/pid")
    [ "${owner}" = "${BASHPID:-$$}" ] || return 1
    rm -f "${lock_dir}/pid" && rmdir "${lock_dir}"
}

recover_renderer_after_connect() {
    local mac="$1" name="$2" sink="$3" card="$4" pause_file="$5" lock_dir="$6" attempts="${7:-5}"
    local connect_timeout="${8:-8}" connect_lock_wait="${9:-10}"
    if [ -e "${pause_file}" ]; then
        bashio::log.info "Reconnect skipped because ${name} is paused." || true
        return 2
    fi
    if ! acquire_reconnect_lock "${lock_dir}"; then
        bashio::log.info "Reconnect already in progress for ${name}; skipping duplicate attempt." || true
        return 2
    fi

    if [ -e "${pause_file}" ]; then
        release_reconnect_lock "${lock_dir}" || true
        bashio::log.info "Reconnect skipped because ${name} became paused." || true
        return 2
    fi
    connect_speaker "${mac}" "${name}" "${connect_timeout}" "${connect_lock_wait}" || true
    if wait_for_a2dp_sink "${mac}" "${sink}" "${card}" "${pause_file}" "${attempts}"; then
        start_renderer
        release_reconnect_lock "${lock_dir}" || true
        return 0
    else
        local status=$?
        release_reconnect_lock "${lock_dir}" || true
        return "${status}"
    fi
}

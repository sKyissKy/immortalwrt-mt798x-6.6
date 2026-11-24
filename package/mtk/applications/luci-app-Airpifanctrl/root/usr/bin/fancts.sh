#!/bin/sh
# H5000M Fan Controller - Dynamic thermal regulation and robust kernel handover

find_pwm() {
    found=
    for name in "${FANCTRL_ROOT}/sys/class/hwmon"/hwmon*/name; do
        [ -r "$name" ] || continue
        [ "$(cat "$name" 2>/dev/null)" = pwmfan ] || continue
        node="${name%/name}/pwm1"
        [ -r "$node" ] && [ -w "$node" ] || continue
        [ -z "$found" ] || return 1
        found="$node"
    done
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}

write_verified_file() {
    target_path="$1"
    expected_val="$2"
    target_dir="${target_path%/*}"
    [ -d "$target_dir" ] || mkdir -p "$target_dir" 2>/dev/null || return 1
    printf '%s\n' "$expected_val" > "$target_path" 2>/dev/null || return 1
    actual_val=$(tr -d '\r\n ' < "$target_path" 2>/dev/null) || return 1
    [ "$actual_val" = "$expected_val" ]
}

restore_kernel_thermal() {
    if ! is_still_active_smart_owner; then
        return 0
    fi
    RESTORE_CALLED=1
    full_speed="${1:-0}"
    rc=0

    if [ "$full_speed" = "1" ]; then
        if [ -z "$pwm_node" ]; then
            pwm_node=$(find_pwm 2>/dev/null || true)
        fi
        if [ -z "$thermal_mode" ] || ! write_verified_file "$thermal_mode" "disabled"; then
            rc=1
        fi
        if [ -n "$pwm_node" ] && [ -w "${pwm_node}_enable" ]; then
            write_verified_file "${pwm_node}_enable" "1" || rc=1
        fi
        if [ -z "$pwm_node" ] || ! write_verified_file "$pwm_node" "255"; then
            rc=1
        fi
    else
        if [ -z "$thermal_mode" ] || ! write_verified_file "$thermal_mode" "enabled"; then
            rc=1
        fi
    fi

    if [ "$rc" -ne 0 ]; then
        RESTORE_RC=1
        logger -t Airpifanctrl -p daemon.err "restore_kernel_thermal failed (full_speed=$full_speed)" 2>/dev/null || true
        mkdir -p "${errfile%/*}" 2>/dev/null || true
        printf 'thermal_restore_failed\n' > "$errfile" 2>/dev/null || true
        return 1
    fi

    RESTORE_RC=0
    if [ -f "$readyfile" ] && [ "$(tr -d '\r\n ' < "$readyfile" 2>/dev/null)" != "$$" ]; then
        rm -f "$errfile" 2>/dev/null || true
        return 0
    fi
    rm -f "$readyfile" "$errfile" 2>/dev/null || true
    return 0
}

parse_qtemp_output() {
    _best=
    while IFS= read -r _line; do
        case "$_line" in
            *+QTEMP:*)
                _val=$(printf '%s\n' "$_line" | sed -n 's/.*"\([-+0-9.]*\)"[[:space:]]*$/\1/p')
                [ -n "$_val" ] || _val=$(printf '%s\n' "$_line" | sed -n 's/.*,[[:space:]]*\([-+0-9.]*\)[[:space:]]*$/\1/p')
                _val=$(printf '%s' "$_val" | tr -d '\r ' | cut -d. -f1)
                case "$_val" in
                    ''|*[!0-9]*) continue ;;
                esac
                if [ "$_val" -gt 0 ] 2>/dev/null && [ "$_val" -le 130 ] 2>/dev/null; then
                    if [ -z "$_best" ] || [ "$_val" -gt "$_best" ] 2>/dev/null; then
                        _best="$_val"
                    fi
                fi
                ;;
        esac
    done
    if [ -n "$_best" ]; then
        printf '%s\n' "$((_best * 1000))"
        return 0
    fi
    return 1
}

parse_chiptemp_output() {
    _raw=$(grep 'CHIPTEMP' | sed -n '1p' | cut -d, -f9 | sed '/^$/d' | tr -d '\r ' | cut -d. -f1)
    case "$_raw" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$_raw" -gt 0 ] 2>/dev/null || return 1
    if [ "$_raw" -le 150 ]; then
        _raw=$((_raw * 1000))
    elif [ "$_raw" -le 1500 ]; then
        _raw=$((_raw * 100))
    fi
    printf '%s\n' "$_raw"
}

read_valid_temp() {
    temp_source_conf="${FANCTRL_ROOT}/etc/fanvallv.conf"
    temp=
    if [ -r "$temp_source_conf" ]; then
        temp_source_val=$(tr -d '\r\n ' < "$temp_source_conf" 2>/dev/null || true)
        if [ "$temp_source_val" = "modem" ]; then
            _at_ports=
            if [ -r "${FANCTRL_ROOT}/etc/config/qmodem" ]; then
                _at_ports=$(sed -n "s/.*option[[:space:]]\{1,\}at_port[[:space:]]\{1,\}['\"]\{0,1\}\([^'\"[:space:]]\{1,\}\)['\"]\{0,1\}.*/\1/p" "${FANCTRL_ROOT}/etc/config/qmodem" 2>/dev/null)
            fi
            if [ -z "${FANCTRL_ROOT}" ] && command -v ubus >/dev/null 2>&1; then
                for _cand in $_at_ports /dev/ttyUSB2 /dev/ttyUSB3; do
                    [ -e "$_cand" ] || continue
                    temp=$(ubus -t 2 call at-daemon sendat "{\"at_port\":\"$_cand\",\"at_cmd\":\"AT+QTEMP\",\"timeout\":2}" 2>/dev/null | sed 's/\\r/\n/g; s/\\n/\n/g; s/\\"/"/g' | parse_qtemp_output) || true
                    [ -n "$temp" ] && break
                    temp=$(ubus -t 2 call at-daemon sendat "{\"at_port\":\"$_cand\",\"at_cmd\":\"AT^CHIPTEMP?\",\"timeout\":2}" 2>/dev/null | sed 's/\\r/\n/g; s/\\n/\n/g; s/\\"/"/g' | parse_chiptemp_output) || true
                    [ -n "$temp" ] && break
                done
            fi
            if [ -z "$temp" ]; then
                for _cand in /dev/ttyUSB3 /dev/ttyUSB2 /dev/ttyUSB1 /dev/mhi_DUN $_at_ports; do
                    _dev="${FANCTRL_ROOT}${_cand}"
                    [ -e "$_dev" ] || continue
                    if [ -x "${FANCTRL_ROOT}/usr/bin/sms_tool" ]; then
                        temp=$("${FANCTRL_ROOT}/usr/bin/sms_tool" -d "$_dev" at 'AT+QTEMP' 2>/dev/null | parse_qtemp_output) || true
                        [ -n "$temp" ] && break
                        temp=$("${FANCTRL_ROOT}/usr/bin/sms_tool" -d "$_dev" at 'AT^CHIPTEMP?' 2>/dev/null | parse_chiptemp_output) || true
                        [ -n "$temp" ] && break
                    elif [ -z "${FANCTRL_ROOT}" ] && command -v sms_tool >/dev/null 2>&1; then
                        temp=$(sms_tool -d "$_dev" at 'AT+QTEMP' 2>/dev/null | parse_qtemp_output) || true
                        [ -n "$temp" ] && break
                        temp=$(sms_tool -d "$_dev" at 'AT^CHIPTEMP?' 2>/dev/null | parse_chiptemp_output) || true
                        [ -n "$temp" ] && break
                    fi
                done
            fi
            if [ -z "$temp" ] && command -v sendat >/dev/null 2>&1; then
                if [ -e "${FANCTRL_ROOT}/dev/ttyUSB1" ] || [ -e "/dev/ttyUSB1" ]; then
                    temp=$(sendat 1 'AT+QTEMP' 2>/dev/null | parse_qtemp_output) || true
                    [ -n "$temp" ] || temp=$(sendat 1 'AT^CHIPTEMP?' 2>/dev/null | parse_chiptemp_output) || true
                fi
            fi
        fi
    fi

    if [ -z "$temp" ]; then
        temp_zone="${FANCTRL_ROOT}/sys/class/thermal/thermal_zone0/temp"
        [ -r "$temp_zone" ] || return 1
        temp=$(cat "$temp_zone" 2>/dev/null | tr -d '\r\n ' | cut -d. -f1)
    fi

    case "$temp" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$temp" -gt 0 ] 2>/dev/null || return 1
    if [ "$temp" -lt 200 ]; then
        temp=$((temp * 1000))
    fi
    [ "$temp" -le 150000 ] 2>/dev/null || return 1
    printf '%s\n' "$temp"
}

is_confirmed_fancts_pid() {
    _pid="$1"
    case "$_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$_pid" 2>/dev/null || return 1
    _stat="${FANCTRL_ROOT}/proc/${_pid}/stat"
    [ -r "$_stat" ] || _stat="/proc/${_pid}/stat"
    if [ -r "$_stat" ] && grep -q ') Z' "$_stat" 2>/dev/null; then
        return 1
    fi
    _cmdline="${FANCTRL_ROOT}/proc/${_pid}/cmdline"
    [ -r "$_cmdline" ] || _cmdline="/proc/${_pid}/cmdline"
    [ -r "$_cmdline" ] || return 1
    tr '\000' ' ' < "$_cmdline" 2>/dev/null | grep -q 'fancts\.sh'
}

read_self_start_ticks() {
    _stat="${FANCTRL_ROOT}/proc/$$/stat"
    [ -r "$_stat" ] || _stat="/proc/$$/stat"
    [ -r "$_stat" ] || return 1
    _ticks=$(sed 's/^.*)//' "$_stat" 2>/dev/null | awk '{print $20}')
    case "$_ticks" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$_ticks"
}

write_atomic_runtime_file() {
    _target="$1"
    _val="$2"
    _dir="${_target%/*}"
    [ -d "$_dir" ] || mkdir -p "$_dir" 2>/dev/null || return 1
    _tmp="${_target}.tmp.$$"
    printf '%s\n' "$_val" > "$_tmp" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
    _got=$(tr -d '\r\n ' < "$_tmp" 2>/dev/null) || { rm -f "$_tmp" 2>/dev/null; return 1; }
    [ "$_got" = "$_val" ] || { rm -f "$_tmp" 2>/dev/null; return 1; }
    mv -f "$_tmp" "$_target" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
    _actual=$(tr -d '\r\n ' < "$_target" 2>/dev/null) || return 1
    [ "$_actual" = "$_val" ]
}

write_owner_atomic() {
    _dir="${ownerfile%/*}"
    [ -d "$_dir" ] || mkdir -p "$_dir" 2>/dev/null || return 1
    _tmp="${ownerfile}.tmp.$$"
    _gen_esc=$(printf '%s' "$GEN" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"generation":"%s","pid":%s,"start_ticks":"%s"}\n' "$_gen_esc" "$$" "$START_TICKS" > "$_tmp" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
    mv -f "$_tmp" "$ownerfile" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
    [ -r "$ownerfile" ]
}

owner_matches_self() {
    [ -f "$ownerfile" ] || return 1
    _raw=$(tr -d '\r\n' < "$ownerfile" 2>/dev/null) || return 1
    _opid=$(printf '%s\n' "$_raw" | sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*"*\([0-9][0-9]*\)"*.*/\1/p')
    _ogen=$(printf '%s\n' "$_raw" | sed -n 's/.*"generation"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    _gen_esc=$(printf '%s' "$GEN" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g')
    [ "$_opid" = "$$" ] && [ "$_ogen" = "$_gen_esc" ]
}

cleanup_runtime_files() {
    _keep_ready="${1:-0}"
    if [ -f "$lockfile" ] && [ "$(tr -d '\r\n ' < "$lockfile" 2>/dev/null)" = "$$" ]; then
        rm -f "$lockfile" 2>/dev/null || true
    fi
    if owner_matches_self; then
        rm -f "$ownerfile" 2>/dev/null || true
    fi
    if [ "$_keep_ready" != "1" ] && [ -f "$readyfile" ] && [ "$(tr -d '\r\n ' < "$readyfile" 2>/dev/null)" = "$$" ]; then
        rm -f "$readyfile" 2>/dev/null || true
    fi
}

is_still_active_smart_owner() {
    if [ -f "$readyfile" ] && [ "$(tr -d '\r\n ' < "$readyfile" 2>/dev/null)" = "manual" ]; then
        return 1
    fi
    if [ "$SMART_LOOP_ACTIVE" = "1" ] && [ -r "${FANCTRL_ROOT}/etc/fanvall" ]; then
        _cur_fv=$(tr -d '\r\n ' < "${FANCTRL_ROOT}/etc/fanvall" 2>/dev/null || true)
        case "$_cur_fv" in
            0|1|2|3|999) return 1 ;;
        esac
    fi
    if [ ! -f "$lockfile" ] || [ "$(tr -d '\r\n ' < "$lockfile" 2>/dev/null)" != "$$" ]; then
        return 1
    fi
    if [ -f "$ownerfile" ] && ! owner_matches_self; then
        return 1
    fi
    if [ -f "$readyfile" ] && [ "$(tr -d '\r\n ' < "$readyfile" 2>/dev/null)" != "$$" ]; then
        return 1
    fi
    return 0
}

GEN="${1:-boot}"
[ -n "$GEN" ] || GEN="boot"
lockfile="${FANCTRL_ROOT}/var/run/cooling_control.pid"
ownerfile="${FANCTRL_ROOT}/var/run/cooling_control.owner.json"
readyfile="${FANCTRL_ROOT}/var/run/cooling_control.ready"
errfile="${FANCTRL_ROOT}/var/run/cooling_control.error"
thermal_mode="${FANCTRL_ROOT}/sys/class/thermal/thermal_zone0/mode"
fanspeed_conf="${FANCTRL_ROOT}/usr/bin/fanspeed.conf"
sleep_sec="${FANCTRL_SLEEP:-4}"
HANDOVER_MANUAL_DONE=0
SMART_LOOP_ACTIVE=0
RESTORE_CALLED=0
RESTORE_RC=0

mkdir -p "${FANCTRL_ROOT}/var/run" 2>/dev/null || true

if [ -e "$lockfile" ]; then
    pid=$(cat "$lockfile" 2>/dev/null | tr -d '\r\n ')
    if is_confirmed_fancts_pid "$pid"; then
        echo "Script is already running with PID $pid."
        exit 1
    else
        rm -f "$lockfile" "$readyfile" "$ownerfile" 2>/dev/null || true
    fi
fi

rm -f "$readyfile" "$ownerfile" 2>/dev/null || true
START_TICKS=$(read_self_start_ticks) || exit 1
write_atomic_runtime_file "$lockfile" "$$" || exit 1

handle_cleanup() {
    local sig_exit="${1:-0}"
    trap - INT TERM EXIT

    if [ "$HANDOVER_MANUAL_DONE" != "1" ] && is_still_active_smart_owner; then
        if [ "$RESTORE_CALLED" != "1" ]; then
            if ! restore_kernel_thermal 0; then
                cleanup_runtime_files 1
                exit 1
            fi
        elif [ "$RESTORE_RC" -ne 0 ]; then
            cleanup_runtime_files 1
            exit 1
        fi
    fi

    if [ "$HANDOVER_MANUAL_DONE" = "1" ] || [ "$RESTORE_RC" -ne 0 ]; then
        cleanup_runtime_files 1
    else
        cleanup_runtime_files 0
    fi

    if [ "$sig_exit" = "1" ]; then
        exit 0
    fi
}

trap 'handle_cleanup 1' INT TERM
trap 'handle_cleanup 0' EXIT

write_owner_atomic || exit 1

# Step 1: Discover unique pwm_node and verify thermal_mode writable
pwm_node=$(find_pwm) || { restore_kernel_thermal 0; exit 1; }
[ -r "$thermal_mode" ] && [ -w "$thermal_mode" ] || { restore_kernel_thermal 0; exit 1; }

# Step 2: Validate temperature source
init_temp=$(read_valid_temp) || { restore_kernel_thermal 1; exit 1; }

compute_smart_pwm() {
    _temp="$1"
    _prev="${2:-0}"

    if [ "$_temp" -ge 75000 ] 2>/dev/null; then
        printf '255\n'
        return 0
    elif [ "$_temp" -ge 68000 ] 2>/dev/null; then
        _raw=$((200 + (_temp - 68000) * 55 / 7000))
    elif [ "$_temp" -ge 55000 ] 2>/dev/null; then
        _raw=$((112 + (_temp - 55000) * 88 / 13000))
    elif [ "$_temp" -ge 40000 ] 2>/dev/null; then
        _raw=$((64 + (_temp - 40000) * 48 / 15000))
    else
        _raw=64
    fi

    if [ "$_raw" -lt 64 ]; then
        _raw=64
    elif [ "$_raw" -gt 255 ]; then
        _raw=255
    fi

    if [ "$_prev" -gt 0 ] 2>/dev/null; then
        _diff=$((_raw - _prev))
        if [ "$_diff" -gt 0 ]; then
            if [ "$_diff" -le 3 ] && [ "$_raw" -lt 255 ]; then
                _raw="$_prev"
            elif [ "$_diff" -gt 12 ]; then
                _raw=$((_prev + 12))
            fi
        elif [ "$_diff" -lt 0 ]; then
            if [ "$_diff" -ge -3 ] && [ "$_raw" -gt 64 ]; then
                _raw="$_prev"
            elif [ "$_diff" -lt -6 ]; then
                _raw=$((_prev - 6))
            fi
        fi
    fi

    printf '%s\n' "$_raw"
}

# Step 3: Read fanvall and compute init_pwm
if [ -r "${FANCTRL_ROOT}/etc/fanvall" ]; then
    fanvall=$(tr -d '\r\n ' < "${FANCTRL_ROOT}/etc/fanvall" 2>/dev/null || echo 4)
else
    fanvall=4
fi
case "$fanvall" in
    3) init_pwm=255 ;;
    2) init_pwm=192 ;;
    1) init_pwm=128 ;;
    0) init_pwm=64 ;;
    999)
        saved_pwm=$(tr -d '\r\n ' < "$fanspeed_conf" 2>/dev/null)
        case "$saved_pwm" in
            ''|*[!0-9]*) saved_pwm=192 ;;
        esac
        if [ "$saved_pwm" -lt 0 ] 2>/dev/null; then
            saved_pwm=0
        elif [ "$saved_pwm" -gt 255 ] 2>/dev/null; then
            saved_pwm=255
        fi
        init_pwm="$saved_pwm"
        ;;
    *)
        init_pwm=$(compute_smart_pwm "$init_temp" 0)
        ;;
esac

# Step 4: Write and verify initial PWM
write_verified_file "$pwm_node" "$init_pwm" || { restore_kernel_thermal 0; exit 1; }

# Step 5: Confirm userspace thermal handover
write_verified_file "$thermal_mode" "disabled" || { restore_kernel_thermal 0; exit 1; }
if [ -w "${pwm_node}_enable" ]; then
    write_verified_file "${pwm_node}_enable" "1" || { restore_kernel_thermal 0; exit 1; }
fi

# Step 6: Re-verify/write pwm_node (and fanspeed_conf only in manual modes to avoid flash wear)
write_verified_file "$pwm_node" "$init_pwm" || { restore_kernel_thermal 0; exit 1; }
case "$fanvall" in
    0|1|2|3|999)
        write_verified_file "$fanspeed_conf" "$init_pwm" || { restore_kernel_thermal 0; exit 1; }
        ;;
esac

# Step 7: Atomically write ready file last (after pid, owner.json, pwm, and thermal handover)
write_atomic_runtime_file "$readyfile" "$$" || { restore_kernel_thermal 0; exit 1; }
rm -f "$errfile" 2>/dev/null || true

# Step 8: Manual mode exit
case "$fanvall" in
    0|1|2|3|999)
        HANDOVER_MANUAL_DONE=1
        exit 0
        ;;
esac

# Step 9: Smart mode loop
SMART_LOOP_ACTIVE=1
cur_pwm="$init_pwm"
while true; do
    temp=$(read_valid_temp) || { restore_kernel_thermal 1; exit 1; }
    target_pwm=$(compute_smart_pwm "$temp" "$cur_pwm")
    if [ "$target_pwm" != "$cur_pwm" ] || [ "$(tr -d '\r\n ' < "$pwm_node" 2>/dev/null)" != "$target_pwm" ]; then
        write_verified_file "$pwm_node" "$target_pwm" || { restore_kernel_thermal 1; exit 1; }
    fi
    cur_pwm="$target_pwm"
    sleep "$sleep_sec"
done

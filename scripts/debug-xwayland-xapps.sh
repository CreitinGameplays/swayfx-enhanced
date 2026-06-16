#!/usr/bin/env bash
set -Eeuo pipefail

# Debug Xwayland/X11 client failures under SwayFX, especially xterm failures
# such as "fatal IO error 11" or cases where launching an X app crashes the WM.
# Run from inside the affected SwayFX session.

SCRIPT_NAME="$(basename "$0")"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-$PWD/xwayland-xapps-debug-$RUN_ID}"
SWAYMSG_BIN="${SWAYMSG_BIN:-swaymsg}"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"
XTERM_BIN="${XTERM_BIN:-xterm}"
XAPP_TIMEOUT="${XAPP_TIMEOUT:-20}"
SUBSCRIBE_TIMEOUT="${SUBSCRIBE_TIMEOUT:-60}"
JOURNAL_TIMEOUT="${JOURNAL_TIMEOUT:-75}"
APP_COMMAND="${APP_COMMAND:-}"

PIDS=()

log() {
	printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT_DIR/debug-script.log"
}

warn() {
	printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT_DIR/debug-script.log" >&2
}

die() {
	printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT_DIR/debug-script.log" >&2
	exit 1
}

cleanup() {
	local status=$?
	for pid in "${PIDS[@]:-}"; do
		if kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
		fi
	done
	exit "$status"
}
trap cleanup EXIT

usage() {
	cat <<EOF
Usage:
  $SCRIPT_NAME collect
  $SCRIPT_NAME xterm
  $SCRIPT_NAME stress
  $SCRIPT_NAME app -- <command> [args...]

Environment:
  OUT_DIR=path             Output directory, default ./xwayland-xapps-debug-<time>
  XTERM_BIN=xterm          xterm binary
  XAPP_TIMEOUT=20          Seconds to let each X app run
  APP_COMMAND='xeyes'      Optional app command for "app" mode

Recommended:
  1. Run inside the affected SwayFX session:
     bash scripts/debug-xwayland-xapps.sh xterm
  2. If xterm sometimes crashes the WM, run:
     bash scripts/debug-xwayland-xapps.sh stress
  3. Send the generated .tar.gz archive.

Notes:
  - This script intentionally avoids destructive actions.
  - If the compositor crashes, run the script again in "collect" mode after
    restarting SwayFX so it can capture post-crash system state.

EOF
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1
}

run_capture() {
	local name="$1"
	shift
	{
		printf '$'
		printf ' %q' "$@"
		printf '\n\n'
		"$@"
	} >"$OUT_DIR/$name.out" 2>"$OUT_DIR/$name.err" || {
		local code=$?
		printf 'exit=%s\n' "$code" >"$OUT_DIR/$name.exit"
		return 0
	}
	printf 'exit=0\n' >"$OUT_DIR/$name.exit"
}

run_shell_capture() {
	local name="$1"
	local command="$2"
	{
		printf '$ %s\n\n' "$command"
		sh -c "$command"
	} >"$OUT_DIR/$name.out" 2>"$OUT_DIR/$name.err" || {
		local code=$?
		printf 'exit=%s\n' "$code" >"$OUT_DIR/$name.exit"
		return 0
	}
	printf 'exit=0\n' >"$OUT_DIR/$name.exit"
}

run_swaymsg() {
	local name="$1"
	shift
	if need_cmd "$SWAYMSG_BIN"; then
		run_capture "$name" "$SWAYMSG_BIN" "$@"
	else
		warn "swaymsg not found; skipped $name"
	fi
}

find_sway_pid() {
	pgrep -u "$USER" -f '(^|/)(sway|swayfx)( |$)' | head -n 1 || true
}

find_xwayland_pids() {
	pgrep -u "$USER" -f '(^|/)Xwayland( |$)' || true
}

write_environment() {
	log "Writing environment snapshot"
	{
		echo "run_id=$RUN_ID"
		echo "date=$(date --iso-8601=seconds)"
		echo "user=$USER"
		echo "hostname=$(hostname)"
		echo "pwd=$PWD"
		echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
		echo "DISPLAY=${DISPLAY:-}"
		echo "SWAYSOCK=${SWAYSOCK:-}"
		echo "XAUTHORITY=${XAUTHORITY:-}"
		echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-}"
		echo "XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-}"
		echo "GDK_BACKEND=${GDK_BACKEND:-}"
		echo "QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-}"
		echo "PATH=$PATH"
		echo
		echo "kernel:"
		uname -a || true
		echo
		echo "binaries:"
		for bin in "$SWAYMSG_BIN" sway swayfx Xwayland xterm xeyes xclock xdpyinfo xprop xwininfo xauth xlsclients glxinfo strace gdb coredumpctl journalctl loginctl ps ss lsof; do
			if command -v "$bin" >/dev/null 2>&1; then
				printf '%-16s %s\n' "$bin" "$(command -v "$bin")"
			else
				printf '%-16s missing\n' "$bin"
			fi
		done
		echo
		echo "versions:"
		"$SWAYMSG_BIN" -t get_version 2>/dev/null || true
		Xwayland -version 2>&1 || true
		"$XTERM_BIN" -version 2>&1 || true
	} >"$OUT_DIR/environment.txt" 2>&1
}

snapshot_ipc() {
	local prefix="$1"
	log "Capturing sway IPC snapshot: $prefix"
	run_swaymsg "$prefix-version" -t get_version
	run_swaymsg "$prefix-tree" -t get_tree
	run_swaymsg "$prefix-workspaces" -t get_workspaces
	run_swaymsg "$prefix-outputs" -t get_outputs
	run_swaymsg "$prefix-inputs" -t get_inputs
	run_swaymsg "$prefix-seats" -t get_seats
}

snapshot_processes() {
	local prefix="$1"
	log "Capturing process/socket snapshot: $prefix"
	run_shell_capture "$prefix-processes" "ps -eo pid,ppid,pgid,sid,stat,wchan:24,comm,args | grep -E 'sway|swayfx|Xwayland|xterm|xeyes|xclock|foot|dbus|pipewire' | grep -v grep"
	run_shell_capture "$prefix-xwayland-pids" "pgrep -a -u '$USER' -f '(^|/)Xwayland( |$)' || true"
	run_shell_capture "$prefix-sockets" "ss -xlpn 2>/dev/null | grep -E 'X11|wayland|sway|Xwayland|\\.X11-unix' || true"
	run_shell_capture "$prefix-top" "top -b -n 1 -c | head -n 30"
	run_shell_capture "$prefix-tmp-x11" "ls -la /tmp/.X11-unix /tmp 2>/dev/null | sed -n '1,160p'"
	if need_cmd lsof; then
		run_shell_capture "$prefix-lsof-xwayland" "pids=\$(pgrep -u '$USER' -f '(^|/)Xwayland( |$)' | tr '\n' ','); pids=\${pids%,}; if [ -n \"\$pids\" ]; then lsof -nP -p \"\$pids\"; fi"
	fi
}

snapshot_x11() {
	local prefix="$1"
	log "Capturing X11/Xwayland client snapshot: $prefix"
	if [[ -n "${DISPLAY:-}" ]]; then
		if need_cmd xdpyinfo; then
			run_capture "$prefix-xdpyinfo" xdpyinfo
		fi
		if need_cmd xlsclients; then
			run_capture "$prefix-xlsclients" xlsclients -la
		fi
		if need_cmd xprop; then
			run_capture "$prefix-xprop-root" xprop -root
		fi
		if need_cmd xauth; then
			run_capture "$prefix-xauth-list" xauth list
		fi
	else
		warn "DISPLAY is empty; X11 client checks will likely fail"
	fi
}

capture_proc_state() {
	local prefix="$1"
	local sway_pid
	sway_pid="$(find_sway_pid)"
	if [[ -n "$sway_pid" ]]; then
		log "Capturing compositor proc state: pid=$sway_pid"
		{
			echo "pid=$sway_pid"
			tr '\0' ' ' <"/proc/$sway_pid/cmdline" || true
			echo
		} >"$OUT_DIR/$prefix-compositor-cmdline.txt" 2>&1
		cp "/proc/$sway_pid/status" "$OUT_DIR/$prefix-compositor-status.txt" 2>/dev/null || true
		cp "/proc/$sway_pid/limits" "$OUT_DIR/$prefix-compositor-limits.txt" 2>/dev/null || true
		cp "/proc/$sway_pid/maps" "$OUT_DIR/$prefix-compositor-maps.txt" 2>/dev/null || true
		if need_cmd gdb; then
			(
				gdb -q -batch \
					-ex "set pagination off" \
					-ex "thread apply all bt 30" \
					-p "$sway_pid"
			) >"$OUT_DIR/$prefix-compositor-gdb-bt.txt" 2>"$OUT_DIR/$prefix-compositor-gdb-bt.err" || true
		fi
	else
		warn "Could not find sway/swayfx PID"
	fi

	local xpid
	while read -r xpid; do
		[[ -n "$xpid" ]] || continue
		log "Capturing Xwayland proc state: pid=$xpid"
		{
			echo "pid=$xpid"
			tr '\0' ' ' <"/proc/$xpid/cmdline" || true
			echo
		} >"$OUT_DIR/$prefix-xwayland-$xpid-cmdline.txt" 2>&1
		cp "/proc/$xpid/status" "$OUT_DIR/$prefix-xwayland-$xpid-status.txt" 2>/dev/null || true
		cp "/proc/$xpid/limits" "$OUT_DIR/$prefix-xwayland-$xpid-limits.txt" 2>/dev/null || true
		if need_cmd gdb; then
			(
				gdb -q -batch \
					-ex "set pagination off" \
					-ex "thread apply all bt 30" \
					-p "$xpid"
			) >"$OUT_DIR/$prefix-xwayland-$xpid-gdb-bt.txt" 2>"$OUT_DIR/$prefix-xwayland-$xpid-gdb-bt.err" || true
		fi
	done < <(find_xwayland_pids)
}

start_ipc_subscribe() {
	local prefix="$1"
	if ! need_cmd "$SWAYMSG_BIN"; then
		return
	fi
	log "Starting sway IPC subscription: $prefix"
	(
		"$TIMEOUT_BIN" "$SUBSCRIBE_TIMEOUT" "$SWAYMSG_BIN" -m -t subscribe \
			'["window","workspace","mode","input","binding","shutdown"]'
	) >"$OUT_DIR/$prefix-ipc-events.jsonl" 2>"$OUT_DIR/$prefix-ipc-events.err" &
	PIDS+=("$!")
}

start_journal_capture() {
	local prefix="$1"
	if ! need_cmd journalctl; then
		warn "journalctl not found; skipped journal capture"
		return
	fi
	log "Starting journal capture: $prefix"
	(
		journalctl --user --since now -f -o short-precise
	) >"$OUT_DIR/$prefix-journal-user.log" 2>"$OUT_DIR/$prefix-journal-user.err" &
	local user_pid=$!
	PIDS+=("$user_pid")
	(
		journalctl --since now -f -o short-precise
	) >"$OUT_DIR/$prefix-journal-system.log" 2>"$OUT_DIR/$prefix-journal-system.err" &
	local system_pid=$!
	PIDS+=("$system_pid")
	(
		sleep "$JOURNAL_TIMEOUT"
		kill "$user_pid" "$system_pid" 2>/dev/null || true
	) >/dev/null 2>&1 &
	PIDS+=("$!")
}

start_compositor_watchdog() {
	local prefix="$1"
	log "Starting compositor watchdog"
	(
		for i in $(seq 1 "$JOURNAL_TIMEOUT"); do
			date --iso-8601=seconds
			local_pid="$(find_sway_pid)"
			echo "sway_pid=${local_pid:-missing}"
			find_xwayland_pids | sed 's/^/xwayland_pid=/'
			sleep 1
		done
	) >"$OUT_DIR/$prefix-watchdog.log" 2>"$OUT_DIR/$prefix-watchdog.err" &
	PIDS+=("$!")
}

start_strace_monitors() {
	local prefix="$1"
	if ! need_cmd strace; then
		warn "strace not found; skipped process monitors"
		return
	fi
	local sway_pid
	sway_pid="$(find_sway_pid)"
	if [[ -n "$sway_pid" ]]; then
		log "Starting strace monitor for sway compositor (PID $sway_pid)"
		(
			timeout "$XAPP_TIMEOUT" strace -p "$sway_pid" -f -o "$OUT_DIR/$prefix-sway-$sway_pid.strace"
		) >/dev/null 2>&1 &
		PIDS+=("$!")
	fi

	local xpid
	while read -r xpid; do
		[[ -n "$xpid" ]] || continue
		log "Starting strace monitor for Xwayland (PID $xpid)"
		(
			timeout "$XAPP_TIMEOUT" strace -p "$xpid" -f -o "$OUT_DIR/$prefix-xwayland-$xpid.strace"
		) >/dev/null 2>&1 &
		PIDS+=("$!")
	done < <(find_xwayland_pids)
}

run_xapp() {
	local prefix="$1"
	shift
	local -a cmd=("$@")
	log "Running X app ($prefix): ${cmd[*]}"
	(
		echo "DISPLAY=${DISPLAY:-}"
		echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
		echo "command=${cmd[*]}"
		echo
		"$TIMEOUT_BIN" "$XAPP_TIMEOUT" "${cmd[@]}"
	) >"$OUT_DIR/$prefix.stdout" 2>"$OUT_DIR/$prefix.stderr" || {
		local code=$?
		printf 'exit=%s\n' "$code" >"$OUT_DIR/$prefix.exit"
		return 0
	}
	printf 'exit=0\n' >"$OUT_DIR/$prefix.exit"
}

run_xapp_strace() {
	local prefix="$1"
	shift
	local -a cmd=("$@")
	if ! need_cmd strace; then
		warn "strace not found; skipped strace for ${cmd[*]}"
		return
	fi
	log "Running strace for ($prefix): ${cmd[*]}"
	(
		strace -ff -tt -s 256 \
			-o "$OUT_DIR/$prefix.strace" \
			"$TIMEOUT_BIN" "$XAPP_TIMEOUT" "${cmd[@]}"
	) >"$OUT_DIR/$prefix-strace.stdout" 2>"$OUT_DIR/$prefix-strace.stderr" || {
		local code=$?
		printf 'exit=%s\n' "$code" >"$OUT_DIR/$prefix-strace.exit"
		return 0
	}
	printf 'exit=0\n' >"$OUT_DIR/$prefix-strace.exit"
}

run_case() {
	local prefix="$1"
	shift
	local -a cmd=("$@")

	log "===== CASE: $prefix ====="
	snapshot_ipc "$prefix-before"
	snapshot_processes "$prefix-before"
	snapshot_x11 "$prefix-before"
	capture_proc_state "$prefix-before"
	start_ipc_subscribe "$prefix"
	start_journal_capture "$prefix"
	start_compositor_watchdog "$prefix"
	start_strace_monitors "$prefix"

	run_xapp "$prefix-app" "${cmd[@]}"
	sleep 1
	snapshot_ipc "$prefix-after"
	snapshot_processes "$prefix-after"
	snapshot_x11 "$prefix-after"
	capture_proc_state "$prefix-after"

	run_xapp_strace "$prefix-app" "${cmd[@]}"
	sleep 1
	snapshot_processes "$prefix-after-strace"
	log "Finished case: $prefix"
}

run_stress() {
	log "===== STRESS: repeated xterm launches ====="
	snapshot_ipc "stress-before"
	snapshot_processes "stress-before"
	capture_proc_state "stress-before"
	start_ipc_subscribe "stress"
	start_journal_capture "stress"
	start_compositor_watchdog "stress"
	start_strace_monitors "stress"

	for i in $(seq 1 10); do
		log "Stress iteration $i"
		run_xapp "stress-xterm-$i" "$XTERM_BIN" -T "xwayland-debug-$i" -e sh -lc 'echo xterm-started; sleep 3'
		sleep 1
		snapshot_processes "stress-iter-$i"
		local sway_pid
		sway_pid="$(find_sway_pid)"
		if [[ -z "$sway_pid" ]]; then
			warn "Compositor appears to be gone after stress iteration $i"
			break
		fi
	done

	snapshot_ipc "stress-after"
	snapshot_processes "stress-after"
	capture_proc_state "stress-after"
}

collect_coredumps() {
	local prefix="$1"
	if ! need_cmd coredumpctl; then
		warn "coredumpctl not found; skipped coredump capture"
		return
	fi
	log "Capturing recent coredumps"
	run_capture "$prefix-coredump-list" coredumpctl --no-pager --since "30 minutes ago"
	for exe in sway swayfx Xwayland xterm; do
		coredumpctl --no-pager --since "30 minutes ago" info "$exe" \
			>"$OUT_DIR/$prefix-coredump-$exe-info.txt" 2>"$OUT_DIR/$prefix-coredump-$exe-info.err" || true
	done
}

analyze_outputs() {
	log "Writing quick analysis summaries"
	{
		echo "X app stderr/errors:"
		grep -RniE 'fatal|error|resource temporarily unavailable|killclient|x io|broken pipe|connection|Bad[A-Z]|segmentation|abort|crash' \
			"$OUT_DIR"/*stderr "$OUT_DIR"/*err 2>/dev/null || true
		echo
		echo "Xwayland process/socket evidence:"
		grep -RniE 'Xwayland|DISPLAY|/tmp/.X11-unix|xterm|xeyes|xclock' \
			"$OUT_DIR"/*processes* "$OUT_DIR"/*sockets* "$OUT_DIR"/*xwayland* "$OUT_DIR"/environment.txt 2>/dev/null || true
		echo
		echo "IPC Xwayland window events:"
		grep -RniE '"shell": "xwayland"|"window_properties"|xterm|xeyes|xclock|"change": "new"|"change": "close"' \
			"$OUT_DIR"/*ipc-events* "$OUT_DIR"/*tree.out 2>/dev/null || true
		echo
		echo "Recent coredumps:"
		grep -RniE 'sway|swayfx|Xwayland|xterm|signal|stack trace|executable' \
			"$OUT_DIR"/*coredump* 2>/dev/null || true
		echo
		echo "strace connection-related lines:"
		grep -RniE 'connect|ECONN|EAGAIN|EPIPE|SIGPIPE|SIGSEGV|SIGABRT|write\\(|read\\(|/tmp/.X11-unix|Xauthority' \
			"$OUT_DIR"/*.strace* 2>/dev/null | head -n 500 || true
	} >"$OUT_DIR/analysis-grep.txt"
}

archive_outputs() {
	local archive="$OUT_DIR.tar.gz"
	log "Creating archive: $archive"
	tar -czf "$archive" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")"
	log "Archive ready: $archive"
}

collect_baseline() {
	snapshot_ipc "baseline"
	snapshot_processes "baseline"
	snapshot_x11 "baseline"
	capture_proc_state "baseline"
	collect_coredumps "baseline"
}

main() {
	local mode="${1:-}"
	case "$mode" in
		collect|xterm|stress|app)
			;;
		-h|--help|help|"")
			usage
			exit 0
			;;
		*)
			usage
			die "Unknown mode: $mode"
			;;
	esac

	need_cmd "$TIMEOUT_BIN" || die "timeout command not found"
	need_cmd "$SWAYMSG_BIN" || warn "swaymsg not found; compositor IPC capture will be incomplete"
	[[ -n "${WAYLAND_DISPLAY:-}" ]] || warn "WAYLAND_DISPLAY is empty"
	[[ -n "${SWAYSOCK:-}" ]] || warn "SWAYSOCK is empty"
	[[ -n "${DISPLAY:-}" ]] || warn "DISPLAY is empty; Xwayland may not be active"

	mkdir -p "$OUT_DIR"
	: >"$OUT_DIR/debug-script.log"
	log "Output directory: $OUT_DIR"
	write_environment

	case "$mode" in
		collect)
			collect_baseline
			;;
		xterm)
			need_cmd "$XTERM_BIN" || die "xterm not found"
			run_case "xterm" "$XTERM_BIN" -T "xwayland-debug-xterm" -e sh -lc 'echo xterm-started; env | sort | grep -E "DISPLAY|WAYLAND|XAUTH"; sleep 8'
			collect_coredumps "xterm"
			;;
		stress)
			need_cmd "$XTERM_BIN" || die "xterm not found"
			run_stress
			collect_coredumps "stress"
			;;
		app)
			shift
			if [[ "$#" -gt 0 && "${1:-}" == "--" ]]; then
				shift
			fi
			if [[ "$#" -gt 0 ]]; then
				run_case "custom-app" "$@"
			elif [[ -n "$APP_COMMAND" ]]; then
				run_shell_capture "custom-app-command" "$APP_COMMAND"
			else
				die "app mode requires -- <command> or APP_COMMAND='...'"
			fi
			collect_coredumps "custom-app"
			;;
	esac

	analyze_outputs
	archive_outputs
}

main "$@"

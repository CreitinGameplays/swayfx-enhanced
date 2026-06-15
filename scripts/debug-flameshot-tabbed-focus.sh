#!/usr/bin/env bash
set -Eeuo pipefail

# Debug SwayFX/Flameshot focus loss where tabbed containers steal input from
# the Flameshot GUI overlay. Run this inside the affected SwayFX session.

SCRIPT_NAME="$(basename "$0")"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-$PWD/flameshot-focus-debug-$RUN_ID}"
FLAMESHOT_BIN="${FLAMESHOT_BIN:-flameshot}"
SWAYMSG_BIN="${SWAYMSG_BIN:-swaymsg}"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"
FLAMESHOT_TIMEOUT="${FLAMESHOT_TIMEOUT:-20}"
SUBSCRIBE_TIMEOUT="${SUBSCRIBE_TIMEOUT:-45}"
JOURNAL_TIMEOUT="${JOURNAL_TIMEOUT:-60}"
PROTO_TIMEOUT="${PROTO_TIMEOUT:-25}"

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
  $SCRIPT_NAME tabbed
  $SCRIPT_NAME stacked
  $SCRIPT_NAME compare

Environment:
  OUT_DIR=path                 Output directory, default ./flameshot-focus-debug-<time>
  FLAMESHOT_BIN=flameshot      Flameshot binary
  FLAMESHOT_TIMEOUT=20         Seconds to let flameshot gui run
  SUBSCRIBE_TIMEOUT=45         Seconds to capture sway IPC events
  JOURNAL_TIMEOUT=60           Seconds to capture user journal

Recommended:
  1. Open two terminals in the affected workspace.
  2. Run: bash scripts/debug-flameshot-tabbed-focus.sh compare
  3. In each test, trigger the bug exactly like normal.
  4. Send the generated .tar.gz archive.

EOF
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || return 1
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
	pgrep -xu "$USER" -f '(^|/)(sway|swayfx)( |$)' | head -n 1 || true
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
		echo "SWAYSOCK=${SWAYSOCK:-}"
		echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-}"
		echo "XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-}"
		echo "DESKTOP_SESSION=${DESKTOP_SESSION:-}"
		echo "FLAMESHOT_BIN=$FLAMESHOT_BIN"
		echo "PATH=$PATH"
		echo
		echo "kernel:"
		uname -a || true
		echo
		echo "binaries:"
		for bin in "$SWAYMSG_BIN" "$FLAMESHOT_BIN" sway swayfx wayland-info wev jq journalctl gdb strace; do
			if command -v "$bin" >/dev/null 2>&1; then
				printf '%-16s %s\n' "$bin" "$(command -v "$bin")"
			else
				printf '%-16s missing\n' "$bin"
			fi
		done
		echo
		echo "versions:"
		"$SWAYMSG_BIN" -t get_version 2>/dev/null || true
		"$FLAMESHOT_BIN" --version 2>/dev/null || true
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
	run_swaymsg "$prefix-marks" -t get_marks
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
	log "Starting user journal capture: $prefix"
	(
		journalctl --user --since now -f -o short-precise
	) >"$OUT_DIR/$prefix-journal-user.log" 2>"$OUT_DIR/$prefix-journal-user.err" &
	local pid=$!
	PIDS+=("$pid")
	(
		sleep "$JOURNAL_TIMEOUT"
		kill "$pid" 2>/dev/null || true
	) >/dev/null 2>&1 &
	PIDS+=("$!")
}

capture_proc_state() {
	local prefix="$1"
	local pid
	pid="$(find_sway_pid)"
	if [[ -z "$pid" ]]; then
		warn "Could not find sway/swayfx PID"
		return
	fi
	log "Capturing compositor proc state: pid=$pid"
	{
		echo "pid=$pid"
		tr '\0' ' ' <"/proc/$pid/cmdline" || true
		echo
	} >"$OUT_DIR/$prefix-compositor-cmdline.txt" 2>&1
	cp "/proc/$pid/status" "$OUT_DIR/$prefix-compositor-status.txt" 2>/dev/null || true
	cp "/proc/$pid/maps" "$OUT_DIR/$prefix-compositor-maps.txt" 2>/dev/null || true
	if need_cmd gdb; then
		(
			gdb -q -batch \
				-ex "set pagination off" \
				-ex "thread apply all bt 20" \
				-p "$pid"
		) >"$OUT_DIR/$prefix-compositor-gdb-bt.txt" 2>"$OUT_DIR/$prefix-compositor-gdb-bt.err" || true
	fi
}

capture_wayland_info() {
	local prefix="$1"
	if need_cmd wayland-info; then
		log "Capturing wayland-info"
		"$TIMEOUT_BIN" 5 wayland-info >"$OUT_DIR/$prefix-wayland-info.txt" 2>"$OUT_DIR/$prefix-wayland-info.err" || true
	fi
}

set_layout() {
	local layout="$1"
	log "Setting workspace layout: $layout"
	run_swaymsg "layout-$layout" layout "$layout"
	sleep 0.5
}

focus_active_workspace() {
	run_swaymsg "focus-active-workspace" focus tiling
	sleep 0.2
}

run_flameshot_protocol() {
	local prefix="$1"
	log "Starting Flameshot with WAYLAND_DEBUG=1 for $PROTO_TIMEOUT seconds"
	(
		WAYLAND_DEBUG=1 "$TIMEOUT_BIN" "$PROTO_TIMEOUT" "$FLAMESHOT_BIN" gui
	) >"$OUT_DIR/$prefix-flameshot.stdout" 2>"$OUT_DIR/$prefix-flameshot-wayland-debug.log" || {
		printf 'exit=%s\n' "$?" >"$OUT_DIR/$prefix-flameshot.exit"
		return 0
	}
	printf 'exit=0\n' >"$OUT_DIR/$prefix-flameshot.exit"
}

run_flameshot_normal() {
	local prefix="$1"
	log "Starting normal Flameshot GUI for $FLAMESHOT_TIMEOUT seconds"
	(
		"$TIMEOUT_BIN" "$FLAMESHOT_TIMEOUT" "$FLAMESHOT_BIN" gui
	) >"$OUT_DIR/$prefix-flameshot-normal.stdout" 2>"$OUT_DIR/$prefix-flameshot-normal.stderr" || {
		printf 'exit=%s\n' "$?" >"$OUT_DIR/$prefix-flameshot-normal.exit"
		return 0
	}
	printf 'exit=0\n' >"$OUT_DIR/$prefix-flameshot-normal.exit"
}

prompt_reproduce() {
	local label="$1"
	cat <<EOF | tee -a "$OUT_DIR/debug-script.log"

=== Reproduce: $label ===
When Flameshot appears:
  - Move the pointer over the overlay.
  - Press a key that normally affects Flameshot, e.g. Esc or Enter.
  - Click/drag as you normally do when it fails.
  - If input goes to the terminal behind it, leave that visible.

Press Enter here when you are ready to start this $label capture.
EOF
	read -r _
}

capture_layout_case() {
	local layout="$1"
	local prefix="$layout"

	log "===== CASE: $layout ====="
	set_layout "$layout"
	focus_active_workspace
	snapshot_ipc "$prefix-before"
	capture_proc_state "$prefix-before"
	capture_wayland_info "$prefix-before"
	start_ipc_subscribe "$prefix"
	start_journal_capture "$prefix"

	prompt_reproduce "$layout / normal flameshot"
	run_flameshot_normal "$prefix"
	sleep 1
	snapshot_ipc "$prefix-after-normal"

	prompt_reproduce "$layout / WAYLAND_DEBUG flameshot"
	run_flameshot_protocol "$prefix"
	sleep 1
	snapshot_ipc "$prefix-after-protocol"

	log "Finished case: $layout"
}

extract_tree_focus_summary() {
	local file="$1"
	local out="$2"
	if ! need_cmd jq; then
		echo "jq not found; cannot summarize $file" >"$out"
		return
	fi
	jq -r '
		def walk_nodes:
			. as $n
			| $n
			| (try (.nodes[] | walk_nodes) catch empty),
			  (try (.floating_nodes[] | walk_nodes) catch empty);
		[
			"focused nodes:",
			(walk_nodes
				| select(.focused == true)
				| "id=\(.id) type=\(.type) layout=\(.layout) app_id=\(.app_id // "") name=\(.name // "") rect=\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)"),
			"",
			"tabbed/stacked containers:",
			(walk_nodes
				| select(.layout == "tabbed" or .layout == "stacked")
				| "id=\(.id) type=\(.type) layout=\(.layout) focused=\(.focused) name=\(.name // "") rect=\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)")
		][]' "$file" >"$out" 2>&1 || true
}

analyze_outputs() {
	log "Writing quick analysis summaries"
	for tree in "$OUT_DIR"/*-tree.out; do
		[[ -e "$tree" ]] || continue
		extract_tree_focus_summary "$tree" "${tree%.out}.summary.txt"
	done

	{
		echo "Flameshot Wayland protocol layer-shell related lines:"
		grep -RniE 'layer|zwlr|keyboard|pointer|xdg|focus|enter|leave|configure|ack_configure|wl_keyboard|wl_pointer' \
			"$OUT_DIR"/*flameshot* 2>/dev/null || true
		echo
		echo "IPC focus/window/layout events:"
		grep -RniE '"change"|"container"|"focused"|"layout"|"mode"' \
			"$OUT_DIR"/*ipc-events* 2>/dev/null || true
		echo
		echo "Compositor warnings/errors:"
		grep -RniE 'error|warn|focus|layer|seat|keyboard|pointer|flameshot|tabbed|stacked' \
			"$OUT_DIR"/*journal* "$OUT_DIR"/*err 2>/dev/null || true
	} >"$OUT_DIR/analysis-grep.txt"
}

archive_outputs() {
	local archive="$OUT_DIR.tar.gz"
	log "Creating archive: $archive"
	tar -czf "$archive" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")"
	log "Archive ready: $archive"
}

collect_baseline() {
	mkdir -p "$OUT_DIR"
	: >"$OUT_DIR/debug-script.log"
	write_environment
	snapshot_ipc "baseline"
	capture_proc_state "baseline"
	capture_wayland_info "baseline"
	analyze_outputs
	archive_outputs
}

main() {
	local mode="${1:-}"
	case "$mode" in
		collect|tabbed|stacked|compare)
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
	need_cmd "$SWAYMSG_BIN" || die "swaymsg not found"
	need_cmd "$FLAMESHOT_BIN" || die "flameshot not found"
	[[ -n "${WAYLAND_DISPLAY:-}" ]] || warn "WAYLAND_DISPLAY is empty"
	[[ -n "${SWAYSOCK:-}" ]] || warn "SWAYSOCK is empty"

	mkdir -p "$OUT_DIR"
	: >"$OUT_DIR/debug-script.log"
	log "Output directory: $OUT_DIR"
	write_environment

	case "$mode" in
		collect)
			collect_baseline
			;;
		tabbed)
			capture_layout_case tabbed
			analyze_outputs
			archive_outputs
			;;
		stacked)
			capture_layout_case stacking
			analyze_outputs
			archive_outputs
			;;
		compare)
			capture_layout_case stacking
			capture_layout_case tabbed
			analyze_outputs
			archive_outputs
			;;
	esac
}

main "$@"

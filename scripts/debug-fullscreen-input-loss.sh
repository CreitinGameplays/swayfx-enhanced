#!/usr/bin/env bash
set -Eeuo pipefail

# Diagnose the fullscreen focus/input regression where a fullscreen app stops
# receiving keyboard or pointer input, especially after closing an XDG overlay
# app like Flameshot. Run this from inside the affected SwayFX session.

SCRIPT_NAME="$(basename "$0")"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-$PWD/fullscreen-input-loss-debug-$RUN_ID}"
SWAYMSG_BIN="${SWAYMSG_BIN:-swaymsg}"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"
OVERLAY_COMMAND="${OVERLAY_COMMAND:-flameshot gui}"
OVERLAY_LABEL="${OVERLAY_LABEL:-flameshot}"
OVERLAY_TIMEOUT="${OVERLAY_TIMEOUT:-25}"
SUBSCRIBE_TIMEOUT="${SUBSCRIBE_TIMEOUT:-90}"
JOURNAL_TIMEOUT="${JOURNAL_TIMEOUT:-120}"
POST_CLOSE_SETTLE="${POST_CLOSE_SETTLE:-2}"
CAPTURE_GDB="${CAPTURE_GDB:-1}"

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
  $SCRIPT_NAME overlay
  $SCRIPT_NAME manual
  $SCRIPT_NAME compare

Environment:
  OUT_DIR=path                 Output directory, default ./fullscreen-input-loss-debug-<time>
  OVERLAY_COMMAND='flameshot gui'
                               Overlay command to test in "overlay" and "compare" modes
  OVERLAY_LABEL=flameshot      Name used in filenames for the overlay case
  OVERLAY_TIMEOUT=25           Seconds to wait for the overlay command
  SUBSCRIBE_TIMEOUT=90         Seconds to capture sway IPC events
  JOURNAL_TIMEOUT=120          Seconds to capture user journal output
  POST_CLOSE_SETTLE=2          Seconds to wait after the overlay closes
  CAPTURE_GDB=1                Attach gdb and record seat focus internals when available

Recommended:
  1. Open the fullscreen app that misbehaves.
  2. Run: bash scripts/debug-fullscreen-input-loss.sh overlay
  3. Then run: bash scripts/debug-fullscreen-input-loss.sh manual
  4. Send the generated .tar.gz archive.

The archive contains:
  - sway IPC snapshots before/after the event
  - a seat focus probe from gdb if available
  - compositor process state
  - sway IPC event stream
  - user journal lines around the reproduction window

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

run_json_capture() {
	local name="$1"
	shift
	"$@" >"$OUT_DIR/$name.json" 2>"$OUT_DIR/$name.err" || {
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
		run_json_capture "$name" "$SWAYMSG_BIN" "$@"
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
		echo "OVERLAY_COMMAND=$OVERLAY_COMMAND"
		echo "OVERLAY_LABEL=$OVERLAY_LABEL"
		echo "CAPTURE_GDB=$CAPTURE_GDB"
		echo "PATH=$PATH"
		echo
		echo "kernel:"
		uname -a || true
		echo
		echo "binaries:"
		for bin in "$SWAYMSG_BIN" "$TIMEOUT_BIN" sway swayfx jq journalctl gdb wayland-info wev flameshot; do
			if command -v "$bin" >/dev/null 2>&1; then
				printf '%-16s %s\n' "$bin" "$(command -v "$bin")"
			else
				printf '%-16s missing\n' "$bin"
			fi
		done
		echo
		echo "versions:"
		"$SWAYMSG_BIN" -t get_version 2>/dev/null || true
		flameshot --version 2>/dev/null || true
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
		"$TIMEOUT_BIN" "$JOURNAL_TIMEOUT" journalctl --user --since now -f -o short-precise
	) >"$OUT_DIR/$prefix-journal-user.log" 2>"$OUT_DIR/$prefix-journal-user.err" &
	PIDS+=("$!")
}

stop_background_jobs() {
	for pid in "${PIDS[@]:-}"; do
		if kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
		fi
	done
	PIDS=()
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
	run_shell_capture "$prefix-processes" \
		"ps -eo pid,ppid,stat,comm,args | grep -E 'sway|swayfx|flameshot|swaync|xdg-desktop-portal|wayland-info|wev' | grep -v grep || true"
}

capture_wayland_info() {
	local prefix="$1"
	if need_cmd wayland-info; then
		log "Capturing wayland-info"
		"$TIMEOUT_BIN" 6 wayland-info >"$OUT_DIR/$prefix-wayland-info.txt" 2>"$OUT_DIR/$prefix-wayland-info.err" || true
	fi
}

capture_gdb_focus_state() {
	local prefix="$1"
	if [[ "$CAPTURE_GDB" != "1" ]]; then
		return
	fi
	if ! need_cmd gdb; then
		warn "gdb not found; skipped focus probe"
		return
	fi
	local pid
	pid="$(find_sway_pid)"
	if [[ -z "$pid" ]]; then
		warn "Could not find sway/swayfx PID for gdb probe"
		return
	fi
	log "Capturing gdb focus probe: pid=$pid"
	local gdb_cmd="$OUT_DIR/$prefix-gdb.cmd"
	cat >"$gdb_cmd" <<'EOF'
set pagination off
set confirm off
set print elements 0
set print pretty off
set print repeats 0
set $seat = input_manager_get_default_seat()
printf "seat_ptr=%p\n", $seat
if $seat
	printf "seat_name=%s\n", $seat->wlr_seat->name
	printf "seat_has_focus=%d\n", $seat->has_focus
	printf "seat_has_exclusive_layer=%d\n", $seat->has_exclusive_layer
	printf "seat_focused_layer=%p\n", $seat->focused_layer
	printf "seat_keyboard_surface=%p\n", $seat->wlr_seat->keyboard_state.focused_surface
	printf "seat_workspace=%p\n", $seat->workspace
	if $seat->workspace
		printf "seat_workspace_name=%s\n", $seat->workspace->name
	end
	set $focus = seat_get_focus($seat)
	printf "focus_node=%p\n", $focus
	if $focus
		printf "focus_node_id=%lu\n", (unsigned long)$focus->id
		printf "focus_node_type=%d\n", $focus->type
		printf "focus_container=%p\n", $focus->sway_container
		if $focus->sway_container
			set $con = $focus->sway_container
			printf "focus_container_view=%p\n", $con->view
			printf "focus_container_pending_fullscreen_mode=%d\n", $con->pending.fullscreen_mode
			printf "focus_container_full_output_overlay=%d\n", $con->full_output_overlay
			printf "focus_container_pending_workspace=%p\n", $con->pending.workspace
			if $con->view
				printf "focus_view_surface=%p\n", $con->view->surface
				printf "focus_view_pid=%d\n", (int)$con->view->pid
			end
		end
	end
end
EOF
	"$TIMEOUT_BIN" 20 gdb -q -batch -x "$gdb_cmd" -p "$pid" \
		>"$OUT_DIR/$prefix-gdb.txt" 2>"$OUT_DIR/$prefix-gdb.err" || true
}

capture_state() {
	local prefix="$1"
	snapshot_ipc "$prefix"
	capture_proc_state "$prefix"
	capture_wayland_info "$prefix"
	capture_gdb_focus_state "$prefix"
}

prompt_user() {
	local label="$1"
	cat <<EOF | tee -a "$OUT_DIR/debug-script.log"

=== Reproduce: $label ===
Make the fullscreen app enter its broken state, or close the overlay app
after it has been used, then come back here.

Press Enter when the state is reproduced and the compositor has had a moment
to settle.
EOF
	read -r _
}

run_overlay_case() {
	local prefix="$1"
	log "===== CASE: overlay / $OVERLAY_LABEL ====="
	capture_state "$prefix-before"
	start_ipc_subscribe "$prefix"
	start_journal_capture "$prefix"
	prompt_user "$OVERLAY_LABEL overlay"
	log "Launching overlay command: $OVERLAY_COMMAND"
	if (
		WAYLAND_DEBUG=1 "$TIMEOUT_BIN" "$OVERLAY_TIMEOUT" sh -c "$OVERLAY_COMMAND"
	) >"$OUT_DIR/$prefix-overlay.stdout" 2>"$OUT_DIR/$prefix-overlay-wayland-debug.log"; then
		printf 'exit=0\n' >"$OUT_DIR/$prefix-overlay.exit"
	else
		local code=$?
		printf 'exit=%s\n' "$code" >"$OUT_DIR/$prefix-overlay.exit"
	fi
	sleep "$POST_CLOSE_SETTLE"
	capture_state "$prefix-after"
	stop_background_jobs
	log "Finished overlay case: $prefix"
}

run_manual_case() {
	local prefix="$1"
	log "===== CASE: manual fullscreen no-overlay ====="
	capture_state "$prefix-before"
	start_ipc_subscribe "$prefix"
	start_journal_capture "$prefix"
	prompt_user "manual fullscreen input-loss"
	sleep "$POST_CLOSE_SETTLE"
	capture_state "$prefix-after"
	stop_background_jobs
	log "Finished manual case: $prefix"
}

extract_focus_id() {
	local seats_json="$1"
	if ! need_cmd jq; then
		return 0
	fi
	jq -r '.[0].focus // 0' "$seats_json" 2>/dev/null || true
}

extract_focus_summary() {
	local stage="$1"
	local tree_json="$OUT_DIR/$stage-tree.json"
	local seats_json="$OUT_DIR/$stage-seats.json"
	local gdb_txt="$OUT_DIR/$stage-gdb.txt"
	local out="$OUT_DIR/$stage-summary.txt"

	{
		echo "stage=$stage"
		echo
		if need_cmd jq && [[ -f "$seats_json" ]] && [[ -f "$tree_json" ]]; then
			local focus_id
			focus_id="$(extract_focus_id "$seats_json")"
			echo "seat focus id: $focus_id"
			echo
			echo "seats:"
			jq -r '.[] | "seat=\(.name) capabilities=\(.capabilities) focus_id=\(.focus) devices=\(.devices|length)"' "$seats_json" 2>/dev/null || true
			echo
			echo "focused nodes and fullscreen nodes:"
			jq -r '
				def walk_nodes:
					. as $n
					| $n,
					  (try (.nodes[] | walk_nodes) catch empty),
					  (try (.floating_nodes[] | walk_nodes) catch empty);
				walk_nodes
				| select(type == "object")
				| select(.focused == true or (.fullscreen_mode != null and .fullscreen_mode != 0))
				| "id=\(.id) type=\(.type) layout=\(.layout // "") fullscreen_mode=\(.fullscreen_mode // "none") focused=\(.focused) app_id=\(.app_id // "") name=\(.name // "") rect=\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)"
			' "$tree_json" 2>/dev/null || true
			echo
			if [[ "$focus_id" != "0" && "$focus_id" != "" ]]; then
				echo "focused node lookup:"
				jq -r --argjson focus_id "$focus_id" '
					def walk_nodes:
						. as $n
						| $n,
						  (try (.nodes[] | walk_nodes) catch empty),
						  (try (.floating_nodes[] | walk_nodes) catch empty);
					walk_nodes
					| select(type == "object")
					| select(.id == $focus_id)
					| "id=\(.id) type=\(.type) layout=\(.layout // "") fullscreen_mode=\(.fullscreen_mode // "none") focused=\(.focused) app_id=\(.app_id // "") name=\(.name // "") rect=\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)"
				' "$tree_json" 2>/dev/null || true
			fi
		fi
		echo
		if [[ -f "$gdb_txt" ]]; then
			echo "gdb focus probe:"
			grep -E '^(seat_|focus_)' "$gdb_txt" 2>/dev/null || true
		fi
	} >"$out"
}

normalize_ptr() {
	case "${1:-}" in
		""|0x0|'(nil)') echo "0x0" ;;
		*) echo "$1" ;;
	esac
}

build_diagnosis() {
	local out="$OUT_DIR/diagnosis.txt"
	{
		echo "diagnosis"
		echo
		for stage in "$@"; do
			local summary="$OUT_DIR/$stage-summary.txt"
			[[ -f "$summary" ]] || continue
			echo "== $stage =="
			grep -E '^(stage=|seat focus id:|seat=|id=|seat_|focus_)' "$summary" 2>/dev/null || true
			echo
		done

		local before="$OUT_DIR/${1:-}-summary.txt"
		local after="$OUT_DIR/${2:-}-summary.txt"
		if [[ -f "$OUT_DIR/${1:-}-gdb.txt" && -f "$OUT_DIR/${2:-}-gdb.txt" ]]; then
			local before_focus after_focus before_layer after_layer before_surface after_surface before_fs after_fs before_overlay after_overlay
			before_focus="$(awk -F= '/^focus_node_id=/{print $2; exit}' "$OUT_DIR/${1:-}-gdb.txt" 2>/dev/null || true)"
			after_focus="$(awk -F= '/^focus_node_id=/{print $2; exit}' "$OUT_DIR/${2:-}-gdb.txt" 2>/dev/null || true)"
			before_layer="$(normalize_ptr "$(awk -F= '/^seat_focused_layer=/{print $2; exit}' "$OUT_DIR/${1:-}-gdb.txt" 2>/dev/null || true)")"
			after_layer="$(normalize_ptr "$(awk -F= '/^seat_focused_layer=/{print $2; exit}' "$OUT_DIR/${2:-}-gdb.txt" 2>/dev/null || true)")"
			before_surface="$(normalize_ptr "$(awk -F= '/^seat_keyboard_surface=/{print $2; exit}' "$OUT_DIR/${1:-}-gdb.txt" 2>/dev/null || true)")"
			after_surface="$(normalize_ptr "$(awk -F= '/^seat_keyboard_surface=/{print $2; exit}' "$OUT_DIR/${2:-}-gdb.txt" 2>/dev/null || true)")"
			before_fs="$(awk -F= '/^focus_container_pending_fullscreen_mode=/{print $2; exit}' "$OUT_DIR/${1:-}-gdb.txt" 2>/dev/null || true)"
			after_fs="$(awk -F= '/^focus_container_pending_fullscreen_mode=/{print $2; exit}' "$OUT_DIR/${2:-}-gdb.txt" 2>/dev/null || true)"
			before_overlay="$(awk -F= '/^focus_container_full_output_overlay=/{print $2; exit}' "$OUT_DIR/${1:-}-gdb.txt" 2>/dev/null || true)"
			after_overlay="$(awk -F= '/^focus_container_full_output_overlay=/{print $2; exit}' "$OUT_DIR/${2:-}-gdb.txt" 2>/dev/null || true)"

			echo "comparison"
			echo "  focus_node_id: ${before_focus:-?} -> ${after_focus:-?}"
			echo "  seat_focused_layer: ${before_layer:-?} -> ${after_layer:-?}"
			echo "  seat_keyboard_surface: ${before_surface:-?} -> ${after_surface:-?}"
			echo "  fullscreen_mode: ${before_fs:-?} -> ${after_fs:-?}"
			echo "  full_output_overlay: ${before_overlay:-?} -> ${after_overlay:-?}"
			echo

			if [[ -n "${before_focus:-}" && "$before_focus" == "$after_focus" ]]; then
				echo "The focus stack stayed on the same node across the event."
				if [[ "$before_surface" != "$after_surface" ]]; then
					echo "The seat keyboard surface changed anyway, which suggests the compositor re-entered a different surface or lost enter on the fullscreen client."
				fi
			fi
			if [[ "$after_layer" != "0x0" && "$after_layer" != "" ]]; then
				echo "The seat still has a focused layer after the test. That points to a layer focus leak."
			fi
			if [[ "$after_surface" == "0x0" || "$after_surface" == "" ]]; then
				echo "The keyboard seat ended up with no focused surface."
			fi
			if [[ "$after_fs" != "" && "$after_fs" != "0" ]]; then
				echo "The focused container is fullscreen-capable or fullscreen-active, so a missing keyboard enter here is suspicious."
			fi
			if [[ "$after_overlay" == "1" ]]; then
				echo "The focused container is marked as a full-output overlay."
			fi
		fi
	} >"$out"
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
	capture_state "baseline"
	extract_focus_summary "baseline"
	build_diagnosis "baseline"
	archive_outputs
}

analyze_case() {
	local prefix="$1"
	extract_focus_summary "$prefix-before"
	extract_focus_summary "$prefix-after"
	build_diagnosis "$prefix-before" "$prefix-after"
}

main() {
	local mode="${1:-}"
	case "$mode" in
		collect|overlay|manual|compare)
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
		overlay)
			run_overlay_case "$OVERLAY_LABEL"
			analyze_case "$OVERLAY_LABEL"
			archive_outputs
			;;
		manual)
			run_manual_case "manual"
			analyze_case "manual"
			archive_outputs
			;;
		compare)
			run_overlay_case "$OVERLAY_LABEL"
			run_manual_case "manual"
			analyze_case "$OVERLAY_LABEL"
			analyze_case "manual"
			archive_outputs
			;;
	esac
}

main "$@"

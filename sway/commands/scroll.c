#include <errno.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "sway/commands.h"
#include "sway/desktop/transaction.h"
#include "sway/input/input-manager.h"
#include "sway/input/seat.h"
#include "sway/tree/arrange.h"
#include "sway/tree/container.h"
#include "sway/tree/workspace.h"

static const int scroll_default_amount = 100;

static const char expected_syntax[] =
	"Expected 'scroll left|right [<px> px]', 'scroll center', "
	"'scroll follow', 'scroll home', or 'scroll end'";

static struct sway_seat *get_command_seat(void) {
	if (config->handler_context.seat) {
		return config->handler_context.seat;
	}
	return input_manager_current_seat();
}

static struct sway_workspace *get_scrollable_workspace(void) {
	struct sway_workspace *ws = config->handler_context.workspace;
	if (!ws) {
		struct sway_container *con = config->handler_context.container;
		if (con) {
			ws = con->pending.workspace;
		}
	}
	if (!ws) {
		struct sway_seat *seat = get_command_seat();
		ws = seat ? seat_get_focused_workspace(seat) : NULL;
	}
	return ws;
}

static int get_scroll_content_width(struct sway_workspace *ws) {
	int content_width = 0;
	for (int i = 0; i < ws->tiling->length; ++i) {
		struct sway_container *child = ws->tiling->items[i];
		content_width += child->pending.width;
		if (i + 1 < ws->tiling->length) {
			content_width += ws->gaps_inner;
		}
	}
	return content_width;
}

static int get_scroll_max_offset(struct sway_workspace *ws) {
	struct wlr_box box;
	workspace_get_box(ws, &box);
	int max_offset = get_scroll_content_width(ws) - box.width;
	return max_offset > 0 ? max_offset : 0;
}

static int clamp_scroll_offset(struct sway_workspace *ws, int offset) {
	int max_offset = get_scroll_max_offset(ws);
	if (offset < 0) {
		return 0;
	}
	if (offset > max_offset) {
		return max_offset;
	}
	return offset;
}

static struct sway_container *get_scroll_focus(struct sway_workspace *ws) {
	struct sway_seat *seat = get_command_seat();
	struct sway_container *focus = seat ?
		seat_get_focus_inactive_tiling(seat, ws) : NULL;
	if (!focus && ws->tiling->length > 0) {
		focus = ws->tiling->items[0];
	}
	if (!focus) {
		return NULL;
	}
	return container_toplevel_ancestor(focus);
}

static int get_centered_scroll_offset(struct sway_workspace *ws) {
	struct sway_container *focused = get_scroll_focus(ws);
	if (!focused) {
		return 0;
	}

	struct wlr_box box;
	workspace_get_box(ws, &box);

	int focused_x = 0;
	for (int i = 0; i < ws->tiling->length; ++i) {
		struct sway_container *child = ws->tiling->items[i];
		if (child == focused) {
			break;
		}
		focused_x += child->pending.width + ws->gaps_inner;
	}

	int offset = focused_x + focused->pending.width / 2 - box.width / 2;
	return clamp_scroll_offset(ws, offset);
}

static bool parse_amount(int argc, char **argv, int *amount) {
	if (argc == 1) {
		*amount = scroll_default_amount;
		return true;
	}
	if (argc != 2) {
		return false;
	}

	char *end = NULL;
	errno = 0;
	long parsed = strtol(argv[1], &end, 10);
	if (errno || end == argv[1] || parsed < 0 ||
			(*end != '\0' && strcasecmp(end, "px") != 0)) {
		return false;
	}

	*amount = (int)parsed;
	return true;
}

struct cmd_results *cmd_scroll(int argc, char **argv) {
	struct cmd_results *error = NULL;
	if ((error = checkarg(argc, "scroll", EXPECTED_AT_LEAST, 1))) {
		return error;
	}

	struct sway_workspace *ws = get_scrollable_workspace();
	if (!ws || ws->layout != L_SCROLL_H) {
		return cmd_results_new(CMD_FAILURE,
				"Can only scroll a workspace in scrollable layout");
	}

	if (strcasecmp(argv[0], "follow") == 0) {
		if (argc != 1) {
			return cmd_results_new(CMD_INVALID, "%s", expected_syntax);
		}
		ws->scroll_follow_focus = true;
		arrange_workspace(ws);
		transaction_commit_dirty();
		return cmd_results_new(CMD_SUCCESS, NULL);
	}

	if (strcasecmp(argv[0], "center") == 0) {
		if (argc != 1) {
			return cmd_results_new(CMD_INVALID, "%s", expected_syntax);
		}
		ws->scroll_follow_focus = false;
		ws->target_scroll_x = get_centered_scroll_offset(ws);
		arrange_workspace(ws);
		transaction_commit_dirty();
		return cmd_results_new(CMD_SUCCESS, NULL);
	}

	if (strcasecmp(argv[0], "home") == 0 || strcasecmp(argv[0], "end") == 0) {
		if (argc != 1) {
			return cmd_results_new(CMD_INVALID, "%s", expected_syntax);
		}
		ws->scroll_follow_focus = false;
		ws->target_scroll_x = strcasecmp(argv[0], "home") == 0 ? 0 :
			get_scroll_max_offset(ws);
		arrange_workspace(ws);
		transaction_commit_dirty();
		return cmd_results_new(CMD_SUCCESS, NULL);
	}

	int amount = 0;
	if (!parse_amount(argc, argv, &amount)) {
		return cmd_results_new(CMD_INVALID, "%s", expected_syntax);
	}

	int direction = 0;
	if (strcasecmp(argv[0], "left") == 0) {
		direction = -1;
	} else if (strcasecmp(argv[0], "right") == 0) {
		direction = 1;
	} else {
		return cmd_results_new(CMD_INVALID, "%s", expected_syntax);
	}

	ws->scroll_follow_focus = false;
	ws->target_scroll_x = clamp_scroll_offset(ws,
		ws->target_scroll_x + direction * amount);
	arrange_workspace(ws);
	transaction_commit_dirty();
	return cmd_results_new(CMD_SUCCESS, NULL);
}

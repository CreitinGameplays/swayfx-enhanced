#include <wlr/types/wlr_cursor.h>
#include <wlr/util/edges.h>
#include "sway/commands.h"
#include "sway/desktop/transaction.h"
#include "sway/input/cursor.h"
#include "sway/input/seat.h"
#include "sway/tree/arrange.h"
#include "sway/tree/container.h"
#include "sway/tree/view.h"
#include "sway/tree/workspace.h"

struct seatop_resize_tiling_event {
	struct sway_container *con;    // leaf container

	// con, or ancestor of con which will be resized horizontally/vertically
	struct sway_container *h_con;
	struct sway_container *v_con;

	// sibling con(s) that will be resized to accommodate
	struct sway_container *h_sib;
	struct sway_container *v_sib;

	enum wlr_edges edge;
	enum wlr_edges edge_x, edge_y;
	double ref_lx, ref_ly;         // cursor's x/y at start of op
	double h_con_orig_width;       // width of the horizontal ancestor at start
	double v_con_orig_height;      // height of the vertical ancestor at start
	int h_con_orig_scroll_x;       // workspace scroll offset at start
	bool h_con_is_scrollable_column;
};

static struct sway_container *container_get_resize_sibling(
		struct sway_container *con, uint32_t edge) {
	if (!con) {
		return NULL;
	}

	list_t *siblings = container_get_siblings(con);
	int index = container_sibling_index(con);
	int offset = edge & (WLR_EDGE_TOP | WLR_EDGE_LEFT) ? -1 : 1;
	int sibling_index = index + offset;

	if (siblings->length == 1) {
		return NULL;
	}

	if (sibling_index < 0 || sibling_index >= siblings->length) {
		return NULL;
	}

	return siblings->items[sibling_index];
}

static int get_scrollable_content_width(struct sway_workspace *ws) {
	if (!ws) {
		return 0;
	}

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

static int clamp_scrollable_scroll_x(struct sway_workspace *ws,
		int scroll_x) {
	struct wlr_box box;
	workspace_get_box(ws, &box);

	int max_scroll_x = get_scrollable_content_width(ws) - box.width;
	if (max_scroll_x < 0) {
		max_scroll_x = 0;
	}
	if (scroll_x < 0) {
		return 0;
	}
	if (scroll_x > max_scroll_x) {
		return max_scroll_x;
	}
	return scroll_x;
}

static int get_visual_scroll_x(struct sway_workspace *ws) {
	struct wlr_box box;
	workspace_get_box(ws, &box);

	int scroll_x = box.x - ws->layers.tiling->node.x;
	return clamp_scrollable_scroll_x(ws, scroll_x);
}

static void adjust_scrollable_resize_position(
		struct seatop_resize_tiling_event *e) {
	if (!e->h_con_is_scrollable_column || !e->h_con ||
			e->edge_x != WLR_EDGE_LEFT) {
		return;
	}

	struct sway_workspace *ws = e->h_con->pending.workspace;
	if (!ws) {
		return;
	}

	int scroll_delta = e->h_con->pending.width - e->h_con_orig_width;
	int scroll_x = clamp_scrollable_scroll_x(ws,
		e->h_con_orig_scroll_x + scroll_delta);

	struct wlr_box box;
	workspace_get_box(ws, &box);
	wlr_scene_node_set_position(&ws->layers.tiling->node,
		box.x - scroll_x, ws->layers.tiling->node.y);
	ws->scroll_x = scroll_x;
	ws->target_scroll_x = scroll_x;
}

static void update_scrollable_resize_state(
		struct seatop_resize_tiling_event *e, bool resizing) {
	if (!e->h_con_is_scrollable_column || !e->h_con ||
			!e->h_con->pending.workspace) {
		return;
	}

	e->h_con->pending.workspace->scroll_animation_state.interactive_resize =
		resizing;
}

static void handle_button(struct sway_seat *seat, uint32_t time_msec,
		struct wlr_input_device *device, uint32_t button,
		enum wl_pointer_button_state state) {
	struct seatop_resize_tiling_event *e = seat->seatop_data;

	if (seat->cursor->pressed_button_count == 0) {
		update_scrollable_resize_state(e, false);
		if (e->h_con) {
			container_set_resizing(e->h_con, false);
			container_set_resizing(e->h_sib, false);
			if (e->h_con->pending.parent) {
				arrange_container(e->h_con->pending.parent);
			} else if (e->h_con->pending.workspace) {
				arrange_workspace(e->h_con->pending.workspace);
			}
		}
		if (e->v_con) {
			container_set_resizing(e->v_con, false);
			container_set_resizing(e->v_sib, false);
			if (e->v_con->pending.parent) {
				arrange_container(e->v_con->pending.parent);
			} else if (e->v_con->pending.workspace) {
				arrange_workspace(e->v_con->pending.workspace);
			}
		}
		transaction_commit_dirty();
		seatop_begin_default(seat);
	}
}

static void handle_pointer_motion(struct sway_seat *seat, uint32_t time_msec) {
	struct seatop_resize_tiling_event *e = seat->seatop_data;
	int amount_x = 0;
	int amount_y = 0;
	int moved_x = seat->cursor->cursor->x - e->ref_lx;
	int moved_y = seat->cursor->cursor->y - e->ref_ly;

	if (e->h_con) {
		if (e->h_con_is_scrollable_column) {
			if (e->edge_x == WLR_EDGE_LEFT) {
				amount_x = (e->h_con_orig_width - moved_x) -
					e->h_con->pending.width;
			} else if (e->edge_x == WLR_EDGE_RIGHT) {
				amount_x = (e->h_con_orig_width + moved_x) -
					e->h_con->pending.width;
			}
		} else if (e->edge_x == WLR_EDGE_LEFT) {
			amount_x = (e->h_con_orig_width - moved_x) - e->h_con->pending.width;
		} else if (e->edge_x == WLR_EDGE_RIGHT) {
			amount_x = (e->h_con_orig_width + moved_x) - e->h_con->pending.width;
		}
	}
	if (e->v_con) {
		if (e->edge & WLR_EDGE_TOP) {
			amount_y = (e->v_con_orig_height - moved_y) - e->v_con->pending.height;
		} else if (e->edge & WLR_EDGE_BOTTOM) {
			amount_y = (e->v_con_orig_height + moved_y) - e->v_con->pending.height;
		}
	}

	if (amount_x != 0) {
		container_resize_tiled(e->h_con, e->edge_x, amount_x);
		adjust_scrollable_resize_position(e);
	}
	if (amount_y != 0) {
		container_resize_tiled(e->v_con, e->edge_y, amount_y);
	}
	transaction_commit_dirty();
}

static bool event_tracks_container(struct seatop_resize_tiling_event *e,
		struct sway_container *con) {
	return e->con == con || e->h_con == con || e->v_con == con ||
		e->h_sib == con || e->v_sib == con;
}

static void handle_unref(struct sway_seat *seat, struct sway_container *con) {
	struct seatop_resize_tiling_event *e = seat->seatop_data;
	if (event_tracks_container(e, con)) {
		update_scrollable_resize_state(e, false);
		seatop_begin_default(seat);
	}
}

static const struct sway_seatop_impl seatop_impl = {
	.button = handle_button,
	.pointer_motion = handle_pointer_motion,
	.unref = handle_unref,
};

void seatop_begin_resize_tiling(struct sway_seat *seat,
		struct sway_container *con, enum wlr_edges edge) {
	seatop_end(seat);

	struct seatop_resize_tiling_event *e =
		calloc(1, sizeof(struct seatop_resize_tiling_event));
	if (!e) {
		return;
	}
	e->con = con;
	e->edge = edge;

	e->ref_lx = seat->cursor->cursor->x;
	e->ref_ly = seat->cursor->cursor->y;

	if (edge & (WLR_EDGE_LEFT | WLR_EDGE_RIGHT)) {
		e->edge_x = edge & (WLR_EDGE_LEFT | WLR_EDGE_RIGHT);
		e->h_con = container_find_resize_parent(e->con, e->edge_x);

		if (e->h_con) {
			e->h_con_is_scrollable_column = !e->h_con->pending.parent &&
				e->h_con->pending.workspace &&
				e->h_con->pending.workspace->layout == L_SCROLL_H;
			if (!e->h_con_is_scrollable_column) {
				e->h_sib = container_get_resize_sibling(e->h_con, e->edge_x);
			}
			update_scrollable_resize_state(e, true);
			container_set_resizing(e->h_con, true);
			container_set_resizing(e->h_sib, true);
			e->h_con_orig_width = e->h_con->pending.width;
			e->h_con_orig_scroll_x =
				get_visual_scroll_x(e->h_con->pending.workspace);
		}
	}
	if (edge & (WLR_EDGE_TOP | WLR_EDGE_BOTTOM)) {
		e->edge_y = edge & (WLR_EDGE_TOP | WLR_EDGE_BOTTOM);
		e->v_con = container_find_resize_parent(e->con, e->edge_y);
		e->v_sib = container_get_resize_sibling(e->v_con, e->edge_y);

		if (e->v_con) {
			container_set_resizing(e->v_con, true);
			container_set_resizing(e->v_sib, true);
			e->v_con_orig_height = e->v_con->pending.height;
		}
	}

	seat->seatop_impl = &seatop_impl;
	seat->seatop_data = e;

	transaction_commit_dirty();
	wlr_seat_pointer_notify_clear_focus(seat->wlr_seat);
}

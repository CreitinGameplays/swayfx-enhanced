#include <limits.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/util/edges.h>
#include "sway/desktop/transaction.h"
#include "sway/input/cursor.h"
#include "sway/input/seat.h"
#include "sway/ipc-server.h"
#include "sway/output.h"
#include "sway/tree/arrange.h"
#include "sway/tree/node.h"
#include "sway/tree/view.h"
#include "sway/tree/workspace.h"

// Thickness of the dropzone when dragging to the edge of a layout container
#define DROP_LAYOUT_BORDER 30

// Thickness of indicator when dropping onto a titlebar.  This should be a
// multiple of 2.
#define DROP_SPLIT_INDICATOR 10

#define DRAG_SCROLL_EDGE_THRESHOLD 96
#define DRAG_SCROLL_MIN_SPEED 400
#define DRAG_SCROLL_MAX_SPEED 2400

struct seatop_move_tiling_event {
	struct sway_container *con;
	struct sway_node *target_node;
	enum wlr_edges target_edge;
	double ref_lx, ref_ly; // cursor's x/y at start of op
	bool threshold_reached;
	bool split_target;
	bool insert_after_target;
	struct wlr_scene_rect *indicator_rect;
	struct wlr_scene_blur *indicator_blur;
	uint32_t last_auto_scroll_time_msec;
};

static void handle_end(struct sway_seat *seat) {
	struct seatop_move_tiling_event *e = seat->seatop_data;
	wlr_scene_node_destroy(&e->indicator_rect->node);
	wlr_scene_node_destroy(&e->indicator_blur->node);
	e->indicator_rect = NULL;
}

static void handle_motion_prethreshold(struct sway_seat *seat) {
	struct seatop_move_tiling_event *e = seat->seatop_data;
	double cx = seat->cursor->cursor->x;
	double cy = seat->cursor->cursor->y;
	double sx = e->ref_lx;
	double sy = e->ref_ly;

	// Get the scaled threshold for the output. Even if the operation goes
	// across multiple outputs of varying scales, just use the scale for the
	// output that the cursor is currently on for simplicity.
	struct wlr_output *wlr_output = wlr_output_layout_output_at(
			root->output_layout, cx, cy);
	double output_scale = wlr_output ? wlr_output->scale : 1;
	double threshold = config->tiling_drag_threshold * output_scale;
	threshold *= threshold;

	// If the threshold has been exceeded, start the actual drag
	if ((cx - sx) * (cx - sx) + (cy - sy) * (cy - sy) > threshold) {
		wlr_scene_node_set_enabled(&e->indicator_rect->node, true);
		wlr_scene_node_set_enabled(&e->indicator_blur->node, true);
		e->threshold_reached = true;
		cursor_set_image(seat->cursor, "grab", NULL);
	}
}

static void resize_box(struct wlr_box *box, enum wlr_edges edge,
		int thickness) {
	switch (edge) {
	case WLR_EDGE_TOP:
		box->height = thickness;
		break;
	case WLR_EDGE_LEFT:
		box->width = thickness;
		break;
	case WLR_EDGE_RIGHT:
		box->x = box->x + box->width - thickness;
		box->width = thickness;
		break;
	case WLR_EDGE_BOTTOM:
		box->y = box->y + box->height - thickness;
		box->height = thickness;
		break;
	case WLR_EDGE_NONE:
		box->x += thickness;
		box->y += thickness;
		box->width -= thickness * 2;
		box->height -= thickness * 2;
		break;
	}
}

static void split_border(double pos, int offset, int len, int n_children,
		int avoid, int *out_pos, bool *out_after) {
	int region = 2 * n_children * (pos - offset) / len;
	// If the cursor is over the right side of a left-adjacent titlebar, or the
	// left side of a right-adjacent titlebar, it's position when dropped will
	// be the same.  To avoid this, shift the region for adjacent containers.
	if (avoid >= 0) {
		if (region == 2 * avoid - 1 || region == 2 * avoid) {
			region--;
		} else if (region == 2 * avoid + 1 || region == 2 * avoid + 2) {
			region++;
		}
	}

	int child_index = (region + 1) / 2;
	*out_after = region % 2;
	// When dropping at the beginning or end of a container, show the drop
	// region within the container boundary, otherwise show it on top of the
	// border between two titlebars.
	if (child_index == 0) {
		*out_pos = offset;
	} else if (child_index == n_children) {
		*out_pos = offset + len - DROP_SPLIT_INDICATOR;
	} else {
		*out_pos = offset + child_index * len / n_children -
			DROP_SPLIT_INDICATOR / 2;
	}
}

static bool split_titlebar(struct sway_node *node, struct sway_container *avoid,
		struct wlr_cursor *cursor, struct wlr_box *title_box, bool *after) {
	struct sway_container *con = node->sway_container;
	struct sway_node *parent = &con->pending.parent->node;
	int title_height = container_titlebar_height();
	struct wlr_box box;
	int n_children, avoid_index;
	enum sway_container_layout layout =
		parent ? node_get_layout(parent) : L_NONE;
	if (layout == L_TABBED || layout == L_STACKED) {
		node_get_box(parent, &box);
		n_children = node_get_children(parent)->length;
		avoid_index = list_find(node_get_children(parent), avoid);
	} else {
		node_get_box(node, &box);
		n_children = 1;
		avoid_index = -1;
	}
	if (layout == L_STACKED && cursor->y < box.y + title_height * n_children) {
		// Drop into stacked titlebars.
		title_box->width = box.width;
		title_box->height = DROP_SPLIT_INDICATOR;
		title_box->x = box.x;
		split_border(cursor->y, box.y, title_height * n_children,
			n_children, avoid_index, &title_box->y, after);
		return true;
	} else if (layout != L_STACKED && cursor->y < box.y + title_height) {
		// Drop into side-by-side titlebars.
		title_box->width = DROP_SPLIT_INDICATOR;
		title_box->height = title_height;
		title_box->y = box.y;
		split_border(cursor->x, box.x, box.width, n_children,
			avoid_index, &title_box->x, after);
		return true;
	}
	return false;
}

static void update_indicator(struct seatop_move_tiling_event *e, struct wlr_box *box) {
	wlr_scene_node_set_position(&e->indicator_blur->node, box->x, box->y);
	wlr_scene_blur_set_size(e->indicator_blur, box->width, box->height);

	wlr_scene_node_set_position(&e->indicator_rect->node, box->x, box->y);
	wlr_scene_rect_set_size(e->indicator_rect, box->width, box->height);

	int corner_radius = config->corner_radius;
	if (e->con) {
		corner_radius = e->con->corner_radius;
		// The indicator will be shown above a view if the type is of a container,
		// otherwise it'll be shown above a container border/title bar
		if (e->target_node && e->target_node->type != N_CONTAINER) {
			corner_radius += e->con->current.border_thickness;
		}
	}

	int corner_radius_real = MIN(corner_radius, MIN(box->width / 2, box->height / 2));
	wlr_scene_rect_set_corner_radii(e->indicator_rect, corner_radii_all(corner_radius_real));
	wlr_scene_blur_set_corner_radii(e->indicator_blur, corner_radii_all(corner_radius_real));
}

static bool container_is_scrollable_column(struct sway_container *con) {
	return con && !con->pending.parent && con->pending.workspace &&
		con->pending.workspace->layout == L_SCROLL_H;
}

static int get_scrollable_content_width(struct sway_workspace *ws) {
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

static int clamp_scrollable_target(struct sway_workspace *ws, int target) {
	struct wlr_box box;
	workspace_get_box(ws, &box);
	int max_target = get_scrollable_content_width(ws) - box.width;
	if (max_target < 0) {
		max_target = 0;
	}
	if (target < 0) {
		return 0;
	}
	if (target > max_target) {
		return max_target;
	}
	return target;
}

static bool auto_scroll_scrollable_drag(struct sway_seat *seat,
		struct seatop_move_tiling_event *e, uint32_t time_msec) {
	if (!container_is_scrollable_column(e->con)) {
		e->last_auto_scroll_time_msec = time_msec;
		return false;
	}

	struct sway_workspace *ws = e->con->pending.workspace;
	if (!ws || !workspace_is_visible(ws)) {
		e->last_auto_scroll_time_msec = time_msec;
		return false;
	}

	struct wlr_box box;
	workspace_get_box(ws, &box);
	if (box.width <= 0) {
		e->last_auto_scroll_time_msec = time_msec;
		return false;
	}

	int direction = 0;
	int distance = 0;
	double cursor_x = seat->cursor->cursor->x;
	if (cursor_x < box.x + DRAG_SCROLL_EDGE_THRESHOLD) {
		direction = -1;
		distance = box.x + DRAG_SCROLL_EDGE_THRESHOLD - cursor_x;
	} else if (cursor_x > box.x + box.width - DRAG_SCROLL_EDGE_THRESHOLD) {
		direction = 1;
		distance = cursor_x - (box.x + box.width - DRAG_SCROLL_EDGE_THRESHOLD);
	} else {
		e->last_auto_scroll_time_msec = time_msec;
		return false;
	}

	if (distance < 0) {
		distance = 0;
	} else if (distance > DRAG_SCROLL_EDGE_THRESHOLD) {
		distance = DRAG_SCROLL_EDGE_THRESHOLD;
	}

	uint32_t delta = e->last_auto_scroll_time_msec == 0 ? 16 :
		time_msec - e->last_auto_scroll_time_msec;
	if (delta == 0) {
		delta = 16;
	} else if (delta > 32) {
		delta = 32;
	}
	e->last_auto_scroll_time_msec = time_msec;

	int speed = DRAG_SCROLL_MIN_SPEED +
		(DRAG_SCROLL_MAX_SPEED - DRAG_SCROLL_MIN_SPEED) * distance /
		DRAG_SCROLL_EDGE_THRESHOLD;
	int amount = speed * (int)delta / 1000;
	if (amount < 1) {
		amount = 1;
	}

	int target = clamp_scrollable_target(ws,
		ws->target_scroll_x + direction * amount);
	if (target == ws->target_scroll_x) {
		return false;
	}

	ws->scroll_follow_focus = false;
	ws->target_scroll_x = target;
	arrange_workspace(ws);
	return true;
}

static void update_scrollable_indicator(struct seatop_move_tiling_event *e,
		struct sway_workspace *ws, int edge_x) {
	struct wlr_box workspace_box;
	workspace_get_box(ws, &workspace_box);

	struct wlr_box box = {
		.x = edge_x - DROP_SPLIT_INDICATOR / 2,
		.y = workspace_box.y,
		.width = DROP_SPLIT_INDICATOR,
		.height = workspace_box.height,
	};

	if (box.x < workspace_box.x) {
		box.x = workspace_box.x;
	}
	int max_x = workspace_box.x + workspace_box.width - box.width;
	if (box.x > max_x) {
		box.x = max_x;
	}
	update_indicator(e, &box);
}

static bool handle_motion_scrollable_column(struct sway_seat *seat,
		struct seatop_move_tiling_event *e, struct sway_node *node) {
	if (!container_is_scrollable_column(e->con)) {
		return false;
	}

	struct sway_workspace *ws = NULL;
	struct sway_container *target_column = NULL;
	if (node) {
		if (node->type == N_WORKSPACE) {
			ws = node->sway_workspace;
		} else if (node->type == N_CONTAINER) {
			target_column = container_toplevel_ancestor(node->sway_container);
			ws = target_column ? target_column->pending.workspace : NULL;
		}
	}

	if (!ws || ws->layout != L_SCROLL_H) {
		return false;
	}

	if (target_column == e->con || node_has_ancestor(node, &e->con->node)) {
		target_column = NULL;
	}

	if (target_column && container_is_scrollable_column(target_column)) {
		bool after = seat->cursor->cursor->x >=
			target_column->pending.x + target_column->pending.width / 2.0;
		int edge_x = after ?
			target_column->pending.x + target_column->pending.width :
			target_column->pending.x;
		e->target_node = &target_column->node;
		e->target_edge = after ? WLR_EDGE_RIGHT : WLR_EDGE_LEFT;
		e->split_target = false;
		update_scrollable_indicator(e, ws, edge_x);
		return true;
	}

	struct wlr_box box;
	workspace_get_box(ws, &box);
	bool after = seat->cursor->cursor->x >= box.x + box.width / 2.0;
	e->target_node = &ws->node;
	e->target_edge = after ? WLR_EDGE_RIGHT : WLR_EDGE_LEFT;
	e->split_target = false;
	update_scrollable_indicator(e, ws, after ? box.x + box.width : box.x);
	return true;
}

static void handle_motion_postthreshold(struct sway_seat *seat, uint32_t time_msec) {
	struct seatop_move_tiling_event *e = seat->seatop_data;
	e->split_target = false;
	auto_scroll_scrollable_drag(seat, e, time_msec);
	struct wlr_surface *surface = NULL;
	double sx, sy;
	struct sway_cursor *cursor = seat->cursor;
	struct sway_node *node = node_at_coords(seat,
			cursor->cursor->x, cursor->cursor->y, &surface, &sx, &sy);

	if (!node) {
		// Eg. hovered over a layer surface such as swaybar
		e->target_node = NULL;
		e->target_edge = WLR_EDGE_NONE;
		return;
	}

	if (handle_motion_scrollable_column(seat, e, node)) {
		return;
	}

	if (node->type == N_WORKSPACE) {
		// Empty workspace
		e->target_node = node;
		e->target_edge = WLR_EDGE_NONE;

		struct wlr_box drop_box;
		workspace_get_box(node->sway_workspace, &drop_box);
		update_indicator(e, &drop_box);
		return;
	}

	// Deny moving within own workspace if this is the only child
	struct sway_container *con = node->sway_container;
	if (workspace_num_tiling_views(e->con->pending.workspace) == 1 &&
			con->pending.workspace == e->con->pending.workspace) {
		e->target_node = NULL;
		e->target_edge = WLR_EDGE_NONE;
		return;
	}

	struct wlr_box drop_box = {
		.x = con->pending.content_x,
		.y = con->pending.content_y,
		.width = con->pending.content_width,
		.height = con->pending.content_height,
	};

	// Check if the cursor is over a tilebar only if the destination
	// container is not a descendant of the source container.
	if (!surface && !container_has_ancestor(con, e->con) &&
			split_titlebar(node, e->con, cursor->cursor,
				&drop_box, &e->insert_after_target)) {
		// Don't allow dropping over the source container's titlebar
		// to give users a chance to cancel a drag operation.
		if (con == e->con) {
			e->target_node = NULL;
		} else {
			e->target_node = node;
			e->split_target = true;
		}
		e->target_edge = WLR_EDGE_NONE;
		update_indicator(e, &drop_box);
		return;
	}

	// Traverse the ancestors, trying to find a layout container perpendicular
	// to the edge. Eg. close to the top or bottom of a horiz layout.
	int thresh_top = con->pending.content_y + DROP_LAYOUT_BORDER;
	int thresh_bottom = con->pending.content_y +
		con->pending.content_height - DROP_LAYOUT_BORDER;
	int thresh_left = con->pending.content_x + DROP_LAYOUT_BORDER;
	int thresh_right = con->pending.content_x +
		con->pending.content_width - DROP_LAYOUT_BORDER;
	while (con) {
		enum wlr_edges edge = WLR_EDGE_NONE;
		enum sway_container_layout layout = container_parent_layout(con);
		struct wlr_box box;
		node_get_box(node_get_parent(&con->node), &box);
		if (layout == L_HORIZ || layout == L_TABBED) {
			if (cursor->cursor->y < thresh_top) {
				edge = WLR_EDGE_TOP;
				box.height = thresh_top - box.y;
			} else if (cursor->cursor->y > thresh_bottom) {
				edge = WLR_EDGE_BOTTOM;
				box.height = box.y + box.height - thresh_bottom;
				box.y = thresh_bottom;
			}
		} else if (layout == L_VERT || layout == L_STACKED) {
			if (cursor->cursor->x < thresh_left) {
				edge = WLR_EDGE_LEFT;
				box.width = thresh_left - box.x;
			} else if (cursor->cursor->x > thresh_right) {
				edge = WLR_EDGE_RIGHT;
				box.width = box.x + box.width - thresh_right;
				box.x = thresh_right;
			}
		}
		if (edge) {
			e->target_node = node_get_parent(&con->node);
			if (e->target_node == &e->con->node) {
				e->target_node = node_get_parent(e->target_node);
			}
			e->target_edge = edge;
			update_indicator(e, &box);
			return;
		}
		con = con->pending.parent;
	}

	// Use the hovered view - but we must be over the actual surface
	con = node->sway_container;
	if (!con->view || !con->view->surface || node == &e->con->node
			|| node_has_ancestor(node, &e->con->node)) {
		e->target_node = NULL;
		e->target_edge = WLR_EDGE_NONE;
		return;
	}

	// Find the closest edge
	size_t thickness = fmin(con->pending.content_width, con->pending.content_height) * 0.3;
	size_t closest_dist = INT_MAX;
	size_t dist;
	e->target_edge = WLR_EDGE_NONE;
	if ((dist = cursor->cursor->y - con->pending.y) < closest_dist) {
		closest_dist = dist;
		e->target_edge = WLR_EDGE_TOP;
	}
	if ((dist = cursor->cursor->x - con->pending.x) < closest_dist) {
		closest_dist = dist;
		e->target_edge = WLR_EDGE_LEFT;
	}
	if ((dist = con->pending.x + con->pending.width - cursor->cursor->x) < closest_dist) {
		closest_dist = dist;
		e->target_edge = WLR_EDGE_RIGHT;
	}
	if ((dist = con->pending.y + con->pending.height - cursor->cursor->y) < closest_dist) {
		closest_dist = dist;
		e->target_edge = WLR_EDGE_BOTTOM;
	}

	if (closest_dist > thickness) {
		e->target_edge = WLR_EDGE_NONE;
	}

	e->target_node = node;
	resize_box(&drop_box, e->target_edge, thickness);
	update_indicator(e, &drop_box);
}

static void handle_pointer_motion(struct sway_seat *seat, uint32_t time_msec) {
	struct seatop_move_tiling_event *e = seat->seatop_data;
	if (e->threshold_reached) {
		handle_motion_postthreshold(seat, time_msec);
	} else {
		handle_motion_prethreshold(seat);
	}
	transaction_commit_dirty();
}

static bool is_parallel(enum sway_container_layout layout,
		enum wlr_edges edge) {
	bool layout_is_horiz = layout == L_HORIZ || layout == L_TABBED;
	bool edge_is_horiz = edge == WLR_EDGE_LEFT || edge == WLR_EDGE_RIGHT;
	return layout_is_horiz == edge_is_horiz;
}

static int clamp_workspace_insert_index(struct sway_workspace *ws, int index) {
	if (index < 0) {
		return 0;
	}
	if (index > ws->tiling->length) {
		return ws->tiling->length;
	}
	return index;
}

static bool finalize_scrollable_move(struct sway_seat *seat) {
	struct seatop_move_tiling_event *e = seat->seatop_data;
	struct sway_container *con = e->con;
	if (!container_is_scrollable_column(con) || !e->target_node) {
		return false;
	}

	struct sway_workspace *old_ws = con->pending.workspace;
	struct sway_workspace *new_ws = e->target_node->type == N_WORKSPACE ?
		e->target_node->sway_workspace :
		e->target_node->sway_container->pending.workspace;
	if (!new_ws || new_ws->layout != L_SCROLL_H) {
		return false;
	}

	container_detach(con);

	int index = 0;
	if (e->target_node->type == N_CONTAINER) {
		struct sway_container *target =
			container_toplevel_ancestor(e->target_node->sway_container);
		int target_index = list_find(new_ws->tiling, target);
		if (target_index < 0) {
			index = new_ws->tiling->length;
		} else {
			index = target_index + (e->target_edge == WLR_EDGE_RIGHT);
		}
	} else {
		index = e->target_edge == WLR_EDGE_RIGHT ? new_ws->tiling->length : 0;
	}

	workspace_insert_tiling_direct(new_ws, con,
		clamp_workspace_insert_index(new_ws, index));

	if (con->view) {
		ipc_event_window(con, "move");
	}

	arrange_workspace(new_ws);
	if (old_ws != new_ws) {
		arrange_workspace(old_ws);
	}

	transaction_commit_dirty();
	seatop_begin_default(seat);
	return true;
}

static void finalize_move(struct sway_seat *seat) {
	struct seatop_move_tiling_event *e = seat->seatop_data;

	if (!e->target_node) {
		seatop_begin_default(seat);
		return;
	}

	if (finalize_scrollable_move(seat)) {
		return;
	}

	struct sway_container *con = e->con;
	struct sway_container *old_parent = con->pending.parent;
	struct sway_workspace *old_ws = con->pending.workspace;
	struct sway_node *target_node = e->target_node;
	struct sway_workspace *new_ws = target_node->type == N_WORKSPACE ?
		target_node->sway_workspace : target_node->sway_container->pending.workspace;
	enum wlr_edges edge = e->target_edge;
	int after = edge != WLR_EDGE_TOP && edge != WLR_EDGE_LEFT;
	bool swap = edge == WLR_EDGE_NONE && target_node->type == N_CONTAINER &&
		!e->split_target;

	if (!swap) {
		container_detach(con);
	}

	// Moving container into empty workspace
	if (target_node->type == N_WORKSPACE && edge == WLR_EDGE_NONE) {
		con = workspace_add_tiling(new_ws, con);
	} else if (e->split_target) {
		struct sway_container *target = target_node->sway_container;
		enum sway_container_layout layout = container_parent_layout(target);
		if (layout != L_TABBED && layout != L_STACKED) {
			container_split(target, L_TABBED);
		}
		container_add_sibling(target, con, e->insert_after_target);
		ipc_event_window(con, "move");
	} else if (target_node->type == N_CONTAINER) {
		// Moving container before/after another
		struct sway_container *target = target_node->sway_container;
		if (swap) {
			container_swap(target_node->sway_container, con);
		} else {
			enum sway_container_layout layout = container_parent_layout(target);
			if (edge && !is_parallel(layout, edge)) {
				enum sway_container_layout new_layout = edge == WLR_EDGE_TOP ||
					edge == WLR_EDGE_BOTTOM ? L_VERT : L_HORIZ;
				container_split(target, new_layout);
			}
			container_add_sibling(target, con, after);
			ipc_event_window(con, "move");
		}
	} else {
		// Target is a workspace which requires splitting
		enum sway_container_layout new_layout = edge == WLR_EDGE_TOP ||
			edge == WLR_EDGE_BOTTOM ? L_VERT : L_HORIZ;
		workspace_split(new_ws, new_layout);
		workspace_insert_tiling(new_ws, con, after);
	}

	if (old_parent) {
		container_reap_empty(old_parent);
	}

	// This is a bit dirty, but we'll set the dimensions to that of a sibling.
	// I don't think there's any other way to make it consistent without
	// changing how we auto-size containers.
	list_t *siblings = container_get_siblings(con);
	if (siblings->length > 1) {
		int index = list_find(siblings, con);
		struct sway_container *sibling = index == 0 ?
			siblings->items[1] : siblings->items[index - 1];
		con->pending.width = sibling->pending.width;
		con->pending.height = sibling->pending.height;
		con->width_fraction = sibling->width_fraction;
		con->height_fraction = sibling->height_fraction;
	}

	arrange_workspace(old_ws);
	if (new_ws != old_ws) {
		arrange_workspace(new_ws);
	}

	transaction_commit_dirty();
	seatop_begin_default(seat);
}

static void handle_button(struct sway_seat *seat, uint32_t time_msec,
		struct wlr_input_device *device, uint32_t button,
		enum wl_pointer_button_state state) {
	if (seat->cursor->pressed_button_count == 0) {
		finalize_move(seat);
	}
}

static void handle_tablet_tool_tip(struct sway_seat *seat,
		struct sway_tablet_tool *tool, uint32_t time_msec,
		enum wlr_tablet_tool_tip_state state) {
	if (state == WLR_TABLET_TOOL_TIP_UP) {
		finalize_move(seat);
	}
}

static void handle_unref(struct sway_seat *seat, struct sway_container *con) {
	struct seatop_move_tiling_event *e = seat->seatop_data;
	if (e->target_node == &con->node) { // Drop target
		e->target_node = NULL;
	}
	if (e->con == con) { // The container being moved
		seatop_begin_default(seat);
	}
}

static const struct sway_seatop_impl seatop_impl = {
	.button = handle_button,
	.pointer_motion = handle_pointer_motion,
	.tablet_tool_tip = handle_tablet_tool_tip,
	.unref = handle_unref,
	.end = handle_end,
};

void seatop_begin_move_tiling_threshold(struct sway_seat *seat,
		struct sway_container *con) {
	seatop_end(seat);

	struct seatop_move_tiling_event *e =
		calloc(1, sizeof(struct seatop_move_tiling_event));
	if (!e) {
		return;
	}

	const float *indicator = config->border_colors.focused.indicator;
	float color[4] = {
		indicator[0] * .5,
		indicator[1] * .5,
		indicator[2] * .5,
		indicator[3] * .5,
	};

	e->indicator_blur = wlr_scene_blur_create(seat->scene_tree, 0, 0);
	if (!e->indicator_blur) {
		free(e);
		return;
	}

	e->indicator_rect = wlr_scene_rect_create(seat->scene_tree, 0, 0, color);
	if (!e->indicator_rect) {
		wlr_scene_node_destroy(&e->indicator_blur->node);
		free(e);
		return;
	}

	e->con = con;
	e->ref_lx = seat->cursor->cursor->x;
	e->ref_ly = seat->cursor->cursor->y;

	seat->seatop_impl = &seatop_impl;
	seat->seatop_data = e;

	container_raise_floating(con);
	transaction_commit_dirty();
	wlr_seat_pointer_notify_clear_focus(seat->wlr_seat);
}

void seatop_begin_move_tiling(struct sway_seat *seat,
		struct sway_container *con) {
	seatop_begin_move_tiling_threshold(seat, con);
	struct seatop_move_tiling_event *e = seat->seatop_data;
	if (e) {
		e->threshold_reached = true;
		cursor_set_image(seat->cursor, "grab", NULL);
	}
}

#ifndef SWAY_XWAYLAND_H
#define SWAY_XWAYLAND_H

#include <stdbool.h>
#include <wlr/xwayland.h>
#include <xcb/xproto.h>

enum atom_name {
	NET_WM_WINDOW_TYPE_NORMAL,
	NET_WM_WINDOW_TYPE_DIALOG,
	NET_WM_WINDOW_TYPE_UTILITY,
	NET_WM_WINDOW_TYPE_TOOLBAR,
	NET_WM_WINDOW_TYPE_SPLASH,
	NET_WM_WINDOW_TYPE_MENU,
	NET_WM_WINDOW_TYPE_DROPDOWN_MENU,
	NET_WM_WINDOW_TYPE_POPUP_MENU,
	NET_WM_WINDOW_TYPE_TOOLTIP,
	NET_WM_WINDOW_TYPE_NOTIFICATION,
	NET_WM_STATE_MODAL,
	ATOM_LAST,
};

struct sway_xwayland {
	struct wlr_xwayland *wlr_xwayland;
	struct wlr_xcursor_manager *xcursor_manager;

	xcb_atom_t atoms[ATOM_LAST];
};

void handle_xwayland_ready(struct wl_listener *listener, void *data);

bool sway_xwayland_surface_is_fullscreen_overlay(
	struct wlr_xwayland_surface *xsurface);
void sway_xwayland_surface_focus(struct wlr_xwayland_surface *xsurface,
	bool unfocus);

#endif

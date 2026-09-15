#include "sway/commands.h"
#include "sway/config.h"
#include "sway/desktop/transaction.h"
#include "sway/tree/arrange.h"
#include "sway/tree/container.h"
#include "sway/tree/node.h"
#include "sway/tree/root.h"
#include "util.h"

static void dwindle_border_iter(struct sway_container *con, void *data) {
	bool enabled = *(bool *)data;
	if (!con->view) {
		return;
	}
	if (container_is_floating_or_child(con)) {
		return;
	}
	if (enabled) {
		if (con->pending.border == B_NORMAL) {
			con->pending.border = B_PIXEL;
			node_set_dirty(&con->node);
		}
	} else {
		if (con->pending.border == B_PIXEL) {
			con->pending.border = config->border;
			node_set_dirty(&con->node);
		}
	}
}

struct cmd_results *cmd_dwindle(int argc, char **argv) {
    struct cmd_results *error = NULL;
    if ((error = checkarg(argc, "dwindle", EXPECTED_EQUAL_TO, 1))) {
        return error;
    }
    bool enabled = parse_boolean(argv[0], config->dwindle);
    if (config->dwindle == enabled) {
        return cmd_results_new(CMD_SUCCESS, NULL);
    }
    config->dwindle = enabled;
    root_for_each_container(dwindle_border_iter, &enabled);
    arrange_root();
    transaction_commit_dirty();
    return cmd_results_new(CMD_SUCCESS, NULL);
}

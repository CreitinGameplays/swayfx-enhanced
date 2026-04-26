#include "sway/commands.h"
#include "util.h"

struct cmd_results *cmd_scrollable_tiling_touchpad_pinch_resize(
		int argc, char **argv) {
	struct cmd_results *error = NULL;
	if ((error = checkarg(argc, "scrollable_tiling_touchpad_pinch_resize",
			EXPECTED_EQUAL_TO, 1))) {
		return error;
	}

	config->scrollable_tiling_touchpad_pinch_resize = parse_boolean(argv[0],
		config->scrollable_tiling_touchpad_pinch_resize);
	return cmd_results_new(CMD_SUCCESS, NULL);
}

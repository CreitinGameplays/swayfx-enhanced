#include <stdlib.h>
#include "sway/commands.h"

struct cmd_results *cmd_scrollable_tiling_touchpad_scroll_factor(
		int argc, char **argv) {
	struct cmd_results *error = NULL;
	if ((error = checkarg(argc, "scrollable_tiling_touchpad_scroll_factor",
			EXPECTED_EQUAL_TO, 1))) {
		return error;
	}

	char *end = NULL;
	float factor = strtof(argv[0], &end);
	if (*end) {
		return cmd_results_new(CMD_INVALID,
			"scrollable_tiling_touchpad_scroll_factor float invalid");
	}
	if (factor < 0.0f || factor > 10.0f) {
		return cmd_results_new(CMD_FAILURE,
			"scrollable_tiling_touchpad_scroll_factor value out of bounds");
	}

	config->scrollable_tiling_touchpad_scroll_factor = factor;
	return cmd_results_new(CMD_SUCCESS, NULL);
}

#include "sway/commands.h"
#include "util.h"

struct cmd_results *cmd_fullscreen_anim(int argc, char **argv) {
	struct cmd_results *error = NULL;
	if ((error = checkarg(argc, "fullscreen_anim", EXPECTED_EQUAL_TO, 1))) {
		return error;
	}
	config->fullscreen_anim = parse_boolean(argv[0], config->fullscreen_anim);
	return cmd_results_new(CMD_SUCCESS, NULL);
}

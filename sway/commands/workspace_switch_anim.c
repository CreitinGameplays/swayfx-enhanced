#include "sway/commands.h"
#include "util.h"

struct cmd_results *cmd_workspace_switch_anim(int argc, char **argv) {
	struct cmd_results *error = NULL;
	if ((error = checkarg(argc, "workspace_switch_anim", EXPECTED_EQUAL_TO, 1))) {
		return error;
	}
	config->workspace_switch_anim = parse_boolean(argv[0], config->workspace_switch_anim);
	return cmd_results_new(CMD_SUCCESS, NULL);
}
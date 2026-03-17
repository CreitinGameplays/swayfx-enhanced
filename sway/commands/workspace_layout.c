#include <string.h>
#include <strings.h>
#include "sway/commands.h"

struct cmd_results *cmd_workspace_layout(int argc, char **argv) {
	struct cmd_results *error = NULL;
	if ((error = checkarg(argc, "workspace_layout", EXPECTED_EQUAL_TO, 1))) {
		return error;
	}
	if (strcasecmp(argv[0], "default") == 0) {
		config->default_workspace_layout = L_NONE;
		config->default_layout = L_NONE;
	} else if (strcasecmp(argv[0], "scrollable") == 0) {
		config->default_workspace_layout = L_SCROLL_H;
		config->default_layout = L_NONE;
	} else if (strcasecmp(argv[0], "stacking") == 0) {
		config->default_workspace_layout = L_NONE;
		config->default_layout = L_STACKED;
	} else if (strcasecmp(argv[0], "tabbed") == 0) {
		config->default_workspace_layout = L_NONE;
		config->default_layout = L_TABBED;
	} else {
		return cmd_results_new(CMD_INVALID,
				"Expected 'workspace_layout <default|scrollable|stacking|tabbed>'");
	}
	return cmd_results_new(CMD_SUCCESS, NULL);
}

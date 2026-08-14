#include <math.h>
#include <stdio.h>
#include <string.h>
#include "sway/commands.h"
#include "util.h"

static bool set_curve(double c1x, double c1y, double c2x, double c2y) {
	// x control points need to stay in [0, 1] for the math to make sense.
	if (c1x < 0.0 || c1x > 1.0 || c2x < 0.0 || c2x > 1.0) {
		return false;
	}
	config->workspace_switch_curve_c1x = c1x;
	config->workspace_switch_curve_c1y = c1y;
	config->workspace_switch_curve_c2x = c2x;
	config->workspace_switch_curve_c2y = c2y;
	return true;
}

struct cmd_results *cmd_workspace_switch_curve(int argc, char **argv) {
	struct cmd_results *error = NULL;
	if ((error = checkarg(argc, "workspace_switch_curve", EXPECTED_AT_LEAST, 1))) {
		return error;
	}

	const char *a = argv[0];

	// Named presets; the default is cubic-bezier(0.1, 1, 0, 1) = menu_decel.
	if (strcmp(a, "linear") == 0) {
		set_curve(0.0, 0.0, 1.0, 1.0);
		return cmd_results_new(CMD_SUCCESS, NULL);
	}
	if (strcmp(a, "ease") == 0) {
		set_curve(0.25, 0.1, 0.25, 1.0);
		return cmd_results_new(CMD_SUCCESS, NULL);
	}
	if (strcmp(a, "ease-in") == 0) {
		set_curve(0.42, 0.0, 1.0, 1.0);
		return cmd_results_new(CMD_SUCCESS, NULL);
	}
	if (strcmp(a, "ease-out") == 0) {
		set_curve(0.0, 0.0, 0.58, 1.0);
		return cmd_results_new(CMD_SUCCESS, NULL);
	}
	if (strcmp(a, "ease-in-out") == 0) {
		set_curve(0.42, 0.0, 0.58, 1.0);
		return cmd_results_new(CMD_SUCCESS, NULL);
	}
	if (strcmp(a, "menu_decel") == 0 || strcmp(a, "default") == 0) {
		set_curve(0.1, 1.0, 0.0, 1.0);
		return cmd_results_new(CMD_SUCCESS, NULL);
	}

	// Raw curve: workspace_switch_curve cubic-bezier(0.1, 1, 0, 1)
	if (strncmp(a, "cubic-bezier", strlen("cubic-bezier")) == 0) {
		// The config parser splits on spaces, so rejoin all args before
		// looking for the parenthesized control points.
		char joined[256] = "";
		size_t used = 0;
		for (int i = 0; i < argc; ++i) {
			size_t len = strlen(argv[i]);
			if (used + len + 2 > sizeof(joined)) {
				return cmd_results_new(CMD_FAILURE,
					"workspace_switch_curve cubic-bezier value too long");
			}
			if (used) {
				joined[used++] = ' ';
			}
			memcpy(joined + used, argv[i], len);
			used += len;
		}
		joined[used] = '\0';

		double xy[4];
		int n = 0;
		const char *p = strchr(joined, '(');
		if (p) {
			char buf[128];
			size_t len = strcspn(p + 1, ")");
			if (len >= sizeof(buf)) {
				return cmd_results_new(CMD_FAILURE,
					"workspace_switch_curve cubic-bezier value too long");
			}
			memcpy(buf, p + 1, len);
			buf[len] = '\0';
			char *tok = strtok(buf, " ,");
			while (tok && n < 4) {
				char *end = NULL;
				double v = strtod(tok, &end);
				if (end == tok) {
					break;
				}
				xy[n++] = v;
				tok = strtok(NULL, " ,");
			}
		}
		if (n == 4 && set_curve(xy[0], xy[1], xy[2], xy[3])) {
			return cmd_results_new(CMD_SUCCESS, NULL);
		}
		return cmd_results_new(CMD_FAILURE,
			"workspace_switch_curve cubic-bezier expects four floats with x in [0; 1]");
	}

	return cmd_results_new(CMD_INVALID, "workspace_switch_curve: unknown curve");
}
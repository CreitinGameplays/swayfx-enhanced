#include <string.h>
#include <stdlib.h>
#include "sway/commands.h"
#include "sway/config.h"
#include "sway/tree/container.h"
#include "sway/tree/root.h"
#include "sway/tree/arrange.h"
#include "sway/output.h"
#include "util.h"

static void arrange_liquid_glass_iter(struct sway_container *con, void *data) {
	con->liquid_glass_enabled = config->liquid_glass_enabled;
}

struct cmd_results *cmd_liquid_glass(int argc, char **argv) {
	struct cmd_results *error = checkarg(argc, "liquid_glass", EXPECTED_AT_LEAST, 1);
	if (error) {
		return error;
	}

	struct sway_container *con = config->handler_context.container;
	bool result = parse_boolean(argv[0], true);

	if (con == NULL) {
		config->liquid_glass_enabled = result;
		root_for_each_container(arrange_liquid_glass_iter, NULL);
		arrange_root();
	} else {
		con->liquid_glass_enabled = result;
		node_set_dirty(&con->node);
	}

	return cmd_results_new(CMD_SUCCESS, NULL);
}

struct cmd_results *cmd_liquid_glass_surface(int argc, char **argv) {
	struct cmd_results *error = checkarg(argc, "liquid_glass_surface", EXPECTED_EQUAL_TO, 1);
	if (error) {
		return error;
	}

	if (strcmp(argv[0], "convex_circle") == 0) {
		config->liquid_glass_data.surface_type = LIQUID_GLASS_SURFACE_CONVEX_CIRCLE;
	} else if (strcmp(argv[0], "convex_squircle") == 0) {
		config->liquid_glass_data.surface_type = LIQUID_GLASS_SURFACE_CONVEX_SQUIRCLE;
	} else if (strcmp(argv[0], "concave") == 0) {
		config->liquid_glass_data.surface_type = LIQUID_GLASS_SURFACE_CONCAVE;
	} else if (strcmp(argv[0], "lip") == 0) {
		config->liquid_glass_data.surface_type = LIQUID_GLASS_SURFACE_LIP;
	} else {
		return cmd_results_new(CMD_INVALID, "Invalid surface type. Expected one of: convex_circle, convex_squircle, concave, lip");
	}

	arrange_root();

	return cmd_results_new(CMD_SUCCESS, NULL);
}

struct cmd_results *cmd_liquid_glass_bezel_width(int argc, char **argv) {
	struct cmd_results *error = checkarg(argc, "liquid_glass_bezel_width", EXPECTED_EQUAL_TO, 1);
	if (error) {
		return error;
	}

	char *inv;
	float value = strtof(argv[0], &inv);
	if (*inv != '\0' || value < 0) {
		return cmd_results_new(CMD_INVALID, "Invalid bezel width");
	}

	config->liquid_glass_data.bezel_width = value;

	arrange_root();

	return cmd_results_new(CMD_SUCCESS, NULL);
}

struct cmd_results *cmd_liquid_glass_thickness(int argc, char **argv) {
	struct cmd_results *error = checkarg(argc, "liquid_glass_thickness", EXPECTED_EQUAL_TO, 1);
	if (error) {
		return error;
	}

	char *inv;
	float value = strtof(argv[0], &inv);
	if (*inv != '\0' || value < 0) {
		return cmd_results_new(CMD_INVALID, "Invalid thickness");
	}

	config->liquid_glass_data.thickness = value;

	arrange_root();

	return cmd_results_new(CMD_SUCCESS, NULL);
}

struct cmd_results *cmd_liquid_glass_refraction_index(int argc, char **argv) {
	struct cmd_results *error = checkarg(argc, "liquid_glass_refraction_index", EXPECTED_EQUAL_TO, 1);
	if (error) {
		return error;
	}

	char *inv;
	float value = strtof(argv[0], &inv);
	if (*inv != '\0' || value < 1.0) {
		return cmd_results_new(CMD_INVALID, "Invalid refraction index (must be >= 1.0)");
	}

	config->liquid_glass_data.refraction_index = value;

	arrange_root();

	return cmd_results_new(CMD_SUCCESS, NULL);
}

struct cmd_results *cmd_liquid_glass_specular_opacity(int argc, char **argv) {
	struct cmd_results *error = checkarg(argc, "liquid_glass_specular_opacity", EXPECTED_EQUAL_TO, 1);
	if (error) {
		return error;
	}

	char *inv;
	float value = strtof(argv[0], &inv);
	if (*inv != '\0' || value < 0 || value > 1.0) {
		return cmd_results_new(CMD_INVALID, "Invalid specular opacity (must be between 0 and 1)");
	}

	config->liquid_glass_data.specular_opacity = value;

	arrange_root();

	return cmd_results_new(CMD_SUCCESS, NULL);
}

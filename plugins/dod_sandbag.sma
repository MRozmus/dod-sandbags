// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 dod-modding contributors
// Distributed without warranty; see LICENSES/GPL-3.0.txt.
/* Modules: engine, hamsandwich, dodx; fakemeta for server diagnostics. Uses a generated, static model baked from the server's stock DoD bag.
 * Mesh bounds, StudioMDL hitbox and network BBOX share the same dimensions.
 */
#include <amxmodx>
#include <amxmisc>
#include <engine>
#include <hamsandwich>
#include <dodx>
#include <fakemeta>

#define PLUGIN_NAME "DoD Sandbags"
#define PLUGIN_VERSION "2.5.0"
#define PLUGIN_AUTHOR "dod-modding"
#define MAX_PLAYERS 32
#define MAX_SANDBAGS 128
#define TRACE_DISTANCE 8192.0
#define SANDBAG_MODEL "models/dod_modding/sandbag_v6.mdl"
#define SANDBAG_CLASSNAME "dod_sandbag"
#define PREVIEW_CLASSNAME "dod_sandbag_preview"
#define BAG_HALF_LENGTH 32.0
#define BAG_HALF_WIDTH 16.0
#define BAG_HALF_HEIGHT 8.0
// The generated model is centered and has a frozen identity bone transform.
#define MODEL_CENTER_X 0.0
#define MODEL_CENTER_Y 0.0
#define MODEL_BOTTOM_Z -8.0
#define PLACE_OK 0
#define PLACE_NO_SURFACE 1
#define PLACE_BAD_SURFACE 2
#define PLACE_TOO_FAR 3
#define PLACE_BLOCKED 4

new bool:g_enabled[MAX_PLAYERS + 1];
new bool:g_placing[MAX_PLAYERS + 1];
new bool:g_rotation_override[MAX_PLAYERS + 1];
new g_preview[MAX_PLAYERS + 1];
new Float:g_yaw[MAX_PLAYERS + 1];
new g_health_cvar;
new g_server_enabled_cvar, g_limit_cvar, g_player_limit_cvar, g_cooldown_cvar;
new g_reach_cvar, g_lifetime_cvar, g_disconnect_cvar, g_access_cvar;
new g_pistol_damage_cvar, g_reserve_cvar, g_alpha_cvar;
new g_access_mask;
new bool:g_config_ready;
new g_test_expiry;
new Float:g_last_placement[MAX_PLAYERS + 1];
#define PISTOL_SANDBAG_DAMAGE 40.0
new Float:g_next_preview[MAX_PLAYERS + 1];
new Float:g_maxs[3] = {BAG_HALF_LENGTH, BAG_HALF_WIDTH, BAG_HALF_HEIGHT};
new g_test_bags[4];
new Float:g_test_center[3];
new g_test_checks;
new g_test_failures;

public plugin_precache()
{
	new mod[16];
	get_modname(mod, charsmax(mod));
	if (!equal(mod, "dod"))
	{
		set_fail_state("DoD Sandbags supports GoldSrc Day of Defeat 1.3 only.");
		return;
	}
	if (!file_exists(SANDBAG_MODEL))
	{
		set_fail_state("Missing %s. Generate the model before installing the plugin; see README.", SANDBAG_MODEL);
		return;
	}
	precache_model(SANDBAG_MODEL);
}

public plugin_init()
{
	register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);
	if (!register_dictionary("dod_sandbag.txt"))
	{
		set_fail_state("Missing/unreadable addons/amxmodx/data/lang/dod_sandbag.txt.");
		return;
	}
	register_clcmd("dod_sandbag", "cmd_sandbag_toggle");
	register_clcmd("+dod_sandbag", "cmd_sandbag_start");
	register_clcmd("-dod_sandbag", "cmd_sandbag_commit");
	register_srvcmd("dod_sandbag_selftest", "cmd_selftest");
	register_clcmd("dod_sandbag_rotate", "cmd_sandbag_rotate");
	register_clcmd("dod_sandbag_help", "cmd_sandbag_help");
	register_clcmd("dod_sandbag_remove", "cmd_remove_owned");
	register_concmd("dod_sandbag_clear", "cmd_clear", ADMIN_CFG, "- remove all project sandbags and previews");
	register_srvcmd("dod_sandbag_status", "cmd_status");
	register_cvar("dod_sandbag_version", PLUGIN_VERSION, FCVAR_SERVER | FCVAR_SPONLY);
	g_server_enabled_cvar = bounded_cvar("dod_sandbag_enabled", "1", "Allow players to build. Existing bags remain when disabled.", 0.0, 1.0);
	g_limit_cvar = bounded_cvar("dod_sandbag_max_bags", "64", "Global bag limit. Hard safety cap: 128.", 1.0, float(MAX_SANDBAGS));
	g_player_limit_cvar = bounded_cvar("dod_sandbag_max_per_player", "16", "Per-player bag limit. 0 disables this quota; global limit still applies.", 0.0, float(MAX_SANDBAGS));
	g_cooldown_cvar = bounded_cvar("dod_sandbag_cooldown", "0.5", "Seconds between successful placements.", 0.1, 10.0);
	g_reach_cvar = bounded_cvar("dod_sandbag_reach", "256", "Maximum placement distance in GoldSrc units.", 64.0, 512.0);
	g_health_cvar = bounded_cvar("dod_sandbag_health", "400", "Health of newly placed bags; existing health is unchanged.", 1.0, 10000.0);
	g_pistol_damage_cvar = bounded_cvar("dod_sandbag_pistol_damage", "40", "Damage per Colt/Luger/Webley bullet against a bag. 0 uses stock damage.", 0.0, 1000.0);
	g_lifetime_cvar = bounded_cvar("dod_sandbag_lifetime", "0", "Seconds until a new bag expires. 0 lasts until destroyed/map change.", 0.0, 3600.0);
	g_disconnect_cvar = bounded_cvar("dod_sandbag_remove_on_disconnect", "1", "Remove a player's bags on disconnect. Helps prevent reconnect quota abuse.", 0.0, 1.0);
	g_reserve_cvar = bounded_cvar("dod_sandbag_entity_reserve", "64", "Keep this many free engine entities for the map and other plugins.", 32.0, 256.0);
	g_alpha_cvar = bounded_cvar("dod_sandbag_preview_alpha", "125", "Preview opacity (0=transparent, 255=opaque).", 20.0, 200.0);
	g_access_cvar = create_cvar("dod_sandbag_access_flags", "", FCVAR_NONE, "Required AMXX flags (all). Empty allows everyone; malformed input denies access.");
	hook_cvar_change(g_access_cvar, "access_flags_changed");
	hook_cvar_change(g_server_enabled_cvar, "building_enabled_changed");
	AutoExecConfig(true, "dod_sandbag");
	register_think(SANDBAG_CLASSNAME, "sandbag_expire");
	RegisterHam(Ham_TraceAttack, "info_target", "sandbag_trace_attack");
	RegisterHam(Ham_TakeDamage, "info_target", "sandbag_take_damage");
	log_amx("dod_sandbag loaded: version %s", PLUGIN_VERSION);
}

bounded_cvar(const name[], const value[], const description[], Float:minimum, Float:maximum)
{
	return create_cvar(name, value, FCVAR_NONE, description, true, minimum, true, maximum);
}

public OnConfigsExecuted()
{
	refresh_access_flags();
	g_config_ready = true;
	log_amx("dod_sandbag config ready: enabled=%d max=%d per_player=%d health=%d reach=%d",
		get_pcvar_num(g_server_enabled_cvar), get_pcvar_num(g_limit_cvar),
		get_pcvar_num(g_player_limit_cvar), get_pcvar_num(g_health_cvar), get_pcvar_num(g_reach_cvar));
}

public access_flags_changed(pcvar, const old_value[], const new_value[])
{
	refresh_access_flags();
	for (new id = 1; id <= MAX_PLAYERS; id++)
		if (g_placing[id] && !can_build(id))
			destroy_preview(id);
}

refresh_access_flags()
{
	new flags[32];
	get_pcvar_string(g_access_cvar, flags, charsmax(flags));
	g_access_mask = parse_access_flags(flags);
	if (g_access_mask < 0)
		log_amx("Invalid dod_sandbag_access_flags; building denied until corrected. Use letters a-z or an empty string.");
}

parse_access_flags(const flags[])
{
	if (strlen(flags) > 26)
		return -1;
	for (new index = 0; flags[index]; index++)
		if (flags[index] < 'a' || flags[index] > 'z')
			return -1;
	return read_flags(flags);
}

public building_enabled_changed(pcvar, const old_value[], const new_value[])
{
	if (!get_pcvar_num(g_server_enabled_cvar))
		for (new id = 1; id <= MAX_PLAYERS; id++)
			destroy_preview(id);
}

bool:can_build(id, bool:notify = false)
{
	if (id < 1 || id > MAX_PLAYERS || !is_user_connected(id))
		return false;
	if (!g_config_ready || !get_pcvar_num(g_server_enabled_cvar))
	{
		if (notify)
			client_print(id, print_chat, "[dod_sandbag] %L", id, "SB_SERVER_DISABLED");
		return false;
	}
	if (g_access_mask < 0 || (get_user_flags(id) & g_access_mask) != g_access_mask)
	{
		if (notify)
			client_print(id, print_chat, "[dod_sandbag] %L", id, "SB_NO_ACCESS");
		return false;
	}
	return true;
}

count_owned_bags(userid)
{
	new count, bag = -1;
	while ((bag = find_ent_by_class(bag, SANDBAG_CLASSNAME)) > 0)
		if (userid > 0 && entity_get_int(bag, EV_INT_iuser1) == userid)
			count++;
	return count;
}

bool:placement_budget(id, bool:notify = false)
{
	new reason[32];
	if (count_sandbags() >= get_pcvar_num(g_limit_cvar))
		copy(reason, charsmax(reason), "SB_GLOBAL_LIMIT");
	else if (get_pcvar_num(g_player_limit_cvar) > 0
		&& count_owned_bags(get_user_userid(id)) >= get_pcvar_num(g_player_limit_cvar))
		copy(reason, charsmax(reason), "SB_PLAYER_LIMIT");
	else if (entity_count() + 2 > get_global_int(GL_maxEntities) - get_pcvar_num(g_reserve_cvar))
		copy(reason, charsmax(reason), "SB_ENTITY_LIMIT");
	else if (g_last_placement[id] > 0.0
		&& get_gametime() - g_last_placement[id] < get_pcvar_float(g_cooldown_cvar))
		copy(reason, charsmax(reason), "SB_COOLDOWN");
	if (!reason[0])
		return true;
	if (notify)
		client_print(id, print_chat, "[dod_sandbag] %L", id, reason);
	return false;
}

public cmd_sandbag_help(id)
{
	if (id >= 1 && id <= MAX_PLAYERS && is_user_connected(id))
	{
		client_print(id, print_console, "[dod_sandbag] %L", id, "SB_HELP");
		client_print(id, print_console, "[dod_sandbag] %L", id, "SB_COMMANDS");
	}
	return PLUGIN_HANDLED;
}

public cmd_clear(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	if (g_test_bags[0])
	{
		console_print(id, "[dod_sandbag] Wait for the self-test to finish.");
		return PLUGIN_HANDLED;
	}
	new bag = -1, count;
	while ((bag = find_ent_by_class(bag, SANDBAG_CLASSNAME)) > 0)
	{
		remove_sandbag(bag);
		count++;
	}
	for (new player = 1; player <= MAX_PLAYERS; player++)
		destroy_preview(player);
	console_print(id, "[dod_sandbag] Removed %d bags.", count);
	log_amx("dod_sandbag clear: %d bags removed by console/client %d", count, id);
	return PLUGIN_HANDLED;
}

public cmd_remove_owned(id)
{
	if (id < 1 || id > MAX_PLAYERS || !is_user_alive(id))
		return PLUGIN_HANDLED;
	new aimed, body;
	get_user_aiming(id, aimed, body, floatround(get_pcvar_float(g_reach_cvar)));
	if (!is_sandbag(aimed) || entity_get_int(aimed, EV_INT_iuser1) != get_user_userid(id))
		client_print(id, print_chat, "[dod_sandbag] %L", id, "SB_NOT_OWNED");
	else
		remove_sandbag(aimed);
	return PLUGIN_HANDLED;
}

remove_owned_bags(userid)
{
	new bag = -1;
	while ((bag = find_ent_by_class(bag, SANDBAG_CLASSNAME)) > 0)
		if (userid > 0 && entity_get_int(bag, EV_INT_iuser1) == userid)
			remove_sandbag(bag);
}

public sandbag_expire(bag)
{
	if (!is_sandbag(bag))
		return;
	new Float:expiry = entity_get_float(bag, EV_FL_fuser1);
	if (expiry > 0.0 && get_gametime() >= expiry)
		remove_sandbag(bag);
}

public cmd_status()
{
	server_print("[dod_sandbag] version=%s enabled=%d bags=%d/%d per_player=%d entities=%d/%d reserve=%d",
		PLUGIN_VERSION, get_pcvar_num(g_server_enabled_cvar), count_sandbags(), get_pcvar_num(g_limit_cvar),
		get_pcvar_num(g_player_limit_cvar), entity_count(), get_global_int(GL_maxEntities), get_pcvar_num(g_reserve_cvar));
	return PLUGIN_HANDLED;
}

public plugin_end()
{
	for (new id = 1; id <= MAX_PLAYERS; id++)
		destroy_preview(id);
	new bag = -1;
	while ((bag = find_ent_by_class(bag, SANDBAG_CLASSNAME)) > 0)
		remove_sandbag(bag);
	remove_task();
}

public client_disconnected(id)
{
	if (get_pcvar_num(g_disconnect_cvar))
		remove_owned_bags(get_user_userid(id));
	destroy_preview(id);
	g_last_placement[id] = 0.0;
	g_enabled[id] = false;
}

public client_PreThink(id)
{
	if (!g_placing[id])
		return;
	if (!is_user_alive(id) || !can_build(id))
	{
		destroy_preview(id);
		return;
	}
	new Float:now = get_gametime();
	if (now >= g_next_preview[id])
	{
		g_next_preview[id] = now + 0.05;
		update_preview(id);
	}
}

public cmd_sandbag_toggle(id)
{
	if (!is_user_connected(id))
		return PLUGIN_HANDLED;
	if (!g_enabled[id] && !can_build(id, true))
		return PLUGIN_HANDLED;
	g_enabled[id] = !g_enabled[id];
	if (g_enabled[id])
	{
		client_print(id, print_chat, "[dod_sandbag] %L", id, "SB_ENABLED");
		client_print(id, print_console, "[dod_sandbag] %L", id, "SB_HELP");
	}
	else
	{
		destroy_preview(id);
		client_print(id, print_chat, "[dod_sandbag] %L", id, "SB_DISABLED");
	}
	return PLUGIN_HANDLED;
}

public cmd_sandbag_start(id)
{
	if (!is_user_alive(id) || !g_enabled[id] || g_placing[id])
		return PLUGIN_HANDLED;
	if (!can_build(id, true) || !placement_budget(id, true))
		return PLUGIN_HANDLED;
	g_preview[id] = create_visual(PREVIEW_CLASSNAME);
	if (!g_preview[id])
		return PLUGIN_HANDLED;
	entity_set_int(g_preview[id], EV_INT_rendermode, kRenderTransAlpha);
	entity_set_vector(g_preview[id], EV_VEC_rendercolor, Float:{80.0, 255.0, 80.0});
	new Float:angles[3];
	entity_get_vector(id, EV_VEC_v_angle, angles);
	g_yaw[id] = float(floatround(angles[1] / 90.0)) * 90.0;
	g_placing[id] = true;
	g_rotation_override[id] = false;
	update_preview(id);
	return PLUGIN_HANDLED;
}

public cmd_sandbag_rotate(id)
{
	if (id < 1 || id > MAX_PLAYERS || !is_user_alive(id) || !g_placing[id])
		return PLUGIN_HANDLED;
	if (!can_build(id))
	{
		destroy_preview(id);
		return PLUGIN_HANDLED;
	}
	g_rotation_override[id] = true;
	g_yaw[id] += 90.0;
	if (g_yaw[id] >= 360.0)
		g_yaw[id] -= 360.0;
	update_preview(id);
	return PLUGIN_HANDLED;
}

// info_target has no breakable-specific health implementation. Handle its
// trace damage ourselves, without adding a second engine MultiDamage hit.
public sandbag_trace_attack(bag, attacker, Float:damage, Float:direction[3], trace, damage_bits)
{
	if (!is_sandbag(bag))
		return HAM_IGNORED;
	// Balance sidearms equally against props: ten direct pistol hits at the
	// default 400 HP. Other weapons/explosions keep their actual damage.
	if (damage > 0.0 && (damage_bits & DMG_BULLET) && attacker >= 1
		&& attacker <= MAX_PLAYERS && is_user_connected(attacker))
		damage = balanced_trace_damage(dod_get_user_weapon(attacker), damage, get_pcvar_float(g_pistol_damage_cvar));
	ExecuteHamB(Ham_TakeDamage, bag, attacker, attacker, damage, damage_bits);
	return HAM_SUPERCEDE;
}

Float:balanced_trace_damage(weapon, Float:damage, Float:pistol_damage = PISTOL_SANDBAG_DAMAGE)
{
	if (pistol_damage > 0.0 && (weapon == DODW_COLT || weapon == DODW_LUGER || weapon == DODW_WEBLEY))
		return pistol_damage;
	return damage;
}

public sandbag_take_damage(bag, inflictor, attacker, Float:damage, damage_bits)
{
	if (!is_sandbag(bag))
		return HAM_IGNORED;
	if (entity_get_int(bag, EV_INT_iuser4) || damage <= 0.0)
		return HAM_SUPERCEDE;
	new Float:health = entity_get_float(bag, EV_FL_health) - damage;
	entity_set_float(bag, EV_FL_health, floatmax(0.0, health));
	if (health <= 0.0)
	{
		// Remove after the weapon callback unwinds, avoiding a freed edict in
		// the game's remaining damage/penetration code. Hide/disable now.
		entity_set_int(bag, EV_INT_iuser4, 1);
		entity_set_int(bag, EV_INT_solid, SOLID_NOT);
		entity_set_int(bag, EV_INT_effects, EF_NODRAW);
		entity_set_float(bag, EV_FL_takedamage, DAMAGE_NO);
		set_task(0.01, "finish_destroyed_bag", bag);
	}
	SetHamReturnInteger(1);
	return HAM_SUPERCEDE;
}

public finish_destroyed_bag(bag)
{
	if (is_sandbag(bag) && entity_get_int(bag, EV_INT_iuser4))
		remove_sandbag(bag);
}

get_bounds(Float:yaw, Float:mins[3], Float:maxs[3])
{
	new bool:swapped = (floatround(yaw / 90.0) % 2) != 0;
	maxs[0] = swapped ? BAG_HALF_WIDTH : BAG_HALF_LENGTH;
	maxs[1] = swapped ? BAG_HALF_LENGTH : BAG_HALF_WIDTH;
	maxs[2] = BAG_HALF_HEIGHT;
	for (new axis = 0; axis < 3; axis++)
		mins[axis] = -maxs[axis];
}

adjacent_center(bag, axis, Float:sign, Float:yaw, Float:center[3])
{
	new Float:mins[3], Float:maxs[3], Float:neighbor_maxs[3];
	get_bounds(yaw, mins, maxs);
	entity_get_vector(bag, EV_VEC_maxs, neighbor_maxs);
	entity_get_vector(bag, EV_VEC_origin, center);
	center[axis] += sign * (neighbor_maxs[axis] + maxs[axis]);
}

// Nearby floor aiming selects the nearest valid cardinal neighbor. Direct
// side aiming already lands exactly in that slot via the surface trace.
snap_adjacent(ignore, Float:center[3], Float:yaw = 0.0)
{
	new Float:best_distance = 26.0, Float:best[3], Float:candidate[3], Float:origin[3];
	new bool:found;
	new bag = -1;
	while ((bag = find_ent_by_class(bag, SANDBAG_CLASSNAME)) > 0)
	{
		if (entity_get_int(bag, EV_INT_iuser4))
			continue;
		entity_get_vector(bag, EV_VEC_origin, origin);
		if (floatabs(origin[2] - center[2]) > 0.15)
			continue;
		for (new side = 0; side < 4; side++)
		{
			adjacent_center(bag, side / 2, side % 2 ? 1.0 : -1.0, yaw, candidate);
			new Float:distance = get_distance_f(center, candidate);
			if (distance >= best_distance || !has_support(ignore, candidate, yaw) || !space_clear(ignore, candidate, yaw))
				continue;
			found = true;
			best_distance = distance;
			for (new axis = 0; axis < 3; axis++)
				best[axis] = candidate[axis];
		}
	}
	if (found)
		for (new axis = 0; axis < 3; axis++)
			center[axis] = best[axis];
}

public cmd_sandbag_commit(id)
{
	if (id < 1 || id > MAX_PLAYERS || !g_placing[id])
		return PLUGIN_HANDLED;
	if (!can_build(id, true) || !placement_budget(id, true))
	{
		destroy_preview(id);
		return PLUGIN_HANDLED;
	}
	new Float:center[3], Float:yaw;
	new result = PLACE_NO_SURFACE;
	if (is_user_alive(id) && g_enabled[id])
		result = get_sandbag_placement(id, center, yaw);
	destroy_preview(id);
	if (result != PLACE_OK)
	{
		switch (result)
		{
			case PLACE_TOO_FAR: client_print(id, print_center, "%L", id, "SB_TOO_FAR");
			case PLACE_BAD_SURFACE: client_print(id, print_center, "%L", id, "SB_BAD_SURFACE");
			case PLACE_BLOCKED: client_print(id, print_center, "%L", id, "SB_BLOCKED");
			default: client_print(id, print_center, "%L", id, "SB_NO_SURFACE");
		}
		return PLUGIN_HANDLED;
	}
	if (!create_sandbag(center, yaw, id))
		client_print(id, print_chat, "[dod_sandbag] %L", id, "SB_ALLOCATION");
	else
		g_last_placement[id] = get_gametime();
	return PLUGIN_HANDLED;
}

update_preview(id)
{
	if (!is_valid_ent(g_preview[id]))
	{
		g_placing[id] = false;
		g_preview[id] = 0;
		return;
	}
	new Float:center[3], Float:yaw;
	new result = get_sandbag_placement(id, center, yaw);
	if (result == PLACE_OK)
		set_visual_transform(g_preview[id], center, yaw);
	entity_set_float(g_preview[id], EV_FL_renderamt, result == PLACE_OK ? get_pcvar_float(g_alpha_cvar) : 0.0);
}

get_sandbag_placement(id, Float:center[3], &Float:yaw)
{
	new Float:start[3], Float:view_offset[3], Float:angles[3], Float:direction[3], Float:end[3];
	entity_get_vector(id, EV_VEC_origin, start);
	entity_get_vector(id, EV_VEC_view_ofs, view_offset);
	entity_get_vector(id, EV_VEC_v_angle, angles);
	angle_vector(angles, ANGLEVECTOR_FORWARD, direction);
	for (new axis = 0; axis < 3; axis++)
	{
		start[axis] += view_offset[axis];
		end[axis] = start[axis] + direction[axis] * TRACE_DISTANCE;
	}
	// GoldSrc BBOX does not rotate itself: all clearance/support/snap checks
	// use width/length swapped to match the selected quarter-turn model yaw.
	yaw = g_yaw[id];
	new result = trace_placement_surface(id, start, end, center, yaw);
	if (result != PLACE_OK)
		return result;
	new anchor = traceresult(TR_Hit);
	if (!g_rotation_override[id] && is_sandbag(anchor))
	{
		new Float:anchor_angles[3];
		entity_get_vector(anchor, EV_VEC_angles, anchor_angles);
		yaw = g_yaw[id] = anchor_angles[1];
		result = trace_placement_surface(id, start, end, center, yaw);
		if (result != PLACE_OK)
			return result;
	}
	snap_adjacent(id, center, yaw);
	if (get_distance_f(start, center) > get_pcvar_float(g_reach_cvar))
		return PLACE_TOO_FAR;
	if (!has_support(id, center, yaw) || !space_clear(id, center, yaw))
		return PLACE_BLOCKED;
	return PLACE_OK;
}

trace_placement_surface(ignore, const Float:start[3], const Float:end[3], Float:center[3], Float:yaw = 0.0)
{
	new Float:surface[3], Float:normal[3], Float:fraction;
	trace_line(ignore, start, end, surface);
	traceresult(TR_Fraction, fraction);
	if (fraction >= 1.0 || traceresult(TR_StartSolid) || traceresult(TR_AllSolid))
		return PLACE_NO_SURFACE;
	if (get_distance_f(start, surface) > get_pcvar_float(g_reach_cvar))
		return PLACE_TOO_FAR;
	traceresult(TR_PlaneNormal, normal);
	new hit = traceresult(TR_Hit);
	if (normal[2] < 0.98)
	{
		if (!is_sandbag(hit))
			return PLACE_BAD_SURFACE;
		for (new axis = 0; axis < 2; axis++)
		{
			if (floatabs(normal[axis]) < 0.98)
				continue;
			adjacent_center(hit, axis, normal[axis], yaw, center);
			return PLACE_OK;
		}
		return PLACE_BAD_SURFACE;
	}
	if (hit >= 1 && hit <= MAX_PLAYERS)
		return PLACE_BAD_SURFACE;
	for (new axis = 0; axis < 3; axis++)
		center[axis] = surface[axis];
	// GoldSrc traces stop about 1/32 unit before the plane. Snap bag tops to
	// their exact height instead of accumulating trace epsilon in every layer.
	if (is_sandbag(hit))
	{
		new Float:origin[3];
		entity_get_vector(hit, EV_VEC_origin, origin);
		center[0] = origin[0];
		center[1] = origin[1];
		center[2] = origin[2] + BAG_HALF_HEIGHT;
	}
	center[2] += BAG_HALF_HEIGHT;
	return PLACE_OK;
}

bool:has_support(ignore, const Float:center[3], Float:yaw = 0.0)
{
	new Float:start[3], Float:end[3], Float:hit[3], Float:normal[3], Float:fraction;
	new Float:mins[3], Float:maxs[3];
	get_bounds(yaw, mins, maxs);
	// Check the middle and four corners; do not let bags bridge unsupported space.
	for (new sample = 0; sample < 5; sample++)
	{
		start[0] = center[0];
		start[1] = center[1];
		if (sample > 0)
		{
			start[0] += (sample <= 2) ? -(maxs[0] - 4.0) : maxs[0] - 4.0;
			start[1] += (sample % 2) ? -(maxs[1] - 4.0) : maxs[1] - 4.0;
		}
		start[2] = center[2] - BAG_HALF_HEIGHT + 1.0;
		end[0] = start[0];
		end[1] = start[1];
		end[2] = start[2] - 3.0;
		trace_line(ignore, start, end, hit);
		traceresult(TR_Fraction, fraction);
		traceresult(TR_PlaneNormal, normal);
		new entity = traceresult(TR_Hit);
		if (fraction >= 1.0 || traceresult(TR_StartSolid) || normal[2] < 0.98
			|| (entity >= 1 && entity <= MAX_PLAYERS)
			|| floatabs(hit[2] - (center[2] - BAG_HALF_HEIGHT)) > 0.15)
			return false;
	}
	return true;
}

bool:space_clear(ignore, const Float:center[3], Float:yaw = 0.0)
{
	new Float:start[3], Float:end[3], Float:hit[3], Float:fraction;
	new Float:mins[3], Float:maxs[3];
	get_bounds(yaw, mins, maxs);
	// Two horizontal slices cover wall/prop intersections across the footprint.
	for (new layer = 0; layer < 2; layer++)
	{
		for (new sample = 0; sample < 8; sample++)
		{
			start[0] = center[0];
			start[1] = center[1];
			start[2] = center[2] + (layer ? 7.5 : -7.5);
			end[0] = start[0];
			end[1] = start[1];
			if (sample != 2 && sample != 6)
				end[0] += (sample <= 1 || sample == 7) ? maxs[0] : -maxs[0];
			if (sample != 0 && sample != 4)
				end[1] += sample < 4 ? maxs[1] : -maxs[1];
			end[2] = start[2];
			trace_line(ignore, start, end, hit);
			traceresult(TR_Fraction, fraction);
			if ((fraction < 1.0 && get_distance_f(hit, end) > 0.1)
				|| traceresult(TR_StartSolid) || traceresult(TR_AllSolid))
				return false;
		}
	}
	// Explicit overlap checks also reject objects fully contained by the new hull.
	new entity = -1;
	while ((entity = find_ent_by_class(entity, SANDBAG_CLASSNAME)) > 0)
		if (overlaps_entity(center, entity, yaw))
			return false;
	for (new id = 1; id <= MAX_PLAYERS; id++)
		if (is_user_alive(id) && overlaps_entity(center, id, yaw))
			return false;
	return true;
}

bool:overlaps_entity(const Float:center[3], entity, Float:yaw = 0.0)
{
	new Float:origin[3], Float:mins[3], Float:maxs[3];
	entity_get_vector(entity, EV_VEC_origin, origin);
	entity_get_vector(entity, EV_VEC_mins, mins);
	entity_get_vector(entity, EV_VEC_maxs, maxs);
	new Float:own_mins[3], Float:own_maxs[3];
	get_bounds(yaw, own_mins, own_maxs);
	for (new axis = 0; axis < 3; axis++)
		if (center[axis] + own_maxs[axis] <= origin[axis] + mins[axis] + 0.1
			|| center[axis] + own_mins[axis] >= origin[axis] + maxs[axis] - 0.1)
			return false;
	return true;
}

create_visual(const classname[])
{
	new entity = create_entity("info_target");
	if (!entity)
		return 0;
	entity_set_string(entity, EV_SZ_classname, classname);
	entity_set_model(entity, SANDBAG_MODEL);
	entity_set_int(entity, EV_INT_solid, SOLID_NOT);
	entity_set_int(entity, EV_INT_movetype, MOVETYPE_NONE);
	entity_set_float(entity, EV_FL_scale, 1.0);
	entity_set_float(entity, EV_FL_frame, 0.0);
	entity_set_float(entity, EV_FL_framerate, 0.0);
	return entity;
}

create_sandbag(const Float:center[3], Float:yaw, owner = 0)
{
	new bag = create_visual(SANDBAG_CLASSNAME);
	if (!bag)
		return 0;
	new Float:mins[3], Float:maxs[3];
	get_bounds(yaw, mins, maxs);
	entity_set_size(bag, mins, maxs);
	entity_set_int(bag, EV_INT_solid, SOLID_BBOX);
	entity_set_int(bag, EV_INT_movetype, MOVETYPE_PUSHSTEP);
	// PUSHSTEP participates even in IGNORE_MONSTERS traces. FL_FLY prevents
	// gravity; the mesh's base and hitbox already sit exactly on the support.
	entity_set_int(bag, EV_INT_flags, entity_get_int(bag, EV_INT_flags) | FL_FLY);
	entity_set_float(bag, EV_FL_takedamage, DAMAGE_YES);
	entity_set_float(bag, EV_FL_health, floatmax(1.0, get_pcvar_float(g_health_cvar)));
	if (owner >= 1 && owner <= MAX_PLAYERS && is_user_connected(owner))
	{
		entity_set_int(bag, EV_INT_iuser1, get_user_userid(owner));
		new Float:lifetime = get_pcvar_float(g_lifetime_cvar);
		if (lifetime > 0.0)
		{
			entity_set_float(bag, EV_FL_fuser1, get_gametime() + lifetime);
			entity_set_float(bag, EV_FL_nextthink, get_gametime() + lifetime);
		}
	}
	set_visual_transform(bag, center, yaw);
	return bag;
}

set_visual_transform(visual, const Float:center[3], Float:yaw)
{
	new Float:origin[3], Float:angles[3];
	new Float:c = floatcos(yaw, degrees), Float:s = floatsin(yaw, degrees);
	origin[0] = center[0] - (MODEL_CENTER_X * c - MODEL_CENTER_Y * s);
	origin[1] = center[1] - (MODEL_CENTER_X * s + MODEL_CENTER_Y * c);
	origin[2] = center[2] - BAG_HALF_HEIGHT - MODEL_BOTTOM_Z;
	angles[1] = yaw;
	entity_set_vector(visual, EV_VEC_angles, angles);
	new Float:mins[3], Float:maxs[3];
	get_bounds(yaw, mins, maxs);
	entity_set_size(visual, mins, maxs);
	entity_set_origin(visual, origin);
}

bool:is_sandbag(entity)
{
	if (entity <= MAX_PLAYERS || !is_valid_ent(entity))
		return false;
	new classname[32];
	entity_get_string(entity, EV_SZ_classname, classname, charsmax(classname));
	return equal(classname, SANDBAG_CLASSNAME) != 0;
}

count_sandbags()
{
	new count, entity = -1;
	while ((entity = find_ent_by_class(entity, SANDBAG_CLASSNAME)) > 0)
		count++;
	return count;
}

remove_sandbag(bag)
{
	if (bag <= MAX_PLAYERS || !is_valid_ent(bag))
		return;
	remove_task(bag);
	remove_entity(bag);
}

destroy_preview(id)
{
	if (g_preview[id] > 0 && is_valid_ent(g_preview[id]))
		remove_entity(g_preview[id]);
	g_preview[id] = 0;
	g_placing[id] = false;
}

// These tests run against the actual HLDS collision engine, not a math mock.
public cmd_selftest()
{
	for (new id = 1; id <= MAX_PLAYERS; id++)
		if (is_user_connected(id))
		{
			log_amx("dod_sandbag selftest: skipped (run on an empty test server)");
			return PLUGIN_HANDLED;
		}
	if (g_test_bags[0])
		return PLUGIN_HANDLED;
	g_test_checks = 0;
	g_test_failures = 0;
	new original_limit = get_pcvar_num(g_limit_cvar);
	set_pcvar_num(g_limit_cvar, 999);
	test_check(get_pcvar_num(g_limit_cvar) == MAX_SANDBAGS, "configured global quota clamps to hard maximum");
	set_pcvar_num(g_limit_cvar, -10);
	test_check(get_pcvar_num(g_limit_cvar) == 1, "configured global quota clamps to minimum");
	set_pcvar_num(g_limit_cvar, original_limit);
	test_check(parse_access_flags("") == 0, "empty access flags allow public access");
	test_check(parse_access_flags("h") == ADMIN_CFG, "admin access flag parses correctly");
	test_check(parse_access_flags("h!") == -1, "malformed access flags fail closed");
	test_check(balanced_trace_damage(DODW_COLT, 25.0, 0.0) == 25.0, "zero pistol override uses stock damage");
	test_check(balanced_trace_damage(DODW_COLT, 25.0, 60.0) == 60.0, "configured pistol damage applies");
	if (!find_test_position(g_test_center))
	{
		log_amx("dod_sandbag selftest: FAIL (no clear fixture position)");
		return PLUGIN_HANDLED;
	}
	g_test_bags[0] = create_sandbag(g_test_center, 0.0);
	if (!g_test_bags[0])
	{
		log_amx("dod_sandbag selftest: FAIL (fixture allocation)");
		return PLUGIN_HANDLED;
	}
	new Float:start[3], Float:end[3], Float:hit[3], Float:normal[3];
	for (new axis = 0; axis < 3; axis++)
	{
		for (new sign = -1; sign <= 1; sign += 2)
		{
			for (new flag_case = 0; flag_case < 3; flag_case++)
			{
				for (new component = 0; component < 3; component++)
					start[component] = end[component] = g_test_center[component];
				start[axis] += float(sign) * 40.0;
				end[axis] -= float(sign) * 40.0;
				if (flag_case == 0)
					trace_line(-1, start, end, hit);
				else
				{
					trace_hull(start, HULL_POINT, 0, flag_case == 1 ? IGNORE_GLASS : IGNORE_MONSTERS, end);
					traceresult(TR_EndPos, hit);
				}
				traceresult(TR_PlaneNormal, normal);
				test_check(traceresult(TR_Hit) == g_test_bags[0]
					&& floatabs(hit[axis] - (g_test_center[axis] + float(sign) * g_maxs[axis])) < 0.1
					&& normal[axis] * float(sign) > 0.99, "six-face trace/normal with ignore flags");
			}
		}
	}
	for (new side = 0; side < 4; side++)
	{
		for (new axis = 0; axis < 3; axis++)
			start[axis] = end[axis] = g_test_center[axis];
		new axis = side / 2;
		new Float:sign = side % 2 ? 1.0 : -1.0;
		start[axis] += sign * 40.0;
		new Float:neighbor[3];
		test_check(trace_placement_surface(-1, start, end, neighbor) == PLACE_OK
			&& floatabs(neighbor[axis] - g_test_center[axis] - sign * g_maxs[axis] * 2.0) < 0.01
			&& floatabs(neighbor[2] - g_test_center[2]) < 0.01,
			"side aiming selects adjacent bag slot");
	}
	for (new hull = HULL_HUMAN; hull <= HULL_HEAD; hull += 2)
	{
		for (new axis = 0; axis < 3; axis++)
			start[axis] = end[axis] = g_test_center[axis];
		start[0] -= 64.0;
		end[0] += 64.0;
		trace_hull(start, hull, 0, DONT_IGNORE_MONSTERS, end);
		test_check(traceresult(TR_Hit) == g_test_bags[0], "standing/crouched player hull collision");
	}
	for (new axis = 0; axis < 3; axis++)
		start[axis] = end[axis] = g_test_center[axis];
	start[2] += 60.0;
	new Float:stack_center[3];
	test_check(trace_placement_surface(-1, start, end, stack_center) == PLACE_OK
		&& floatabs(stack_center[2] - g_test_center[2] - 16.0) < 0.01,
		"placement on top of first bag");
	test_check(has_support(-1, stack_center), "all five stack support samples");
	test_check(!has_support(-1, stack_center, 90.0), "unsupported crosswise overhang is rejected");
	test_check(space_clear(-1, stack_center), "stack does not overlap supporting bag");
	test_check(!space_clear(-1, g_test_center), "overlapping bag is rejected");
	new Float:floating[3];
	for (new axis = 0; axis < 3; axis++)
		floating[axis] = g_test_center[axis];
	floating[2] += 32.0;
	test_check(!has_support(-1, floating), "unsupported floating placement is rejected");
	start[0] += 12.0;
	start[1] += 8.0;
	end[0] += 12.0;
	end[1] += 8.0;
	test_check(trace_placement_surface(-1, start, end, floating) == PLACE_OK
		&& floatabs(floating[0] - g_test_center[0]) < 0.01
		&& floatabs(floating[1] - g_test_center[1]) < 0.01,
		"off-center aim snaps the next bag to the stack");
	start[0] = end[0] = g_test_center[0];
	start[1] = end[1] = g_test_center[1];
	start[2] = g_test_center[2] - 32.0;
	test_check(trace_placement_surface(-1, start, end, floating) == PLACE_BAD_SURFACE,
		"underside cannot be used as a placement surface");
	start[2] = g_test_center[2] + 60.0;
	g_test_bags[1] = create_sandbag(stack_center, 0.0);
	trace_line(-1, start, end, hit);
	test_check(traceresult(TR_Hit) == g_test_bags[1], "trace hits second bag before first");
	for (new yaw = 0; yaw < 360; yaw += 90)
	{
		new visual = g_test_bags[0];
		set_visual_transform(visual, g_test_center, float(yaw));
		entity_get_vector(visual, EV_VEC_origin, hit);
		test_check(floatabs(hit[2] + MODEL_BOTTOM_Z - (g_test_center[2] - BAG_HALF_HEIGHT)) < 0.01,
			"visual bottom matches physical bottom at all quarter turns");
	}
	set_visual_transform(g_test_bags[0], g_test_center, 0.0);
	new Float:side_base[3], Float:nearby[3];
	for (new axis = 0; axis < 3; axis++)
		side_base[axis] = g_test_center[axis];
	side_base[0] += BAG_HALF_LENGTH * 2.0;
	g_test_bags[2] = create_sandbag(side_base, 0.0);
	for (new axis = 0; axis < 3; axis++)
		nearby[axis] = side_base[axis];
	nearby[2] += 16.0;
	nearby[0] += 8.0;
	nearby[1] += 8.0;
	snap_adjacent(-1, nearby);
	test_check(floatabs(nearby[0] - side_base[0]) < 0.01
		&& floatabs(nearby[1] - side_base[1]) < 0.01,
		"nearby surface aim snaps to supported adjacent slot");
	test_check(has_support(-1, nearby) && space_clear(-1, nearby),
		"adjacent snapped slot has support and does not overlap neighbor");
	// Continue directly from the second base bag: all three centers must stay
	// on one axis, and cardinal hulls must meet edge-to-edge without overlap.
	for (new axis = 0; axis < 3; axis++)
		start[axis] = end[axis] = side_base[axis];
	start[0] += 40.0;
	new Float:third_center[3];
	test_check(trace_placement_surface(-1, start, end, third_center) == PLACE_OK
		&& floatabs(third_center[0] - g_test_center[0] - BAG_HALF_LENGTH * 4.0) < 0.01
		&& floatabs(third_center[1] - g_test_center[1]) < 0.01
		&& floatabs(third_center[2] - g_test_center[2]) < 0.01,
		"side snap extends three bags in a straight line");
	test_check(space_clear(-1, third_center), "third straight-line bag has clearance");
	g_test_bags[3] = create_sandbag(third_center, 0.0);
	test_check(is_sandbag(g_test_bags[3]) && !overlaps_entity(third_center, g_test_bags[2]),
		"straight-line bags meet without hull overlap");
	// Real engine hitboxes, movement boxes and neighbor spacing after rotation.
	for (new yaw = 0; yaw < 360; yaw += 90)
	{
		new Float:mins[3], Float:maxs[3], Float:actual[3];
		get_bounds(float(yaw), mins, maxs);
		set_visual_transform(g_test_bags[3], third_center, float(yaw));
		entity_get_vector(g_test_bags[3], EV_VEC_maxs, actual);
		test_check(get_distance_f(actual, maxs) < 0.01,
			"quarter-turn movement box swaps length and width");
		for (new axis = 0; axis < 3; axis++)
		{
			for (new sign = -1; sign <= 1; sign += 2)
			{
				for (new component = 0; component < 3; component++)
					start[component] = end[component] = third_center[component];
				start[axis] += float(sign) * 40.0;
				trace_line(g_test_bags[2], start, end, hit);
				traceresult(TR_PlaneNormal, normal);
				test_check(traceresult(TR_Hit) == g_test_bags[3]
					&& floatabs(hit[axis] - third_center[axis] - float(sign) * maxs[axis]) < 0.1
					&& normal[axis] * float(sign) > 0.99,
					"rotated rectangular model trace matches movement box");
				if (axis < 2)
				{
					new Float:neighbor[3];
					test_check(trace_placement_surface(g_test_bags[2], start, end, neighbor, float(yaw)) == PLACE_OK
						&& floatabs(neighbor[axis] - third_center[axis] - float(sign) * maxs[axis] * 2.0) < 0.01,
						"rotated neighbor spacing matches rectangular dimensions");
					new Float:mixed[3];
					adjacent_center(g_test_bags[3], axis, float(sign), float(yaw) + 90.0, mixed);
					test_check(floatabs(mixed[axis] - third_center[axis] - float(sign) * (BAG_HALF_LENGTH + BAG_HALF_WIDTH)) < 0.01,
						"mixed orientation neighbors meet at exact edge spacing");
				}
			}
		}
		// The thin-axis gap must be free for both point and player hull traces.
		new thin_axis = (yaw / 90) % 2 ? 0 : 1;
		new long_axis = 1 - thin_axis;
		for (new component = 0; component < 3; component++)
			start[component] = end[component] = third_center[component];
		start[thin_axis] = end[thin_axis] = third_center[thin_axis] + maxs[thin_axis] + 4.0;
		start[long_axis] -= 40.0;
		end[long_axis] += 40.0;
		trace_line(g_test_bags[2], start, end, hit);
		test_check(traceresult(TR_Hit) != g_test_bags[3],
			"no invisible square hitbox beside the narrow side");
	}
	entity_set_int(g_test_bags[2], EV_INT_iuser1, 900001);
	entity_set_int(g_test_bags[3], EV_INT_iuser1, 900001);
	test_check(count_owned_bags(900001) == 2, "owner quota counts only that session's bags");
	test_check(count_owned_bags(900002) == 0, "new user session does not inherit another owner's quota");
	g_test_expiry = create_sandbag(third_center, 0.0);
	if (g_test_expiry)
	{
		entity_set_int(g_test_expiry, EV_INT_solid, SOLID_NOT);
		entity_set_float(g_test_expiry, EV_FL_fuser1, get_gametime() + 0.1);
		entity_set_float(g_test_expiry, EV_FL_nextthink, get_gametime() + 0.1);
	}
	// Verify that several physics frames cannot move/rotate the completed bag.
	set_task(0.5, "finish_selftest");
	return PLUGIN_HANDLED;
}

bool:find_test_position(Float:center[3])
{
	new spawn = -1;
	while ((spawn = find_ent_by_class(spawn, "info_player_allies")) > 0)
	{
		for (new height = 48; height <= 144; height += 48)
		{
			entity_get_vector(spawn, EV_VEC_origin, center);
			center[2] += float(height);
			if (!space_clear(-1, center))
				continue;
			new Float:neighbor[3];
			for (new axis = 0; axis < 3; axis++)
				neighbor[axis] = center[axis];
			neighbor[0] += BAG_HALF_LENGTH * 2.0;
			if (!space_clear(-1, neighbor))
				continue;
			neighbor[0] += BAG_HALF_LENGTH * 2.0;
			if (!space_clear(-1, neighbor))
				continue;
			new Float:start[3], Float:end[3], Float:hit[3], Float:fraction;
			new bool:clear = true;
			for (new axis = 0; axis < 3; axis++)
			{
				for (new component = 0; component < 3; component++)
					start[component] = end[component] = center[component];
				start[axis] -= 40.0;
				end[axis] += 40.0;
				trace_line(-1, start, end, hit);
				traceresult(TR_Fraction, fraction);
				if (fraction < 1.0 || traceresult(TR_StartSolid))
					clear = false;
			}
			if (clear)
				return true;
		}
	}
	return false;
}

test_check(bool:passed, const description[])
{
	g_test_checks++;
	if (!passed)
	{
		g_test_failures++;
		log_amx("dod_sandbag selftest failed: %s", description);
	}
}

public finish_selftest()
{
	test_check(g_test_expiry > 0 && !is_valid_ent(g_test_expiry), "entity expires through its live engine think callback");
	g_test_expiry = 0;
	new Float:origin[3];
	if (is_valid_ent(g_test_bags[0]))
	{
		entity_get_vector(g_test_bags[0], EV_VEC_origin, origin);
		test_check(get_distance_f(origin, g_test_center) < 0.01, "no drift after physics frames");
	}
	else
		test_check(false, "fixture survives physics frames");
	test_check(balanced_trace_damage(DODW_COLT, 12.0) == 40.0
		&& balanced_trace_damage(DODW_LUGER, 25.0) == 40.0
		&& balanced_trace_damage(DODW_WEBLEY, 60.0) == 40.0,
		"all three pistols balance to ten hits at default health");
	test_check(balanced_trace_damage(DODW_GARAND, 100.0) == 100.0,
		"other weapons preserve actual damage");
	new bag = g_test_bags[0];
	if (is_sandbag(bag))
	{
		entity_set_float(bag, EV_FL_health, 400.0);
		new Float:direction[3] = {1.0, 0.0, 0.0};
		new trace = create_tr2();
		for (new shot = 0; shot < 9; shot++)
			ExecuteHamB(Ham_TraceAttack, bag, 0, 40.0, direction, trace, DMG_BULLET);
		test_check(entity_get_float(bag, EV_FL_health) == 40.0
			&& entity_get_int(bag, EV_INT_solid) == SOLID_BBOX,
			"nine 40-damage trace attacks leave bag intact");
		ExecuteHamB(Ham_TraceAttack, bag, 0, 40.0, direction, trace, DMG_BULLET);
		test_check(entity_get_float(bag, EV_FL_health) == 0.0
			&& entity_get_int(bag, EV_INT_solid) == SOLID_NOT,
			"tenth trace attack destroys bag collision");
		free_tr2(trace);
		// The fixture's entity index remains reserved until deferred removal.
		set_task(0.05, "finish_damage_selftest");
		return;
	}
	finish_damage_selftest();
}

public finish_damage_selftest()
{
	test_check(!is_valid_ent(g_test_bags[0]), "destroyed bag edict is removed after damage callback");
	remove_owned_bags(900001);
	test_check(count_owned_bags(900001) == 0 && !is_valid_ent(g_test_bags[2]) && !is_valid_ent(g_test_bags[3]),
		"owner cleanup removes only owned bag fixtures");
	for (new i = 0; i < 4; i++)
	{
		remove_sandbag(g_test_bags[i]);
		g_test_bags[i] = 0;
	}
	log_amx("dod_sandbag selftest: %s (%d checks, %d failures)",
		g_test_failures ? "FAIL" : "PASS", g_test_checks, g_test_failures);
}

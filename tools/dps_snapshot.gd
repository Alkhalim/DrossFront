@tool
extends EditorScript
## One-shot baseline capture for the data-driven balance refactor.
##
## Walks every unit .tres in resources/units/ and writes
## tools/baseline_dps.txt with DPS Gnd / DPS Air per unit, computed
## with the same math as hud.gd:_compute_dps_vs. Re-run after each
## refactor phase and diff against the committed baseline.
##
## Run via Godot Editor: open this file in the script editor,
## then File → Run.

func _run() -> void:
	var dir: DirAccess = DirAccess.open("res://resources/units/")
	if dir == null:
		push_error("can't open res://resources/units/")
		return
	var lines: PackedStringArray = []
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if fname.ends_with(".tres"):
			var stat: UnitStatResource = load("res://resources/units/" + fname) as UnitStatResource
			if stat != null:
				var dps_g: float = _compute_dps_vs(stat, &"medium")
				var dps_a: float = _compute_dps_vs(stat, &"light_air")
				lines.append("%-50s  GND=%7.2f  AIR=%7.2f" % [fname, dps_g, dps_a])
		fname = dir.get_next()
	lines.sort()
	var out: FileAccess = FileAccess.open("res://tools/baseline_dps.txt", FileAccess.WRITE)
	if out == null:
		push_error("can't write res://tools/baseline_dps.txt — does the tools/ dir exist?")
		return
	for line: String in lines:
		out.store_line(line)
		print(line)
	out.close()
	print("Wrote ", lines.size(), " entries to tools/baseline_dps.txt")


func _weapon_dps(weapon: WeaponResource) -> float:
	if not weapon:
		return 0.0
	var dmg: float = float(weapon.resolved_damage())
	var rof: float = weapon.resolved_rof_seconds()
	if rof <= 0.0:
		return 0.0
	var salvo: int = maxi(int(weapon.salvo_count), 1)
	return (dmg * float(salvo)) / rof


func _compute_dps_vs(stat: UnitStatResource, armor_class: StringName) -> float:
	## Mirror of hud.gd:_compute_dps_vs.
	if not stat:
		return 0.0
	var is_air_query: bool = (armor_class == &"light_air" or armor_class == &"heavy_air")
	var dps: float = 0.0
	var weapons: Array[WeaponResource] = []
	if stat.primary_weapon:
		weapons.append(stat.primary_weapon)
	if stat.secondary_weapon:
		weapons.append(stat.secondary_weapon)
	for weapon: WeaponResource in weapons:
		if is_air_query and not weapon.engages_air():
			continue
		var raw: float = _weapon_dps(weapon) * float(stat.squad_size)
		var role_mod: float = weapon.get_role_mult_for(armor_class)
		var armor_red: float = CombatTables.get_armor_reduction(armor_class)
		var air_mult: float = weapon.air_damage_mult if is_air_query else 1.0
		dps += raw * role_mod * (1.0 - armor_red) * air_mult
	if stat.ability_autocast and stat.ability_autocast_damage > 0 and stat.ability_cooldown > 0.0:
		var ab_target: int = stat.ability_autocast_target
		var hits_this_class: bool = (
			ab_target == 2
			or (ab_target == 0 and not is_air_query)
			or (ab_target == 1 and is_air_query)
		)
		if hits_this_class:
			dps += float(stat.ability_autocast_damage) / stat.ability_cooldown
	return dps

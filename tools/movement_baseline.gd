@tool
extends EditorScript
## Run via Godot Editor → File → Run. Lists every ground unit
## .tres in resources/units/ with a MANUAL_RECORD placeholder.
## The user fills in measured seconds by spawning each class in
## scenes/test_arena.tscn, commanding move from one corner to
## the opposite, stopwatching arrival. 6-8 representative units
## is enough.
##
## Output: tools/movement_baseline.txt — used as a regression
## reference for Plan A. Post-migration times should be within
## 2× of baseline on identical scenarios.

const START_POS := Vector3(-40, 0, -40)
const END_POS   := Vector3( 40, 0,  40)

func _run() -> void:
	var dir: DirAccess = DirAccess.open("res://resources/units/")
	if dir == null:
		push_error("can't open resources/units/")
		return
	var lines: PackedStringArray = []
	lines.append("# Drossfront single-squad path-time baseline")
	lines.append("# From (%s) to (%s)" % [START_POS, END_POS])
	lines.append("# Format: unit_name<TAB>time_sec or MANUAL_RECORD")
	lines.append("")
	var entries: PackedStringArray = []
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if fname.ends_with(".tres") and not fname.begins_with("."):
			var stat: Resource = load("res://resources/units/" + fname)
			if stat == null:
				fname = dir.get_next()
				continue
			# Filter: only ground units. The schema may not have
			# is_aircraft yet (added in PA-21); fall back on a
			# filename heuristic for known aircraft families.
			var is_aircraft: bool = false
			if "is_aircraft" in stat:
				is_aircraft = stat.is_aircraft
			else:
				for prefix in ["anvil_hammerhead", "anvil_phalanx",
							   "sable_switchblade", "sable_wraith"]:
					if fname.begins_with(prefix):
						is_aircraft = true
						break
			if not is_aircraft:
				entries.append("%s\tMANUAL_RECORD" % fname.get_basename())
		fname = dir.get_next()
	entries.sort()
	lines.append_array(entries)
	var f: FileAccess = FileAccess.open("res://tools/movement_baseline.txt", FileAccess.WRITE)
	f.store_string("\n".join(lines))
	f.close()
	print("Wrote tools/movement_baseline.txt with %d entries — fill MANUAL_RECORD by stopwatching." % entries.size())

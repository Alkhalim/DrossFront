class_name AudioManager
extends Node
## Generates and plays simple procedural sound effects for prototyping.
## Industrial/mechanical tone — low frequencies, clicks, metallic.
##
## Sounds are layered: a "shot" is a filtered-noise crack plus a low body thump,
## an "explosion" is a three-stage crack → mid-rumble → low decay tail.

var _players: Array[AudioStreamPlayer] = []
## Separate 3D pool for sounds that should fade with distance from the
## camera (weapon fire, impacts, deaths, building placement). UI sounds
## (select / command / error) stay on the 2D pool so they're always
## crisp regardless of where the camera is looking.
var _players_3d: Array[AudioStreamPlayer3D] = []

## Pre-loaded sample banks. Real recorded sound effects replace the
## procedural-tone generators for the events where a recorded sample
## reads better (combat fire, impacts, deaths). The procedural
## generators stay for UI / production / alert noises that don't have
## a matched recording.
var _sfx_machine_gun: Array[AudioStream] = []
var _sfx_cannon: Array[AudioStream] = []
var _sfx_artillery: Array[AudioStream] = []
var _sfx_laser: Array[AudioStream] = []
var _sfx_plasma: Array[AudioStream] = []
var _sfx_explosion: Array[AudioStream] = []
## Missile-launch bank — used for any weapon whose rof_tier produces a
## missile projectile (single / slow / volley).
var _sfx_missile_launch: Array[AudioStream] = []
## Heavier explosion bank for full unit deaths — beefier than the
## generic explosion used for bullet impacts.
var _sfx_explosion_large: Array[AudioStream] = []
## Catastrophic explosion bank — ammo dumps, HQ destruction.
var _sfx_explosion_huge: Array[AudioStream] = []
## Crumbling masonry / steel — when a building is destroyed.
var _sfx_building_collapse: Array[AudioStream] = []
## Defeat stinger — match-end loss.
var _sfx_defeat: Array[AudioStream] = []
## Error / invalid-command bank.
var _sfx_error: Array[AudioStream] = []
## UI confirm — replaces the procedural beep on select / command issue.
var _sfx_confirm: Array[AudioStream] = []

## --- Voicelines -----------------------------------------------------------
## Per-faction commander VO. Nested as (faction_id, category) → bank.
## faction_id: 0 = Anvil, 1 = Sable. Category strings:
##   "select", "move", "attack", "attacked", "build"
## Voicelines route through a SINGLE dedicated player so commands
## issued during an active line are ignored rather than stacking up
## five overlapping voices.
var _voicelines: Dictionary = {}
## Two voiceline channels — `_vl_player` for routine commands
## (select/move/attack/build) which step on each other if spammed,
## and `_vl_attacked` for the rare "we're under fire" stinger which
## has its own player so a fast string of move commands doesn't
## block the alert.
var _vl_player: AudioStreamPlayer = null
var _vl_attacked: AudioStreamPlayer = null
## Dedicated audio bus for voicelines so we can apply the radio /
## bandpass effect once and route every commander line through it.
var _vl_bus_idx: int = -1
const VL_BUS_NAME: String = "Voiceline"
## Hard cooldown for the "attacked" voiceline — fires at most once
## every COOLDOWN_ATTACKED_SEC seconds regardless of source.
const COOLDOWN_ATTACKED_SEC: float = 30.0
var _attacked_next_at_msec: int = 0
## When set to a non-INF position, the next batch of `_play_tone` /
## `_play_thump` / etc. internal calls route to a 3D player at that
## position instead of the 2D pool. Public "play X at" methods stash
## the world position in here before invoking the existing layered
## sound recipes, so we don't have to thread the position through every
## helper signature.
var _spatial_pos: Vector3 = Vector3.INF
const POOL_SIZE: int = 16
const SAMPLE_RATE: int = 22050
## How loud a sound is at the listener relative to its source — units of
## meters in Godot's 3D audio model. The RTS camera arm is ~30u above
## the ground, so even an event directly under the camera is 30u away
## from the listener. `unit_size` is set well above the camera height
## so on-screen action plays at near-full volume; falloff still kicks
## in for off-screen events at the larger ranges.
const POSITIONAL_UNIT_SIZE: float = 36.0
const POSITIONAL_MAX_DISTANCE: float = 130.0


func _ready() -> void:
	for i: int in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = "Master"
		add_child(player)
		_players.append(player)

		var p3d := AudioStreamPlayer3D.new()
		p3d.bus = "Master"
		p3d.unit_size = POSITIONAL_UNIT_SIZE
		p3d.max_distance = POSITIONAL_MAX_DISTANCE
		p3d.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p3d)
		_players_3d.append(p3d)

	_load_sfx_banks()


func _load_sfx_banks() -> void:
	## Load every recorded sample once at startup. Each bank holds 1-4
	## variants; play_X picks one at random so back-to-back fires don't
	## sound copy-pasted.
	_sfx_machine_gun = _load_bank([
		"res://assets/audio/Machine Gun, Rts Sfx.mp3",
		"res://assets/audio/Machine Gun, Rts Sfx (1).mp3",
	])
	_sfx_cannon = _load_bank([
		"res://assets/audio/Cannon, Rts Sfx.mp3",
	])
	_sfx_artillery = _load_bank([
		"res://assets/audio/Artillery Gun, Rts Sfx.mp3",
		"res://assets/audio/Artillery Gun, Rts Sfx (1).mp3",
		"res://assets/audio/Artillery Gun, Rts Sfx (2).mp3",
		"res://assets/audio/Artillery Gun, Rts Sfx (3).mp3",
	])
	_sfx_laser = _load_bank([
		"res://assets/audio/Laser Gun, Rts Sfx.mp3",
		"res://assets/audio/Laser Gun, Rts Sfx (1).mp3",
	])
	_sfx_plasma = _load_bank([
		"res://assets/audio/Plasma Gun, Rts Sfx.mp3",
	])
	_sfx_explosion = _load_bank([
		"res://assets/audio/Explosion, Rts Sfx.mp3",
		"res://assets/audio/Explosion, Rts Sfx (1).mp3",
		"res://assets/audio/Explosion, Rts Sfx (2).mp3",
		"res://assets/audio/Explosion, Rts Sfx (3).mp3",
	])
	_sfx_missile_launch = _load_bank([
		"res://assets/audio/Missile Launch.mp3",
		"res://assets/audio/Missile Launch (1).mp3",
		"res://assets/audio/Missile Launch (2).mp3",
		"res://assets/audio/Missile Launch (3).mp3",
		"res://assets/audio/Missile Launch (4).mp3",
		"res://assets/audio/Missile Launch (5).mp3",
	])
	_sfx_explosion_large = _load_bank([
		"res://assets/audio/Explosion large.mp3",
		"res://assets/audio/Explosion large (2).mp3",
		"res://assets/audio/Explosion large (3).mp3",
	])
	_sfx_explosion_huge = _load_bank([
		"res://assets/audio/Huge Explosion.mp3",
		"res://assets/audio/Huge Explosion (1).mp3",
		"res://assets/audio/Huge Explosion (2).mp3",
		"res://assets/audio/Huge Explosion (3).mp3",
	])
	_sfx_building_collapse = _load_bank([
		"res://assets/audio/Building Collapse.mp3",
		"res://assets/audio/Building Collapse (1).mp3",
		"res://assets/audio/Building Collapse (2).mp3",
	])
	_sfx_defeat = _load_bank([
		"res://assets/audio/Defeat Sound.mp3",
		"res://assets/audio/Sad Defeat.mp3",
	])
	_sfx_error = _load_bank([
		"res://assets/audio/Error Sfx.mp3",
	])
	_sfx_confirm = _load_bank([
		"res://assets/audio/Confirm UI Sfx Low.mp3",
		"res://assets/audio/Confirm UI Sfx Low (1).mp3",
	])
	_load_voicelines()


func _load_voicelines() -> void:
	## Anvil + Sable voiceline banks. Folder layout under
	## res://assets/audio/Voicelines/<Faction>/<Faction> <Category> N.mp3.
	## Each (faction, category) holds 4-6 variants; play_voice picks
	## one at random so commanders don't repeat the same line back-to-back.
	for faction_pair: Array in [[0, "Anvil"], [1, "Sable"]]:
		var fid: int = faction_pair[0] as int
		var fname: String = faction_pair[1] as String
		_voicelines[fid] = {}
		var f: Dictionary = _voicelines[fid] as Dictionary
		f["select"] = _load_voiceline_bank(fname, "Select", 6)
		f["move"] = _load_voiceline_bank(fname, "Move", 4)
		f["attack"] = _load_voiceline_bank(fname, "Attack", 4)
		f["attacked"] = _load_voiceline_bank(fname, "Attacked", 4)
		f["build"] = _load_voiceline_bank(fname, "Build", 4)
	# Set up a dedicated voiceline bus with a radio-style filter chain
	# so every commander line shares the in-world handheld-radio
	# feel. Done once at startup; players route to it.
	_setup_voiceline_bus()
	# Two players — routine commands and the dedicated "attacked"
	# stinger. Both go through the radio bus.
	_vl_player = AudioStreamPlayer.new()
	_vl_player.bus = VL_BUS_NAME if _vl_bus_idx >= 0 else "Master"
	add_child(_vl_player)
	_vl_attacked = AudioStreamPlayer.new()
	_vl_attacked.bus = VL_BUS_NAME if _vl_bus_idx >= 0 else "Master"
	add_child(_vl_attacked)


func _setup_voiceline_bus() -> void:
	## Adds a "Voiceline" audio bus (if missing) and stacks effects on
	## it: bandpass to cut sub and air frequencies (handheld-radio
	## bandwidth), gentle distortion to add tube crunch, and a touch of
	## reverb for the sense of being heard from inside a vehicle. Bus
	## volume is pulled down so commander VO sits under the gameplay
	## SFX rather than overpowering it.
	if AudioServer.get_bus_index(VL_BUS_NAME) >= 0:
		_vl_bus_idx = AudioServer.get_bus_index(VL_BUS_NAME)
		return
	var idx: int = AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, VL_BUS_NAME)
	AudioServer.set_bus_send(idx, "Master")
	# Bandpass — narrowed to roughly 400-2400Hz, simulating a field
	# radio's restricted bandwidth. Higher resonance (1.4) gives the
	# nasal mid-range honk characteristic of squad radios.
	var bp := AudioEffectBandPassFilter.new()
	bp.cutoff_hz = 1100.0
	bp.resonance = 1.4
	AudioServer.add_bus_effect(idx, bp)
	# Heavy distortion — bitcrush mode gives the digital crunch /
	# clipping edge of compressed radio audio. Drive bumped from the
	# previous gentle overdrive so the VO actually sounds processed
	# rather than just slightly filtered.
	var dist := AudioEffectDistortion.new()
	dist.mode = AudioEffectDistortion.MODE_LOFI
	dist.drive = 0.55
	dist.post_gain = -4.0
	AudioServer.add_bus_effect(idx, dist)
	# (Reverb removed — earlier "small room" tail muddied the line.
	# Field radios don't have that kind of space; they're tight, dry,
	# and crunchy.)
	# Subtle chorus for radio-static modulation — fills the dryness
	# without adding spatial reverb tail.
	var chorus := AudioEffectChorus.new()
	chorus.wet = 0.20
	chorus.dry = 0.85
	if chorus.voice_count > 0:
		chorus.set_voice_depth_ms(0, 1.2)
		chorus.set_voice_rate_hz(0, 0.7)
		chorus.set_voice_level_db(0, -6.0)
	AudioServer.add_bus_effect(idx, chorus)
	# Bus level — pulled back from the previous -8 dB so voicelines
	# are clearly audible. The crunchy bandpass + lofi distortion
	# already keep them mixed-feeling against the dry combat SFX.
	AudioServer.set_bus_volume_db(idx, -2.0)
	_vl_bus_idx = idx


func _load_voiceline_bank(faction: String, category: String, max_idx: int) -> Array[AudioStream]:
	var bank: Array[AudioStream] = []
	for i: int in range(1, max_idx + 1):
		var path: String = "res://assets/audio/Voicelines/%s/%s %s %d.mp3" % [faction, faction, category, i]
		var stream: AudioStream = load(path) as AudioStream
		if stream:
			bank.append(stream)
	return bank


func _load_bank(paths: Array) -> Array[AudioStream]:
	var bank: Array[AudioStream] = []
	for p: Variant in paths:
		var stream: AudioStream = load(p as String) as AudioStream
		if stream:
			bank.append(stream)
	return bank


func _pick(bank: Array[AudioStream]) -> AudioStream:
	if bank.is_empty():
		return null
	return bank[randi() % bank.size()]


func _get_free_player() -> AudioStreamPlayer:
	for player: AudioStreamPlayer in _players:
		if not player.playing:
			return player
	return _players[0]


func _get_free_player_3d() -> AudioStreamPlayer3D:
	for player: AudioStreamPlayer3D in _players_3d:
		if not player.playing:
			return player
	return _players_3d[0]


## --- Positional playback ---
##
## Each "play X at" wrapper generates the same procedural stream the 2D
## variant uses, then plays it on a 3D player parented at `world_pos`.
## Off-screen events fall off naturally; on-screen ones come through.

func _play_3d_at(stream: AudioStream, world_pos: Vector3, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	var player := _get_free_player_3d()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch
	player.global_position = world_pos
	player.play()


## --- Public API ---

## All public sounds layer 2-4 generators per call AND randomize every input
## (frequency, duration, filter cutoff, volume) so back-to-back triggers
## never produce identical samples. Each generator goes to a separate
## AudioStreamPlayer so layers actually mix instead of stomping each other.

func play_command() -> void:
	# Recorded confirm sample — pitched UP slightly so command-issue
	# reads brighter than select. Falls back to procedural beep if no
	# bank loaded.
	var stream: AudioStream = _pick(_sfx_confirm)
	if stream:
		var pitch: float = randf_range(1.05, 1.20)
		_emit(stream, randf_range(-8.0, -5.0), pitch)
		return
	var pitch_proc: float = randf_range(255.0, 320.0)
	_play_tone(pitch_proc, randf_range(0.05, 0.07), randf_range(-12.0, -9.0), randf_range(1.0, 2.5))
	_play_tone(pitch_proc * 0.45, randf_range(0.04, 0.06), randf_range(-15.0, -12.0))

func play_select() -> void:
	# Same recorded confirm bank as command, but pitched DOWN so the
	# two read distinctly — selection feels lower and softer than
	# issuing an order.
	var stream: AudioStream = _pick(_sfx_confirm)
	if stream:
		var pitch: float = randf_range(0.85, 0.95)
		_emit(stream, randf_range(-12.0, -9.0), pitch)
		return
	var freq: float = randf_range(360.0, 460.0)
	_play_tone(freq, randf_range(0.035, 0.05), randf_range(-15.0, -12.0))
	if randf() < 0.6:
		_play_tone(freq * randf_range(1.45, 1.55), randf_range(0.03, 0.045), randf_range(-19.0, -16.0))

func play_building_placed(at: Vector3 = Vector3.INF) -> void:
	# Heavy industrial thud — pitched-down body + dirt-noise crack +
	# low rumble tail.
	_spatial_pos = at
	_play_thump(randf_range(60.0, 82.0), randf_range(0.2, 0.26), randf_range(-5.0, -3.0))
	_play_filtered_noise(randf_range(0.16, 0.22), randf_range(1500.0, 2200.0), randf_range(-12.0, -8.0))
	_play_filtered_noise(randf_range(0.28, 0.4), randf_range(450.0, 700.0), randf_range(-14.0, -10.0))
	_spatial_pos = Vector3.INF

func play_production_started(at: Vector3 = Vector3.INF) -> void:
	# Mechanical clunk: noise burst + low click + small high tick.
	_spatial_pos = at
	_play_filtered_noise(randf_range(0.05, 0.08), randf_range(2000.0, 2800.0), randf_range(-12.0, -8.0))
	_play_tone(randf_range(140.0, 175.0), randf_range(0.04, 0.06), randf_range(-16.0, -12.0), randf_range(1.5, 3.0))
	if randf() < 0.5:
		_play_tone(randf_range(420.0, 520.0), 0.03, -19.0)
	_spatial_pos = Vector3.INF

func play_production_complete(at: Vector3 = Vector3.INF) -> void:
	# Rising two-tone chime with a small noise puff for breath.
	_spatial_pos = at
	var base: float = randf_range(360.0, 410.0)
	_play_two_tone(base, base * randf_range(1.32, 1.42), randf_range(0.09, 0.12), randf_range(-9.0, -6.0))
	_play_filtered_noise(randf_range(0.04, 0.06), 3500.0, -18.0)
	_spatial_pos = Vector3.INF

func play_construction_complete(at: Vector3 = Vector3.INF) -> void:
	# Heavier completion tone — lower fundamental + a thump tail.
	_spatial_pos = at
	var base: float = randf_range(245.0, 285.0)
	_play_two_tone(base, base * randf_range(1.45, 1.6), randf_range(0.13, 0.18), randf_range(-7.0, -5.0))
	_play_thump(randf_range(80.0, 105.0), randf_range(0.18, 0.24), -10.0)
	_spatial_pos = Vector3.INF

func play_error() -> void:
	# Recorded error stinger when the bank is loaded; falls back to
	# the layered procedural buzz otherwise. Pitch jitter even on a
	# single-variant bank so repeated rejected commands don't sound
	# identical.
	var stream: AudioStream = _pick(_sfx_error)
	if stream:
		var pitch: float = randf_range(0.92, 1.08)
		_emit(stream, randf_range(-7.0, -5.0), pitch)
		return
	_play_tone(randf_range(70.0, 82.0), randf_range(0.22, 0.28), -6.0, randf_range(-2.0, 2.0))
	_play_filtered_noise(0.18, 800.0, -16.0)


func play_huge_explosion(at: Vector3 = Vector3.INF) -> void:
	## Catastrophic detonation — ammo dump or HQ destruction. Bigger
	## sample + louder + slight pitch jitter so back-to-back booms
	## (e.g. chain detonation) don't sound copy-pasted.
	var stream: AudioStream = _pick(_sfx_explosion_huge)
	if stream:
		var pitch: float = randf_range(0.88, 1.08)
		_spatial_pos = at
		_emit(stream, randf_range(-1.0, 2.0), pitch)
		_spatial_pos = Vector3.INF
		return
	# Fall back to the standard unit-destroyed bank if the huge bank
	# isn't loaded — better than silence.
	play_unit_destroyed(at)


func play_building_collapse(at: Vector3 = Vector3.INF) -> void:
	## Crumbling masonry / steel — distinct from the unit-death
	## explosion so the player can hear "a building went down" vs
	## "another squad died."
	var stream: AudioStream = _pick(_sfx_building_collapse)
	if stream:
		var pitch: float = randf_range(0.92, 1.05)
		_spatial_pos = at
		_emit(stream, randf_range(-4.0, -1.0), pitch)
		_spatial_pos = Vector3.INF
		return
	# Fall back to large explosion if no collapse bank is loaded.
	if not _sfx_explosion_large.is_empty():
		var alt: AudioStream = _pick(_sfx_explosion_large)
		_spatial_pos = at
		_emit(alt, randf_range(-3.0, 0.0), randf_range(0.85, 1.0))
		_spatial_pos = Vector3.INF


func play_defeat() -> void:
	## Match-end loss stinger — UI-level (not spatial). Two variants
	## random-pick so repeated playthroughs don't always hear the same
	## one.
	var stream: AudioStream = _pick(_sfx_defeat)
	if stream:
		# Light pitch jitter so the "Defeat Sound" / "Sad Defeat"
		# choice plus a slight pitch shift gives 4-5 distinct flavours
		# across runs.
		var pitch: float = randf_range(0.96, 1.04)
		_emit(stream, randf_range(-2.0, 1.0), pitch)


func play_alert(severity: int = 0) -> void:
	# Two-pulse warning chirp — higher and brighter for criticals so the
	# player can read the urgency without looking at the HUD. Severity 0
	# (info) is a single soft beep; 1 (warning) double-pulses; 2 (critical)
	# triple-pulses with a low body thump for weight.
	var pitch: float = lerp(420.0, 620.0, clampf(float(severity) / 2.0, 0.0, 1.0))
	var pulse_db: float = lerp(-12.0, -7.0, clampf(float(severity) / 2.0, 0.0, 1.0))
	var pulse_count: int = clampi(severity + 1, 1, 3)
	for i: int in pulse_count:
		_play_tone(pitch + randf_range(-15.0, 15.0), 0.07, pulse_db)
		_play_tone(pitch * 1.5 + randf_range(-15.0, 15.0), 0.05, pulse_db - 4.0)
	if severity >= 2:
		_play_thump(randf_range(85.0, 110.0), 0.18, -9.0)

func play_weapon_fire(weapon: WeaponResource = null, at: Vector3 = Vector3.INF) -> void:
	## Pick a recorded sample matching the weapon's character. Falls back
	## to the original procedural recipe (`_play_weapon_fire_inner`) if
	## no SFX banks loaded — keeps the prototype usable without the
	## `assets/audio/` folder present.
	var stream: AudioStream = _pick_weapon_fire_stream(weapon)
	if stream:
		# Volume offset roughly tracks weapon weight so heavy artillery
		# is louder than a Ratchet pistol crack. Tuned by ear within
		# the recorded samples' loudness range.
		var weight: float = _weapon_weight(weapon)
		var volume_db: float = lerp(-10.0, -3.0, weight) + randf_range(-2.0, 1.0)
		# Pitch jitter — heavier weapons get tighter range so they
		# stay recognizably "heavy"; lighter rapid weapons swing wider
		# so a continuous burst sounds varied.
		var pitch_spread: float = lerp(0.18, 0.07, weight)
		var pitch: float = 1.0 + randf_range(-pitch_spread, pitch_spread)
		_spatial_pos = at
		_emit(stream, volume_db, pitch)
		_spatial_pos = Vector3.INF
		return
	_spatial_pos = at
	_play_weapon_fire_inner(weapon)
	_spatial_pos = Vector3.INF


func _pick_weapon_fire_stream(weapon: WeaponResource) -> AudioStream:
	## Maps weapon characteristics to a recorded bank:
	## - Continuous-RoF or AA → laser (zippy energy weapons read here).
	## - Heavy + slow / single → artillery (Bulwark cannon).
	## - High-damage moderate → cannon (Hound autocannons / Tracker
	##   long guns).
	## - Rapid + AP → machine gun (Rook bursts, Ratchet pistols).
	## - Plasma kept available as a "weird energy" option for future
	##   weapons; not currently used by any base unit.
	if not weapon:
		return _pick(_sfx_machine_gun)
	var weight: float = _weapon_weight(weapon)
	var rapid: float = _weapon_rapid_factor(weapon)
	var role: StringName = weapon.role_tag
	# Missile-tier weapons (single/slow/volley) launch visible missile
	# projectiles — give them the missile-launch bank so the audio
	# matches the visual. Checked first so it overrides the
	# weight/role-based routing below.
	var rof: StringName = weapon.rof_tier
	if (rof == &"single" or rof == &"slow" or rof == &"volley") and not _sfx_missile_launch.is_empty():
		return _pick(_sfx_missile_launch)
	if role == &"AA" or rof == &"continuous":
		return _pick(_sfx_laser)
	if weight >= 0.7 and rapid < 0.3:
		return _pick(_sfx_artillery)
	if weight >= 0.55:
		return _pick(_sfx_cannon)
	if rapid >= 0.55:
		return _pick(_sfx_machine_gun)
	# Mid-weight, moderate-RoF default — cannon reads as "decent
	# punch but not artillery" which fits Hound autocannons.
	return _pick(_sfx_cannon)


func _play_weapon_fire_inner(weapon: WeaponResource = null) -> void:
	## Layered crack tuned by the weapon's damage / ROF / role:
	## - Heavier weapons (high+ damage tier) drop the body pitch and bump
	##   the volume so they read as deep booms.
	## - Faster ROF tiers shorten layers so rapid fire stays legible.
	## - AA weapons get a brighter, higher-frequency crack; AP weapons get
	##   a punchier mid-range; everything else lands somewhere in between.
	var weight: float = _weapon_weight(weapon)            # 0 = light, 1 = heavy
	var rapid: float = _weapon_rapid_factor(weapon)       # 0 = slow, 1 = rapid
	var role: StringName = weapon.role_tag if weapon else &"Universal"

	# Body pitch: lower for heavier weapons. ~250 Hz for light, ~120 Hz for
	# heavy artillery.
	var base_pitch: float = lerp(255.0, 130.0, weight)
	var pitch: float = base_pitch + randf_range(-25.0, 25.0)
	var body_db: float = lerp(-15.0, -7.0, weight)
	var body_dur: float = lerp(0.08, 0.18, weight) * randf_range(0.85, 1.15)
	# Rapid weapons shorten the body so layers don't muddy at high RoF.
	body_dur = lerp(body_dur, body_dur * 0.55, rapid)

	# HF crack — cutoff varies by role, duration by RoF.
	var crack_cutoff: float
	match role:
		&"AA":
			crack_cutoff = randf_range(6500.0, 9000.0)   # zippy
		&"AP":
			crack_cutoff = randf_range(3500.0, 5000.0)   # punchy
		_:
			crack_cutoff = randf_range(4500.0, 6500.0)
	var crack_dur: float = lerp(0.06, 0.03, rapid) * randf_range(0.85, 1.15)
	var crack_db: float = lerp(-13.0, -8.0, weight)

	_play_filtered_noise(crack_dur, crack_cutoff, crack_db)
	_play_thump(pitch * 0.5, body_dur, body_db)

	# Sizzle / shell-case extras — more likely on rapid weapons for grit.
	var sizzle_chance: float = lerp(0.4, 0.75, rapid)
	if randf() < sizzle_chance:
		_play_filtered_noise(randf_range(0.025, 0.05), randf_range(7000.0, 9500.0), randf_range(-22.0, -17.0))
	if randf() < 0.25:
		_play_tone(randf_range(900.0, 1300.0), 0.02, -22.0)

	# Heavy artillery gets a low rumble tail.
	if weight > 0.65:
		_play_filtered_noise(randf_range(0.18, 0.32), randf_range(550.0, 800.0), -12.0)


func _weapon_weight(weapon: WeaponResource) -> float:
	if not weapon:
		return 0.4
	# Map damage_tier strings to a 0..1 "heaviness" factor.
	match weapon.damage_tier:
		&"very_low": return 0.05
		&"low": return 0.2
		&"moderate": return 0.4
		&"high": return 0.65
		&"very_high": return 0.85
		&"extreme": return 1.0
		_: return 0.4


func _weapon_rapid_factor(weapon: WeaponResource) -> float:
	if not weapon:
		return 0.3
	# Map rof_tier to a 0..1 "rapidness" factor (1 = continuous).
	match weapon.rof_tier:
		&"single": return 0.0
		&"slow": return 0.15
		&"moderate": return 0.35
		&"fast": return 0.6
		&"rapid": return 0.85
		&"volley": return 0.9
		&"continuous": return 1.0
		_: return 0.4

func play_weapon_impact(at: Vector3 = Vector3.INF) -> void:
	# Smaller-scale recorded explosion as a metallic clang substitute,
	# played quietly so it's a brief tick rather than a full boom.
	# Falls back to the procedural metallic-clang recipe if no bank.
	var stream: AudioStream = _pick(_sfx_explosion)
	if stream:
		# Pitched UP for impacts so the same explosion bank reads as
		# a quick clang rather than a full boom.
		var pitch: float = randf_range(1.6, 2.0)
		_spatial_pos = at
		_emit(stream, -16.0 + randf_range(-2.0, 1.0), pitch)
		_spatial_pos = Vector3.INF
		return
	_spatial_pos = at
	var legacy_pitch: float = randf_range(100.0, 165.0)
	_play_filtered_noise(randf_range(0.03, 0.05), randf_range(2800.0, 3800.0), randf_range(-18.0, -14.0))
	_play_tone(legacy_pitch, randf_range(0.06, 0.09), randf_range(-15.0, -12.0), randf_range(3.0, 8.0))
	if randf() < 0.4:
		_play_thump(legacy_pitch * 0.5, 0.08, -16.0)
	_spatial_pos = Vector3.INF


func play_unit_destroyed(at: Vector3 = Vector3.INF, heavy: bool = false) -> void:
	## Picks from the LARGE explosion bank for heavy units (Bulwarks,
	## Harbingers, gunships), the standard bank for everything else.
	## Combined with the per-call pitch jitter the player gets ~7
	## distinct death sounds across the two banks instead of looping
	## through 4. `heavy` is opt-in — Unit calls it from `_die` based
	## on its unit_class.
	var bank: Array[AudioStream] = _sfx_explosion
	if heavy and not _sfx_explosion_large.is_empty():
		bank = _sfx_explosion_large
	var stream: AudioStream = _pick(bank)
	if stream:
		# Slight pitch-down so unit-deaths read heavier than impacts
		# (which used the same bank pitched up).
		var pitch: float = randf_range(0.85, 1.05)
		_spatial_pos = at
		var vol_db: float = -3.0 + randf_range(-1.0, 1.0)
		# Heavy explosions get a touch more volume and a wider pitch
		# range so they feel weightier.
		if heavy:
			vol_db += 1.5
			pitch = randf_range(0.80, 1.0)
		_emit(stream, vol_db, pitch)
		_spatial_pos = Vector3.INF
		return
	_spatial_pos = at
	_play_filtered_noise(randf_range(0.06, 0.1), randf_range(4200.0, 5800.0), randf_range(-5.0, -2.0))
	_play_thump(randf_range(45.0, 65.0), randf_range(0.35, 0.5), randf_range(-5.0, -3.0))
	_play_filtered_noise(randf_range(0.45, 0.7), randf_range(550.0, 850.0), randf_range(-10.0, -7.0))
	if randf() < 0.6:
		_play_filtered_noise(randf_range(0.1, 0.18), randf_range(1400.0, 2200.0), -10.0)
	_spatial_pos = Vector3.INF

## --- Voiceline API --------------------------------------------------------

func play_voice_select() -> void:
	_play_voiceline("select")


func play_voice_move() -> void:
	_play_voiceline("move")


func play_voice_attack() -> void:
	_play_voiceline("attack")


func play_voice_attacked() -> void:
	## Goes through the dedicated `_vl_attacked` player (separate from
	## the routine-command channel) so a player rapid-firing move
	## orders doesn't block the under-attack alert. Hard 30-second
	## cooldown so sustained battles don't loop the line.
	if not _vl_attacked:
		return
	if _vl_attacked.playing:
		return
	var now_msec: int = Time.get_ticks_msec()
	if now_msec < _attacked_next_at_msec:
		return
	var fid: int = _player_faction_id()
	if not _voicelines.has(fid):
		return
	var bank: Array = _voicelines[fid].get("attacked", []) as Array
	if bank.is_empty():
		return
	var stream: AudioStream = bank[randi() % bank.size()] as AudioStream
	if not stream:
		return
	_vl_attacked.stream = stream
	_vl_attacked.volume_db = 0.0
	_vl_attacked.pitch_scale = 1.0
	# Same radio crackle treatment as the routine voicelines — the
	# attacked stinger should still feel like it's coming through
	# the squad radio.
	_play_radio_crackle("on")
	_vl_attacked.play()
	if not _vl_attacked.finished.is_connected(_on_voiceline_finished):
		_vl_attacked.finished.connect(_on_voiceline_finished, CONNECT_ONE_SHOT)
	_attacked_next_at_msec = now_msec + int(COOLDOWN_ATTACKED_SEC * 1000.0)


## --- Radio crackle generator -----------------------------------------------

## Pool of dedicated players for the crackle bursts so they don't
## stomp the main voiceline channel and can overlap briefly at the
## tuning-in / tuning-out boundary.
var _crackle_players: Array[AudioStreamPlayer] = []
const _CRACKLE_POOL_SIZE: int = 4


func _play_radio_crackle(kind: String) -> void:
	## Generates a short procedural noise burst that gets shaped by the
	## same Voiceline bus (bandpass + lofi distortion + chorus), so it
	## comes out sounding like a real radio click + static spit. `kind`
	## controls envelope shape:
	##   "on"  — quick rising click + 50ms static tail
	##   "off" — short snap as the carrier drops
	## Both run through the radio bus so the output character matches
	## the VO they bracket.
	if _vl_bus_idx < 0:
		return
	# Lazy-init the crackle player pool.
	if _crackle_players.is_empty():
		for i: int in _CRACKLE_POOL_SIZE:
			var p := AudioStreamPlayer.new()
			p.bus = VL_BUS_NAME
			add_child(p)
			_crackle_players.append(p)
	var player: AudioStreamPlayer = null
	for cp: AudioStreamPlayer in _crackle_players:
		if not cp.playing:
			player = cp
			break
	if not player:
		return
	var stream: AudioStreamWAV = _generate_radio_crackle(kind)
	player.stream = stream
	# Bus already gets the bandpass+distortion. Crackle volume slightly
	# louder than voiceline neutral so the click reads clearly.
	player.volume_db = randf_range(-2.0, 1.0)
	# Pitch-jitter so back-to-back voicelines don't have identical clicks.
	player.pitch_scale = randf_range(0.85, 1.15)
	player.play()


func _generate_radio_crackle(kind: String) -> AudioStreamWAV:
	## Brief filtered-noise burst with a sharp click at the front and
	## a fast envelope. `kind == "on"` ramps in over 5ms then decays
	## over 80ms, giving the "carrier click + static" sound. `kind ==
	## "off"` is shorter (40ms total) and snappier.
	var dur: float = 0.085 if kind == "on" else 0.045
	var samples: int = int(SAMPLE_RATE * dur)
	var data := PackedByteArray()
	data.resize(samples * 2)
	# IIR low-pass setup so the static doesn't sound like pure white
	# noise — radio static has rolled-off highs.
	var dt: float = 1.0 / float(SAMPLE_RATE)
	var rc: float = 1.0 / (TAU * 4500.0)
	var alpha: float = dt / (rc + dt)
	var prev_lp: float = 0.0
	var attack_samples: int = int(SAMPLE_RATE * 0.005)
	for i: int in samples:
		var u: float = float(i) / float(maxi(samples, 1))
		# Front click — first 2-3 samples are full amplitude raw noise
		# for the sharp transient that sells the carrier handover.
		var raw: float = randf_range(-1.0, 1.0)
		prev_lp = prev_lp + alpha * (raw - prev_lp)
		var v: float = prev_lp
		# Envelope: fast attack into exponential decay.
		var attack: float = clampf(float(i) / float(maxi(attack_samples, 1)), 0.0, 1.0)
		var decay_u: float = clampf((u - 0.05) / 0.95, 0.0, 1.0)
		var decay: float = exp(-decay_u * 5.0)
		v *= attack * decay
		# Boost — bandpass on the bus drops a lot of energy, so we
		# pre-boost here to keep the click loud post-filtering.
		v = clampf(v * 2.5, -1.0, 1.0)
		_write_sample(data, i, v)
	return _make_stream(data)


func play_voice_build() -> void:
	_play_voiceline("build")


func _play_voiceline(category: String) -> void:
	## Plays one variant from the local player's faction. Single channel
	## means a new command issued while a line is playing is ignored.
	if not _vl_player:
		return
	if _vl_player.playing:
		return
	var fid: int = _player_faction_id()
	if not _voicelines.has(fid):
		return
	var bank: Array = _voicelines[fid].get(category, []) as Array
	if bank.is_empty():
		return
	var stream: AudioStream = bank[randi() % bank.size()] as AudioStream
	if not stream:
		return
	_vl_player.stream = stream
	_vl_player.volume_db = 0.0
	_vl_player.pitch_scale = 1.0
	# Radio "tuning in" crackle right before the line starts — a quick
	# noise burst on the same bus, so it gets the same band-pass / lofi
	# treatment as the VO. Sells the squad-radio handover feel.
	_play_radio_crackle("on")
	_vl_player.play()
	# "Tuning out" crackle when the line finishes. Connect once per
	# play; CONNECT_ONE_SHOT auto-disconnects after firing so we don't
	# stack handlers.
	if not _vl_player.finished.is_connected(_on_voiceline_finished):
		_vl_player.finished.connect(_on_voiceline_finished, CONNECT_ONE_SHOT)


func _on_voiceline_finished() -> void:
	_play_radio_crackle("off")


func _player_faction_id() -> int:
	# Local player's chosen faction. Anvil (0) is the default fallback
	# when MatchSettings isn't loaded — keeps the test arena working
	# from the editor.
	var settings: Node = get_node_or_null("/root/MatchSettings")
	if not settings or not "player_faction" in settings:
		return 0
	return settings.get("player_faction") as int


func play_capture_complete(at: Vector3 = Vector3.INF) -> void:
	_spatial_pos = at
	var base: float = randf_range(330.0, 380.0)
	_play_two_tone(base, base * randf_range(1.4, 1.5), randf_range(0.1, 0.14), randf_range(-9.0, -7.0))
	_spatial_pos = Vector3.INF


## --- Generator playback ---

func _play_tone(freq: float, duration: float, volume_db: float, detune: float = 0.0) -> void:
	var stream := _generate_tone(freq + detune, duration)
	_emit(stream, volume_db)


func _play_thump(freq: float, duration: float, volume_db: float) -> void:
	# A "thump" is a tone that pitches down across its duration — gives weight.
	var stream := _generate_pitched_tone(freq * 1.6, freq * 0.7, duration)
	_emit(stream, volume_db)


func _play_two_tone(freq1: float, freq2: float, duration: float, volume_db: float) -> void:
	var stream := _generate_two_tone(freq1, freq2, duration)
	_emit(stream, volume_db)


func _play_filtered_noise(duration: float, lowpass_hz: float, volume_db: float) -> void:
	var stream := _generate_filtered_noise(duration, lowpass_hz)
	_emit(stream, volume_db)


func _emit(stream: AudioStream, volume_db: float, pitch: float = 1.0) -> void:
	# Single dispatch point — routes to the 2D or 3D pool based on whether
	# a public spatial caller has stashed a position. Saves duplicating
	# every layered recipe between 2D and 3D variants. Pitch defaults to
	# 1.0; recorded SFX pass a randomized pitch so back-to-back fires
	# don't sound identical.
	if _spatial_pos != Vector3.INF:
		_play_3d_at(stream, _spatial_pos, volume_db, pitch)
	else:
		var player := _get_free_player()
		player.stream = stream
		player.volume_db = volume_db
		player.pitch_scale = pitch
		player.play()


## --- Generators ---

func _generate_tone(freq: float, duration: float) -> AudioStreamWAV:
	var samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(samples * 2)

	for i: int in samples:
		var t: float = float(i) / float(SAMPLE_RATE)
		# Quick attack, exponential decay — punchier than a linear ramp.
		var env: float = _attack_decay_env(i, samples, 0.04)

		# Square-ish wave for industrial feel (clipped sine).
		var sample: float = sin(t * freq * TAU)
		sample = clampf(sample * 2.0, -1.0, 1.0)
		sample *= env

		_write_sample(data, i, sample)

	return _make_stream(data)


func _generate_pitched_tone(start_freq: float, end_freq: float, duration: float) -> AudioStreamWAV:
	# Frequency sweep — thump, kick, boom feel.
	var samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(samples * 2)

	# Phase accumulator so the pitch sweep is smooth and click-free.
	var phase: float = 0.0
	for i: int in samples:
		var u: float = float(i) / float(samples)
		var freq: float = lerp(start_freq, end_freq, u)
		phase += freq * TAU / float(SAMPLE_RATE)

		var env: float = _attack_decay_env(i, samples, 0.02)
		var sample: float = sin(phase)
		# Subtle saturation for body — gentle clip.
		sample = clampf(sample * 1.4, -1.0, 1.0)
		sample *= env

		_write_sample(data, i, sample)

	return _make_stream(data)


func _generate_two_tone(freq1: float, freq2: float, duration: float) -> AudioStreamWAV:
	var samples: int = int(SAMPLE_RATE * duration)
	var half: int = samples / 2
	var data := PackedByteArray()
	data.resize(samples * 2)

	for i: int in samples:
		var t: float = float(i) / float(SAMPLE_RATE)
		var env: float = _attack_decay_env(i, samples, 0.05)

		var freq: float = freq1 if i < half else freq2
		var sample: float = sin(t * freq * TAU)
		sample = clampf(sample * 2.0, -1.0, 1.0)
		sample *= env

		_write_sample(data, i, sample)

	return _make_stream(data)


func _generate_filtered_noise(duration: float, lowpass_hz: float) -> AudioStreamWAV:
	# One-pole IIR low-pass. Lower cutoff = more rumbly/muffled.
	var samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(samples * 2)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var rc: float = 1.0 / (TAU * maxf(lowpass_hz, 1.0))
	var alpha: float = dt / (rc + dt)
	var prev: float = 0.0

	for i: int in samples:
		var raw: float = randf_range(-1.0, 1.0)
		# IIR low-pass.
		prev = prev + alpha * (raw - prev)
		var env: float = _attack_decay_env(i, samples, 0.005)
		# Boost a bit since LP cuts amplitude.
		var sample: float = clampf(prev * 2.0, -1.0, 1.0) * env

		_write_sample(data, i, sample)

	return _make_stream(data)


## --- Helpers ---

func _attack_decay_env(i: int, samples: int, attack_frac: float) -> float:
	## Quick attack ramp + exponential decay — feels punchier than a linear fade.
	var u: float = float(i) / float(maxi(samples, 1))
	var attack: float = clampf(u / maxf(attack_frac, 0.0001), 0.0, 1.0)
	var decay_u: float = clampf((u - attack_frac) / maxf(1.0 - attack_frac, 0.0001), 0.0, 1.0)
	var decay: float = exp(-decay_u * 4.0)
	return attack * decay


func _write_sample(data: PackedByteArray, i: int, sample: float) -> void:
	var value: int = int(sample * 16000.0)
	value = clampi(value, -32768, 32767)
	data[i * 2] = value & 0xFF
	data[i * 2 + 1] = (value >> 8) & 0xFF


func _make_stream(data: PackedByteArray) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.data = data
	return stream

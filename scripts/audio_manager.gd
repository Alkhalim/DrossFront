class_name AudioManager
extends Node
## Generates and plays simple procedural sound effects for prototyping.
## Industrial/mechanical tone — low frequencies, clicks, metallic.
##
## Sounds are layered: a "shot" is a filtered-noise crack plus a low body thump,
## an "explosion" is a three-stage crack → mid-rumble → low decay tail.

var _players: Array[AudioStreamPlayer] = []
const POOL_SIZE: int = 16
const SAMPLE_RATE: int = 22050


func _ready() -> void:
	for i: int in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = "Master"
		add_child(player)
		_players.append(player)


func _get_free_player() -> AudioStreamPlayer:
	for player: AudioStreamPlayer in _players:
		if not player.playing:
			return player
	return _players[0]


## --- Public API ---

## All public sounds layer 2-4 generators per call AND randomize every input
## (frequency, duration, filter cutoff, volume) so back-to-back triggers
## never produce identical samples. Each generator goes to a separate
## AudioStreamPlayer so layers actually mix instead of stomping each other.

func play_command() -> void:
	# Two-layer click: a high tick + a quick low body pulse.
	var pitch: float = randf_range(255.0, 320.0)
	_play_tone(pitch, randf_range(0.05, 0.07), randf_range(-12.0, -9.0), randf_range(1.0, 2.5))
	_play_tone(pitch * 0.45, randf_range(0.04, 0.06), randf_range(-15.0, -12.0))

func play_select() -> void:
	# Two-layer ping: bright lead tone + a fifth above it for color.
	var freq: float = randf_range(360.0, 460.0)
	_play_tone(freq, randf_range(0.035, 0.05), randf_range(-15.0, -12.0))
	if randf() < 0.6:
		_play_tone(freq * randf_range(1.45, 1.55), randf_range(0.03, 0.045), randf_range(-19.0, -16.0))

func play_building_placed() -> void:
	# Heavy industrial thud — pitched-down body + dirt-noise crack +
	# low rumble tail.
	_play_thump(randf_range(60.0, 82.0), randf_range(0.2, 0.26), randf_range(-5.0, -3.0))
	_play_filtered_noise(randf_range(0.16, 0.22), randf_range(1500.0, 2200.0), randf_range(-12.0, -8.0))
	_play_filtered_noise(randf_range(0.28, 0.4), randf_range(450.0, 700.0), randf_range(-14.0, -10.0))

func play_production_started() -> void:
	# Mechanical clunk: noise burst + low click + small high tick.
	_play_filtered_noise(randf_range(0.05, 0.08), randf_range(2000.0, 2800.0), randf_range(-12.0, -8.0))
	_play_tone(randf_range(140.0, 175.0), randf_range(0.04, 0.06), randf_range(-16.0, -12.0), randf_range(1.5, 3.0))
	if randf() < 0.5:
		_play_tone(randf_range(420.0, 520.0), 0.03, -19.0)

func play_production_complete() -> void:
	# Rising two-tone chime with a small noise puff for breath.
	var base: float = randf_range(360.0, 410.0)
	_play_two_tone(base, base * randf_range(1.32, 1.42), randf_range(0.09, 0.12), randf_range(-9.0, -6.0))
	_play_filtered_noise(randf_range(0.04, 0.06), 3500.0, -18.0)

func play_construction_complete() -> void:
	# Heavier completion tone — lower fundamental + a thump tail.
	var base: float = randf_range(245.0, 285.0)
	_play_two_tone(base, base * randf_range(1.45, 1.6), randf_range(0.13, 0.18), randf_range(-7.0, -5.0))
	_play_thump(randf_range(80.0, 105.0), randf_range(0.18, 0.24), -10.0)

func play_error() -> void:
	# Low buzz with a slight detune wobble.
	_play_tone(randf_range(70.0, 82.0), randf_range(0.22, 0.28), -6.0, randf_range(-2.0, 2.0))
	_play_filtered_noise(0.18, 800.0, -16.0)


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

func play_weapon_fire(weapon: WeaponResource = null) -> void:
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

func play_weapon_impact() -> void:
	# Metallic clang: noise crack + pitched ring + low body thump.
	var pitch: float = randf_range(100.0, 165.0)
	_play_filtered_noise(randf_range(0.03, 0.05), randf_range(2800.0, 3800.0), randf_range(-18.0, -14.0))
	_play_tone(pitch, randf_range(0.06, 0.09), randf_range(-15.0, -12.0), randf_range(3.0, 8.0))
	if randf() < 0.4:
		_play_thump(pitch * 0.5, 0.08, -16.0)

func play_unit_destroyed() -> void:
	# Three-stage explosion with substantial randomization on each stage so
	# back-to-back kills don't sound copy-pasted.
	_play_filtered_noise(randf_range(0.06, 0.1), randf_range(4200.0, 5800.0), randf_range(-5.0, -2.0))   # crack
	_play_thump(randf_range(45.0, 65.0), randf_range(0.35, 0.5), randf_range(-5.0, -3.0))                # body boom
	_play_filtered_noise(randf_range(0.45, 0.7), randf_range(550.0, 850.0), randf_range(-10.0, -7.0))    # rumble tail
	# A mid-frequency crack lands sometimes for added texture.
	if randf() < 0.6:
		_play_filtered_noise(randf_range(0.1, 0.18), randf_range(1400.0, 2200.0), -10.0)

func play_capture_complete() -> void:
	var base: float = randf_range(330.0, 380.0)
	_play_two_tone(base, base * randf_range(1.4, 1.5), randf_range(0.1, 0.14), randf_range(-9.0, -7.0))


## --- Generator playback ---

func _play_tone(freq: float, duration: float, volume_db: float, detune: float = 0.0) -> void:
	var stream := _generate_tone(freq + detune, duration)
	var player := _get_free_player()
	player.stream = stream
	player.volume_db = volume_db
	player.play()


func _play_thump(freq: float, duration: float, volume_db: float) -> void:
	# A "thump" is a tone that pitches down across its duration — gives weight.
	var stream := _generate_pitched_tone(freq * 1.6, freq * 0.7, duration)
	var player := _get_free_player()
	player.stream = stream
	player.volume_db = volume_db
	player.play()


func _play_two_tone(freq1: float, freq2: float, duration: float, volume_db: float) -> void:
	var stream := _generate_two_tone(freq1, freq2, duration)
	var player := _get_free_player()
	player.stream = stream
	player.volume_db = volume_db
	player.play()


func _play_filtered_noise(duration: float, lowpass_hz: float, volume_db: float) -> void:
	var stream := _generate_filtered_noise(duration, lowpass_hz)
	var player := _get_free_player()
	player.stream = stream
	player.volume_db = volume_db
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

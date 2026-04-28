class_name AudioManager
extends Node
## Generates and plays simple procedural sound effects for prototyping.
## Industrial/mechanical tone — low frequencies, clicks, metallic.

## Call these from anywhere via AudioManager reference on the scene root.

var _players: Array[AudioStreamPlayer] = []
const POOL_SIZE: int = 8
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

func play_command() -> void:
	_play_tone(220.0, 0.08, -8.0)

func play_select() -> void:
	_play_tone(330.0, 0.05, -12.0)

func play_building_placed() -> void:
	_play_tone(110.0, 0.15, -6.0, 0.3)

func play_production_started() -> void:
	_play_noise_burst(0.06, -10.0)

func play_production_complete() -> void:
	_play_two_tone(440.0, 550.0, 0.08, -8.0)

func play_construction_complete() -> void:
	_play_two_tone(330.0, 440.0, 0.12, -6.0)

func play_error() -> void:
	_play_tone(90.0, 0.2, -6.0, 0.0)

func play_weapon_fire() -> void:
	_play_noise_burst(0.04, -14.0)

func play_unit_destroyed() -> void:
	_play_tone(65.0, 0.35, -4.0, 2.0)


## --- Generators ---

func _play_tone(freq: float, duration: float, volume_db: float, detune: float = 0.0) -> void:
	var stream := _generate_tone(freq + detune, duration)
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


func _play_noise_burst(duration: float, volume_db: float) -> void:
	var stream := _generate_noise(duration)
	var player := _get_free_player()
	player.stream = stream
	player.volume_db = volume_db
	player.play()


func _generate_tone(freq: float, duration: float) -> AudioStreamWAV:
	var samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(samples * 2)

	for i: int in samples:
		var t: float = float(i) / float(SAMPLE_RATE)
		var envelope: float = 1.0 - (float(i) / float(samples))
		envelope = envelope * envelope

		# Square-ish wave for industrial feel (clipped sine)
		var sample: float = sin(t * freq * TAU)
		sample = clampf(sample * 2.0, -1.0, 1.0)
		sample *= envelope

		var value: int = int(sample * 16000.0)
		value = clampi(value, -32768, 32767)
		data[i * 2] = value & 0xFF
		data[i * 2 + 1] = (value >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.data = data
	return stream


func _generate_two_tone(freq1: float, freq2: float, duration: float) -> AudioStreamWAV:
	var samples: int = int(SAMPLE_RATE * duration)
	var half: int = samples / 2
	var data := PackedByteArray()
	data.resize(samples * 2)

	for i: int in samples:
		var t: float = float(i) / float(SAMPLE_RATE)
		var envelope: float = 1.0 - (float(i) / float(samples))
		envelope = envelope * envelope

		var freq: float = freq1 if i < half else freq2
		var sample: float = sin(t * freq * TAU)
		sample = clampf(sample * 2.0, -1.0, 1.0)
		sample *= envelope

		var value: int = int(sample * 16000.0)
		value = clampi(value, -32768, 32767)
		data[i * 2] = value & 0xFF
		data[i * 2 + 1] = (value >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.data = data
	return stream


func _generate_noise(duration: float) -> AudioStreamWAV:
	var samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(samples * 2)

	for i: int in samples:
		var envelope: float = 1.0 - (float(i) / float(samples))
		envelope = envelope * envelope * envelope

		# Filtered noise — low-pass by averaging
		var noise: float = randf_range(-1.0, 1.0) * envelope * 0.6

		var value: int = int(noise * 16000.0)
		value = clampi(value, -32768, 32767)
		data[i * 2] = value & 0xFF
		data[i * 2 + 1] = (value >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.data = data
	return stream

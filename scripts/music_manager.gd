class_name MusicManager
extends Node
## Background music playlists. Loads tracks at scene start, plays one
## at a time via a single AudioStreamPlayer, and queues the next one
## when the current track finishes. Three playlists ship by default:
##   - Universal (menus, neutral framing)
##   - Anvil    (in-match when local player is Anvil)
##   - Sable    (in-match when local player is Sable)
## In-match the active list is the player's faction list mixed with the
## universal one — both pools are eligible for the next pick — so the
## faction music dominates without repeating endlessly.

const MUSIC_DIR_UNIVERSAL: String = "res://assets/audio/Music/Universal"
const MUSIC_DIR_ANVIL: String = "res://assets/audio/Music/Anvil"
const MUSIC_DIR_SABLE: String = "res://assets/audio/Music/Sable"

## Playback volume on the music bus. -14 dB sits the score well
## under SFX (~50% perceived loudness vs the previous -8 dB) so
## the score stays present without competing with combat audio.
const MUSIC_VOLUME_DB: float = -14.0

## Gap between tracks so the next one doesn't slam in immediately.
const TRACK_GAP_SEC: float = 1.4

var _player: AudioStreamPlayer = null
var _playlist: Array[AudioStream] = []
var _last_track: AudioStream = null
var _gap_remaining: float = 0.0
var _started: bool = false


func _ready() -> void:
	# Ensure the "Music" bus exists before the player is wired up so
	# the pause-menu Music slider (which routes via that bus) can
	# actually change music volume. AudioManager also creates this
	# bus, but MusicManager runs in main_menu where there's no
	# AudioManager — make our own.
	_ensure_music_bus()
	_player = AudioStreamPlayer.new()
	_player.bus = "Music"
	_player.volume_db = MUSIC_VOLUME_DB
	_player.finished.connect(_on_track_finished)
	add_child(_player)


func _ensure_music_bus() -> void:
	if AudioServer.get_bus_index("Music") >= 0:
		return
	var idx: int = AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, "Music")
	AudioServer.set_bus_send(idx, "Master")


func _process(delta: float) -> void:
	if not _started:
		return
	if _gap_remaining > 0.0:
		_gap_remaining -= delta
		if _gap_remaining <= 0.0:
			_play_next()


## Public entry point — pick the playlist appropriate to the active
## scene. faction_id < 0 → universal-only (menus); otherwise mixes
## faction tracks with the universal pool.
func start(faction_id: int = -1) -> void:
	_playlist = _build_playlist(faction_id)
	_started = true
	_gap_remaining = 0.0
	_play_next()


func stop() -> void:
	_started = false
	if _player:
		_player.stop()


func _build_playlist(faction_id: int) -> Array[AudioStream]:
	var out: Array[AudioStream] = []
	# Universal tracks always go in so even in-match the menu themes
	# break up the faction motif.
	out.append_array(_load_dir(MUSIC_DIR_UNIVERSAL))
	if faction_id == 0:
		out.append_array(_load_dir(MUSIC_DIR_ANVIL))
	elif faction_id == 1:
		out.append_array(_load_dir(MUSIC_DIR_SABLE))
	# Universal-only fallback when the requested faction folder is
	# empty or the id is out of range.
	if out.is_empty():
		out.append_array(_load_dir(MUSIC_DIR_UNIVERSAL))
	return out


func _load_dir(path: String) -> Array[AudioStream]:
	var streams: Array[AudioStream] = []
	var dir: DirAccess = DirAccess.open(path)
	if not dir:
		return streams
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		# Skip the .import sidecars — they're metadata, not playable.
		if not dir.current_is_dir() and not entry.ends_with(".import"):
			var full: String = "%s/%s" % [path, entry]
			var stream: AudioStream = load(full) as AudioStream
			if stream:
				streams.append(stream)
		entry = dir.get_next()
	return streams


func _play_next() -> void:
	if _playlist.is_empty() or not _player:
		return
	# Avoid the same track twice in a row when the playlist has more
	# than one entry, otherwise pick whatever's available.
	var next: AudioStream = _pick_random()
	if _playlist.size() > 1 and next == _last_track:
		next = _pick_random()
	_last_track = next
	_player.stream = next
	_player.play()


func _pick_random() -> AudioStream:
	return _playlist[randi() % _playlist.size()]


func _on_track_finished() -> void:
	_gap_remaining = TRACK_GAP_SEC

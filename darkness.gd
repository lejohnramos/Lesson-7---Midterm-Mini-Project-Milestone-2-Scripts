extends Node3D

@onready var sun: DirectionalLight3D = $Environment/DirectionalLight3D
@onready var env: Environment = $Environment/WorldEnvironment.environment
@export var ambience: AudioStreamPlayer

# Optional random creepy sounds (owl, branch snap, whisper...). Drag files in the Inspector.
@export var one_shots: Array[AudioStream] = []
@export var one_shot_min_delay := 15.0
@export var one_shot_max_delay := 45.0

const DAY_COLOR := Color(1.0, 0.96, 0.9)
const MOON_COLOR := Color(0.3, 0.45, 0.55)   # cold pale blue

# Direction from the world TOWARD the moon (needs positive Y to be above the horizon).
# Used for both the sky shader and the light, so they always match.
const MOON_DIR := Vector3(0.4, 0.4, -0.8)

const MOON_ENERGY := 0.08      # moonlight, the only real light source
const NIGHT_AMBIENT := 0.0005  # shadows are pure black
const NIGHT_SKY := 0.08        # darker sky (moon is boosted in the shader to compensate)

const AMBIENCE_DAY_DB := -30.0    # ambience volume in daylight
const AMBIENCE_NIGHT_DB := -10.0  # ambience volume at full night

var _current := 0.0
var _shot_player := AudioStreamPlayer.new()

func _ready() -> void:
	if env == null:
		push_error("WorldEnvironment has no Environment.")
		return

	# Point the light away from the moon, so light travels from the moon to the ground
	sun.global_transform.basis = Basis.looking_at(-MOON_DIR.normalized(), Vector3.UP)

	# Shadow setup
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 150.0
	sun.shadow_normal_bias = 1.5
	sun.shadow_blur = 1.2

	# Keep the moon in the sky shader in the same place as the light
	if env.sky and env.sky.sky_material is ShaderMaterial:
		env.sky.sky_material.set_shader_parameter("moon_dir", MOON_DIR)

	_setup_audio()
	set_darkness(1.0, 3.0)  # test: fade to full night over 3 seconds

func _setup_audio() -> void:
	# If the Inspector slot is empty, try to find a child node named "Ambience"
	if ambience == null:
		ambience = get_node_or_null("Ambience") as AudioStreamPlayer

	if ambience == null:
		push_error("Ambience player not found. Assign it in the Inspector, or add an AudioStreamPlayer named 'Ambience' under this node.")
		return
	if ambience.stream == null:
		push_error("The Ambience node has no audio Stream. Drag your .mp3 into its Stream slot.")
		return

	# Looping ambience: set the loop flag on the stream...
	if ambience.stream is AudioStreamMP3:
		ambience.stream.loop = true
	elif ambience.stream is AudioStreamOggVorbis:
		ambience.stream.loop = true
	# ...and restart it if it ever finishes (works for any format)
	if not ambience.finished.is_connected(ambience.play):
		ambience.finished.connect(ambience.play)
	ambience.volume_db = AMBIENCE_DAY_DB
	ambience.play()   # untick Autoplay on the node so it doesn't start twice

	# Random one-shot sounds
	add_child(_shot_player)
	_shot_player.volume_db = -8.0
	_random_sound_loop()

func _random_sound_loop() -> void:
	while true:
		await get_tree().create_timer(randf_range(one_shot_min_delay, one_shot_max_delay)).timeout
		if one_shots.is_empty():
			continue
		_shot_player.stream = one_shots.pick_random()
		_shot_player.pitch_scale = randf_range(0.85, 1.1)
		_shot_player.play()

# amount: 0.0 = full day, 1.0 = full night (moon only)
func set_darkness(amount: float, duration := 2.0) -> void:
	var t := create_tween()
	t.tween_method(_apply, _current, amount, duration)
	_current = amount

func _apply(a: float) -> void:
	sun.light_energy = lerp(1.0, MOON_ENERGY, a)
	sun.light_color = DAY_COLOR.lerp(MOON_COLOR, a)
	env.ambient_light_energy = lerp(1.0, NIGHT_AMBIENT, a)
	env.background_energy_multiplier = lerp(1.0, NIGHT_SKY, a)
	if ambience != null:
		ambience.volume_db = lerp(AMBIENCE_DAY_DB, AMBIENCE_NIGHT_DB, a)

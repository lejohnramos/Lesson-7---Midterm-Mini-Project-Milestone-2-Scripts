extends Node3D
## Glowing flower. Dim and hard to see until the player presses F next to it.
## Hold G next to it to refill the player's lantern.
## Once lit it stays lit: it heals the player inside its light and enemies can't enter it.

@export_group("Light")
@export var idle_energy := 0.15         # barely visible while waiting
@export var active_energy := 1.0        # brightness once lit
@export var idle_range := 1.2           # tiny light while waiting
@export var light_range := 3.0          # size of the light AND the safe zone once lit
@export var pulse_amount := 0.2         # how much the light flickers (fraction of brightness)
@export var pulse_speed := 1.5
@export var fade_time := 0.6            # seconds to fade from dim to bright

@export_group("Interaction")
@export var interact_radius := 2.0      # how close you must be to press F
@export var heal_per_second := 5.0      # health given to the player inside the light
@export var refill_seconds := 3.0       # seconds of holding G to refill an empty lantern
@export var prompt_height := 1.0        # height of the "Press F" text above the flower

var light: OmniLight3D
var _player: Node3D
var _prompt: Label3D
var _lit := false
var _intensity := 0.0                   # 0 = dim, 1 = fully lit
var _t := randf() * TAU                 # random start so plants don't pulse in sync


func _ready() -> void:
	add_to_group("glow_plant")   # enemies look for this group to avoid the light

	var lights := find_children("*", "OmniLight3D", true, false)
	if lights.is_empty():
		push_warning("GlowPlant: no OmniLight3D found. Add one inside glow_plant.tscn.")
	else:
		light = lights[0] as OmniLight3D
		light.light_energy = idle_energy
		light.omni_range = idle_range

	_build_prompt()


func _build_prompt() -> void:
	_prompt = Label3D.new()
	_prompt.text = "Press F"
	_prompt.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_prompt.no_depth_test = true
	_prompt.pixel_size = 0.004
	_prompt.font_size = 48
	_prompt.outline_size = 12
	_prompt.position = Vector3(0, prompt_height, 0)
	_prompt.visible = false
	add_child(_prompt)


func _process(delta: float) -> void:
	# Fade the light up once lit
	var target := 1.0 if _lit else 0.0
	_intensity = move_toward(_intensity, target, delta / maxf(fade_time, 0.01))
	_t += delta * pulse_speed

	if light != null:
		var base := lerpf(idle_energy, active_energy, _intensity)
		light.light_energy = base * (1.0 + sin(_t) * pulse_amount)
		light.omni_range = _current_radius()


func _physics_process(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node3D

	# Heal the player while they stand inside the light
	if _lit and _player != null and is_in_light(_player.global_position):
		if _player.has_method("heal"):
			_player.heal(heal_per_second * delta)

	var near := _player_is_near()
	var needs_fuel: bool = _player != null and _player.get("fuel") != null and _player.fuel < 0.99

	# Hold G next to the flower to refill the lantern
	if near and needs_fuel and Input.is_physical_key_pressed(KEY_G):
		if _player.has_method("refill_lantern"):
			_player.refill_lantern(delta / maxf(refill_seconds, 0.1))

	# Show only the options that are available right now
	var lines: PackedStringArray = []
	if not _lit:
		lines.append("F: light the flower")
	if needs_fuel:
		lines.append("Hold G: refill lantern")
	_prompt.text = "\n".join(lines)
	_prompt.visible = near and not lines.is_empty()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F:
		if not _lit and _player_is_near():
			_lit = true
			print("Flower lit. Safe radius: ", light_range)
			get_tree().call_group("game_ui", "plant_lit")   # counts toward escaping


func _player_is_near() -> bool:
	if _player == null or not is_instance_valid(_player):
		return false
	var d := _player.global_position - global_position
	d.y = 0.0
	return d.length() <= interact_radius


func _current_radius() -> float:
	return lerpf(idle_range, light_range, _intensity)


## True if pos is inside this flower's light. Only counts once the flower has been lit.
func is_in_light(pos: Vector3, margin := 0.0) -> bool:
	if not _lit:
		return false
	var d := pos - global_position
	d.y = 0.0
	return d.length() <= _current_radius() + margin

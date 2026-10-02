extends Camera3D
## Free-fly testing camera. Press F2 to switch between it and the player's camera.
## While it is active the player can't move, so you can look around the whole level.
##   W/A/S/D = move   Q/E = down/up   Shift = faster   Mouse wheel = change speed

@export var toggle_key: Key = KEY_F2
@export var move_speed := 15.0
@export var fast_multiplier := 3.0
@export var mouse_sensitivity := 0.003
@export var start_height := 20.0        # how far above the player's view it starts
@export var start_pitch_deg := -40.0    # starts looking downwards

var _active := false
var _label: Label


func _ready() -> void:
	set_process(false)

	# Small on-screen reminder while the debug camera is on
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.text = "DEBUG CAMERA  (F2 to exit, wheel = speed)"
	_label.position = Vector2(20, 100)
	_label.add_theme_font_size_override("font_size", 18)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	_label.visible = false
	layer.add_child(_label)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == toggle_key:
		_set_active(not _active)
		get_viewport().set_input_as_handled()
		return

	if not _active:
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotation.y -= event.relative.x * mouse_sensitivity
		rotation.x = clampf(rotation.x - event.relative.y * mouse_sensitivity, -PI / 2.0 + 0.01, PI / 2.0 - 0.01)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			move_speed = minf(move_speed * 1.2, 200.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			move_speed = maxf(move_speed / 1.2, 1.0)


func _set_active(on: bool) -> void:
	_active = on
	set_process(on)
	_label.visible = on
	get_tree().call_group("player", "set_controls_enabled", not on)

	if on:
		# Start from the player's current view, raised up and looking down
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			global_transform = cam.global_transform
		global_position.y += start_height
		rotation = Vector3(deg_to_rad(start_pitch_deg), rotation.y, 0.0)
		make_current()
	else:
		# Hand the view back to the player's camera
		get_tree().call_group("player", "use_follow_camera")


func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		dir -= global_basis.z
	if Input.is_physical_key_pressed(KEY_S):
		dir += global_basis.z
	if Input.is_physical_key_pressed(KEY_D):
		dir += global_basis.x
	if Input.is_physical_key_pressed(KEY_A):
		dir -= global_basis.x
	if Input.is_physical_key_pressed(KEY_E):
		dir += Vector3.UP
	if Input.is_physical_key_pressed(KEY_Q):
		dir += Vector3.DOWN

	if dir.length_squared() > 0.0:
		var speed := move_speed
		if Input.is_physical_key_pressed(KEY_SHIFT):
			speed *= fast_multiplier
		global_position += dir.normalized() * speed * delta	

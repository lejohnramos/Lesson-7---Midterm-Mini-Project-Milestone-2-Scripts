extends CharacterBody3D
## Third-person controller.

@export_group("Movement")
@export var speed := 2.0
@export var run_speed := 4.0         # speed while holding Shift + W/A/S/D
@export var acceleration := 30.0
@export var turn_speed := 10.0

@export_group("Camera")
@export var mouse_sensitivity := 0.003
@export var min_pitch_deg := -50.0
@export var max_pitch_deg := 40.0

@export_group("Model")
@export var model_yaw_offset_deg := 0.0
@export var auto_ground_model := true
@export var ground_offset := 0.0

@export_group("Animation")
@export var walk_anim_speed := 1.7   # 1.0 = normal, lower = slower
@export var run_anim_speed := 1.2    # playback speed of the run clip
@export var attack_anim_speed := 1.8 # playback speed of the attack clips

@export_group("Attack")
@export var attack_knockback := 10.0   # how hard enemies are pushed away
@export var sword_hit_start := 0.15    # seconds after pressing E when the sword starts hurting
@export var sword_hit_end := 0.5       # seconds after pressing E when the sword stops hurting
@export_flags_3d_physics var hit_collision_mask := 1  # physics layer(s) the enemies are on

@export_group("Footsteps")
@export var walk_sound_speed := 1.0  # playback speed of the sound while walking
@export var run_sound_speed := 1.5   # playback speed of the sound while running

@export_group("Lantern")
@export var lantern_duration := 120.0   # seconds a full lantern lasts
@export var lantern_min_energy := 0.2   # brightness when the fuel is empty (0 = fully off)
@export var lantern_min_range := 2.0    # light range when the fuel is empty

@export_group("Health")
@export var max_health := 100.0
@export var death_restart_delay := 1.0 # seconds before the Game Over screen shows after dying

# UPDATED PATH: Pointing to the built-in AnimationPlayer inside the imported model
@onready var model: Node3D = $CharacterModel
@onready var pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var anim: AnimationPlayer = $CharacterModel/AnimationPlayer
@onready var _steps: AudioStreamPlayer = get_node_or_null("FootstepPlayer")

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

var _idle_name := ""
var _walk_name := ""
var _run_name := ""
var _attack_names: Array[String] = []
var _last_attack := ""
var _attacking := false

var _sword_hitbox: Area3D
var _hit_this_swing: Array = []

var controls_enabled := true         # false while the debug camera is flying around

var health := 0.0
var _dead := false
var _health_bar: ProgressBar

var fuel := 1.0                      # lantern fuel, 1.0 = full, 0.0 = empty
var _fuel_bar: ProgressBar
var _lantern_light: OmniLight3D
var _lantern_full_energy := 2.0
var _lantern_full_range := 6.0


func _ready() -> void:
	add_to_group("player")   # lets enemies find the player
	health = max_health
	_build_health_bar()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	spring_arm.add_excluded_object(get_rid())

	_activate_follow_camera()
	_setup_animations()
	_setup_sword_hitbox()

	# Make the footstep sound loop (works even though the imported Loop box is locked)
	if _steps == null:
		push_warning("FootstepPlayer node not found under Character. Add an AudioStreamPlayer named FootstepPlayer.")
	elif _steps.stream is AudioStreamMP3:
		(_steps.stream as AudioStreamMP3).loop = true

	_setup_lantern()
	
	# --- TEST CODE START ---
	# FORCE PLAY IDLE TO TEST
	if anim != null:
		print("Forcing Idle to play. Anim list: ", anim.get_animation_list())
		anim.play("Idle") 
	# --- TEST CODE END ---

	if auto_ground_model:
		_ground_model()


func _build_health_bar() -> void:
	# Creates the life bar in code, so there is nothing to set up in the editor
	var layer := CanvasLayer.new()
	add_child(layer)

	_health_bar = ProgressBar.new()
	_health_bar.max_value = max_health
	_health_bar.value = health
	_health_bar.show_percentage = false
	_health_bar.position = Vector2(20, 20)
	_health_bar.custom_minimum_size = Vector2(250, 22)

	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.8, 0.1, 0.1)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0.1, 0.1, 0.1, 0.8)
	_health_bar.add_theme_stylebox_override("fill", fill)
	_health_bar.add_theme_stylebox_override("background", back)

	layer.add_child(_health_bar)

	# Lantern fuel bar, just under the life bar
	_fuel_bar = ProgressBar.new()
	_fuel_bar.max_value = 1.0
	_fuel_bar.value = fuel
	_fuel_bar.show_percentage = false
	_fuel_bar.position = Vector2(20, 50)
	_fuel_bar.custom_minimum_size = Vector2(250, 12)

	var fuel_fill := StyleBoxFlat.new()
	fuel_fill.bg_color = Color(1.0, 0.65, 0.2)
	var fuel_back := StyleBoxFlat.new()
	fuel_back.bg_color = Color(0.1, 0.1, 0.1, 0.8)
	_fuel_bar.add_theme_stylebox_override("fill", fuel_fill)
	_fuel_bar.add_theme_stylebox_override("background", fuel_back)

	layer.add_child(_fuel_bar)


func take_damage(amount: float) -> void:
	if _dead:
		return
	health = maxf(health - amount, 0.0)
	if _health_bar != null:
		_health_bar.value = health
	if health <= 0.0:
		_die()


func heal(amount: float) -> void:
	if _dead:
		return
	health = minf(health + amount, max_health)
	if _health_bar != null:
		_health_bar.value = health


func _die() -> void:
	_dead = true
	print("Player died")
	await get_tree().create_timer(death_restart_delay).timeout
	if not is_inside_tree():
		return
	var ui := get_tree().get_first_node_in_group("game_ui")
	if ui != null:
		ui.show_game_over()
	else:
		get_tree().reload_current_scene()   # fallback if there is no GameUI node


## Used by the debug camera: turns player movement, mouse look and attacks off/on
func set_controls_enabled(enabled: bool) -> void:
	controls_enabled = enabled


## Used by the debug camera to hand the view back to the player
func use_follow_camera() -> void:
	_activate_follow_camera()


func _activate_follow_camera() -> void:
	for child in spring_arm.get_children():
		if child is Camera3D:
			(child as Camera3D).make_current()
			return
	push_warning("No Camera3D found under SpringArm3D.")


func _setup_animations() -> void:
	if anim == null:
		push_error("AnimationPlayer node not found! Check the @onready path.")
		return

	# This will print exactly what Godot sees in the Output panel
	print("Animations found: ", anim.get_animation_list())

	for n in anim.get_animation_list():
		var lower := String(n).to_lower()
		if _idle_name == "" and "idle" in lower:
			_idle_name = n
		if _walk_name == "" and "walk" in lower:
			_walk_name = n
		if _run_name == "" and "run" in lower:
			_run_name = n
		if "attack" in lower and not "attack3" in lower:
			_attack_names.append(String(n))

	if _idle_name == "":
		push_error("No animation with 'idle' in its name was found.")
	else:
		anim.get_animation(_idle_name).loop_mode = Animation.LOOP_LINEAR
		anim.play(_idle_name)
		print("Started Idle animation: ", _idle_name)

	if _walk_name == "":
		push_error("No animation with 'walk' in its name was found.")
	else:
		anim.get_animation(_walk_name).loop_mode = Animation.LOOP_LINEAR
		print("Ready to play Walk animation: ", _walk_name)

	if _run_name == "":
		push_error("No animation with 'run' in its name was found.")
	else:
		anim.get_animation(_run_name).loop_mode = Animation.LOOP_LINEAR
		print("Ready to play Run animation: ", _run_name)

	if _attack_names.is_empty():
		push_warning("No animations with 'attack' in their name were found.")
	else:
		# Attacks play once, not in a loop
		for a in _attack_names:
			anim.get_animation(a).loop_mode = Animation.LOOP_NONE
		print("Ready to play Attack animations: ", _attack_names)

	anim.animation_finished.connect(_on_animation_finished)


func _start_attack() -> void:
	if _attacking or _attack_names.is_empty() or anim == null:
		return
	if not is_on_floor():
		return

	# Pick a random attack, avoiding the same one twice in a row
	var pick: String = _attack_names.pick_random()
	if _attack_names.size() > 1:
		while pick == _last_attack:
			pick = _attack_names.pick_random()
	_last_attack = pick

	_attacking = true
	_update_footsteps(false, false)
	anim.play(pick, 0.1, attack_anim_speed)
	print("Attack: ", pick)
	_hit_enemies()


func _hit_enemies() -> void:
	# The sword only hurts during the swing window
	if _sword_hitbox == null:
		return
	_hit_this_swing.clear()

	await get_tree().create_timer(sword_hit_start).timeout
	if not is_inside_tree():
		return
	_sword_hitbox.monitoring = true

	await get_tree().create_timer(maxf(sword_hit_end - sword_hit_start, 0.05)).timeout
	if not is_inside_tree():
		return
	_sword_hitbox.monitoring = false


func _setup_sword_hitbox() -> void:
	# Builds an Area3D on the sword that matches the sword mesh size
	var sword := model.find_child("Sword", true, false) as Node3D
	if sword == null:
		push_warning("Sword node not found under CharacterModel.")
		return

	var size := Vector3(0.3, 1.2, 0.3)
	var center := Vector3.ZERO
	if sword is MeshInstance3D and (sword as MeshInstance3D).mesh != null:
		var box_aabb := (sword as MeshInstance3D).get_aabb()
		size = box_aabb.size
		center = box_aabb.get_center()

	var box := BoxShape3D.new()
	box.size = size
	var col := CollisionShape3D.new()
	col.shape = box
	col.position = center

	_sword_hitbox = Area3D.new()
	_sword_hitbox.name = "SwordHitbox"
	_sword_hitbox.collision_layer = 0
	_sword_hitbox.collision_mask = hit_collision_mask
	_sword_hitbox.monitorable = false
	_sword_hitbox.monitoring = false
	_sword_hitbox.add_child(col)
	sword.add_child(_sword_hitbox)
	_sword_hitbox.body_entered.connect(_on_sword_hit)


func _on_sword_hit(body: Node3D) -> void:
	if body == self or _hit_this_swing.has(body):
		return
	if not body.is_in_group("enemy") or not body.has_method("apply_knockback"):
		return

	_hit_this_swing.append(body)
	var dir := body.global_position - global_position
	dir.y = 0.0
	body.apply_knockback(dir.normalized(), attack_knockback)
	print("Sword hit: ", body.name)


func _on_animation_finished(anim_name: StringName) -> void:
	if _attack_names.has(String(anim_name)):
		_attacking = false


func _update_footsteps(moving: bool, running: bool) -> void:
	if _steps == null:
		return

	if moving and is_on_floor():
		_steps.pitch_scale = run_sound_speed if running else walk_sound_speed
		if not _steps.playing:
			_steps.play()
	elif _steps.playing:
		_steps.stop()


func _setup_lantern() -> void:
	var lantern := model.find_child("Lantern", true, false)
	if lantern == null:
		push_warning("Lantern node not found.")
		return

	# Uses a light you already added in the editor, or creates one if none exists
	var light: OmniLight3D = null
	for child in lantern.get_children():
		if child is OmniLight3D:
			light = child
			break
	if light == null:
		light = OmniLight3D.new()
		light.light_color = Color("ffb060")
		light.light_energy = 2.0
		light.omni_range = 6.0
		light.shadow_enabled = true
		lantern.add_child(light)

	# Whatever the light is set to in the editor counts as "full fuel"
	_lantern_light = light
	_lantern_full_energy = light.light_energy
	_lantern_full_range = light.omni_range


func _update_lantern(delta: float) -> void:
	if _lantern_light == null or _dead:
		return
	fuel = maxf(fuel - delta / maxf(lantern_duration, 0.1), 0.0)
	_lantern_light.light_energy = lerpf(lantern_min_energy, _lantern_full_energy, fuel)
	_lantern_light.omni_range = lerpf(lantern_min_range, _lantern_full_range, fuel)
	if _fuel_bar != null:
		_fuel_bar.value = fuel


## Called by glow plants while the player holds G next to them
func refill_lantern(amount: float) -> void:
	if _dead:
		return
	fuel = minf(fuel + amount, 1.0)


func _ground_model() -> void:
	if model == null: return

	var target_y := _collision_bottom_y() + ground_offset
	var lowest := INF
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or not mi.visible:
			continue
		var box: AABB = mi.global_transform * mi.get_aabb()
		lowest = minf(lowest, box.position.y)

	if lowest == INF:
		push_warning("Couldn't find any meshes under CharacterModel to ground.")
		return

	model.global_position.y += target_y - lowest
	print("Model grounded. Shifted by ", target_y - lowest, " units.")


func _collision_bottom_y() -> float:
	var cols := find_children("*", "CollisionShape3D", true, false)
	if cols.is_empty():
		return global_position.y

	var col := cols[0] as CollisionShape3D
	var s := col.shape
	if s == null:
		return global_position.y

	var half := 0.0
	if s is CapsuleShape3D:
		half = (s as CapsuleShape3D).height * 0.5
	elif s is CylinderShape3D:
		half = (s as CylinderShape3D).height * 0.5
	elif s is BoxShape3D:
		half = (s as BoxShape3D).size.y * 0.5
	elif s is SphereShape3D:
		half = (s as SphereShape3D).radius
	else:
		half = s.get_debug_mesh().get_aabb().size.y * 0.5

	return col.global_position.y - half * col.global_basis.get_scale().y


func _unhandled_input(event: InputEvent) -> void:
	if not controls_enabled:
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		pivot.rotate_y(-event.relative.x * mouse_sensitivity)
		spring_arm.rotation.x -= event.relative.y * mouse_sensitivity
		spring_arm.rotation.x = clampf(
			spring_arm.rotation.x,
			deg_to_rad(min_pitch_deg),
			deg_to_rad(max_pitch_deg)
		)

	# ESC is handled by the pause menu (game_ui.gd)
	if event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# E = random attack
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E:
		_start_attack()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

	_update_lantern(delta)

	# While attacking: stand still and let the attack animation finish
	if _attacking:
		velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)
		_update_footsteps(false, false)
		move_and_slide()
		return

	var move_input := 0.0
	var strafe_input := 0.0
	if controls_enabled:
		move_input = float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S))
		strafe_input = float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))

	var forward := -pivot.global_basis.z
	forward.y = 0.0
	forward = forward.normalized()

	var right := pivot.global_basis.x
	right.y = 0.0
	right = right.normalized()

	var dir := forward * move_input + right * strafe_input

	if dir.length_squared() > 0.0001:
		dir = dir.normalized()

		# Shift + W/A/S/D = run (only if a run clip exists)
		var running := Input.is_physical_key_pressed(KEY_SHIFT) and _run_name != ""
		var current_speed := run_speed if running else speed

		velocity.x = move_toward(velocity.x, dir.x * current_speed, acceleration * delta)
		velocity.z = move_toward(velocity.z, dir.z * current_speed, acceleration * delta)

		if model != null:
			var target_yaw := atan2(dir.x, dir.z) + deg_to_rad(model_yaw_offset_deg)
			model.rotation.y = lerp_angle(model.rotation.y, target_yaw, turn_speed * delta)

		_play(_run_name if running else _walk_name)
		_update_footsteps(true, running)
	else:
		velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)

		_play(_idle_name)
		_update_footsteps(false, false)

	move_and_slide()


func _play(anim_name: String) -> void:
	if anim == null:
		return
	if anim_name == "":
		return

	if anim.current_animation != anim_name or not anim.is_playing():
		var clip_speed := 1.0
		if anim_name == _walk_name:
			clip_speed = walk_anim_speed
		elif anim_name == _run_name:
			clip_speed = run_anim_speed
		anim.play(anim_name, 0.2, clip_speed)

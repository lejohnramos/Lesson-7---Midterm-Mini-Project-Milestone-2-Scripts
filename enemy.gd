extends CharacterBody3D
## Enemy that wanders around where it spawned and chases the player when close.

@export_group("Wandering")
@export var wander_radius := 5.0        # how far from the spawn point it can roam
@export var walk_speed := 1.3
@export var turn_speed := 6.0
@export var acceleration := 20.0
@export var min_idle_time := 1.0        # pause between walks (seconds)
@export var max_idle_time := 4.0
@export var max_walk_time := 6.0        # gives up on a target after this long

@export_group("Chase")
@export var detect_radius := 12.0       # starts chasing when the player is this close
@export var lose_radius := 20.0         # gives up when the player gets this far
@export var chase_speed := 3.4
@export var max_chase_time := 20.0      # gives up after chasing this long (seconds)
@export var stop_distance := 1.2        # stops this close to the player
@export var chase_cooldown := 4.0       # seconds before it can chase again after giving up

@export_group("Damage")
@export var damage_range := 2.0         # drains the player's health when this close
@export var damage_per_second := 10.0

@export_group("Knockback")
@export var knockback_decay := 20.0     # how fast the push slows down (higher = shorter push)
@export var knockback_stun_time := 1.2  # seconds the enemy can't move or hurt you after a hit
@export var knockback_lift := 2.0       # small hop upward when hit

@export_group("Flower Light")
@export var flee_speed := 3.6           # how fast it runs away from a flower's light
@export var flee_margin := 1.0          # keeps running until this far outside the light

@export_group("Model")
@export var model_yaw_offset_deg := 0.0 # change to 180 if the enemy walks backwards

@export_group("Animation")
@export var walk_anim_speed := 1.0
@export var chase_anim_speed := 1.5

@onready var model: Node3D = get_node_or_null("EnemyModel")

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

var _anim: AnimationPlayer
var _idle_name := ""
var _walk_name := ""

var _spawn_pos := Vector3.ZERO
var _target := Vector3.ZERO
var _walking := false
var _chasing := false
var _timer := 0.0
var _cooldown := 0.0
var _chase_timer := 0.0
var _knockback := Vector3.ZERO
var _stun := 0.0
var _fleeing := false
var _player_safe := false
var _player: Node3D
var _ready_done := false


func _ready() -> void:
	# Enemies pass through each other (no collision between enemies)
	for other in get_tree().get_nodes_in_group("enemy"):
		if other != self and other is PhysicsBody3D:
			add_collision_exception_with(other)
			(other as PhysicsBody3D).add_collision_exception_with(self)

	add_to_group("enemy")   # lets the player's attack find enemies
	_find_animations()
	_player = get_tree().get_first_node_in_group("player") as Node3D
	if _player == null:
		push_warning("Enemy: no node in group 'player' found. Add the Character to the 'player' group.")
	# Wait one frame so the spawner can set our position first
	_late_init.call_deferred()


func _late_init() -> void:
	_spawn_pos = global_position
	_ready_done = true
	print("Enemy sees player: ", _player)
	_start_walk()


func _find_animations() -> void:
	var players := find_children("*", "AnimationPlayer", true, false)
	if players.is_empty():
		push_warning("Enemy: no AnimationPlayer found inside the enemy model.")
		return
	_anim = players[0] as AnimationPlayer

	for n in _anim.get_animation_list():
		var lower := String(n).to_lower()
		if _idle_name == "" and "idle" in lower:
			_idle_name = n
		if _walk_name == "" and "walk" in lower:
			_walk_name = n
	# Fall back to a run clip if there is no walk clip
	if _walk_name == "":
		for n in _anim.get_animation_list():
			if "run" in String(n).to_lower():
				_walk_name = n
				break
	# Fall back to idle (e.g. a floating ghost with only one clip)
	if _walk_name == "":
		_walk_name = _idle_name

	if _idle_name != "":
		_anim.get_animation(_idle_name).loop_mode = Animation.LOOP_LINEAR
	if _walk_name != "":
		_anim.get_animation(_walk_name).loop_mode = Animation.LOOP_LINEAR


func _start_idle() -> void:
	_walking = false
	_timer = randf_range(min_idle_time, max_idle_time)
	_play(_idle_name, 1.0)


func _start_walk() -> void:
	# Pick a random point inside the roaming circle, avoiding flower light
	for i in 10:
		var angle := randf() * TAU
		var dist := sqrt(randf()) * wander_radius
		_target = _spawn_pos + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
		if not _is_lit(_target, 0.5):
			break
	_walking = true
	_timer = max_walk_time
	_play(_walk_name, walk_anim_speed)


func _update_chase_state() -> void:
	# Retry finding the player if we don't have it yet
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node3D
		if _player == null:
			_chasing = false
			_player_safe = false
			return

	# Player standing in a flower's light: the enemy loses interest
	var was_safe := _player_safe
	_player_safe = _is_lit(_player.global_position)
	if _player_safe != was_safe:
		print("Player safe in flower light: ", _player_safe)   # temporary debug, you can delete this
	if _player_safe:
		if _chasing:
			_chasing = false
			_cooldown = chase_cooldown
			if not _fleeing:
				_start_walk()
		return

	if _fleeing:
		return

	var d := _flat_distance_to(_player.global_position)
	if not _chasing and _cooldown <= 0.0 and d <= detect_radius:
		_chasing = true
		_chase_timer = max_chase_time
		_play(_walk_name, chase_anim_speed)
	elif _chasing and (d >= lose_radius or _chase_timer <= 0.0):
		_chasing = false
		_cooldown = chase_cooldown   # can't chase again until this runs out
		_start_walk()   # go back to wandering


## Keeps this enemy in the "chasing_enemies" group exactly while it is chasing.
## GameUI watches that group to play the chase sound.
func _sync_chase_group() -> void:
	var should_be_in := _chasing and not _fleeing
	var is_in := is_in_group("chasing_enemies")
	if should_be_in and not is_in:
		add_to_group("chasing_enemies")
	elif not should_be_in and is_in:
		remove_from_group("chasing_enemies")


func _is_lit(pos: Vector3, margin := 0.0) -> bool:
	# True if pos is inside the light of any glow plant
	for p in get_tree().get_nodes_in_group("glow_plant"):
		if p.is_in_light(pos, margin):
			return true
	return false


func _update_flee_state() -> void:
	if _fleeing:
		# Keep running until we are a bit outside the light
		_fleeing = _is_lit(global_position, flee_margin)
		if not _fleeing:
			_start_walk()   # safe again, go back to wandering
	elif _is_lit(global_position):
		_fleeing = true
		_chasing = false
		_play(_walk_name, chase_anim_speed)


func _flee_direction() -> Vector3:
	# Direction pointing away from every flower whose light covers us
	var dir := Vector3.ZERO
	for p in get_tree().get_nodes_in_group("glow_plant"):
		if p.is_in_light(global_position, flee_margin):
			var away: Vector3 = global_position - p.global_position
			away.y = 0.0
			if away.length_squared() > 0.0001:
				dir += away.normalized()
	if dir.length_squared() < 0.0001:
		return Vector3.FORWARD
	return dir.normalized()


func apply_knockback(dir: Vector3, force: float) -> void:
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		return
	_knockback = dir.normalized() * force
	_stun = knockback_stun_time
	velocity.y = knockback_lift


func _damage_player(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	if _player_safe:
		return   # standing in a flower's light: safe
	if _flat_distance_to(_player.global_position) <= damage_range:
		if _player.has_method("take_damage"):
			_player.take_damage(damage_per_second * delta)


func _flat_distance_to(p: Vector3) -> float:
	var v := p - global_position
	v.y = 0.0
	return v.length()


func _face(dir: Vector3, delta: float) -> void:
	if model == null:
		return
	var target_yaw := atan2(dir.x, dir.z) + deg_to_rad(model_yaw_offset_deg)
	model.rotation.y = lerp_angle(model.rotation.y, target_yaw, turn_speed * delta)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

	if not _ready_done:
		move_and_slide()
		return

	# Knocked back: slide away and ignore the AI until the stun ends
	if _stun > 0.0:
		_stun -= delta
		velocity.x = _knockback.x
		velocity.z = _knockback.z
		_knockback = _knockback.move_toward(Vector3.ZERO, knockback_decay * delta)
		move_and_slide()
		return

	if _cooldown > 0.0:
		_cooldown -= delta
	if _chasing:
		_chase_timer -= delta

	_update_flee_state()
	_update_chase_state()
	_sync_chase_group()   # tells GameUI whether this enemy is chasing (for the chase sound)
	_damage_player(delta)

	if _fleeing:
		_do_flee(delta)
	elif _chasing:
		_do_chase(delta)
	elif _walking:
		_do_wander(delta)
	else:
		_do_idle(delta)

	move_and_slide()


func _do_flee(delta: float) -> void:
	var away := _flee_direction()
	velocity.x = move_toward(velocity.x, away.x * flee_speed, acceleration * delta)
	velocity.z = move_toward(velocity.z, away.z * flee_speed, acceleration * delta)
	_face(away, delta)
	_play(_walk_name, chase_anim_speed)


func _do_chase(delta: float) -> void:
	var to_player := _player.global_position - global_position
	to_player.y = 0.0

	if to_player.length() <= stop_distance:
		# Close enough: stand and face the player
		velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)
		if to_player.length_squared() > 0.0001:
			_face(to_player.normalized(), delta)
		return

	var dir := to_player.normalized()
	velocity.x = move_toward(velocity.x, dir.x * chase_speed, acceleration * delta)
	velocity.z = move_toward(velocity.z, dir.z * chase_speed, acceleration * delta)
	_face(dir, delta)
	_play(_walk_name, chase_anim_speed)


func _do_wander(delta: float) -> void:
	var to_target := _target - global_position
	to_target.y = 0.0

	# Arrived, ran out of time, or bumped into something -> rest
	_timer -= delta
	if to_target.length() < 0.5 or _timer <= 0.0 or is_on_wall():
		_start_idle()
		return

	var dir := to_target.normalized()
	velocity.x = move_toward(velocity.x, dir.x * walk_speed, acceleration * delta)
	velocity.z = move_toward(velocity.z, dir.z * walk_speed, acceleration * delta)
	_face(dir, delta)


func _do_idle(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
	velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)

	_timer -= delta
	if _timer <= 0.0:
		_start_walk()


func _play(anim_name: String, clip_speed: float) -> void:
	if _anim == null or anim_name == "":
		return
	if _anim.current_animation != anim_name or not _anim.is_playing():
		_anim.play(anim_name, 0.2, clip_speed)

extends Node3D
## Spawns enemies scattered across the grass platform, away from the edge and walls.

@export var enemy_scene: PackedScene          # drag enemy.tscn here
@export var max_enemies := 10
@export var min_distance_from_player := 6.0   # don't spawn right on the player
@export var min_distance_between := 6.0       # keep enemies spread out
@export var respawn := true                   # refill when enemies are removed
@export var respawn_delay := 5.0
@export var random_count := false             # true = 1..max_enemies, false = exactly max

@export_group("Area")
@export var area_node: Node3D                 # drag "Grass Platform1" here to scatter across the whole platform
@export var edge_margin := 5.0                # stay this far away from the platform edge and walls
@export var spawn_radius := 25.0              # only used if Area Node is empty (circle around this node)
@export var spawn_height := 5.0               # only used if Area Node is empty
@export var ground_check_depth := 20.0        # how far down to look for ground

var _enemies: Array[Node3D] = []
var _player: Node3D
var _area := AABB()
var _has_area := false


func _ready() -> void:
	_player = get_tree().get_first_node_in_group("player") as Node3D
	randomize()
	_initial_spawn.call_deferred()


func _initial_spawn() -> void:
	_compute_area()

	var count := randi_range(1, max_enemies) if random_count else max_enemies
	for i in count:
		_spawn_enemy()

	if respawn:
		var t := Timer.new()
		t.wait_time = respawn_delay
		t.autostart = true
		t.timeout.connect(_refill)
		add_child(t)


func _compute_area() -> void:
	# Bounds of the grass platform, from all the meshes under Area Node
	_has_area = false
	var source := area_node
	if source == null:
		# Not assigned: look for a node named "Grass Platform..." in the scene
		source = get_parent().find_child("Grass Platform*", true, false) as Node3D
	if source == null:
		push_warning("EnemySpawner: no Area Node and no 'Grass Platform' found, using the circle around this node.")
		return
	var meshes := source.find_children("*", "MeshInstance3D", true, false)
	if source is MeshInstance3D:
		meshes.append(source)
	for n in meshes:
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var b: AABB = mi.global_transform * mi.get_aabb()
		if _has_area:
			_area = _area.merge(b)
		else:
			_area = b
			_has_area = true
	if _has_area:
		print("EnemySpawner area: from ", _area.position, " to ", _area.end)
	else:
		push_warning("EnemySpawner: no meshes found under '%s', using the circle instead." % source.name)


func _refill() -> void:
	# Clean out freed enemies, then top back up to the max
	_enemies = _enemies.filter(func(e): return is_instance_valid(e))
	if _enemies.size() < max_enemies:
		_spawn_enemy()


func _spawn_enemy() -> void:
	if enemy_scene == null:
		push_error("EnemySpawner: assign enemy_scene in the Inspector.")
		return

	# Try many random spots until one is valid
	for attempt in 100:
		var pos := _random_ground_point()
		if pos == Vector3.INF:
			continue
		if _player and pos.distance_to(_player.global_position) < min_distance_from_player:
			continue
		if _too_close_to_other_enemy(pos):
			continue

		var enemy := enemy_scene.instantiate() as Node3D
		get_parent().add_child(enemy)          # add to the scene root, not under the spawner
		enemy.global_position = pos
		enemy.rotation.y = randf() * TAU
		_enemies.append(enemy)
		print("Spawned enemy at ", pos)
		return

	push_warning("EnemySpawner: couldn't find a valid spawn spot.")


func _random_ground_point() -> Vector3:
	var origin: Vector3
	var end: Vector3
	if _has_area:
		origin = Vector3(randf_range(_area.position.x, _area.end.x), _area.end.y + 1.0, randf_range(_area.position.z, _area.end.z))
		end = Vector3(origin.x, _area.position.y - ground_check_depth, origin.z)
	else:
		var angle := randf() * TAU
		var dist := sqrt(randf()) * spawn_radius
		origin = global_position + Vector3(cos(angle) * dist, spawn_height, sin(angle) * dist)
		end = origin + Vector3.DOWN * (spawn_height + ground_check_depth)

	var hit := _ray(origin, end)
	if hit.is_empty():
		return Vector3.INF
	if hit.collider is CharacterBody3D:
		return Vector3.INF                      # never spawn on top of the player or another enemy
	if hit.normal.y < 0.8:
		return Vector3.INF                      # too steep (tree trunks, rocks, edges)

	var pos: Vector3 = hit.position
	if not _is_clear_of_edge(pos):
		return Vector3.INF
	return pos + Vector3.UP * 0.1


func _is_clear_of_edge(pos: Vector3) -> bool:
	if edge_margin <= 0.0:
		return true
	for i in 8:
		var a := TAU * i / 8.0
		var dir := Vector3(cos(a), 0.0, sin(a))

		# 1. No wall or other solid object within the margin
		var from := pos + Vector3.UP * 0.8
		var wall := _ray(from, from + dir * edge_margin)
		if not wall.is_empty() and not (wall.collider is CharacterBody3D):
			return false

		# 2. The ground must continue at the same height out to the margin (no edge or drop)
		var p := pos + dir * edge_margin
		var down := _ray(p + Vector3.UP * 2.0, p + Vector3.DOWN * 3.0)
		if down.is_empty() or absf(down.position.y - pos.y) > 0.6:
			return false
	return true


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to)
	return get_world_3d().direct_space_state.intersect_ray(query)


func _too_close_to_other_enemy(pos: Vector3) -> bool:
	for e in _enemies:
		if is_instance_valid(e) and e.global_position.distance_to(pos) < min_distance_between:
			return true
	return false

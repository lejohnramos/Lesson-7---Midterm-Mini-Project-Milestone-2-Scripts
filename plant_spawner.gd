extends Node3D
## Scatters glow plants across the grass platform, away from the edge and walls.

@export var plant_scene: PackedScene          # drag glow_plant.tscn here
@export var plant_count := 6                  # how many plants appear (match plants_to_win in GameUI)
@export var min_distance_from_player := 20.0  # plants never appear this close to the player's start
@export var min_distance_between := 15.0      # minimum gap between plants (relaxed only if the platform is too small)
@export var candidates_per_plant := 12        # higher = plants spread out more evenly, lower = more random

@export_group("Area")
@export var area_node: Node3D                 # drag "Grass Platform1" here to scatter across the whole platform
@export var edge_margin := 5.0                # stay this far away from the platform edge and walls
@export var spawn_radius := 25.0              # only used if Area Node is empty (circle around this node)
@export var spawn_height := 5.0               # only used if Area Node is empty
@export var ground_check_depth := 20.0        # how far down to look for ground
@export var min_ground_flatness := 0.8        # 1.0 = only perfectly flat ground, lower allows slopes

var _player: Node3D
var _positions: Array[Vector3] = []
var _area := AABB()
var _has_area := false


func _ready() -> void:
	_player = get_tree().get_first_node_in_group("player") as Node3D
	randomize()
	_spawn_all.call_deferred()


func _spawn_all() -> void:
	if plant_scene == null:
		push_error("PlantSpawner: assign plant_scene in the Inspector.")
		return

	_compute_area()
	for i in plant_count:
		if not _spawn_plant():
			push_warning("PlantSpawner: only placed %d of %d plants. Lower min_distance_between or edge_margin." % [_positions.size(), plant_count])
			return


func _compute_area() -> void:
	# Bounds of the grass platform, from all the meshes under Area Node
	_has_area = false
	var source := area_node
	if source == null:
		# Not assigned: look for a node named "Grass Platform..." in the scene
		source = get_parent().find_child("Grass Platform*", true, false) as Node3D
	if source == null:
		push_warning("PlantSpawner: no Area Node and no 'Grass Platform' found, using the circle around this node.")
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
		print("PlantSpawner area: from ", _area.position, " to ", _area.end)
	else:
		push_warning("PlantSpawner: no meshes found under '%s', using the circle instead." % source.name)


func _spawn_plant() -> bool:
	# Collect several valid spots and keep the one farthest from the plants already placed.
	# That spreads the plants over the whole platform instead of clumping together.
	var floor_dist := min_distance_between
	for relax in 5:
		var best := Vector3.INF
		var best_score := -1.0
		var found := 0

		for attempt in 150:
			var pos := _random_ground_point()
			if pos == Vector3.INF:
				continue
			if _player and pos.distance_to(_player.global_position) < min_distance_from_player:
				continue

			var score := _nearest_plant_distance(pos)
			if score < floor_dist:
				continue

			found += 1
			if score > best_score:
				best_score = score
				best = pos
			if found >= candidates_per_plant:
				break

		if best != Vector3.INF:
			var plant := plant_scene.instantiate() as Node3D
			get_parent().add_child(plant)          # add to the scene root, not under the spawner
			plant.global_position = best
			plant.rotation.y = randf() * TAU
			_positions.append(best)
			print("Spawned plant at ", best)
			return true

		floor_dist *= 0.75   # platform too crowded: allow plants a bit closer and try again
	return false


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
		return Vector3.INF                      # never put a plant on top of the player or an enemy
	if hit.normal.y < min_ground_flatness:
		return Vector3.INF                      # too steep (tree trunks, rocks, edges)

	var pos: Vector3 = hit.position
	if not _is_clear_of_edge(pos):
		return Vector3.INF
	return pos


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


func _nearest_plant_distance(pos: Vector3) -> float:
	# Distance to the closest plant already placed (a random big number if there are none yet)
	if _positions.is_empty():
		return 1000.0 + randf()
	var nearest := INF
	for p in _positions:
		nearest = minf(nearest, p.distance_to(pos))
	return nearest

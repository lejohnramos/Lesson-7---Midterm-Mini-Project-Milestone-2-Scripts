extends Node3D
## Scatters pages randomly across the grass platform. Each page either lies on the ground
## or sticks to a surface (tree trunk, rock, bush, wall) and faces away from it.
## No Marker3D nodes needed.

@export var page_scene: PackedScene     # drag Paper.glb (or Paper.tscn) here
@export var page_count := 10            # how many pages appear each game
@export var pickup_radius := 1.5        # how close you must be to a page to press F on it
@export var page_model_scale := 1.0
@export var visual_rotation_degrees := Vector3.ZERO  # fix the model's facing if it looks wrong on walls (e.g. try x = 90 or -90)

@export_group("Area")
@export var area_node: Node3D                 # drag "Grass Platform1" here to scatter across the whole platform
@export var edge_margin := 5.0                # stay this far away from the platform edge
@export var min_distance_from_player := 10.0  # pages never appear this close to the player's start
@export var min_distance_between := 12.0      # minimum gap between pages (relaxed only if the platform is too small)
@export var candidates_per_page := 12         # higher = pages spread out more evenly, lower = more random
@export var spawn_radius := 25.0              # only used if Area Node is empty (circle around this node)
@export var spawn_height := 5.0               # only used if Area Node is empty
@export var ground_check_depth := 20.0        # how far down to look for ground
@export var min_ground_flatness := 0.8        # ground under the spawn point must be at least this flat

@export_group("Surfaces")
@export var wall_chance := 0.7                # chance a page goes on a tree / rock / bush instead of lying on the ground
@export var surface_roots: Array[Node3D] = [] # optional: drag the nodes that hold your trees / rocks / bushes here. Empty = found by name (below)
@export var surface_keywords: PackedStringArray = ["tree", "trunk", "rock", "stone", "boulder", "bush", "shrub"]  # a node with one of these words in its name (or its parent's name) counts
@export var max_surface_slope := 0.7          # 0 = only perfectly vertical surfaces, higher also allows rounded rocks and bushes
@export var search_distance := 4.0            # how far sideways to look for a trunk / rock / bush / wall to stick to
@export var wall_height_min := 0.3            # lowest a page can be stuck on a surface
@export var wall_height_max := 1.4            # highest a page can be stuck (keep it reachable for the player)
@export var wall_tilt_degrees := 15.0         # random tilt on vertical surfaces (0 = perfectly upright)
@export var surface_offset := 0.02            # gap between the paper and the surface it sticks to (small = looks glued on)
@export var lay_beside_height := 0.5          # stuck spots lower than this on a rock/object become "lying on the ground right beside it"
@export var stand_distance := 0.8             # there must be walkable ground this far in front of a stuck page, so the player can reach it
@export var height_above_ground := 0.03       # tiny lift so ground pages don't flicker inside the grass
@export var random_rotation := true           # ground pages spin randomly

@export_group("Look")
@export var paper_color := Color(0.95, 0.85, 0.6)
@export var bob_height := 0.0           # floating motion (0 = pages stay perfectly still)
@export var bob_speed := 2.0

@export_group("Interaction")
@export var interact_key: Key = KEY_F                       # key that picks up a page
@export var interact_action := "interact"                   # optional: if this InputMap action exists, it works too
@export var prompt_text := "Press F to pick up the page"    # shown while you're close enough

@export_group("Sound")
@export var pickup_sound: AudioStream   # drag a paper/pickup sound here (optional)
@export var pickup_volume_db := 0.0

var _pages: Array[Area3D] = []
var _targets: Array[Dictionary] = []   # trees / rocks / bushes pages can stick to
var _tri_cache := {}
var _nearby: Array[Area3D] = []   # pages the player is currently close enough to pick up
var _prompt: Label
var _positions: Array[Vector3] = []
var _player: Node3D
var _area := AABB()
var _has_area := false
var _time := 0.0


func _ready() -> void:
	add_to_group("page_spawner")   # lets GameUI check that enough pages exist
	_player = get_tree().get_first_node_in_group("player") as Node3D
	randomize()
	_build_prompt()
	_spawn_pages.call_deferred()   # wait one frame so the colliders are ready for raycasts


func _build_prompt() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_prompt = Label.new()
	_prompt.text = prompt_text
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 26)
	_prompt.add_theme_color_override("font_outline_color", Color.BLACK)
	_prompt.add_theme_constant_override("outline_size", 8)
	_prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.offset_left = -250.0
	_prompt.offset_right = 250.0
	_prompt.offset_top = -170.0
	_prompt.offset_bottom = -120.0
	_prompt.visible = false
	layer.add_child(_prompt)


func pages_spawned() -> int:
	return _pages.size()


# ---------------------------------------------------------------- choosing spots

func _spawn_pages() -> void:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player") as Node3D
	_compute_area()
	_collect_targets()
	for i in page_count:
		var spot := _find_spot()
		if spot.is_empty():
			push_warning("PageSpawner: only placed %d of %d pages. Lower min_distance_between or edge_margin." % [_positions.size(), page_count])
			return
		_positions.append(spot.pos)
		_make_page(spot)
		print("Spawned page at ", spot.pos, "  (", spot.what, ")")


func _compute_area() -> void:
	# Bounds of the grass platform, from all the meshes under Area Node
	_has_area = false
	var source := area_node
	if source == null:
		source = get_parent().find_child("Grass Platform*", true, false) as Node3D
	if source == null:
		push_warning("PageSpawner: no Area Node and no 'Grass Platform' found, using the circle around this node.")
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
		print("PageSpawner area: from ", _area.position, " to ", _area.end)
	else:
		push_warning("PageSpawner: no meshes found under '%s', using the circle instead." % source.name)


func _find_spot() -> Dictionary:
	# Collect several valid spots and keep the one farthest from the pages already placed.
	var floor_dist := min_distance_between
	for relax in 5:
		var best := {}
		var best_score := -1.0
		var found := 0

		for attempt in 150:
			var spot := _random_spot()
			if spot.is_empty():
				continue
			if _player and spot.pos.distance_to(_player.global_position) < min_distance_from_player:
				continue

			var score := _nearest_page_distance(spot.pos)
			if score < floor_dist:
				continue

			found += 1
			if score > best_score:
				best_score = score
				best = spot
			if found >= candidates_per_page:
				break

		if not best.is_empty():
			return best

		floor_dist *= 0.75   # platform too crowded: allow pages a bit closer and try again
	return {}


func _random_spot() -> Dictionary:
	# Returns {pos, normal, wall, what} or an empty dictionary if nothing valid was found
	if randf() < wall_chance:
		var on_object := _spot_on_object()
		if not on_object.is_empty():
			return on_object

	# Lie on the ground
	var base := _random_ground_point()
	if base == Vector3.INF:
		return {}
	return {"pos": base + Vector3.UP * height_above_ground, "normal": Vector3.UP, "wall": false, "what": "ground"}


# ---------------------------------------------------------------- trees / rocks / bushes

func _collect_targets() -> void:
	# Finds the meshes of your trees, rocks and bushes. Uses the mesh triangles directly,
	# so it works even if those models have no collision shapes.
	_targets.clear()
	var roots: Array[Node] = []
	if surface_roots.is_empty():
		roots.append(get_parent())
	else:
		for r in surface_roots:
			if r != null:
				roots.append(r)

	for root in roots:
		for n in root.find_children("*", "GeometryInstance3D", true, false):
			if is_ancestor_of(n) or _under_character(n):
				continue
			if surface_roots.is_empty() and not _name_matches(n):
				continue
			if n is MeshInstance3D:
				var mi := n as MeshInstance3D
				if mi.mesh != null:
					_add_target(mi.mesh, mi.global_transform, str(mi.name))
			elif n is MultiMeshInstance3D:
				var mmi := n as MultiMeshInstance3D
				var mm := mmi.multimesh
				if mm == null or mm.mesh == null:
					continue
				for i in mini(mm.instance_count, 3000):
					_add_target(mm.mesh, mmi.global_transform * mm.get_instance_transform(i), str(mmi.name))

	print("PageSpawner: found %d tree / rock / bush surfaces to stick pages on." % _targets.size())
	if _targets.is_empty():
		push_warning("PageSpawner: no trees / rocks / bushes found. Drag the nodes that hold them into 'Surface Roots' (Surfaces group), or add their name words to 'Surface Keywords'.")


func _add_target(mesh: Mesh, xf: Transform3D, node_name: String) -> void:
	var box: AABB = xf * mesh.get_aabb()
	if box.size.y < 0.4 or maxf(box.size.x, box.size.z) > 25.0:
		return   # too small (pebble) or huge (ground)
	_targets.append({"mesh": mesh, "xf": xf, "aabb": box, "name": node_name})


func _under_character(n: Node) -> bool:
	var cur := n.get_parent()
	while cur != null:
		if cur is CharacterBody3D:
			return true
		cur = cur.get_parent()
	return false


func _name_matches(n: Node) -> bool:
	var scene_root := get_tree().current_scene
	var cur: Node = n
	while cur != null and cur != scene_root:
		var nm := String(cur.name).to_lower()
		for kw in surface_keywords:
			if kw.to_lower() in nm:
				return true
		cur = cur.get_parent()
	return false


func _triangles(mesh: Mesh) -> TriangleMesh:
	if not _tri_cache.has(mesh):
		_tri_cache[mesh] = mesh.generate_triangle_mesh()
	return _tri_cache[mesh]


func _inside_area(p: Vector3) -> bool:
	if _has_area:
		return p.x >= _area.position.x + edge_margin and p.x <= _area.end.x - edge_margin \
			and p.z >= _area.position.z + edge_margin and p.z <= _area.end.z - edge_margin
	return Vector2(p.x - global_position.x, p.z - global_position.z).length() <= spawn_radius


func _spot_on_object() -> Dictionary:
	if _targets.is_empty():
		return _spot_by_physics()

	for attempt in 20:
		var t: Dictionary = _targets.pick_random()
		var box: AABB = t.aabb
		var center := box.get_center()
		if not _inside_area(center):
			continue

		# A random height on the object, low enough for the player to reach
		var hmax := minf(wall_height_max, box.size.y * 0.9)
		var hmin := minf(wall_height_min, hmax * 0.5)
		var y := box.position.y + randf_range(hmin, hmax)

		# Shoot a line from a random side toward the middle of the object and find where it touches
		var a := randf() * TAU
		var dir := Vector3(cos(a), 0.0, sin(a))
		var reach := maxf(box.size.x, box.size.z) * 0.5 + 1.0
		var to := Vector3(center.x, y, center.z)
		var from := to + dir * reach

		var tri := _triangles(t.mesh)
		if tri == null:
			continue
		var xf: Transform3D = t.xf
		var inv := xf.affine_inverse()
		var hit: Dictionary = tri.intersect_segment(inv * from, inv * to)
		if hit.is_empty():
			continue

		var pos: Vector3 = xf * (hit.position as Vector3)
		var n: Vector3 = (xf.basis.inverse().transposed() * (hit.normal as Vector3)).normalized()
		if n.dot((to - from).normalized()) > 0.0:
			n = -n   # make sure it faces outward
		if absf(n.y) > max_surface_slope:
			continue   # top or bottom of the object, not a side

		# The player must be able to walk up to it: flat ground right in front of the surface
		var flat := Vector3(n.x, 0.0, n.z)
		if flat.length() < 0.2:
			continue
		flat = flat.normalized()
		var stand := _ground_below(pos + flat * stand_distance)
		if stand == Vector3.INF:
			continue
		var height := pos.y - stand.y
		if height < -0.1 or height > wall_height_max + 0.3:
			continue

		# Very low on the object: lay the page on the ground right beside it
		if height < lay_beside_height:
			var beside := _ground_below(pos + flat * 0.3)
			if beside != Vector3.INF:
				return {"pos": beside + Vector3.UP * height_above_ground, "normal": Vector3.UP, "wall": false, "what": "beside " + str(t.name)}

		return {"pos": pos + n * surface_offset, "normal": n, "wall": true, "what": "on " + str(t.name)}
	return {}


func _spot_by_physics() -> Dictionary:
	# Fallback when no tree / rock / bush meshes were found: use collision shapes instead
	var base := _random_ground_point()
	if base == Vector3.INF:
		return {}
	for i in 8:
		var a := randf() * TAU
		var dir := Vector3(cos(a), 0.0, sin(a))
		var from := base + Vector3.UP * randf_range(wall_height_min, wall_height_max)
		var hit := _ray(from, from + dir * search_distance)
		if hit.is_empty() or hit.collider is CharacterBody3D:
			continue
		var n: Vector3 = hit.normal
		if absf(n.y) > max_surface_slope:
			continue
		var pos: Vector3 = hit.position
		var flat := Vector3(n.x, 0.0, n.z)
		if flat.length() < 0.2:
			continue
		flat = flat.normalized()
		var stand := _ground_below(pos + flat * stand_distance)
		if stand == Vector3.INF:
			continue
		var height := pos.y - stand.y
		if height < -0.1 or height > wall_height_max + 0.3:
			continue
		return {"pos": pos + n * surface_offset, "normal": n, "wall": true, "what": "on a collider"}
	return {}


func _ground_below(p: Vector3) -> Vector3:
	# Flat, walkable ground under a point (Vector3.INF if none)
	var hit := _ray(p + Vector3.UP * 0.5, p + Vector3.DOWN * (wall_height_max + 1.5))
	if hit.is_empty() or hit.collider is CharacterBody3D:
		return Vector3.INF
	if hit.normal.y < min_ground_flatness:
		return Vector3.INF
	return hit.position


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
		return Vector3.INF
	if hit.normal.y < min_ground_flatness:
		return Vector3.INF

	var pos: Vector3 = hit.position
	if not _ground_continues(pos):
		return Vector3.INF
	return pos


func _ground_continues(pos: Vector3) -> bool:
	# The ground must continue at the same height out to the margin (no platform edge or drop)
	if edge_margin <= 0.0:
		return true
	for i in 8:
		var a := TAU * i / 8.0
		var p := pos + Vector3(cos(a), 0.0, sin(a)) * edge_margin
		var down := _ray(p + Vector3.UP * 2.0, p + Vector3.DOWN * 3.0)
		if down.is_empty() or absf(down.position.y - pos.y) > 0.6:
			return false
	return true


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to)
	return get_world_3d().direct_space_state.intersect_ray(query)


func _nearest_page_distance(pos: Vector3) -> float:
	if _positions.is_empty():
		return 1000.0 + randf()
	var nearest := INF
	for p in _positions:
		nearest = minf(nearest, p.distance_to(pos))
	return nearest


# ---------------------------------------------------------------- the page itself

func _page_basis(n: Vector3, on_surface: bool) -> Basis:
	# The page's up axis (Y) points away from the surface, then it gets a random spin
	var ref := Vector3.FORWARD if absf(n.y) > 0.9 else Vector3.UP
	var x := ref.cross(n).normalized()
	var z := x.cross(n).normalized()
	var b := Basis(x, n, z)
	if on_surface:
		b = b.rotated(n, deg_to_rad(randf_range(-wall_tilt_degrees, wall_tilt_degrees)))
	elif random_rotation:
		b = b.rotated(n, randf() * TAU)
	return b


func _make_page(spot: Dictionary) -> void:
	var page := Area3D.new()
	page.collision_layer = 0
	page.collision_mask = 0xFFFFFFFF   # notice any body, we filter for the player below

	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = pickup_radius
	shape.shape = sphere
	page.add_child(shape)

	# The visible paper: your model, or a plain cream sheet if no model is assigned
	var visual: Node3D
	if page_scene != null:
		visual = page_scene.instantiate() as Node3D
		visual.rotation_degrees = visual_rotation_degrees
	else:
		var mi := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.45, 0.6)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = paper_color
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		quad.material = mat
		mi.mesh = quad
		mi.rotation_degrees.x = -90.0   # lie flat
		visual = mi
	visual.scale = Vector3.ONE * page_model_scale
	page.add_child(visual)
	page.set_meta("visual", visual)

	add_child(page)
	page.global_transform = Transform3D(_page_basis(spot.normal, spot.wall), spot.pos)
	page.body_entered.connect(_on_page_body_entered.bind(page))
	page.body_exited.connect(_on_page_body_exited.bind(page))
	_pages.append(page)


func _process(delta: float) -> void:
	_time += delta
	if _prompt != null:
		_prompt.visible = not _nearby.is_empty()
	if bob_height <= 0.0:
		return
	for p in _pages:
		if is_instance_valid(p):
			var v := p.get_meta("visual") as Node3D
			v.position.y = sin(_time * bob_speed + p.get_instance_id() * 0.001) * bob_height


func _on_page_body_entered(body: Node3D, page: Area3D) -> void:
	if body.is_in_group("player") and _pages.has(page) and not _nearby.has(page):
		_nearby.append(page)


func _on_page_body_exited(body: Node3D, page: Area3D) -> void:
	if body.is_in_group("player"):
		_nearby.erase(page)


func _unhandled_input(event: InputEvent) -> void:
	if _nearby.is_empty():
		return
	if _player != null and not _player.get("controls_enabled"):
		return   # debug camera is active
	var pressed := false
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == interact_key:
		pressed = true
	elif InputMap.has_action(interact_action) and event.is_action_pressed(interact_action):
		pressed = true
	if not pressed:
		return
	_collect(_closest_nearby())
	get_viewport().set_input_as_handled()


func _closest_nearby() -> Area3D:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player") as Node3D
	var best: Area3D = _nearby[0]
	if _player != null:
		var best_d := INF
		for p in _nearby:
			var d := p.global_position.distance_to(_player.global_position)
			if d < best_d:
				best_d = d
				best = p
	return best


func _collect(page: Area3D) -> void:
	if not _pages.has(page):
		return
	_nearby.erase(page)
	_pages.erase(page)
	page.queue_free()
	_play_pickup_sound()

	var ui := get_tree().get_first_node_in_group("game_ui")
	if ui != null and ui.has_method("page_collected"):
		ui.page_collected()


func _play_pickup_sound() -> void:
	if pickup_sound == null:
		return
	var p := AudioStreamPlayer.new()
	p.stream = pickup_sound
	p.volume_db = pickup_volume_db
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()

extends CanvasLayer
## Start menu, pause menu (ESC) and game over screen. Everything is built in code.

@export var game_title := "MY GAME"
@export var plants_to_win := 6          # flowers you must light to escape
@export var pages_to_win := 10         # pages you must collect to escape (0 = no pages needed)
@export var win_delay := 1.5            # seconds between finishing the objective and the win screen

@export_group("Objective")
## {n} = number of flowers, {r} = number of pages
@export var objective_text := "Light {n} flowers and collect {r} pages to escape!"
## Shown on the start screen under the title
@export_multiline var instructions := "Something is hunting you in the dark.\nStand in a flower's light to stay safe.\nLight every flower and find every page to escape."

@export_group("Chase Sound")
@export var chase_sound: AudioStream    # drag your chase sound here
@export var chase_volume_db := 0.0      # volume (lower = quieter, e.g. -6)
@export var chase_fade_time := 0.5      # seconds to fade in and out
@export var loop_chase_sound := true    # true = repeats while chased, false = plays once per chase

enum State { START, PLAYING, PAUSED, OVER, WON }

# Stays true across scene reloads, so restarting skips the start screen
static var skip_start_menu := false

var _state := State.START
var _start_menu: Control
var _pause_menu: Control
var _over_menu: Control
var _won_menu: Control
var _hud_label: Label
var _lit_count := 0
var _page_count := 0
var _winning := false

var _chase_player: AudioStreamPlayer
var _chase_wanted := false
var _chase_vol := 0.0                  # 0 = silent, 1 = full volume (used for fading)


func _ready() -> void:
	add_to_group("game_ui")
	process_mode = Node.PROCESS_MODE_ALWAYS   # keep working while the game is paused
	layer = 10

	_build_hud()   # built first so the menus are drawn on top of it
	_build_chase_sound()

	_start_menu = _build_menu(game_title, [
		["Start Game", _on_start],
		["Quit", _on_quit],
	], "%s\n\nObjective: %s" % [instructions, _objective()])
	_pause_menu = _build_menu("Paused", [
		["Resume", _on_resume],
		["Restart", _on_restart],
		["Quit", _on_quit],
	], "Objective: " + _objective())
	_over_menu = _build_menu("Game Over", [
		["Restart", _on_restart],
		["Quit", _on_quit],
	], "Objective: " + _objective())
	_won_menu = _build_menu("You Escaped!", [
		["Play Again", _on_restart],
		["Quit", _on_quit],
	])

	# Wait a frame so the player's _ready has finished first
	_begin.call_deferred()


func _begin() -> void:
	# Let the spawners place their enemies, flowers and pages before the game gets paused
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame

	var total := get_tree().get_nodes_in_group("glow_plant").size()
	if total < plants_to_win:
		push_warning("GameUI: only %d glow plants in the scene but %d are needed to win. Add more plants." % [total, plants_to_win])

	var pages := _count_pages()
	if pages < pages_to_win:
		push_warning("GameUI: only %d pages in the scene but %d are needed to win. Check your PageSpawner." % [pages, pages_to_win])

	if skip_start_menu:
		skip_start_menu = false
		_set_state(State.PLAYING)
	else:
		_set_state(State.START)


func _count_pages() -> int:
	# Pages are Area3D nodes created by the PageSpawner
	var spawner := get_tree().get_first_node_in_group("page_spawner")
	if spawner == null:
		return 0
	if spawner.has_method("pages_spawned"):
		return spawner.pages_spawned()
	return spawner.get_child_count()


func _set_state(new_state: State) -> void:
	_state = new_state
	_start_menu.visible = (new_state == State.START)
	_pause_menu.visible = (new_state == State.PAUSED)
	_over_menu.visible = (new_state == State.OVER)
	_won_menu.visible = (new_state == State.WON)
	_hud_label.visible = (new_state == State.PLAYING or new_state == State.PAUSED)

	var playing := (new_state == State.PLAYING)
	get_tree().paused = not playing
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if playing else Input.MOUSE_MODE_VISIBLE


## Called by the player when health reaches 0
func show_game_over() -> void:
	_set_state(State.OVER)


## Called by a glow plant the moment the player lights it
func plant_lit() -> void:
	_lit_count += 1
	_update_hud()
	_check_win()


## Called by the PageSpawner when the player picks up a page
func page_collected() -> void:
	_page_count += 1
	_update_hud()
	_check_win()


func _goals_met() -> bool:
	return _lit_count >= plants_to_win and _page_count >= pages_to_win


func _check_win() -> void:
	if not _goals_met() or _winning or _state != State.PLAYING:
		return
	_winning = true
	await get_tree().create_timer(win_delay).timeout   # let the last thing glow for a moment
	if _state != State.OVER:
		_set_state(State.WON)


func _objective() -> String:
	return objective_text.replace("{n}", str(plants_to_win)).replace("{r}", str(pages_to_win))


func _build_chase_sound() -> void:
	# ONE player for the whole game, so the sound never stacks no matter how many enemies chase
	if chase_sound == null:
		return
	_chase_player = AudioStreamPlayer.new()
	_chase_player.stream = chase_sound
	_chase_player.volume_db = -80.0
	_chase_player.finished.connect(_on_chase_sound_finished)
	add_child(_chase_player)


func _on_chase_sound_finished() -> void:
	if loop_chase_sound and _chase_wanted:
		_chase_player.play()


func _process(delta: float) -> void:
	_update_chase_sound(delta)


func _update_chase_sound(delta: float) -> void:
	if _chase_player == null:
		return

	# Freeze the sound while the game is paused
	if _state == State.PAUSED:
		_chase_player.stream_paused = true
		return
	_chase_player.stream_paused = false

	# Enemies that are chasing are in the "chasing_enemies" group
	var want := _state == State.PLAYING and not get_tree().get_nodes_in_group("chasing_enemies").is_empty()
	if want and not _chase_wanted:
		_chase_wanted = true
		if not _chase_player.playing:
			_chase_player.play()   # starts once, even if several enemies spot you
	elif not want and _chase_wanted:
		_chase_wanted = false

	# Fade in while chased, fade out when nobody chases anymore
	var target := 1.0 if _chase_wanted else 0.0
	_chase_vol = move_toward(_chase_vol, target, delta / maxf(chase_fade_time, 0.01))
	_chase_player.volume_db = linear_to_db(maxf(_chase_vol, 0.0001)) + chase_volume_db
	if _chase_vol <= 0.0 and not _chase_wanted and _chase_player.playing:
		_chase_player.stop()


func _build_hud() -> void:
	_hud_label = Label.new()
	_hud_label.position = Vector2(20, 72)   # just under the life and fuel bars
	_hud_label.add_theme_font_size_override("font_size", 20)
	_hud_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud_label.add_theme_constant_override("outline_size", 6)
	_hud_label.visible = false
	add_child(_hud_label)
	_update_hud()


func _update_hud() -> void:
	var goal := _objective()
	if _goals_met():
		goal = "You have everything - you're escaping!"
	var text := "Objective: %s\nFlowers lit: %d / %d" % [goal, _lit_count, plants_to_win]
	if pages_to_win > 0:
		text += "\nPages found: %d / %d" % [_page_count, pages_to_win]
	_hud_label.text = text


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):   # ESC
		if _state == State.PLAYING:
			_set_state(State.PAUSED)
		elif _state == State.PAUSED:
			_set_state(State.PLAYING)
		get_viewport().set_input_as_handled()


func _on_start() -> void:
	_set_state(State.PLAYING)


func _on_resume() -> void:
	_set_state(State.PLAYING)


func _on_restart() -> void:
	skip_start_menu = true
	get_tree().paused = false
	get_tree().reload_current_scene()


func _on_quit() -> void:
	get_tree().quit()


func _build_menu(title: String, buttons: Array, subtitle := "") -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.visible = false

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.7)
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	center.add_child(box)

	var label := Label.new()
	label.text = title
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 56)
	box.add_child(label)

	# Optional text under the title (instructions / objective)
	if subtitle != "":
		var sub := Label.new()
		sub.text = subtitle
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sub.custom_minimum_size = Vector2(560, 0)
		sub.add_theme_font_size_override("font_size", 22)
		box.add_child(sub)

	for b in buttons:
		var btn := Button.new()
		btn.text = b[0]
		btn.custom_minimum_size = Vector2(240, 48)
		btn.pressed.connect(b[1])
		box.add_child(btn)

	add_child(root)
	return root

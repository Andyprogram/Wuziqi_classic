extends Node2D
## 五子棋主逻辑：状态机、回合控制、胜负判定、AI 线程调度、程序化 UI。（v3 警告清理）

const SIZE := 15
const EMPTY := 0
const BLACK := 1
const WHITE := 2
const DIRECTIONS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, -1)]
const STATS_PATH := "user://gomoku_stats.cfg"

enum Phase { PLAYER, AI, OVER }
enum Side { RANDOM, BLACK, WHITE }

@onready var board_node: Node2D = $Board
@onready var ui_layer: CanvasLayer = $UI

var cells: Array = []
var phase := Phase.PLAYER
var player_color := BLACK
var ai_color := WHITE
var side_setting: int = Side.RANDOM
var difficulty: int = GomokuAI.Difficulty.MEDIUM
var ai: GomokuAI = null
var win_line: Array = []
var win_time := 0.0
var history: Array = []              # 落子历史（{x,y,p}），悔棋用
var _undo_button: Button = null
var _stats_label: Label = null
var stats := {"total": 0, "player_wins": 0, "ai_wins": 0, "draws": 0}

# AI 后台线程（WorkerThreadPool）
var _gen := 0
var _pending_move := Vector2i(-1, -1)
var _pending_ready := false

# UI 引用
var _root: Control = null
var _status_label: Label = null
var _result_panel: PanelContainer = null
var _result_label: Label = null
var _diff_group := ButtonGroup.new()
var _side_group := ButtonGroup.new()
var _diff_buttons := {}
var _side_buttons := {}


# ---------- 静态规则（可脱离节点单测） ----------

static func check_win_on(board: Array, x: int, y: int, p: int) -> Array:
	for d in DIRECTIONS:
		var line: Array = [Vector2i(x, y)]
		var c: Vector2i = Vector2i(x, y) + d
		while c.x >= 0 and c.x < board.size() and c.y >= 0 and c.y < board.size() and board[c.x][c.y] == p:
			line.append(c)
			c += d
		c = Vector2i(x, y) - d
		while c.x >= 0 and c.x < board.size() and c.y >= 0 and c.y < board.size() and board[c.x][c.y] == p:
			line.append(c)
			c -= d
		if line.size() >= 5:
			return line
	return []


static func is_full(board: Array) -> bool:
	for y in range(board.size()):
		for x in range(board.size()):
			if board[x][y] == EMPTY:
				return false
	return true


static func new_board() -> Array:
	var b := []
	for _i in range(SIZE):
		var row := []
		row.resize(SIZE)
		row.fill(EMPTY)
		b.append(row)
	return b


# ---------- 生命周期 ----------

func _ready() -> void:
	ai = GomokuAI.new()
	cells = new_board()
	board_node.setup(self)
	_build_ui()
	_load_stats()
	_update_stats_label()
	new_game(side_setting)


func _process(_delta: float) -> void:
	if _pending_ready and phase == Phase.AI:
		_pending_ready = false
		_apply_move(_pending_move.x, _pending_move.y, ai_color, true)
	_update_undo_state()


func _unhandled_input(event: InputEvent) -> void:
	if phase != Phase.PLAYER:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var cell: Vector2i = board_node.pixel_to_cell(event.position)
		if cell != Vector2i(-1, -1):
			try_place(cell.x, cell.y)


# ---------- 对局流程 ----------

func new_game(side: int) -> void:
	_gen += 1
	_pending_ready = false
	_pending_move = Vector2i(-1, -1)
	cells = new_board()
	win_line = []
	win_time = 0.0
	history.clear()
	board_node.reset()
	if side == Side.RANDOM:
		player_color = BLACK if randi() % 2 == 0 else WHITE
	else:
		player_color = side
	ai_color = WHITE if player_color == BLACK else BLACK
	_hide_result()
	if ai_color == BLACK:
		phase = Phase.AI
		_update_status("AI 执黑先行…")
		_run_ai()
	else:
		phase = Phase.PLAYER
		_update_status("轮到你了，执%s" % ("黑" if player_color == BLACK else "白"))
	board_node.queue_redraw()


func try_place(col: int, row: int) -> void:
	if phase != Phase.PLAYER:
		return
	if col < 0 or col >= SIZE or row < 0 or row >= SIZE:
		return
	if cells[col][row] != EMPTY:
		return
	_apply_move(col, row, player_color, false)


func _apply_move(x: int, y: int, p: int, by_ai: bool) -> void:
	cells[x][y] = p
	history.append({"x": x, "y": y, "p": p})
	board_node.notify_placed(x, y)
	var line := check_win_on(cells, x, y, p)
	if line.size() >= 5:
		game_over(p, line)
		return
	if is_full(cells):
		game_over(0, [])
		return
	if by_ai:
		phase = Phase.PLAYER
		_update_status("轮到你了，执%s" % ("黑" if player_color == BLACK else "白"))
	else:
		phase = Phase.AI
		_update_status("AI 思考中…")
		_run_ai()


func game_over(w: int, line: Array) -> void:
	phase = Phase.OVER
	win_line = line
	win_time = Time.get_ticks_msec() / 1000.0
	board_node.queue_redraw()
	_record_result(w)
	_update_stats_label()
	if w == 0:
		_update_status("平局", Color(0.78, 0.75, 0.70))
		_show_result("平 局", Color(0.88, 0.85, 0.80))
	elif w == player_color:
		_update_status("你赢了！", Color(1.0, 0.86, 0.35))
		_show_result("你赢了！", Color(1.0, 0.86, 0.35))
	else:
		_update_status("你输了", Color(0.82, 0.60, 0.55))
		_show_result("你输了", Color(0.88, 0.84, 0.78))


# ---------- 悔棋 ----------

## 撤回一整轮到玩家回合：弹掉尾部所有 AI 落子，再弹一步玩家落子。
## 纯逻辑静态函数，便于单元测试。
static func compute_undo(hist: Array, ai_col: int) -> Array:
	var h := hist.duplicate()
	while not h.is_empty() and h.back().p == ai_col:
		h.pop_back()
	if not h.is_empty():
		h.pop_back()
	return h


func undo_move() -> void:
	if phase != Phase.PLAYER and phase != Phase.OVER:
		return
	var new_hist := compute_undo(history, ai_color)
	if new_hist.size() == history.size():
		return  # 无可悔之棋
	_gen += 1  # 作废任何在途 AI 结果
	_pending_ready = false
	history = new_hist
	_rebuild_cells_from_history()
	win_line = []
	_hide_result()
	if history.is_empty() and ai_color == BLACK:
		# 悔到空盘且 AI 执黑：由 AI 重新开局
		phase = Phase.AI
		_update_status("AI 执黑先行…")
		_run_ai()
	else:
		phase = Phase.PLAYER
		_update_status("轮到你了，执%s（已悔棋）" % ("黑" if player_color == BLACK else "白"))
	board_node.queue_redraw()
	_update_undo_state()


func _rebuild_cells_from_history() -> void:
	cells = new_board()
	for mv in history:
		cells[mv.x][mv.y] = mv.p


func _update_undo_state() -> void:
	if _undo_button == null:
		return
	var can_undo := (phase == Phase.PLAYER or phase == Phase.OVER) and not history.is_empty()
	_undo_button.disabled = not can_undo


# ---------- 对局统计（胜率，user:// 持久化） ----------

## 一次对局结束后累计结果。纯逻辑静态函数，便于单元测试。
static func apply_result(in_stats: Dictionary, w: int, p_color: int) -> Dictionary:
	var s := in_stats.duplicate()
	s.total += 1
	if w == p_color:
		s.player_wins += 1
	elif w == 0:
		s.draws += 1
	else:
		s.ai_wins += 1
	return s


func _record_result(w: int) -> void:
	stats = apply_result(stats, w, player_color)
	_save_stats()


func _load_stats() -> void:
	var cf := ConfigFile.new()
	if cf.load(STATS_PATH) == OK:
		stats.total = int(cf.get_value("stats", "total", 0))
		stats.player_wins = int(cf.get_value("stats", "player_wins", 0))
		stats.ai_wins = int(cf.get_value("stats", "ai_wins", 0))
		stats.draws = int(cf.get_value("stats", "draws", 0))


func _save_stats() -> void:
	var cf := ConfigFile.new()
	cf.set_value("stats", "total", int(stats.total))
	cf.set_value("stats", "player_wins", int(stats.player_wins))
	cf.set_value("stats", "ai_wins", int(stats.ai_wins))
	cf.set_value("stats", "draws", int(stats.draws))
	cf.save(STATS_PATH)


func _reset_stats() -> void:
	stats = {"total": 0, "player_wins": 0, "ai_wins": 0, "draws": 0}
	_save_stats()
	_update_stats_label()


func _update_stats_label() -> void:
	if _stats_label == null:
		return
	var total := int(stats.total)
	var rate := 0.0
	if total > 0:
		rate = int(stats.player_wins) * 100.0 / total
	_stats_label.text = "对局 %d · 胜 %d (%.0f%%) · 负 %d · 平 %d" % [
		total, int(stats.player_wins), rate, int(stats.ai_wins), int(stats.draws)]


# ---------- AI 调度（WorkerThreadPool 后台计算，主线程应用结果） ----------

func _run_ai() -> void:
	if phase != Phase.AI:
		return
	_update_status("AI 思考中…")
	var gen := _gen
	await get_tree().create_timer(0.22).timeout
	if phase != Phase.AI or gen != _gen:
		return
	var board_copy := cells.duplicate(true)
	var ai_col := ai_color
	var diff := difficulty
	WorkerThreadPool.add_task(_ai_worker.bind(board_copy, ai_col, diff, gen))


func _ai_worker(board_copy: Array, ai_col: int, diff: int, gen: int) -> void:
	var move := ai.get_move(board_copy, ai_col, diff)
	call_deferred("_notify_ai_result", move, gen)


func _notify_ai_result(move: Vector2i, gen: int) -> void:
	if gen != _gen or phase != Phase.AI:
		return  # 过期结果（已重开 / 已结束），丢弃
	_pending_move = move
	_pending_ready = true


# ---------- 设置 ----------

func set_difficulty(d: int) -> void:
	difficulty = d


func set_side_setting(s: int) -> void:
	side_setting = s


# ---------- UI 构建 ----------

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(_root)

	# 顶部面板
	var top := _make_panel()
	top.anchor_left = 0.5
	top.anchor_right = 0.5
	top.anchor_top = 0.0
	top.anchor_bottom = 0.0
	top.grow_horizontal = Control.GROW_DIRECTION_BOTH
	top.offset_top = 12.0
	_root.add_child(top)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	top.add_child(vbox)

	# 标题行 + 状态
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 14)
	vbox.add_child(title_row)
	var title := Label.new()
	title.text = "五子棋"
	title.add_theme_font_size_override("font_size", 22)
	title_row.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(spacer)
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 16)
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_row.add_child(_status_label)

	# 控制行：难度 / 先手 / 重开
	var ctrl := HBoxContainer.new()
	ctrl.add_theme_constant_override("separation", 10)
	vbox.add_child(ctrl)

	ctrl.add_child(_make_caption("难度"))
	ctrl.add_child(_make_diff_button(GomokuAI.Difficulty.EASY, "简单"))
	ctrl.add_child(_make_diff_button(GomokuAI.Difficulty.MEDIUM, "中等"))
	ctrl.add_child(_make_diff_button(GomokuAI.Difficulty.HARD, "较强"))

	var vsep := Control.new()
	vsep.custom_minimum_size = Vector2(12, 0)
	ctrl.add_child(vsep)

	ctrl.add_child(_make_caption("先手"))
	ctrl.add_child(_make_side_button(Side.RANDOM, "随机"))
	ctrl.add_child(_make_side_button(Side.BLACK, "执黑"))
	ctrl.add_child(_make_side_button(Side.WHITE, "执白"))

	var vsep2 := Control.new()
	vsep2.custom_minimum_size = Vector2(12, 0)
	ctrl.add_child(vsep2)

	var undo_btn := Button.new()
	undo_btn.text = "悔棋"
	undo_btn.custom_minimum_size = Vector2(64, 34)
	undo_btn.pressed.connect(undo_move)
	ctrl.add_child(undo_btn)
	_undo_button = undo_btn

	var vsep3 := Control.new()
	vsep3.custom_minimum_size = Vector2(12, 0)
	ctrl.add_child(vsep3)

	var restart := Button.new()
	restart.text = "重新开始"
	restart.custom_minimum_size = Vector2(96, 34)
	restart.pressed.connect(func(): new_game(side_setting))
	ctrl.add_child(restart)

	# 统计行
	var stats_row := HBoxContainer.new()
	stats_row.add_theme_constant_override("separation", 10)
	vbox.add_child(stats_row)
	_stats_label = Label.new()
	_stats_label.add_theme_font_size_override("font_size", 13)
	_stats_label.add_theme_color_override("font_color", Color(0.72, 0.70, 0.65))
	stats_row.add_child(_stats_label)
	var reset_stats := Button.new()
	reset_stats.text = "清零"
	reset_stats.custom_minimum_size = Vector2(48, 24)
	reset_stats.pressed.connect(_reset_stats)
	stats_row.add_child(reset_stats)

	# 结果面板
	_result_panel = _make_panel()
	_result_panel.anchor_left = 0.5
	_result_panel.anchor_right = 0.5
	_result_panel.anchor_top = 0.5
	_result_panel.anchor_bottom = 0.5
	_result_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_result_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_result_panel.visible = false
	_result_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_result_panel)

	var rv := VBoxContainer.new()
	rv.add_theme_constant_override("separation", 14)
	_result_panel.add_child(rv)
	_result_label = Label.new()
	_result_label.add_theme_font_size_override("font_size", 30)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rv.add_child(_result_label)
	var again := Button.new()
	again.text = "再来一局"
	again.custom_minimum_size = Vector2(180, 42)
	again.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	again.pressed.connect(func(): new_game(side_setting))
	rv.add_child(again)

	# 默认选项高亮
	_diff_buttons[difficulty].button_pressed = true
	_side_buttons[side_setting].button_pressed = true


func _make_panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.09, 0.08, 0.94)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	p.add_theme_stylebox_override("panel", sb)
	return p


func _make_caption(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.78, 0.75, 0.70))
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _make_toggle(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(64, 34)
	return b


func _make_diff_button(d: int, label: String) -> Button:
	var b := _make_toggle(label)
	b.button_group = _diff_group
	b.toggled.connect(func(on: bool, dd := d): if on: set_difficulty(dd))
	_diff_buttons[d] = b
	return b


func _make_side_button(s: int, label: String) -> Button:
	var b := _make_toggle(label)
	b.button_group = _side_group
	b.toggled.connect(func(on: bool, ss := s): if on: set_side_setting(ss))
	_side_buttons[s] = b
	return b


func _update_status(text: String, color: Color = Color(0.95, 0.93, 0.90)) -> void:
	if _status_label == null:
		return
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", color)


func _show_result(text: String, color: Color) -> void:
	_result_label.text = text
	_result_label.add_theme_color_override("font_color", color)
	_result_panel.visible = true
	_result_panel.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_result_panel, "modulate:a", 1.0, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _hide_result() -> void:
	if _result_panel != null:
		_result_panel.visible = false

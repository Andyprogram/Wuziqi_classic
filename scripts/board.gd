extends Node2D
## 棋盘渲染层：深色木质底板、网格、星位、程序生成的棋子纹理、
## 悬停预览、落子弹跳动画、胜利金色高亮、窗口自适应。
## 数据由 game.gd 持有，本层只负责绘制。

const SIZE := 15
const EMPTY := 0
const BLACK := 1
const WHITE := 2

const TOP_MARGIN := 170.0      # 顶部 UI 占用高度
const ANIM_TIME := 0.22        # 落子弹跳动画时长

var game: Node = null          # 主逻辑节点，读取 cells / 状态
var cell_size := 40.0
var board_origin := Vector2.ZERO   # 第 (0,0) 格中心坐标

var wood_tex: ImageTexture = null
var black_tex: ImageTexture = null
var white_tex: ImageTexture = null

var _placed_at := {}           # "x,y" -> 落子时刻（秒）
var hover_cell := Vector2i(-1, -1)
var _last_vp := Vector2.ZERO


func setup(game_node: Node) -> void:
	game = game_node
	_update_layout()
	queue_redraw()


func reset() -> void:
	_placed_at.clear()
	hover_cell = Vector2i(-1, -1)
	queue_redraw()


func notify_placed(x: int, y: int) -> void:
	_placed_at["%d,%d" % [x, y]] = Time.get_ticks_msec() / 1000.0
	queue_redraw()


func _ready() -> void:
	_generate_wood()
	black_tex = _make_piece_image(Color(0.09, 0.09, 0.10), 160)
	white_tex = _make_piece_image(Color(0.97, 0.97, 0.98), 160)
	_update_layout()


func _process(_delta: float) -> void:
	var vp := get_viewport_rect().size
	if vp != _last_vp:
		_last_vp = vp
		_update_layout()
	var cell := pixel_to_cell(get_global_mouse_position())
	if cell != hover_cell:
		hover_cell = cell
		queue_redraw()
	queue_redraw()


func _update_layout() -> void:
	var vp := get_viewport_rect().size
	var avail: float = maxf(280.0, vp.y - TOP_MARGIN)
	var side: float = minf(vp.x, avail)
	cell_size = side * 0.78 / (SIZE - 1)
	var cx := vp.x * 0.5
	var cy := vp.y * 0.5 + TOP_MARGIN * 0.42
	var span := (SIZE - 1) * cell_size
	board_origin = Vector2(cx - span * 0.5, cy - span * 0.5)


## 视图坐标 -> 棋盘格子（超出范围或离交点过远返回 (-1,-1)）。
func pixel_to_cell(pos: Vector2) -> Vector2i:
	var local := pos - board_origin
	var col := roundi(local.x / cell_size)
	var row := roundi(local.y / cell_size)
	if col < 0 or col >= SIZE or row < 0 or row >= SIZE:
		return Vector2i(-1, -1)
	var p := Vector2(col * cell_size, row * cell_size)
	if (local - p).length() > cell_size * 0.58:
		return Vector2i(-1, -1)
	return Vector2i(col, row)


func cell_to_pixel(col: int, row: int) -> Vector2:
	return board_origin + Vector2(col * cell_size, row * cell_size)


func _draw() -> void:
	_draw_base()
	_draw_grid()
	_draw_stars()
	_draw_pieces()
	_draw_hover()
	_draw_win_line()


func _draw_base() -> void:
	var span := (SIZE - 1) * cell_size
	var edge := cell_size * 0.95
	var rect := Rect2(board_origin - Vector2(edge, edge), Vector2(span + edge * 2.0, span + edge * 2.0))
	draw_rect(rect.grow(12.0), Color(0, 0, 0, 0.35), true)   # 外阴影
	if wood_tex:
		draw_texture_rect(wood_tex, rect, false)
	else:
		draw_rect(rect, Color(0.36, 0.24, 0.14), true)
	draw_rect(rect, Color(0, 0, 0, 0.22), true)               # 暗化让线条清晰
	draw_rect(rect, Color(0.94, 0.89, 0.80, 0.85), false, 2.0)
	draw_rect(rect.grow(-edge * 0.45), Color(0.94, 0.89, 0.80, 0.30), false, 1.0)


func _draw_grid() -> void:
	var span := (SIZE - 1) * cell_size
	var col := Color(0.92, 0.88, 0.80, 0.75)
	for i in range(SIZE):
		var p := board_origin + Vector2(i * cell_size, 0.0)
		draw_line(p, p + Vector2(0.0, span), col, 1.0)
		var q := board_origin + Vector2(0.0, i * cell_size)
		draw_line(q, q + Vector2(span, 0.0), col, 1.0)


func _draw_stars() -> void:
	var stars := [Vector2i(3, 3), Vector2i(11, 3), Vector2i(7, 7), Vector2i(3, 11), Vector2i(11, 11)]
	for s in stars:
		draw_circle(cell_to_pixel(s.x, s.y), cell_size * 0.09, Color(0.92, 0.88, 0.80, 0.9))


func _draw_pieces() -> void:
	if game == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	for y in range(SIZE):
		for x in range(SIZE):
			var c: int = game.cells[x][y]
			if c == EMPTY:
				continue
			var sc := 1.0
			var key := "%d,%d" % [x, y]
			if _placed_at.has(key):
				var t: float = (now - _placed_at[key]) / ANIM_TIME
				if t < 1.0:
					sc = _ease_out_back(maxf(t, 0.0))
			_draw_piece_at(cell_to_pixel(x, y), c, sc)


func _draw_piece_at(center: Vector2, player: int, sc: float) -> void:
	var d := cell_size * 0.9 * maxf(sc, 0.02)
	draw_circle(center + Vector2(0.0, d * 0.05), d * 0.52, Color(0, 0, 0, 0.28))
	var tex := black_tex if player == BLACK else white_tex
	if tex:
		draw_texture_rect(tex, Rect2(center - Vector2(d, d) * 0.5, Vector2(d, d)), false)


func _draw_hover() -> void:
	if game == null or hover_cell == Vector2i(-1, -1):
		return
	if game.phase != game.Phase.PLAYER:
		return
	if game.cells[hover_cell.x][hover_cell.y] != EMPTY:
		return
	var center := cell_to_pixel(hover_cell.x, hover_cell.y)
	var d := cell_size * 0.9
	var tex := black_tex if game.player_color == BLACK else white_tex
	if tex:
		draw_texture_rect(tex, Rect2(center - Vector2(d, d) * 0.5, Vector2(d, d)), false, Color(1, 1, 1, 0.35))
	draw_circle(center, cell_size * 0.32, Color(1, 1, 1, 0.10))


func _draw_win_line() -> void:
	if game == null or game.win_line.is_empty():
		return
	var t: float = Time.get_ticks_msec() / 1000.0 - game.win_time
	var glow := 0.5 + 0.5 * sin(t * 6.0)
	for cell in game.win_line:
		var center := cell_to_pixel(cell.x, cell.y)
		var r := cell_size * 0.52
		draw_arc(center, r + 2.0 + glow * 2.0, 0.0, TAU, 40, Color(1.0, 0.85, 0.35, 0.95), 3.0)
		draw_arc(center, r + 6.0 + glow * 4.0, 0.0, TAU, 40, Color(1.0, 0.85, 0.35, 0.35), 2.0)


func _ease_out_back(t: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	return 1.0 + c3 * pow(t - 1.0, 3) + c1 * pow(t - 1.0, 2)


## 运行时生成深色木纹纹理（噪声 + 年轮条纹）。
func _generate_wood() -> void:
	var size := 256
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.seed = 20260813
	noise.frequency = 0.045
	noise.fractal_octaves = 4
	var img := noise.get_image(size, size)
	var out := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var cx := size * 0.32
	var cy := size * 0.55
	for y in range(size):
		for x in range(size):
			var nv := img.get_pixel(x, y).r
			var d := Vector2(x - cx, y - cy).length()
			var ring := 0.5 + 0.5 * sin(d * 0.045 + nv * 2.5)
			var t := clampf(nv * 0.5 + ring * 0.5, 0.0, 1.0)
			out.set_pixel(x, y, Color(
				lerp(0.42, 0.60, t),
				lerp(0.26, 0.38, t),
				lerp(0.15, 0.22, t),
				1.0))
	wood_tex = ImageTexture.create_from_image(out)


## 逐像素生成一枚棋子纹理：径向渐变 + 偏移高光 + 边缘暗环 + 抗锯齿。
func _make_piece_image(base: Color, size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r := size / 2.0
	var hx := r - r * 0.28
	var hy := r - r * 0.32
	for y in range(size):
		for x in range(size):
			var dx := x + 0.5 - r
			var dy := y + 0.5 - r
			var dist := sqrt(dx * dx + dy * dy)
			if dist >= r:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var t := dist / r
			var c := base.darkened(t * t * 0.35)
			c = c.lightened((1.0 - t) * 0.12)
			var hdx := x + 0.5 - hx
			var hdy := y + 0.5 - hy
			var hd := sqrt(hdx * hdx + hdy * hdy) / (r * 0.85)
			if hd < 1.0:
				c = c.lightened((1.0 - hd) * 0.30)
			var a := 1.0
			if dist > r - 1.5:
				a = clampf(r - dist, 0.0, 1.0)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, a))
	return ImageTexture.create_from_image(img)

@tool
extends McpTestSuite
## 五子棋核心逻辑单元测试：棋盘工具、四方向胜负检测（含过长连线）、
## AI 三档难度冒烟（必赢 / 必守 / 落子合法性）。全部为纯逻辑，无场景依赖。

const Game = preload("res://scripts/game.gd")
const GomokuAI = preload("res://scripts/ai.gd")

const EMPTY := 0
const BLACK := 1
const WHITE := 2

const DIFFS: Array = [GomokuAI.Difficulty.EASY, GomokuAI.Difficulty.MEDIUM, GomokuAI.Difficulty.HARD]


func suite_name() -> String:
	return "gomoku"


# ---------- 棋盘工具 ----------

func test_new_board_all_empty() -> void:
	var b := Game.new_board()
	assert_eq(b.size(), 15, "board height should be 15")
	assert_eq(b[0].size(), 15, "board width should be 15")
	assert_eq(b[0][0], EMPTY)
	assert_eq(b[7][7], EMPTY)
	assert_eq(b[14][14], EMPTY)


func test_is_full_empty_board() -> void:
	assert_false(Game.is_full(Game.new_board()), "empty board must not be full")


func test_is_full_filled_board() -> void:
	var b := Game.new_board()
	for y in range(15):
		for x in range(15):
			b[x][y] = BLACK
	assert_true(Game.is_full(b), "fully filled board must be full")


# ---------- 胜负检测 ----------

func test_horizontal_win() -> void:
	var b := Game.new_board()
	for i in range(5):
		b[i][4] = BLACK
	assert_eq(Game.check_win_on(b, 4, 4, BLACK).size(), 5, "horizontal five should win")


func test_vertical_win() -> void:
	var b := Game.new_board()
	for i in range(5):
		b[6][i] = WHITE
	assert_eq(Game.check_win_on(b, 6, 4, WHITE).size(), 5, "vertical five should win")


func test_diagonal_win() -> void:
	var b := Game.new_board()
	for i in range(5):
		b[2 + i][2 + i] = BLACK
	assert_eq(Game.check_win_on(b, 6, 6, BLACK).size(), 5, "diagonal five should win")


func test_anti_diagonal_win() -> void:
	var b := Game.new_board()
	for i in range(5):
		b[i][4 - i] = WHITE
	assert_eq(Game.check_win_on(b, 4, 0, WHITE).size(), 5, "anti-diagonal five should win")


func test_four_in_a_row_no_win() -> void:
	var b := Game.new_board()
	b[0][0] = BLACK
	b[1][0] = BLACK
	b[2][0] = BLACK
	b[3][0] = BLACK
	assert_eq(Game.check_win_on(b, 3, 0, BLACK).size(), 0, "four in a row must not win")


func test_exact_five_becomes_win() -> void:
	var b := Game.new_board()
	for i in range(5):
		b[i][2] = BLACK
	assert_eq(Game.check_win_on(b, 4, 2, BLACK).size(), 5, "exactly five must win")


func test_overline_six_still_win() -> void:
	var b := Game.new_board()
	for i in range(6):
		b[3][i] = WHITE
	assert_eq(Game.check_win_on(b, 3, 5, WHITE).size(), 6, "overline (6) must still count as a win")


func test_opponent_stone_breaks_line() -> void:
	var b := Game.new_board()
	b[0][0] = BLACK
	b[1][0] = BLACK
	b[2][0] = BLACK
	b[3][0] = WHITE  # 挡断
	b[4][0] = BLACK
	assert_eq(Game.check_win_on(b, 4, 0, BLACK).size(), 0, "opponent stone must break the line")


func test_win_line_contains_endpoints() -> void:
	var b := Game.new_board()
	for i in range(5):
		b[2 + i][8] = BLACK
	var win := Game.check_win_on(b, 6, 8, BLACK)
	assert_eq(win.size(), 5)
	var has := {}
	for c in win:
		has[Vector2i(c.x, c.y)] = true
	assert_true(has.has(Vector2i(2, 8)), "line must include left endpoint")
	assert_true(has.has(Vector2i(6, 8)), "line must include right endpoint")
	assert_false(has.has(Vector2i(7, 8)), "line must not include empty cell")


# ---------- AI 冒烟测试 ----------

func _make_ai():
	return GomokuAI.new()


func test_ai_opens_center_on_empty() -> void:
	for d in DIFFS:
		var move := _make_ai().get_move(Game.new_board(), BLACK, d)
		assert_eq(move, Vector2i(7, 7), "empty board should open at center for difficulty %d" % d)


func test_ai_takes_winning_move() -> void:
	# AI(黑) 有活四 (1,7)~(4,7)，两端开放，应直接取胜
	for d in DIFFS:
		var b := Game.new_board()
		b[1][7] = BLACK
		b[2][7] = BLACK
		b[3][7] = BLACK
		b[4][7] = BLACK
		var move := _make_ai().get_move(b, BLACK, d)
		var is_win := move == Vector2i(0, 7) or move == Vector2i(5, 7)
		assert_true(is_win, "difficulty %d played %s, expected (0,7) or (5,7)" % [d, str(move)])


func test_ai_blocks_opponent_rush_four() -> void:
	# 白(对手)冲四 (1,7)~(4,7)，左端被黑封，(5,7) 是唯一必守点
	for d in DIFFS:
		var b := Game.new_board()
		b[1][7] = WHITE
		b[2][7] = WHITE
		b[3][7] = WHITE
		b[4][7] = WHITE
		b[0][7] = BLACK
		var move := _make_ai().get_move(b, BLACK, d)
		assert_eq(move, Vector2i(5, 7), "difficulty %d played %s, expected to block at (5,7)" % [d, str(move)])


func test_ai_move_is_legal() -> void:
	# 任意难度下，AI 落子必须落在棋盘内的空位
	var b := Game.new_board()
	b[7][7] = BLACK
	b[7][8] = WHITE
	b[8][7] = WHITE
	b[8][8] = BLACK
	for d in DIFFS:
		var move := _make_ai().get_move(b, BLACK, d)
		assert_true(move.x >= 0 and move.x < 15 and move.y >= 0 and move.y < 15,
			"difficulty %d move out of bounds: %s" % [d, str(move)])
		assert_eq(b[move.x][move.y], EMPTY, "difficulty %d moved onto occupied cell %s" % [d, str(move)])


# ---------- 悔棋（撤回一整轮） ----------

func test_compute_undo_round() -> void:
	# 玩家执黑：[黑, 白, 黑, 白]，撤回一整轮 → [黑, 白]
	var h: Array = [
		{"x": 7, "y": 7, "p": BLACK},
		{"x": 8, "y": 8, "p": WHITE},
		{"x": 6, "y": 6, "p": BLACK},
		{"x": 6, "y": 8, "p": WHITE},
	]
	var after := Game.compute_undo(h, WHITE)
	assert_eq(after.size(), 2, "one round undo should leave 2 moves")
	assert_eq(after[0].x, 7, "first kept move x")
	assert_eq(after[1].p, WHITE, "second kept move is AI's")


func test_compute_undo_ai_black_keeps_opening() -> void:
	# AI 执黑开局：[黑AI, 白P, 黑AI]，轮到玩家时悔棋 → 剩 [黑AI]
	var h: Array = [
		{"x": 7, "y": 7, "p": BLACK},
		{"x": 6, "y": 7, "p": WHITE},
		{"x": 8, "y": 8, "p": BLACK},
	]
	var after := Game.compute_undo(h, BLACK)
	assert_eq(after.size(), 1, "AI opening move should remain")
	assert_eq(after[0].p, BLACK, "remaining move is AI's opening")


func test_compute_undo_single_ai_opening_empties() -> void:
	var h: Array = [{"x": 7, "y": 7, "p": BLACK}]
	var after := Game.compute_undo(h, BLACK)
	assert_eq(after.size(), 0, "undo on lone AI opening empties history")


func test_compute_undo_empty_history() -> void:
	assert_eq(Game.compute_undo([], WHITE).size(), 0, "empty history stays empty")


# ---------- 统计（累计结果） ----------

func test_apply_result_player_win() -> void:
	var s := Game.apply_result({"total": 10, "player_wins": 4, "ai_wins": 5, "draws": 1}, BLACK, BLACK)
	assert_eq(s.total, 11, "total increments")
	assert_eq(s.player_wins, 5, "player win counts")
	assert_eq(s.ai_wins, 5, "ai wins unchanged")


func test_apply_result_ai_win() -> void:
	var s := Game.apply_result({"total": 0, "player_wins": 0, "ai_wins": 0, "draws": 0}, WHITE, BLACK)
	assert_eq(s.total, 1, "total increments")
	assert_eq(s.ai_wins, 1, "ai win counts")
	assert_eq(s.player_wins, 0, "player wins unchanged")


func test_apply_result_draw() -> void:
	var s := Game.apply_result({"total": 3, "player_wins": 1, "ai_wins": 1, "draws": 1}, 0, BLACK)
	assert_eq(s.total, 4, "total increments")
	assert_eq(s.draws, 2, "draw counts")

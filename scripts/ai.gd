@tool
class_name GomokuAI
## 五子棋 AI：三档难度（简单 / 中等 / 较强）。（v4）
## 纯逻辑实现，不依赖场景树，可在子线程中运行，便于单元测试。
##
## 核心思想：
##   - 对每个候选空位，从四个方向统计连子长度与两端开放情况，映射为棋形分值。
##   - 简单：必赢必守 + 较好候选里随机（新手感）。
##   - 中等：候选裁剪后的 depth-2 极小极大。
##   - 较强：候选裁剪后的 depth-3 alpha-beta 剪枝。

const SIZE := 15
const EMPTY := 0
const BLACK := 1
const WHITE := 2

enum Difficulty { EASY, MEDIUM, HARD }

# 棋形分值（相对权重，决定攻防取舍）
const SCORE_FIVE := 10000000      # 连五
const SCORE_LIVE_FOUR := 1000000  # 活四（双端开放）
const SCORE_RUSH_FOUR := 200000   # 冲四（单端开放）
const SCORE_LIVE_THREE := 60000   # 活三
const SCORE_SLEEP_THREE := 8000   # 眠三
const SCORE_LIVE_TWO := 4000      # 活二
const SCORE_SLEEP_TWO := 700      # 眠二
const SCORE_LIVE_ONE := 200
const SCORE_SLEEP_ONE := 60

const DIRECTIONS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, -1)]

const NEG_INF := -1000000000
const POS_INF := 1000000000

# 线程安全：本类使用自己的随机源，避免子线程竞争全局 RNG。
var _rng := RandomNumberGenerator.new()


static func opponent(player: int) -> int:
	return BLACK if player == WHITE else WHITE


## 对外入口：返回 AI 落子坐标。
func get_move(board: Array, player: int, difficulty: int) -> Vector2i:
	var cands := _candidates(board, player, false)
	if cands.is_empty():
		return Vector2i(SIZE >> 1, SIZE >> 1)
	match difficulty:
		Difficulty.EASY:
			return _easy_move(board, cands, player)
		Difficulty.MEDIUM:
			return _minimax_move(board, player, cands, 2)
		Difficulty.HARD:
			return _minimax_move(board, player, cands, 3)
		_:
			return _easy_move(board, cands, player)


func _easy_move(board: Array, cands: Array, player: int) -> Vector2i:
	var opp := opponent(player)
	# 一子即胜，必须赢
	for c in cands:
		if _is_winning_move(board, c[0], c[1], player):
			return Vector2i(c[0], c[1])
	# 对手一子即胜，必须防
	for c in cands:
		if _is_winning_move(board, c[0], c[1], opp):
			return Vector2i(c[0], c[1])
	# 否则在较好候选里随机，保持新手感
	var top := cands.slice(0, mini(cands.size(), 6))
	_rng.randomize()
	var pick: Array = top[_rng.randi() % top.size()]
	return Vector2i(pick[0], pick[1])


func _is_winning_move(board: Array, x: int, y: int, p: int) -> bool:
	board[x][y] = p
	var win := _point_score(board, x, y, p) >= SCORE_FIVE
	board[x][y] = EMPTY
	return win


func _minimax_move(board: Array, player: int, cands: Array, depth: int) -> Vector2i:
	var opp := opponent(player)
	# 快速路径：必赢 / 必守
	for c in cands:
		if _is_winning_move(board, c[0], c[1], player):
			return Vector2i(c[0], c[1])
	for c in cands:
		if _is_winning_move(board, c[0], c[1], opp):
			return Vector2i(c[0], c[1])
	var best_score := NEG_INF
	var best := Vector2i(cands[0][0], cands[0][1])
	var limit: int = mini(cands.size(), 12)
	for i in range(limit):
		var x: int = cands[i][0]
		var y: int = cands[i][1]
		board[x][y] = player
		var s := _ab(board, depth - 1, NEG_INF, POS_INF, false, player, opp)
		board[x][y] = EMPTY
		if s > best_score:
			best_score = s
			best = Vector2i(x, y)
	return best


## 统一 alpha-beta 极小极大（带候选排序）。is_max 表示当前层是否最大化己方（ai_player）。
func _ab(board: Array, depth: int, alpha: int, beta: int, is_max: bool, ai_player: int, me: int) -> int:
	if depth <= 0:
		return _evaluate(board, ai_player)
	var cands := _candidates(board, me, true)
	if cands.is_empty():
		return _evaluate(board, ai_player)
	var limit: int = mini(cands.size(), 10 if depth >= 2 else 8)
	if is_max:
		var best := NEG_INF
		for i in range(limit):
			var x: int = cands[i][0]
			var y: int = cands[i][1]
			board[x][y] = me
			var v := _ab(board, depth - 1, alpha, beta, false, ai_player, opponent(me))
			board[x][y] = EMPTY
			best = maxi(best, v)
			alpha = maxi(alpha, v)
			if beta <= alpha:
				break
		return best
	else:
		var best := POS_INF
		for i in range(limit):
			var x: int = cands[i][0]
			var y: int = cands[i][1]
			board[x][y] = me
			var v := _ab(board, depth - 1, alpha, beta, true, ai_player, opponent(me))
			board[x][y] = EMPTY
			best = mini(best, v)
			beta = mini(beta, v)
			if beta <= alpha:
				break
		return best


## 候选空位：仅收集有邻居的空位。
## rank=false 时按（己方进攻 + 对方防守）综合分排序（root 层用）；
## rank=true  时按己方棋形分排序（搜索内层用，更便宜）。
func _candidates(board: Array, player: int, rank: bool) -> Array:
	var opp := opponent(player)
	var list: Array = []
	for y in range(SIZE):
		for x in range(SIZE):
			if board[x][y] != EMPTY:
				continue
			if not _has_neighbor(board, x, y):
				continue
			var s: int
			if rank:
				s = _point_score(board, x, y, player)
			else:
				s = _move_score(board, x, y, player, opp)
			list.append([x, y, s])
	list.sort_custom(func(a, b): return a[2] > b[2])
	return list


func _has_neighbor(board: Array, x: int, y: int) -> bool:
	for dy in range(-2, 3):
		var ny := y + dy
		if ny < 0 or ny >= SIZE:
			continue
		for dx in range(-2, 3):
			if dx == 0 and dy == 0:
				continue
			var nx := x + dx
			if nx < 0 or nx >= SIZE:
				continue
			if board[nx][ny] != EMPTY:
				return true
	return false


## 落子估值 = 己方在该点形成的棋形分 + 对方在该点形成的棋形分（攻防兼顾）。
func _move_score(board: Array, x: int, y: int, player: int, opp: int) -> int:
	board[x][y] = player
	var attack := _point_score(board, x, y, player)
	board[x][y] = EMPTY
	board[x][y] = opp
	var defend := _point_score(board, x, y, opp)
	board[x][y] = EMPTY
	return attack + defend


## 一个落子点的棋形分：四方向中最关键方向的分 + 组合（双三/冲四+活三等）奖励。
func _point_score(board: Array, x: int, y: int, player: int) -> int:
	var best := 0
	var total := 0
	for d in DIRECTIONS:
		var s := _direction_score(board, x, y, d.x, d.y, player)
		best = maxi(best, s)
		total += s
	if best >= SCORE_FIVE:
		return best
	# 组合奖励：多个方向同时有威胁（如双活三）应强于单个活三
	var combo := total * 2
	return maxi(best, combo)


func _direction_score(board: Array, x: int, y: int, dx: int, dy: int, player: int) -> int:
	var count := 1
	var block := 0
	var px := x + dx
	var py := y + dy
	while px >= 0 and px < SIZE and py >= 0 and py < SIZE and board[px][py] == player:
		count += 1
		px += dx
		py += dy
	if px < 0 or px >= SIZE or py < 0 or py >= SIZE or board[px][py] != EMPTY:
		block += 1
	var nx := x - dx
	var ny := y - dy
	while nx >= 0 and nx < SIZE and ny >= 0 and ny < SIZE and board[nx][ny] == player:
		count += 1
		nx -= dx
		ny -= dy
	if nx < 0 or nx >= SIZE or ny < 0 or ny >= SIZE or board[nx][ny] != EMPTY:
		block += 1
	return _shape_score(count, block)


func _shape_score(count: int, block: int) -> int:
	if count >= 5:
		return SCORE_FIVE
	if block >= 2:
		return 0
	if block == 0:
		match count:
			4: return SCORE_LIVE_FOUR
			3: return SCORE_LIVE_THREE
			2: return SCORE_LIVE_TWO
			1: return SCORE_LIVE_ONE
			_: return 0
	else:
		match count:
			4: return SCORE_RUSH_FOUR
			3: return SCORE_SLEEP_THREE
			2: return SCORE_SLEEP_TWO
			1: return SCORE_SLEEP_ONE
			_: return 0


## 全盘局势评估（相对分）：AI 总棋形分 - 对手总棋形分。搜索叶子节点用。
func _evaluate(board: Array, ai_player: int) -> int:
	var pl := opponent(ai_player)
	var ai_total := 0
	var pl_total := 0
	for y in range(SIZE):
		for x in range(SIZE):
			var c: int = board[x][y]
			if c == EMPTY:
				continue
			if c == ai_player:
				ai_total += _point_score(board, x, y, ai_player)
			else:
				pl_total += _point_score(board, x, y, pl)
	return ai_total - pl_total

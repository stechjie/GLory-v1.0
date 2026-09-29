extends BattleSimShared

# Simulation-space navigation: search for a free attack position, not the
# occupied enemy centre. No wall-clock time or RNG enters authoritative replay.
const GRID_STEP := 24.0
const MAX_EXPANSIONS := 128
const REPLAN_SEC := 0.8
const MAX_PLANS_PER_TICK := 2
const DIRECTIONS := [Vector2i(0,-1), Vector2i(-1,0), Vector2i(1,0), Vector2i(0,1),
	Vector2i(-1,-1), Vector2i(1,-1), Vector2i(-1,1), Vector2i(1,1)]

static func applies(f: Dictionary) -> bool:
	return float(f.get("range_px", ATTACK_RANGE_SCALE)) <= MELEE_RANGE_PX + 0.01

static func segment_clear(f: Dictionary, a: Vector2, b: Vector2, bodies: Array) -> bool:
	var d := b - a
	var length := d.length()
	if length <= 0.001:
		return true
	var hit := _first_contact(a, body_radius(f), d / length, length, f, bodies)
	return float(hit.contact) >= length - 0.001

static func approach(f: Dictionary, target: Dictionary, from: Vector2) -> Vector2:
	var delta := Vector2(target.pos) - from
	# Stop inside attack tolerance but outside physical contact. This also handles
	# large footprints without requiring the navigation grid to land on a thin ring.
	var distance := maxf(body_radius(f) + body_radius(target) + 0.05,
		_effective_attack_distance(f, target) + ATTACK_RANGE_EPS - 0.5)
	return from + delta.normalized() * maxf(0.0, delta.length() - distance)

static func choose(f: Dictionary, selected: Dictionary, opponents: Array,
		bodies: Array, elapsed: float, state: Dictionary) -> Dictionary:
	var fallback := {"target": selected, "waypoint": Vector2(selected.get("pos", f.pos))}
	if selected.is_empty() or not applies(f):
		return fallback
	var taunter := _nearest_taunter(f, opponents)
	var candidates: Array = []
	for o: Dictionary in opponents:
		if not bool(o.get("alive", false)) or int(o.get("hp", 0)) <= 0 or not _can_target(f, o, opponents):
			continue
		# Respect taunt and the existing own/left/right lane priority.
		if not taunter.is_empty() and str(o.uid) != str(taunter.uid):
			continue
		if GameState.team_mode and int(o.get("lane", -1)) != int(selected.get("lane", -1)):
			continue
		candidates.append(o)
	# Stable ordering makes ties independent of hash iteration order.
	candidates.sort_custom(func(a, b): return str(a.uid) < str(b.uid))
	if Vector2(f.pos).distance_to(selected.pos) <= _effective_attack_distance(f, selected) + ATTACK_RANGE_EPS:
		f.erase("_melee_route")
		return fallback
	# Do not queue behind a locked enemy when a legal enemy is already in reach.
	var ready: Array = []
	for o: Dictionary in candidates:
		if Vector2(f.pos).distance_to(o.pos) <= _effective_attack_distance(f, o) + ATTACK_RANGE_EPS:
			ready.append(o)
	if not ready.is_empty():
		var pick := _score_target(f, ready, str(f.get("def", {}).get("skill_id", "")) == "death_hunt")
		f.locked_target_uid = str(pick.uid)
		f.erase("_melee_route")
		return {"target": pick, "waypoint": Vector2(pick.pos)}
	if segment_clear(f, f.pos, approach(f, selected, f.pos), bodies):
		f.erase("_melee_route")
		return fallback
	# Reuse a route while the next edge is still free. Dynamic bodies are checked
	# again every tick, and the actual move still uses the existing swept collision.
	var route: Dictionary = f.get("_melee_route", {})
	if not route.is_empty() and elapsed < float(route.expires) and str(route.uid) == str(selected.uid) \
			and Vector2(route.target_pos).distance_to(selected.pos) < GRID_STEP:
		var points: Array = route.points
		while not points.is_empty() and Vector2(f.pos).distance_to(points[0]) < 0.5:
			points.pop_front()
		if not points.is_empty() and segment_clear(f, f.pos, points[0], bodies):
			return {"target": selected, "waypoint": points[0]}
	# Never retain an invalid route when this tick has exhausted its search budget.
	f.erase("_melee_route")
	# Failed searches retry; there is no permanent "give up after three targets".
	if elapsed < float(f.get("_melee_retry_at", -1.0)) and route.is_empty():
		return fallback
	if float(state.get("_melee_plan_tick", -1.0)) != elapsed:
		state._melee_plan_tick = elapsed
		state._melee_plan_count = 0
	if int(state.get("_melee_plan_count", 0)) >= MAX_PLANS_PER_TICK:
		return fallback
	state._melee_plan_count = int(state.get("_melee_plan_count", 0)) + 1
	f.erase("_melee_route")
	f._melee_retry_at = elapsed + REPLAN_SEC
	var plan := find_route(f, candidates, bodies)
	if plan.is_empty():
		return fallback
	var target: Dictionary = plan.target
	f.locked_target_uid = str(target.uid)
	f._melee_route = {"uid": str(target.uid), "points": plan.points,
		"target_pos": Vector2(target.pos), "expires": elapsed + REPLAN_SEC}
	return {"target": target, "waypoint": plan.points[0]}

static func _heuristic(f: Dictionary, pos: Vector2, candidates: Array) -> float:
	var best := INF
	for target: Dictionary in candidates:
		best = minf(best, pos.distance_to(approach(f, target, pos)))
	return best

static func find_route(f: Dictionary, candidates: Array, bodies: Array) -> Dictionary:
	if candidates.is_empty():
		return {}
	var origin := Vector2(f.pos)
	var open: Array[Vector2i] = [Vector2i.ZERO]
	var costs := {Vector2i.ZERO: 0.0}
	var ranks := {Vector2i.ZERO: _heuristic(f, origin, candidates)}
	var parents := {}
	var closed := {}
	var best_cost := INF
	var best: Dictionary = {}
	for expansion in MAX_EXPANSIONS:
		if open.is_empty():
			break
		var at := 0
		for i in range(1, open.size()):
			if float(ranks[open[i]]) < float(ranks[open[at]]):
				at = i
		var cell := open[at]
		open.remove_at(at)
		if float(ranks[cell]) >= best_cost:
			break
		closed[cell] = true
		var pos := origin + Vector2(cell) * GRID_STEP
		for target: Dictionary in candidates:
			var goal := approach(f, target, pos)
			var total := float(costs[cell]) + pos.distance_to(goal)
			if total >= best_cost or not _inside(goal) or not segment_clear(f, pos, goal, bodies):
				continue
			var points: Array = [goal]
			var cursor := cell
			while cursor != Vector2i.ZERO:
				points.push_front(origin + Vector2(cursor) * GRID_STEP)
				cursor = parents[cursor]
			best_cost = total
			best = {"target": target, "points": points, "cost": total, "expansions": expansion + 1}
		for direction: Vector2i in DIRECTIONS:
			var next := cell + direction
			if closed.has(next):
				continue
			var next_pos := origin + Vector2(next) * GRID_STEP
			var cost := float(costs[cell]) + pos.distance_to(next_pos)
			if cost >= float(costs.get(next, INF)) or not _inside(next_pos) \
					or not segment_clear(f, pos, next_pos, bodies):
				continue
			costs[next] = cost
			ranks[next] = cost + _heuristic(f, next_pos, candidates)
			parents[next] = cell
			if not open.has(next):
				open.append(next)
	return best

static func _inside(p: Vector2) -> bool:
	return p.x >= 45.0 and p.x <= ARENA_W - 45.0 and p.y >= 40.0 and p.y <= ARENA_H - 40.0

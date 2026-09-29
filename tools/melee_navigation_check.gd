extends Node
const Sim = preload("res://scripts/battle/BattleSimulator.gd")
const Nav = preload("res://scripts/battle/MeleeNavigation.gd")
const Fixture = preload("res://tools/battle_reach_target_check.gd")
const Harness = preload("res://tools/CheckHarness.gd")
var h = Harness.new("melee_navigation")
var fixture = Fixture.new()
func unit(uid: String, pos: Vector2, team: String = "enemy") -> Dictionary:
 var f = fixture._mk("human_militia", team, 0, pos.x, pos.y, 10000, 32.0, uid)
 f.range_px = 32.0
 f.move_speed_px = 165.0
 return f
func _ready():
 NetworkService.set_process(false)
 GameState.team_mode = true
 var f = unit("poison", Vector2(230,380), "player")
 var e = unit("front", Vector2(230,280))
 var wall = [unit("w0",Vector2(198,330),"player"),unit("w1",Vector2(230,330),"player"),unit("w2",Vector2(262,330),"player")]
 var bodies = [f,e]+wall
 var started = Time.get_ticks_usec()
 var plan = Nav.find_route(f,[e],bodies)
 h.expect(not plan.is_empty(), "route_missing", "route must go around three allied bodies to sole enemy")
 if not plan.is_empty():
  var prev: Vector2 = f.pos
  for point: Vector2 in plan.points:
   h.expect(Nav.segment_clear(f,prev,point,bodies),"route_collision","every segment must clear real collision bodies")
   prev=point
  h.expect(prev.distance_to(e.pos)<=Sim._effective_attack_distance(f,e)+Sim.ATTACK_RANGE_EPS,"goal_range","route endpoint must allow attack")
  var repeat = Nav.find_route(f,[e],bodies)
  h.expect(plan.points==repeat.points,"determinism","identical snapshot yields identical path")
 h.note("wall search ms=%.3f" % ((Time.get_ticks_usec()-started)/1000.0))
 # Integration: real walking, targeting and attack code, not only geometry.
 for w in wall: w.move_speed_px=0.0; w.next_attack=9999.0
 f.locked_target_uid=e.uid
 var st = fixture._base_state([f]+wall,[e])
 var first_attack=-1
 var worst=0
 for tick in 100:
  var t=Time.get_ticks_usec()
  Sim._step_team([f]+wall,[e],tick*0.1,st)
  worst=maxi(worst,Time.get_ticks_usec()-t)
  for w in wall:
   h.expect(Vector2(f.pos).distance_to(w.pos)>=29.99,"penetration","walking may not pass through allies")
  if f.attack_count>0: first_attack=tick; break
 h.expect(first_attack>=0 and first_attack<60,"queued_forever","blocked melee must actually attack within six seconds")
 h.note("first attack tick=%d worst step ms=%.3f" % [first_attack,worst/1000.0])
 # A legal target already in reach wins over an out-of-range lock immediately.
 f.pos=Vector2(230,380); f.locked_target_uid=e.uid; f.erase("_melee_route")
 var side=unit("side",Vector2(265,380))
 var choice=Nav.choose(f,e,[e,side],[f,e,side]+wall,20.0,{})
 h.expect(choice.target.uid==side.uid,"ready_target","attack nearby available enemy without a stall timer")
 side.lane=1
 choice=Nav.choose(f,e,[e,side],[f,e,side]+wall,21.0,{})
 h.expect(choice.target.uid==e.uid,"lane","do not select enemy behind an unreleased lane")
 side.lane=0; e.taunt_active=true; e.taunt_radius=300.0
 choice=Nav.choose(f,e,[e,side],[f,e,side]+wall,22.0,{})
 h.expect(choice.target.uid==e.uid,"taunt","taunt remains authoritative")
 e.taunt_active=false
 # Direct approach has no navigation allocations and preserves the current lock.
 f.erase("_melee_route");f.erase("_melee_retry_at")
 choice=Nav.choose(f,e,[e],[f,e],23.0,{})
 h.expect(choice.target.uid==e.uid and not f.has("_melee_route"),"clear_lock","clear path keeps original target")
 # Range and large bodies use the same contact geometry as walking.
 var giant=unit("giant",Vector2(230,280));giant.footprint_cells=2
 plan=Nav.find_route(f,[giant],[f,giant]+wall)
 h.expect(not plan.is_empty(),"large_body","large enemy must have a legal approach")
 # Completely trapped is not a license to tunnel through allies; retry after release.
 var cage=[]
 for i in 8: cage.append(unit("c%d"%i,f.pos+Vector2.from_angle(i*TAU/8.0)*31.0,"player"))
 plan=Nav.find_route(f,[e],[f,e]+cage)
 h.expect(plan.is_empty(),"trapped","do not invent a route through a closed cage")
 f.erase("_melee_route");f.erase("_melee_retry_at")
 Nav.choose(f,e,[e],[f,e]+cage,30.0,{})
 choice=Nav.choose(f,e,[e],[f,e]+wall,31.0,{})
 h.expect(f.has("_melee_route"),"retry","search again when blocking geometry changes")
 # A new body on the next waypoint invalidates the cached edge.
 var path=f.get("_melee_route",{}).get("points",[])
 if not path.is_empty():
  var blocker=unit("dynamic",Vector2(path[0]),"player")
  choice=Nav.choose(f,e,[e],[f,e]+wall+[blocker],31.1,{})
  if f.has("_melee_route"):
   h.expect(Nav.segment_clear(f,f.pos,choice.waypoint,[f,e]+wall+[blocker]),"dynamic_edge","replanned first edge must be free")
 # An enemy with no vacant attack position must lose to a reachable alternative.
 f.pos=Vector2(120,380);f.locked_target_uid=e.uid
 f.erase("_melee_route");f.erase("_melee_retry_at")
 e.pos=Vector2(230,280);side.pos=Vector2(330,380)
 var guards=[]
 for i in 8: guards.append(unit("guard%d"%i,e.pos+Vector2.from_angle(i*TAU/8.0)*32.0,"player"))
 choice=Nav.choose(f,e,[e,side],[f,e,side]+guards,40.0,{})
 h.expect(choice.target.uid==side.uid,"unavailable_attack_position","choose accessible enemy when every attack position around locked enemy is occupied")
 # Invalid cached edges cannot survive when the shared planning budget is exhausted.
 f.pos=Vector2(230,380);e.pos=Vector2(230,280)
 f._melee_route={"uid":e.uid,"points":[Vector2(230,330)],"target_pos":e.pos,"expires":51.0}
 choice=Nav.choose(f,e,[e],[f,e]+wall,50.0,{"_melee_plan_tick":50.0,"_melee_plan_count":Nav.MAX_PLANS_PER_TICK})
 h.expect(not f.has("_melee_route"),"budget_invalid_route","discard blocked cached route even when replanning is deferred")
 fixture.free()
 h.finish(get_tree())

extends SceneTree
## Isolated desktop performance harness for the refined priestess: 6 and 12
## instances, old vs new, 5 s each. This is an isolated animated model workload,
## not a full battle or a mobile result.
## Usage: godot --path . --rendering-driver opengl3 --resolution 1440x900 --script tools/model_refinement/priestess_perf_run.gd -- [--out <abs-json>]
func _initialize(): call_deferred("run")
func run():
	var args=OS.get_cmdline_user_args()
	var out=args[args.find("--out")+1] if "--out" in args else "res://reports/priestess-perf.json"
	root.content_scale_mode=Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size=Vector2i.ZERO
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var preview=load("res://scenes/debug/PriestessModelRefinementPreview.gd").new()
	root.add_child(preview);preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var records=[]
	for count in [6,12]:
		for variant in ["old","new"]:
			preview._variant=variant;preview._count=count;preview._close=false;preview._view="battle";preview._rebuild()
			Engine.max_fps=0
			await create_timer(2.0).timeout
			var times=[];var peak_draws=0;var start=Time.get_ticks_usec();var previous=start
			while Time.get_ticks_usec()-start<5000000:
				await process_frame
				await RenderingServer.frame_post_draw
				var now=Time.get_ticks_usec();times.append((now-previous)/1000.0);previous=now
				peak_draws=maxi(peak_draws,int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
			times.sort();var total=0.0
			for t in times:total+=t
			records.append({"variant":variant,"count":count,"frames":times.size(),"mean_ms":total/times.size(),"p95_ms":times[int(times.size()*.95)],"peak_draw_calls":peak_draws,"engine_max_fps":Engine.max_fps,"vsync":DisplayServer.window_get_vsync_mode()})
	var report={"unit_id":"god_priestess","scope":"isolated animated desktop model workload, not full battle or mobile","old_model":preview.OLD_MODEL_PATH,"new_model":preview.NEW_MODEL_PATH,"gpu":RenderingServer.get_video_adapter_name(),"renderer":RenderingServer.get_current_rendering_method(),"viewport":preview._viewport.size,"cases":records}
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	FileAccess.open(out,FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("PRIESTESS_PERF ",JSON.stringify(report));quit()

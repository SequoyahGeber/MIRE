extends SceneTree

## Verifies F-592 — the FPS/percentage conversions every performance instrument now reports through.
##
## Deliberately a UNIT check on synthetic numbers, not a measurement. Sequoyah asked for the
## reporting units to change and explicitly did not consent to a perf run for it: he backgrounds any
## window we open, which makes frame times worthless (F-457), and a windowed run puts a real window
## on his desktop. So this proves the arithmetic and the phrasing, and leaves measurement to a run
## he agrees to.
##
## The worked example is his own: a 2.4 ms cost inside a 13.51 ms frame reads as "18% of the frame —
## 74 fps with, 90 without". If that line ever comes out differently, this check is what says so.
##
##   .agent/bin/agent godot --script tools/perf_format_check.gd

const PerfFormat := preload("res://tools/perf_format.gd")

var failures: int = 0


func _initialize() -> void:
	_run()


func _run() -> void:
	_check_fps()
	_check_percent_baseline()
	_check_worked_example()
	_check_one_percent_low()
	_check_unmeasured()
	_check_change_direction()
	_check_drift_gate()

	print("\nPERF_FORMAT_CHECK failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _check_fps() -> void:
	print("== frame times read as frame rates ==")
	check(is_equal_approx(PerfFormat.fps(16.6667), 60.0), "16.67 ms is 60 fps (%.2f)" % PerfFormat.fps(16.6667))
	check(is_equal_approx(PerfFormat.fps(33.3333), 30.0), "33.33 ms is 30 fps (%.2f)" % PerfFormat.fps(33.3333))
	# Round-trip, because two instruments converting in opposite directions must agree.
	check(is_equal_approx(PerfFormat.frame_ms(PerfFormat.fps(13.51)), 13.51),
		"ms -> fps -> ms returns the original")


func _check_percent_baseline() -> void:
	print("\n== a percentage is taken against the frame that CONTAINS the cost ==")
	# The distinction that matters: 2.4 ms inside a 13.51 ms frame is 18%, not the 21.6% you get by
	# dividing against the 11.11 ms frame without it. Both are arithmetic; only one answers "how
	# much of my frame is this".
	var against_with: float = PerfFormat.percent_of_frame(2.4, 13.51)
	var against_without: float = PerfFormat.percent_of_frame(2.4, 11.11)
	check(absf(against_with - 17.76) < 0.1, "2.4 ms of a 13.51 ms frame is ~18%% (%.2f%%)" % against_with)
	check(against_with < against_without,
		"and is deliberately the smaller of the two readings (%.1f%% vs %.1f%%)"
			% [against_with, against_without])
	# Half the frame is half the frame at any frame rate — the property that makes a percentage
	# comparable across machines, which a millisecond figure never was.
	check(is_equal_approx(PerfFormat.percent_of_frame(8.0, 16.0), 50.0), "8 ms of 16 ms is 50%")
	check(is_equal_approx(PerfFormat.percent_of_frame(16.0, 32.0), 50.0),
		"16 ms of 32 ms is also 50% — the same share on a slower machine")


func _check_worked_example() -> void:
	print("\n== Sequoyah's own worked example, phrased back to him ==")
	var line: String = PerfFormat.cost_line("shadows", 13.51, 11.11)
	print("     %s" % line)
	check(line.contains("18%"), "the cost leads with 18%% of the frame (%s)" % line)
	check(line.contains("74 fps") and line.contains("90 fps"),
		"both frame rates are stated, so the percentage has a baseline")
	# ms is allowed to survive, but only behind the figures that lead.
	check(line.find("18%") < line.find("ms"), "milliseconds come last, not first")


func _check_one_percent_low() -> void:
	print("\n== the 1% low converts rather than being dropped ==")
	# The headline column: the mean of the worst 1% of frames. It is a frame time like any other,
	# so it converts the same way — the point is that it must still be REPORTED, because an
	# optimisation that moves the median and leaves this flat has improved nothing anyone feels.
	var median_ms: float = 11.11
	var low1_ms: float = 25.0
	check(is_equal_approx(PerfFormat.fps(low1_ms), 40.0),
		"a 25 ms worst-1%% mean reads as a 40 fps 1%% low (%.0f)" % PerfFormat.fps(low1_ms))
	check(PerfFormat.fps(low1_ms) < PerfFormat.fps(median_ms),
		"and stays visibly worse than the median it must not be averaged into (%.0f vs %.0f fps)"
			% [PerfFormat.fps(low1_ms), PerfFormat.fps(median_ms)])


func _check_unmeasured() -> void:
	print("\n== an unmeasured frame reports as unmeasured, not as an enormous frame rate ==")
	check(is_equal_approx(PerfFormat.fps(0.0), 0.0), "a zero frame time is 0 fps, not a division blow-up")
	check(PerfFormat.frame_cell(0.0).contains("—"), "a table cell for it prints a dash")
	check(is_equal_approx(PerfFormat.percent_of_frame(5.0, 0.0), 0.0),
		"a percentage against an unmeasured frame is 0, not infinity")
	check(PerfFormat.change_line(0.0, 11.11) == "not measured",
		"a change from an unmeasured baseline says so instead of inventing a gain")


func _check_change_direction() -> void:
	print("\n== faster is positive in every unit at once ==")
	var faster: String = PerfFormat.change_line(13.51, 11.11)
	print("     %s" % faster)
	check(faster.contains("+16 fps"), "a cheaper frame reads as a frame-rate GAIN (%s)" % faster)
	check(faster.contains("74 -> 90"), "and states where it came from and where it got to")
	var slower: String = PerfFormat.change_line(11.11, 13.51)
	print("     %s" % slower)
	check(slower.contains("-16 fps"), "a more expensive frame reads as a LOSS (%s)" % slower)
	# The sign trap this exists to close: ms goes DOWN when things get better and fps goes UP, so a
	# report that mixed the two could state a regression as an improvement without lying about any
	# individual number.
	check(faster.begins_with("+") and slower.begins_with("-"),
		"the two directions cannot be confused by switching units")
	check(PerfFormat.change_line(11.11, 11.11).contains("unchanged"),
		"no change says 'unchanged' rather than +0")


func _check_drift_gate() -> void:
	print("\n== a delta inside the run's own drift is still not a result ==")
	# The one way this conversion could make reports WORSE: a percentage looks more authoritative
	# than the millisecond it came from, so noise dressed as "3% of the frame" is more likely to be
	# acted on than "0.4 ms". The gate has to survive the conversion.
	check(PerfFormat.is_within_drift(0.4, 1.9), "a 0.4 ms delta inside 1.9 ms of drift is not reportable")
	check(not PerfFormat.is_within_drift(4.0, 1.9), "a 4 ms delta outside it is")
	check(PerfFormat.is_within_drift(-0.4, 1.9), "sign does not smuggle a delta past the gate")
	var free_line: String = PerfFormat.cost_line("ambient occlusion", 11.11, 11.11)
	check(free_line.contains("free"), "a lever with no measurable cost says 'free' (%s)" % free_line)
	var backwards: String = PerfFormat.cost_line("ambient occlusion", 11.11, 13.51)
	check(backwards.contains("drift"),
		"a lever that measured cheaper switched ON is called drift, not a saving (%s)" % backwards)


func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
		return
	failures += 1
	push_error("FAIL: %s" % description)

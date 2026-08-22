extends RefCounted

## How MIRE reports performance to a human (F-592).
##
## Sequoyah, 2026-08-22: *"performance has been reported to me in ms could we change that to % since
## i dont really understand ms as a human, fps or % makes sense to me."* He is the one deciding what
## to act on, so a number he has to convert in his head is a number he cannot judge.
##
## Every instrument that prints a frame timing goes through this file, so the conversion is defined
## once and can be checked on synthetic numbers (`tools/perf_format_check.gd`) instead of being
## re-derived, slightly differently, in each of a dozen tools.
##
## ## The rules
##
## * A frame TIME is reported as **FPS**.
## * A COST or SAVING is reported as **a percentage of the frame**, and/or as a **change in FPS**.
## * Milliseconds survive only as a trailing parenthetical, for whoever is doing the engineering.
##   Never as the primary figure.
##
## So not "shadows cost 2.4 ms" but "shadows cost 18% of the frame — 74 fps with them, 90 without".
##
## ## Why a percentage always names its baseline
##
## "18% of the frame" is meaningless without saying 18% of what, so every percent this file
## produces is printed next to the frame it was taken against. This is not politeness — ms and FPS
## are non-linear in each other, and 2 ms is a large win at 120 fps and a small one at 30. A bare
## millisecond delta could be quoted without ever stating the frame it came from, and routinely
## was; a percentage cannot be, which is what makes the converted claim checkable.
##
## ## The 1% low is still the headline
##
## His standing rule, and the reason `perf_probe` samples the way it does: *"thats what you feel."*
## The conversion turns the worst-1% mean frame time into a 1%-low FPS — it does not replace it
## with an average. An optimisation that lifts the median and leaves the 1% low flat has improved
## nothing anyone feels, and a report that leads with a mean hides exactly that.
##
## ## AUTHORITY: none
##
## Pure arithmetic on numbers already measured. No engine state is read here.

## Below this a frame time is treated as unmeasured rather than as an enormous frame rate — a zero
## delta is what an instrument returns when it never sampled, and 1e9 fps in a table reads as a
## result rather than as the absence of one.
const MIN_MEASURABLE_MS: float = 0.001


## Frame time to frame rate. Returns 0.0 for an unmeasured frame, so callers can print "—" rather
## than a number they would have to know to distrust.
static func fps(frame_ms: float) -> float:
	if frame_ms < MIN_MEASURABLE_MS:
		return 0.0
	return 1000.0 / frame_ms


## Frame rate back to frame time — the inverse, for the engineering parenthetical.
static func frame_ms(frames_per_second: float) -> float:
	if frames_per_second <= 0.0:
		return 0.0
	return 1000.0 / frames_per_second


## What share of the frame a cost occupies, as a percentage.
##
## [param frame_with_cost_ms] is the frame that CONTAINS the cost, which is what makes the answer
## mean "this much of the frame goes on that". Sequoyah's own worked example is the definition: a
## 2.4 ms cost inside a 13.5 ms frame (74 fps) is 18% — not 21.6%, which is what dividing by the
## 11.1 ms frame without it would give. Both numbers are defensible arithmetic and only one answers
## the question "how much of my frame is this".
static func percent_of_frame(cost_ms: float, frame_with_cost_ms: float) -> float:
	if frame_with_cost_ms < MIN_MEASURABLE_MS:
		return 0.0
	return cost_ms / frame_with_cost_ms * 100.0


## One lever's cost, phrased the way he asked for it:
##
##     shadows: 18% of the frame — 74 fps with, 90 fps without (2.40 ms of 13.51)
##
## [param with_ms] and [param without_ms] are the measured frame times either side of the lever.
## The percentage is of the WITH frame, per `percent_of_frame()`. A lever measured as free prints
## as free rather than as "0% of the frame", because the second reads as a rounding artefact.
static func cost_line(label: String, with_ms: float, without_ms: float) -> String:
	var cost: float = with_ms - without_ms
	if absf(cost) < MIN_MEASURABLE_MS:
		return "%s: free — no measurable difference (%.0f fps either way)" % [label, fps(with_ms)]
	if cost < 0.0:
		# The lever measured as CHEAPER when switched on. Real, and usually drift rather than
		# magic — say so plainly instead of printing a negative percentage nobody can act on.
		return "%s: no cost measured — %.0f fps with, %.0f fps without, which is backwards and is drift, not a saving (%+.2f ms)" % [
			label, fps(with_ms), fps(without_ms), cost
		]
	return "%s: %.0f%% of the frame — %.0f fps with, %.0f fps without (%.2f ms of %.2f)" % [
		label, percent_of_frame(cost, with_ms), fps(with_ms), fps(without_ms), cost, with_ms
	]


## A change between two measurements, as FPS and as a percentage of the frame it started from.
## Positive means FASTER — the frame got cheaper — regardless of which unit you read it in, so a
## report cannot accidentally invert its own sign by switching units.
##
##     +12 fps (74 -> 86, 14% of the frame)
static func change_line(before_ms: float, after_ms: float) -> String:
	if before_ms < MIN_MEASURABLE_MS or after_ms < MIN_MEASURABLE_MS:
		return "not measured"
	var saved: float = before_ms - after_ms
	var gained: float = fps(after_ms) - fps(before_ms)
	if absf(saved) < MIN_MEASURABLE_MS:
		return "unchanged (%.0f fps)" % fps(before_ms)
	return "%+.0f fps (%.0f -> %.0f, %+.0f%% of the frame)" % [
		gained, fps(before_ms), fps(after_ms), percent_of_frame(saved, before_ms)
	]


## A frame time for a table column: FPS first, ms in the parenthetical it is now demoted to.
static func frame_cell(frame_ms_value: float) -> String:
	if frame_ms_value < MIN_MEASURABLE_MS:
		return "     — fps"
	return "%6.0f fps (%.2f ms)" % [fps(frame_ms_value), frame_ms_value]


## Whether a difference is worth reporting at all, given how far the run's own baseline moved.
## A delta smaller than the drift is not a result, and printing it as a percentage makes it look
## MORE authoritative than the millisecond form did — which is the one way this conversion could
## make reports worse rather than better.
static func is_within_drift(delta_ms: float, drift_ms: float) -> bool:
	return absf(delta_ms) <= absf(drift_ms)

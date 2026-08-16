extends SceneTree

## Per-operation determinism probe — the follow-up to check_determinism.gd (risk R6, decision D-017).
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/check_determinism_ops.gd
##
## WHY THIS EXISTS
## check_determinism.gd bundles six float operations into one `float_math` hash. That hash diverged
## between macOS arm64 and Linux x86_64, which tells you there is a problem but not where. This splits
## them so the answer is actionable: which operations may world generation use, and which are banned.
##
## The measured answer (D-017) is that the split falls on the IEEE-754 line. Operations the standard
## requires to be correctly rounded — add, subtract, multiply, divide, sqrt — match on every platform.
## Operations that resolve to the platform's libm — sin, cos, tan, exp, log, pow — differ by about one
## unit in the last place, which is invisible in a single call and fatal after five octaves of noise.
##
## Run this alongside check_determinism.gd on any new platform. If a "safe" row ever fails, the §7
## world-gen safe set is wrong and §4 has to be revisited immediately.

const N := 2048


func _initialize() -> void:
	print("\nplatform : %s  arch : %s  godot : %s" % [
		OS.get_name(),
		Engine.get_architecture_name(),
		Engine.get_version_info().get("string", "?"),
	])
	print("")
	print("--- must match everywhere (IEEE-754 correctly rounded) ---")
	_report("arith", func(t: float) -> float: return ((t * 1.37 + 0.11) / 3.9 - t) * 0.5)
	_report("sqrt", func(t: float) -> float: return sqrt(t + 1.0))
	_report("vec2_length", func(t: float) -> float: return Vector2(t - 17.0, t * 0.5 - 9.0).length())
	# The §4 island falloff in its safe form. pow(d, 3.0) would put this in the section below.
	_report("falloff_safe", func(t: float) -> float:
		var d: float = Vector2(t - 17.0, t * 0.5 - 9.0).length() / 24.0
		return clampf(1.0 - d * d * d, 0.0, 1.0))

	print("\n--- expected to diverge (platform libm) — banned in world gen ---")
	_report("sin", func(t: float) -> float: return sin(t))
	_report("cos", func(t: float) -> float: return cos(t))
	_report("tan", func(t: float) -> float: return tan(t))
	_report("exp", func(t: float) -> float: return exp(t * 0.01))
	_report("log", func(t: float) -> float: return log(t + 1.0))
	_report("pow_3", func(t: float) -> float: return pow(t + 1.0, 3.0))
	_report("pow_1_7", func(t: float) -> float: return pow(t + 1.0, 1.7))

	print("\nThe first group failing is the serious result — it invalidates ARCHITECTURE.md §7.")
	quit()


func _report(label: String, op: Callable) -> void:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for i in N:
		var t: float = float(i) * 0.017
		ctx.update(PackedFloat64Array([op.call(t)]).to_byte_array())
	# Raw bits, not a rounded string: a printed decimal hides exactly the 1-ULP gap being hunted.
	var sample_bits := PackedFloat64Array([op.call(17.0)]).to_byte_array().hex_encode()
	print("%-14s %s   sample_bits=%s" % [label, ctx.finish().hex_encode().substr(0, 16), sample_bits])

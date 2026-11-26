extends SceneTree

var failures: Array[String] = []
var assertion_count := 0


func _initialize() -> void:
	call_deferred("_run_suite")


func run_tests() -> void:
	expect(false, "Suite must implement run_tests")


func expect(condition: bool, message: String = "") -> bool:
	assertion_count += 1
	if not condition:
		var detail := message if message != "" else "Expectation %d failed" % assertion_count
		failures.append(detail)
		push_error(detail)
	return condition


func _run_suite() -> void:
	await run_tests()
	if assertion_count == 0:
		failures.append("No assertions executed")
	var result := {
		"suite": get_script().resource_path.get_file().get_basename(),
		"assertions": assertion_count,
		"failures": failures,
		"passed": failures.is_empty()
	}
	print("RAIDDECK_TEST_RESULT " + JSON.stringify(result))
	quit(0 if failures.is_empty() else 1)

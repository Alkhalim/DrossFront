class_name ConveyorNetworkRenderer
extends Node
## Draws belt segments between connected network members. One
## MultiMeshInstance3D per owner_id, holding all of that owner's
## belt segments as scaled/rotated capsules. Rebuilt on every
## network_changed signal — at realistic graph sizes (≤50 nodes,
## ~80 edges) the rebuild is O(n²) ≈ <1 ms.

const BELT_RADIUS: float = 0.30
const BELT_Y_OFFSET: float = 0.20  # slightly above ground

## Scrolling-stripe shader so belts read as moving industrial conveyors,
## not glow capsules. The belt body stays dark (rubber/metal) and a thin
## bright pip travels along UV.y. Per-instance COLOR (from
## set_instance_color) drives both the dark body and the pip accent, so
## network fullness scales brightness without changing the dark/light
## ratio. Slow scroll + thin pip + dark body together read as "industrial
## belt with marker stripes," not "neon strip lighting."
const BELT_SHADER_CODE: String = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

uniform float scroll_speed = 0.25;
uniform float stripe_density = 1.5;
uniform float body_dim = 0.30;     // darkness of the belt body
uniform float pip_boost = 1.30;    // brightness of the marker pip

void fragment() {
	float v = UV.y * stripe_density - TIME * scroll_speed * stripe_density;
	float phase = fract(v);
	// Thin bright pip (~10% of stripe period) with soft edges.
	float pip = smoothstep(0.00, 0.04, phase) - smoothstep(0.10, 0.16, phase);
	vec3 body = COLOR.rgb * body_dim;
	vec3 accent = COLOR.rgb * pip_boost;
	ALBEDO = mix(body, accent, pip);
	ALPHA = COLOR.a;
}
"""

var _mmi_by_owner: Dictionary = {}  # owner_id -> MultiMeshInstance3D


func setup(cnm: ConveyorNetworkManager) -> void:
	cnm.network_changed.connect(_on_network_changed)


func _on_network_changed(owner_id: int) -> void:
	var cnm: ConveyorNetworkManager = get_parent().get_node_or_null("ConveyorNetworkManager") as ConveyorNetworkManager
	if cnm == null:
		return
	var adj: Dictionary = cnm._adjacency.get(owner_id, {})
	var meta: Dictionary = cnm._network_meta.get(owner_id, {})
	var mem: Dictionary = cnm._membership.get(owner_id, {})
	# Collect unique edges (a→b only when id(a) < id(b)).
	var edges: Array = []
	for a in adj.keys():
		if not is_instance_valid(a):
			continue
		for b in adj[a]:
			if not is_instance_valid(b):
				continue
			if a.get_instance_id() < b.get_instance_id():
				var net_id: int = mem.get(a, 0)
				var m: Dictionary = meta.get(net_id, {})
				edges.append({"a": a.global_position, "b": b.global_position, "fullness": int(m.get("production_total", 0))})
	# Get or create the MultiMeshInstance3D for this owner.
	var mmi: MultiMeshInstance3D = _mmi_by_owner.get(owner_id, null)
	if mmi == null:
		mmi = MultiMeshInstance3D.new()
		mmi.name = "ConveyorBelts_p%d" % owner_id
		var mm := MultiMesh.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = BELT_RADIUS
		cyl.bottom_radius = BELT_RADIUS
		cyl.height = 1.0  # scale on Y per-instance
		mm.mesh = cyl
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mmi.multimesh = mm
		var shader := Shader.new()
		shader.code = BELT_SHADER_CODE
		var mat := ShaderMaterial.new()
		mat.shader = shader
		cyl.material = mat
		add_child(mmi)
		_mmi_by_owner[owner_id] = mmi
	# Resize and populate transforms + colors.
	mmi.multimesh.instance_count = edges.size()
	for i in range(edges.size()):
		var e: Dictionary = edges[i]
		var a: Vector3 = e.a + Vector3.UP * BELT_Y_OFFSET
		var b: Vector3 = e.b + Vector3.UP * BELT_Y_OFFSET
		var length: float = a.distance_to(b)
		# Build the basis with the cylinder's long axis (local Y) directly
		# baked to (dir * length). Important quirk: Basis.scaled(scale) in
		# Godot 4 scales the basis by WORLD axes (it's b * Basis.from_scale),
		# so `Basis(x, dir_unit, z).scaled(Vector3(1, length, 1))` with a
		# horizontal dir multiplies the world-Y row by length — leaving the
		# cylinder unit-long and standing upright. Putting the length on the
		# y_axis vector itself sidesteps that entirely.
		var dir: Vector3 = (b - a).normalized() if length > 0.0001 else Vector3.RIGHT
		var up_hint: Vector3 = Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var x_axis: Vector3 = dir.cross(up_hint).normalized()
		var z_axis: Vector3 = x_axis.cross(dir).normalized()
		var t := Transform3D.IDENTITY
		t.origin = (a + b) * 0.5
		t.basis = Basis(x_axis, dir * length, z_axis)
		mmi.multimesh.set_instance_transform(i, t)
		# Per-instance COLOR feeds both belt body and pip in the shader.
		# Base hue is a deep industrial orange; brightness scales with
		# network fullness so a 3-prod-building network reads slightly
		# warmer/more "alive" than a solo 1-prod link.
		var bright: float = clampf(0.55 + 0.15 * float(e.fullness), 0.55, 0.90)
		mmi.multimesh.set_instance_color(i, Color(0.80 * bright, 0.42 * bright, 0.10 * bright, 0.95))

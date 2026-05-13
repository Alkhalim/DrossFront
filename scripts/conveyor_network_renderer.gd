class_name ConveyorNetworkRenderer
extends Node
## Draws belt segments between connected network members as a flat
## textured strip on the ground. One MultiMeshInstance3D per owner_id,
## one PlaneMesh instance per belt edge. Rebuilt on every
## network_changed signal — at realistic graph sizes (≤50 nodes,
## ~80 edges) the rebuild is O(n) ≈ <1 ms.

const BELT_WIDTH: float = 0.95   # world units across the belt
const BELT_Y_OFFSET: float = 0.06  # sits just above ground decals

## Industrial belt shader: dark rubber-grey body, near-black side rails,
## subtle perpendicular tread texture, and scrolling chevron arrows that
## point in the flow direction. INSTANCE_CUSTOM.rgb feeds per-instance
## tint (so fullness scales brightness without recoloring the whole
## thing); INSTANCE_CUSTOM.a passes the belt's world-space length so
## chevron spacing stays constant regardless of how long any one belt
## is — without that, longer belts would have visually-sparser arrows.
const BELT_SHADER_CODE: String = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

uniform float scroll_speed = 0.35;          // world units / sec
uniform float chevron_world_period = 0.85;  // world units between chevron tips
uniform float chevron_slope = 0.45;          // tail lag (0=horizontal bar, 1=sharp V)

varying vec3 v_tint;
varying float v_length;

void vertex() {
	v_tint = INSTANCE_CUSTOM.rgb;
	v_length = INSTANCE_CUSTOM.a;
}

void fragment() {
	// u_centered: -1 at left rail, 0 at belt center, +1 at right rail.
	float u_centered = (UV.x - 0.5) * 2.0;
	// World-space V coordinate so chevron pitch stays constant per belt.
	float v_world = UV.y * v_length;
	// Chevron phase: arms lag toward the edges so the line traces a V
	// pointing in +UV.y direction. Subtract TIME so the V moves forward.
	float v_chevron = (v_world + abs(u_centered) * chevron_slope * 0.5 - TIME * scroll_speed) / chevron_world_period;
	float phase = fract(v_chevron);
	// Thin chevron band — ~8% of period, soft edges.
	float band = max(smoothstep(0.08, 0.00, phase), smoothstep(0.92, 1.00, phase));

	// Side rails: darken the outer ~10% of the belt width.
	float rail_outer = smoothstep(0.00, 0.08, UV.x) * smoothstep(1.00, 0.92, UV.x);

	// Fine perpendicular tread texture across the belt surface.
	float tread = 0.92 + 0.08 * sin(UV.x * 6.2831 * 7.0);

	// Grey-brown rubber body, lightly tinted by per-instance fullness.
	vec3 body = vec3(0.10, 0.09, 0.08) * tread;
	// Chevron accent — muted safety orange, also fullness-tinted.
	vec3 chev = vec3(0.55, 0.36, 0.10);
	// Dark metal side rails.
	vec3 rail = vec3(0.025, 0.025, 0.028);

	vec3 surface = mix(body, chev, band * 0.75);
	vec3 final_color = mix(rail, surface, rail_outer);
	// Per-instance tint scales overall brightness without changing palette.
	final_color *= v_tint;

	ALBEDO = final_color;
	ALPHA = 0.97;
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
		var plane := PlaneMesh.new()
		plane.size = Vector2(1.0, 1.0)  # unit plane, basis scales per-instance
		mm.mesh = plane
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mmi.multimesh = mm
		var shader := Shader.new()
		shader.code = BELT_SHADER_CODE
		var mat := ShaderMaterial.new()
		mat.shader = shader
		plane.material = mat
		add_child(mmi)
		_mmi_by_owner[owner_id] = mmi
	# Resize and populate transforms + per-instance tint/length.
	mmi.multimesh.instance_count = edges.size()
	for i in range(edges.size()):
		var e: Dictionary = edges[i]
		var a: Vector3 = e.a + Vector3.UP * BELT_Y_OFFSET
		var b: Vector3 = e.b + Vector3.UP * BELT_Y_OFFSET
		var length: float = a.distance_to(b)
		# PlaneMesh lies in its local XZ plane with normal +Y. We want:
		#   - local X along the belt width (perpendicular to flow)
		#   - local Y as the plane normal (world UP)
		#   - local Z along the belt length (flow direction)
		# Bake the per-instance width and length into the basis vectors
		# directly — Basis.scaled() in Godot 4 scales by world axes and
		# wouldn't stretch a tilted Z properly.
		var dir: Vector3 = (b - a).normalized() if length > 0.0001 else Vector3.RIGHT
		var width_dir: Vector3 = Vector3.UP.cross(dir).normalized()
		if width_dir.length_squared() < 0.0001:
			width_dir = Vector3.RIGHT  # degenerate (belt direction is vertical)
		var t := Transform3D.IDENTITY
		t.origin = (a + b) * 0.5
		t.basis = Basis(width_dir * BELT_WIDTH, Vector3.UP, dir * length)
		mmi.multimesh.set_instance_transform(i, t)
		# Per-instance custom data: rgb = tint, a = belt world length.
		# Fullness scales brightness on a tight range so even a full
		# network reads as belt material, not glow.
		var bright: float = clampf(0.65 + 0.10 * float(e.fullness), 0.65, 0.95)
		mmi.multimesh.set_instance_custom_data(i, Color(bright, bright, bright, length))

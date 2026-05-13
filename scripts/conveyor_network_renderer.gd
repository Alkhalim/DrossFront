class_name ConveyorNetworkRenderer
extends Node
## Draws belt segments + structural frame (posts + side rails) between
## connected network members. Two MultiMeshInstance3Ds per owner_id:
##   - "ConveyorBelts_p{N}":  PlaneMesh, scrolling-chevron belt surface
##   - "ConveyorStruct_p{N}": BoxMesh, shared by posts (vertical square
##                            pillars) and side rails (horizontal beams
##                            connecting the post tops along the belt
##                            edge). Both use the same dark unshaded
##                            material so they share an instance pool.
## Rebuilt on every network_changed signal. At realistic graph sizes
## (≤50 nodes, ~80 edges, ~600 struct pieces) the rebuild is O(n) and
## comfortably under 1 ms.

const BELT_WIDTH: float = 0.95     # world units across the belt
const BELT_Y_OFFSET: float = 0.22  # belt height above ground; posts hold it
const POST_SPACING: float = 2.0    # one post-pair every N world units
const POST_XY_SIZE: float = 0.08   # square post footprint
const POST_SIDE_OFFSET: float = BELT_WIDTH * 0.5  # at the belt edge
const RAIL_THICKNESS: float = 0.06  # rail square cross-section


## Industrial belt shader: dark rubber-grey body, near-black side rails
## via UV.x masking, subtle perpendicular tread texture, and scrolling
## safety-orange chevron arrows that point in the flow direction.
## INSTANCE_CUSTOM.rgb feeds per-instance tint (fullness scales
## brightness); INSTANCE_CUSTOM.a passes the belt's world-space length
## so chevron pitch stays constant regardless of belt length.
const BELT_SHADER_CODE: String = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

uniform float scroll_speed = 0.30;
uniform float chevron_world_period = 0.85;
uniform float chevron_slope = 0.55;

varying vec3 v_tint;
varying float v_length;

void vertex() {
	v_tint = INSTANCE_CUSTOM.rgb;
	v_length = INSTANCE_CUSTOM.a;
}

void fragment() {
	float u_centered = (UV.x - 0.5) * 2.0;
	float v_world = UV.y * v_length;
	float v_chevron = (v_world + abs(u_centered) * chevron_slope * 0.5 + TIME * scroll_speed) / chevron_world_period;
	float phase = fract(v_chevron);
	float band = max(smoothstep(0.08, 0.00, phase), smoothstep(0.92, 1.00, phase));

	float rail_outer = smoothstep(0.00, 0.08, UV.x) * smoothstep(1.00, 0.92, UV.x);
	float ao = 1.0 - 0.35 * abs(u_centered);
	float tread = 0.92 + 0.08 * sin(UV.x * 6.2831 * 7.0);

	vec3 body = vec3(0.10, 0.09, 0.08) * tread * ao;
	vec3 chev = vec3(0.55, 0.36, 0.10) * ao;
	vec3 rail = vec3(0.025, 0.025, 0.028);

	vec3 surface = mix(body, chev, band * 0.75);
	vec3 final_color = mix(rail, surface, rail_outer);
	final_color *= v_tint;

	ALBEDO = final_color;
	ALPHA = 0.97;
}
"""


## Structural-frame shader (posts + side rails). Subtle vertical
## gradient: near-black at the base, slightly brighter at the top,
## so a square post reads as 3D rather than as a flat black sticker.
const STRUCT_SHADER_CODE: String = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

void fragment() {
	float top_lit = clamp(UV.y, 0.0, 1.0);
	vec3 base = mix(vec3(0.05, 0.05, 0.06), vec3(0.20, 0.19, 0.18), top_lit);
	ALBEDO = base;
	ALPHA = 1.0;
}
"""


var _belts_by_owner: Dictionary = {}    # owner_id -> MultiMeshInstance3D (belts)
var _struct_by_owner: Dictionary = {}   # owner_id -> MultiMeshInstance3D (posts + rails)


func setup(cnm: ConveyorNetworkManager) -> void:
	cnm.network_changed.connect(_on_network_changed)


func _on_network_changed(owner_id: int) -> void:
	var cnm: ConveyorNetworkManager = get_parent().get_node_or_null("ConveyorNetworkManager") as ConveyorNetworkManager
	if cnm == null:
		return
	var adj: Dictionary = cnm._adjacency.get(owner_id, {})
	var meta: Dictionary = cnm._network_meta.get(owner_id, {})
	var mem: Dictionary = cnm._membership.get(owner_id, {})
	# Unique edges (a→b only when id(a) < id(b)).
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

	_rebuild_belts(owner_id, edges)
	_rebuild_struct(owner_id, edges)


func _rebuild_belts(owner_id: int, edges: Array) -> void:
	var mmi: MultiMeshInstance3D = _belts_by_owner.get(owner_id, null)
	if mmi == null:
		mmi = MultiMeshInstance3D.new()
		mmi.name = "ConveyorBelts_p%d" % owner_id
		var mm := MultiMesh.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(1.0, 1.0)
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
		_belts_by_owner[owner_id] = mmi
	mmi.multimesh.instance_count = edges.size()
	for i in range(edges.size()):
		var e: Dictionary = edges[i]
		var a: Vector3 = e.a + Vector3.UP * BELT_Y_OFFSET
		var b: Vector3 = e.b + Vector3.UP * BELT_Y_OFFSET
		var length: float = a.distance_to(b)
		var dir: Vector3 = (b - a).normalized() if length > 0.0001 else Vector3.RIGHT
		var width_dir: Vector3 = Vector3.UP.cross(dir).normalized()
		if width_dir.length_squared() < 0.0001:
			width_dir = Vector3.RIGHT
		var t := Transform3D.IDENTITY
		t.origin = (a + b) * 0.5
		t.basis = Basis(width_dir * BELT_WIDTH, Vector3.UP, dir * length)
		mmi.multimesh.set_instance_transform(i, t)
		var bright: float = clampf(0.65 + 0.10 * float(e.fullness), 0.65, 0.95)
		mmi.multimesh.set_instance_custom_data(i, Color(bright, bright, bright, length))


func _rebuild_struct(owner_id: int, edges: Array) -> void:
	## Posts + side rails share a unit BoxMesh and one ShaderMaterial.
	## Each instance scales the basis to either a square post (tall thin
	## box) or a long horizontal rail (thin box along the flow axis).
	var total: int = 0
	for e in edges:
		var dist: float = (e.a as Vector3).distance_to(e.b as Vector3)
		var fractions_count: int = int(ceil(dist / POST_SPACING)) + 1  # endpoints + intermediate
		total += 2 * fractions_count  # left + right post per fraction
		total += 2                    # left + right rail per belt
	var mmi: MultiMeshInstance3D = _struct_by_owner.get(owner_id, null)
	if mmi == null:
		mmi = MultiMeshInstance3D.new()
		mmi.name = "ConveyorStruct_p%d" % owner_id
		var mm := MultiMesh.new()
		var box := BoxMesh.new()
		box.size = Vector3.ONE  # unit cube; basis does the sizing
		mm.mesh = box
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mmi.multimesh = mm
		var shader := Shader.new()
		shader.code = STRUCT_SHADER_CODE
		var mat := ShaderMaterial.new()
		mat.shader = shader
		box.material = mat
		add_child(mmi)
		_struct_by_owner[owner_id] = mmi
	mmi.multimesh.instance_count = total
	var idx: int = 0
	for e in edges:
		var a: Vector3 = e.a as Vector3
		var b: Vector3 = e.b as Vector3
		var length: float = a.distance_to(b)
		var dir: Vector3 = (b - a).normalized() if length > 0.0001 else Vector3.RIGHT
		var side: Vector3 = Vector3.UP.cross(dir).normalized()
		if side.length_squared() < 0.0001:
			side = Vector3.RIGHT

		# --- Rails: thin horizontal beam along each side of the belt,
		# sitting at belt height so the chevron strip visually rests on
		# top of them.
		var rail_y: float = BELT_Y_OFFSET - RAIL_THICKNESS * 0.5
		for side_sign in [1.0, -1.0]:
			var rail_center_xz: Vector3 = (a + b) * 0.5 + side * (side_sign * POST_SIDE_OFFSET)
			var t_rail := Transform3D.IDENTITY
			t_rail.origin = Vector3(rail_center_xz.x, rail_y, rail_center_xz.z)
			# Local X across the side (thin), local Y vertical (thin),
			# local Z along the belt (full length).
			t_rail.basis = Basis(side * RAIL_THICKNESS, Vector3.UP * RAIL_THICKNESS, dir * length)
			mmi.multimesh.set_instance_transform(idx, t_rail)
			idx += 1

		# --- Posts: square pillars at intervals (incl. both endpoints).
		# Top of post = bottom of rail (BELT_Y_OFFSET - RAIL_THICKNESS).
		var post_height: float = BELT_Y_OFFSET - RAIL_THICKNESS
		var post_y_center: float = post_height * 0.5
		var fractions_count: int = int(ceil(length / POST_SPACING)) + 1
		for fi in range(fractions_count):
			# Even distribution: f=0 at a, f=1 at b, and (fractions_count-2)
			# intermediate points evenly between them.
			var f: float = float(fi) / float(maxi(fractions_count - 1, 1))
			var pt: Vector3 = a.lerp(b, f)
			for side_sign in [1.0, -1.0]:
				var post_pos: Vector3 = pt + side * (side_sign * POST_SIDE_OFFSET)
				var t_post := Transform3D.IDENTITY
				t_post.origin = Vector3(post_pos.x, post_y_center, post_pos.z)
				# Identity-basis scaled in world coords by (xy, height, xy)
				# is correct here precisely because the basis IS identity —
				# world axes line up with local axes. For tilted bases see
				# the belt renderer comment about Basis.scaled scaling
				# world axes.
				t_post.basis = Basis().scaled(Vector3(POST_XY_SIZE, post_height, POST_XY_SIZE))
				mmi.multimesh.set_instance_transform(idx, t_post)
				idx += 1

class_name ConveyorNetworkRenderer
extends Node
## Draws belt segments + support posts between connected network
## members. Two MultiMeshInstance3Ds per owner_id:
##   - "belts_p{N}": flat textured strip on the ground (PlaneMesh)
##   - "posts_p{N}": small vertical pillars on each side at intervals
##                  (CylinderMesh) so the belt reads as a raised object
## Rebuilt on every network_changed signal. At realistic graph sizes
## (≤50 nodes, ~80 edges, ~400 posts) the rebuild is O(n) and <1 ms.

const BELT_WIDTH: float = 0.95     # world units across the belt
const BELT_Y_OFFSET: float = 0.22  # raised above ground; posts hold it up
const POST_SPACING: float = 2.0    # one post-pair every N world units
const POST_RADIUS: float = 0.10
const POST_SIDE_OFFSET: float = BELT_WIDTH * 0.55  # just outside the belt edge

## Industrial belt shader: dark rubber-grey body, near-black side rails,
## subtle perpendicular tread texture, and scrolling safety-orange
## chevron arrows that point in the flow direction. INSTANCE_CUSTOM.rgb
## feeds per-instance tint (fullness scales brightness); INSTANCE_CUSTOM.a
## passes the belt's world-space length so chevron pitch stays constant
## regardless of belt length. Edge darkening near UV.x = 0 and 1 gives
## the belt a softly-AO'd 3D feel without needing real lighting.
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
	// Reversed: chevrons now travel in the +flow direction (matches the
	// player's mental model of belts moving "forward" along a→b).
	float v_chevron = (v_world + abs(u_centered) * chevron_slope * 0.5 + TIME * scroll_speed) / chevron_world_period;
	float phase = fract(v_chevron);
	float band = max(smoothstep(0.08, 0.00, phase), smoothstep(0.92, 1.00, phase));

	// Side rails: darken the outer ~10% of the belt width.
	float rail_outer = smoothstep(0.00, 0.08, UV.x) * smoothstep(1.00, 0.92, UV.x);

	// Belt-center to belt-edge ambient gradient — fake AO that makes
	// the belt sit "inside" the side rails instead of floating flat.
	float ao = 1.0 - 0.35 * abs(u_centered);

	// Fine perpendicular tread texture across the belt surface.
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

## Support-post shader: dark metal cylinders, plain unshaded but with a
## vertical gradient (slightly brighter at top, near-black at bottom) so
## the post reads as a 3D object rather than a flat dark spot.
const POST_SHADER_CODE: String = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

void fragment() {
	float top_lit = clamp(UV.y, 0.0, 1.0);
	vec3 base = mix(vec3(0.04, 0.04, 0.05), vec3(0.18, 0.17, 0.16), top_lit);
	ALBEDO = base;
	ALPHA = 1.0;
}
"""

var _belts_by_owner: Dictionary = {}  # owner_id -> MultiMeshInstance3D (belts)
var _posts_by_owner: Dictionary = {}  # owner_id -> MultiMeshInstance3D (posts)


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

	_rebuild_belts(owner_id, edges)
	_rebuild_posts(owner_id, edges)


func _rebuild_belts(owner_id: int, edges: Array) -> void:
	var mmi: MultiMeshInstance3D = _belts_by_owner.get(owner_id, null)
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
		_belts_by_owner[owner_id] = mmi
	mmi.multimesh.instance_count = edges.size()
	for i in range(edges.size()):
		var e: Dictionary = edges[i]
		var a: Vector3 = e.a + Vector3.UP * BELT_Y_OFFSET
		var b: Vector3 = e.b + Vector3.UP * BELT_Y_OFFSET
		var length: float = a.distance_to(b)
		# PlaneMesh local-Y is its normal; local-X is across; local-Z is
		# along. Set X = width_dir * BELT_WIDTH and Z = dir * length so
		# the plane covers exactly the a→b strip at the right size.
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


func _rebuild_posts(owner_id: int, edges: Array) -> void:
	## One pair of support posts (left + right) every POST_SPACING units
	## along each belt, plus an endpoint pair at each side. Gives the
	## belt a visible "raised on legs" silhouette from any camera angle.
	var post_count_total: int = 0
	for e in edges:
		var dist: float = (e.a as Vector3).distance_to(e.b as Vector3)
		# 2 posts per spacing point + 2 at each end (4 endpoint posts).
		# At minimum 4 posts per belt (just the endpoints).
		var spans: int = int(ceil(dist / POST_SPACING))
		post_count_total += (spans - 1) * 2 + 4
	var mmi: MultiMeshInstance3D = _posts_by_owner.get(owner_id, null)
	if mmi == null:
		mmi = MultiMeshInstance3D.new()
		mmi.name = "ConveyorPosts_p%d" % owner_id
		var mm := MultiMesh.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = POST_RADIUS
		cyl.bottom_radius = POST_RADIUS
		cyl.height = 1.0  # scaled per-instance via basis
		mm.mesh = cyl
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mmi.multimesh = mm
		var shader := Shader.new()
		shader.code = POST_SHADER_CODE
		var mat := ShaderMaterial.new()
		mat.shader = shader
		cyl.material = mat
		add_child(mmi)
		_posts_by_owner[owner_id] = mmi
	mmi.multimesh.instance_count = post_count_total
	var post_idx: int = 0
	for e in edges:
		var a: Vector3 = e.a as Vector3
		var b: Vector3 = e.b as Vector3
		var length: float = a.distance_to(b)
		var dir: Vector3 = (b - a).normalized() if length > 0.0001 else Vector3.RIGHT
		var side: Vector3 = Vector3.UP.cross(dir).normalized()
		if side.length_squared() < 0.0001:
			side = Vector3.RIGHT
		var spans: int = int(ceil(length / POST_SPACING))
		# Emit posts at each fractional point along the belt + both
		# endpoints. Endpoints are at f=0 and f=1; intermediate posts
		# at i/spans for i in 1..spans-1.
		var fractions: PackedFloat32Array = PackedFloat32Array([0.0, 1.0])
		for i in range(1, spans):
			fractions.append(float(i) / float(spans))
		for f in fractions:
			var pt: Vector3 = a.lerp(b, f)
			for side_sign in [1.0, -1.0]:
				var post_pos: Vector3 = pt + side * (side_sign * POST_SIDE_OFFSET)
				# CylinderMesh long axis is local Y. We want it standing
				# vertical, height = BELT_Y_OFFSET so the top meets the
				# bottom of the belt. Center the cylinder at half-height
				# above ground so its base sits at y=0.
				var t := Transform3D.IDENTITY
				t.origin = Vector3(post_pos.x, BELT_Y_OFFSET * 0.5, post_pos.z)
				t.basis = Basis().scaled(Vector3(1.0, BELT_Y_OFFSET, 1.0))
				mmi.multimesh.set_instance_transform(post_idx, t)
				post_idx += 1

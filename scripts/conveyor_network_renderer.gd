class_name ConveyorNetworkRenderer
extends Node
## Draws belt segments between connected network members. One
## MultiMeshInstance3D per owner_id, holding all of that owner's
## belt segments as scaled/rotated capsules. Rebuilt on every
## network_changed signal — at realistic graph sizes (≤50 nodes,
## ~80 edges) the rebuild is O(n²) ≈ <1 ms.

const BELT_RADIUS: float = 0.30
const BELT_Y_OFFSET: float = 0.20  # slightly above ground

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
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.95, 0.55, 0.15, 0.85)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.vertex_color_use_as_albedo = true
		cyl.material = mat
		add_child(mmi)
		_mmi_by_owner[owner_id] = mmi
	# Resize and populate transforms + colors.
	mmi.multimesh.instance_count = edges.size()
	for i in range(edges.size()):
		var e: Dictionary = edges[i]
		var a: Vector3 = e.a + Vector3.UP * BELT_Y_OFFSET
		var b: Vector3 = e.b + Vector3.UP * BELT_Y_OFFSET
		var mid: Vector3 = (a + b) * 0.5
		var length: float = a.distance_to(b)
		var t := Transform3D.IDENTITY
		t.origin = mid
		t.basis = Basis().looking_at((b - a).normalized(), Vector3.UP)
		t.basis = t.basis * Basis(Vector3.RIGHT, -PI * 0.5)  # CylinderMesh Y → -Z (matches ProjectileManager._write_transform)
		t.basis = t.basis.scaled(Vector3(1.0, length, 1.0))
		mmi.multimesh.set_instance_transform(i, t)
		# Color brightness scales with network fullness (1, 2, 3 prod buildings).
		var bright: float = clampf(0.4 + 0.2 * float(e.fullness), 0.4, 1.0)
		mmi.multimesh.set_instance_color(i, Color(0.95 * bright, 0.55 * bright, 0.15 * bright, 0.85))

class_name MeshCombiner
extends RefCounted
## Walks a Node3D's MeshInstance3D descendants and produces a
## single ArrayMesh combining all their geometry, with vertices
## transformed by each child's relative transform. Materials are
## preserved as separate surfaces (one ArrayMesh surface per
## unique Material instance). Used by the MultiMesh migration:
## the per-unit procedural composition (~30 child MeshInstance3D
## nodes per chassis) bakes into one ArrayMesh that can be shared
## across all instances of a unit type and rendered via
## MultiMesh in a single draw call.
##
## The bake is a one-shot at game load (or on first use of a unit
## type). Per-instance variation (faction color, damage flash,
## stealth fade) is layered on top via MultiMesh's
## set_instance_color / set_instance_custom_data, NOT by re-baking.
##
## Limitations:
## - Only handles MeshInstance3D nodes whose mesh has triangle
##   surfaces. Particle / decal / point cloud surfaces are skipped.
## - Material identity is by-reference. Two visually identical
##   StandardMaterial3D instances will end up in separate surfaces
##   (extra draw calls but still vastly fewer than the unbaked
##   tree). Future optimization: hash material properties to merge.
## - Visibility is ignored; baked mesh draws every collected node
##   regardless of whether the source was hidden at bake time.

static func combine(root: Node3D) -> ArrayMesh:
	## Returns a single ArrayMesh combining every MeshInstance3D
	## descendant of `root`, with vertices transformed into root's
	## local space. The returned mesh has one surface per unique
	## material *signature* across the source tree — visually
	## identical StandardMaterial3D instances (same albedo, same
	## roughness, etc.) merge into the same surface even when the
	## underlying procedural unit-build code spawned a fresh
	## Material instance per MeshInstance3D. Without signature
	## grouping the bake produced one surface per source mesh
	## instance (defeating the point of MultiMesh batching).
	var entries: Array = []
	_collect_recursive(root, Transform3D.IDENTITY, entries, root)

	# Group entries by signature. Each group also remembers the
	# first Material instance it saw so the output ArrayMesh can
	# carry that material on the merged surface.
	var groups: Dictionary = {}      # sig -> { material, entries }
	var group_order: Array = []      # preserved insertion order for deterministic output
	for entry: Dictionary in entries:
		var mat: Material = entry.get("material", null) as Material
		var sig: String = _material_signature(mat)
		if not groups.has(sig):
			groups[sig] = {"material": mat, "entries": []}
			group_order.append(sig)
		((groups[sig] as Dictionary)["entries"] as Array).append(entry)

	var combined := ArrayMesh.new()
	for sig: String in group_order:
		var grp: Dictionary = groups[sig] as Dictionary
		var arrays: Array = _build_combined_surface(grp["entries"] as Array)
		if arrays.is_empty():
			continue
		combined.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var rep_mat: Material = grp["material"] as Material
		if rep_mat != null:
			var surf_idx: int = combined.get_surface_count() - 1
			combined.surface_set_material(surf_idx, rep_mat)
	return combined


static func _material_signature(mat: Material) -> String:
	## Stable key for grouping visually equivalent materials. For
	## StandardMaterial3D we hash the rendering-relevant properties
	## (albedo, metallic, roughness, emission, transparency, cull,
	## texture references). For other Material types we fall back
	## to instance identity — ShaderMaterials with the same shader
	## and uniforms COULD be merged, but extracting their parameter
	## values is finicky enough that it's not worth the bug
	## surface for the unit-bake use case.
	if mat == null:
		return "<null>"
	if mat is StandardMaterial3D:
		var sm: StandardMaterial3D = mat as StandardMaterial3D
		# Color components quantised to keep float-jitter in the
		# procedural unit-build palette from splitting groups.
		# 0.001 quantum is well below visual perception.
		var ac: Color = sm.albedo_color
		var em: Color = sm.emission
		var alb_tex_id: int = sm.albedo_texture.get_instance_id() if sm.albedo_texture != null else 0
		var nrm_tex_id: int = sm.normal_texture.get_instance_id() if sm.normal_texture != null else 0
		var em_tex_id: int = sm.emission_texture.get_instance_id() if sm.emission_texture != null else 0
		return "S|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d" % [
			int(ac.r * 1000.0),
			int(ac.g * 1000.0),
			int(ac.b * 1000.0),
			int(ac.a * 1000.0),
			int(sm.metallic * 1000.0),
			int(sm.roughness * 1000.0),
			int(em.r * 1000.0) if sm.emission_enabled else 0,
			int(em.g * 1000.0) if sm.emission_enabled else 0,
			int(em.b * 1000.0) if sm.emission_enabled else 0,
			int(sm.emission_energy_multiplier * 1000.0) if sm.emission_enabled else 0,
			int(sm.transparency),
			int(sm.cull_mode),
			alb_tex_id,
			nrm_tex_id + em_tex_id,  # combined into one slot to keep field count tight
		]
	# Anything else (ShaderMaterial, custom subclass) — group by
	# instance identity so we don't accidentally merge two distinct
	# shaders.
	return "I|" + str(mat.get_instance_id())


static func _collect_recursive(
		node: Node,
		parent_transform: Transform3D,
		entries: Array,
		bake_root: Node3D) -> void:
	if not is_instance_valid(node):
		return
	# Build the cumulative transform from bake_root to this node.
	# The root itself contributes nothing (we want vertices in its
	# local space, so its own transform is excluded).
	var local_transform: Transform3D = parent_transform
	if node is Node3D and node != bake_root:
		local_transform = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		if mi.mesh:
			var n_surfaces: int = mi.mesh.get_surface_count()
			for surf_idx: int in n_surfaces:
				var mat: Material = mi.get_surface_override_material(surf_idx)
				if mat == null:
					mat = mi.mesh.surface_get_material(surf_idx)
				entries.append({
					"mesh": mi.mesh,
					"surface": surf_idx,
					"transform": local_transform,
					"material": mat,
				})
	for child: Node in node.get_children():
		_collect_recursive(child, local_transform, entries, bake_root)


static func _build_combined_surface(entries: Array) -> Array:
	## Combines a list of (mesh, surface, transform, material)
	## entries (already grouped by material) into a single set of
	## vertex/index/normal/UV arrays.
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var any_norms: bool = false
	var any_uvs: bool = false

	for entry: Dictionary in entries:
		var mesh: Mesh = entry["mesh"] as Mesh
		var surf_idx: int = entry["surface"] as int
		var xform: Transform3D = entry["transform"] as Transform3D
		var src: Array = mesh.surface_get_arrays(surf_idx)
		# Some primitive meshes (BoxMesh / CylinderMesh) populate
		# every channel; others may leave normals or UVs empty.
		# Defensive index reads to cope with either.
		var src_verts: PackedVector3Array = src[Mesh.ARRAY_VERTEX] as PackedVector3Array
		if src_verts == null or src_verts.size() == 0:
			continue
		var src_norms_v: Variant = src[Mesh.ARRAY_NORMAL] if Mesh.ARRAY_NORMAL < src.size() else null
		var src_uvs_v: Variant = src[Mesh.ARRAY_TEX_UV] if Mesh.ARRAY_TEX_UV < src.size() else null
		var src_indices_v: Variant = src[Mesh.ARRAY_INDEX] if Mesh.ARRAY_INDEX < src.size() else null

		var vert_offset: int = verts.size()
		# Transform vertices into the bake-root's local space.
		for v: Vector3 in src_verts:
			verts.append(xform * v)

		if src_norms_v is PackedVector3Array and (src_norms_v as PackedVector3Array).size() > 0:
			any_norms = true
			# Transform normals by the basis (no translation; no
			# unit-length re-normalisation since uniform scale and
			# rigid rotation preserve length, and the procedural
			# unit composition uses those exclusively).
			for n: Vector3 in (src_norms_v as PackedVector3Array):
				norms.append((xform.basis * n).normalized())
		else:
			# Surface had no normals — pad zeros so the output
			# shape stays consistent if any other surface in this
			# group does provide normals.
			for _i: int in src_verts.size():
				norms.append(Vector3.ZERO)

		if src_uvs_v is PackedVector2Array and (src_uvs_v as PackedVector2Array).size() > 0:
			any_uvs = true
			uvs.append_array(src_uvs_v as PackedVector2Array)
		else:
			for _i: int in src_verts.size():
				uvs.append(Vector2.ZERO)

		if src_indices_v is PackedInt32Array and (src_indices_v as PackedInt32Array).size() > 0:
			for idx: int in (src_indices_v as PackedInt32Array):
				indices.append(idx + vert_offset)
		else:
			# Non-indexed surface: emit one index per vertex in
			# order, which preserves the implicit triangle list.
			var n_v: int = src_verts.size()
			for i: int in n_v:
				indices.append(vert_offset + i)

	if verts.size() == 0:
		return []

	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	if any_norms:
		out[Mesh.ARRAY_NORMAL] = norms
	if any_uvs:
		out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_INDEX] = indices
	return out


static func bake_stats(root: Node3D) -> Dictionary:
	## Diagnostic helper: bakes `root` and returns a stat dump
	## without keeping the result. Useful for sanity-checking the
	## combiner before wiring it into production.
	var combined: ArrayMesh = combine(root)
	var total_verts: int = 0
	var total_indices: int = 0
	var n_surfaces: int = combined.get_surface_count()
	for s: int in n_surfaces:
		var arr: Array = combined.surface_get_arrays(s)
		if arr.size() > Mesh.ARRAY_VERTEX:
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX] as PackedVector3Array
			if v != null:
				total_verts += v.size()
		if arr.size() > Mesh.ARRAY_INDEX:
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] as PackedInt32Array
			if idx != null:
				total_indices += idx.size()
	# Count source MeshInstance3D nodes for comparison.
	var src_count: int = _count_mesh_instances(root)
	return {
		"surfaces": n_surfaces,
		"vertices": total_verts,
		"indices": total_indices,
		"source_mesh_instances": src_count,
		"draw_call_reduction": maxi(src_count - n_surfaces, 0),
	}


static func _count_mesh_instances(node: Node) -> int:
	var n: int = 0
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		n += 1
	for child: Node in node.get_children():
		n += _count_mesh_instances(child)
	return n

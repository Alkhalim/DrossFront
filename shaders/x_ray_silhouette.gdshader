shader_type spatial;

// Renders a fragment ONLY when the silhouette mesh is occluded by
// something opaque in front of it (a building, terrain piece, etc.).
// Compares this fragment's depth against the scene depth previously
// written by the opaque pass. If the scene's depth is closer to the
// near plane than ours, an occluder is in front of us — draw the
// silhouette pixel in the team color so the player can still see
// where their unit is.
//
// The previous version reconstructed view-space Z via INV_PROJECTION_
// MATRIX and compared in linear units, but the depth-texture sample
// was returning near-plane values in some Forward+ frames and the
// silhouette drew everywhere. Comparing FRAGCOORD.z (the fragment's
// own NDC depth, [0,1] in Vulkan) against DEPTH_TEXTURE.r (also
// [0,1]) avoids the matrix math entirely and is more robust.

render_mode unshaded, depth_draw_never, depth_test_disabled, cull_back, blend_mix;

uniform vec4 outline_color : source_color = vec4(1.0, 0.5, 0.2, 0.85);
// Bias keeps the silhouette from flickering on thin edges where
// our own fragment is essentially co-planar with the scene depth.
uniform float depth_bias : hint_range(0.0, 0.01) = 0.0005;

void fragment() {
	// Scene depth at this screen pixel (opaque pass output, [0,1]).
	float scene_depth = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	// Our own NDC depth ([0,1] in Vulkan / Forward+).
	float my_depth = FRAGCOORD.z;
	// Smaller depth = closer to camera. If the scene is closer than
	// us (scene_depth < my_depth), an occluder is in front — show
	// the silhouette. Otherwise we're not occluded; discard.
	if (scene_depth >= my_depth - depth_bias) {
		discard;
	}
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}

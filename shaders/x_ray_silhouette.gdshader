shader_type spatial;

// Renders a fragment ONLY when something opaque is closer to the
// camera than the fragment itself -- i.e., the unit is occluded
// by a building / terrain piece. The silhouette mesh is drawn
// over the occluder in the team colour so the player can see
// where their unit is even when it's behind a foundry / wall.
//
// Uses the standard scene DEPTH_TEXTURE which Forward+ populates
// from the opaque pass. Unshaded + depth_test_disabled means the
// pixel sits on top of the building once the scene-depth check
// passes; depth_draw_never keeps the silhouette out of the
// depth buffer so it doesn't occlude the actual unit visual when
// the unit walks back into the open.

render_mode unshaded, depth_draw_never, depth_test_disabled, cull_back, blend_mix;

uniform vec4 outline_color : source_color = vec4(1.0, 0.5, 0.2, 0.85);
// Bias keeps the silhouette from flickering on the unit's own
// edges (where the unit's mesh is JUST barely closer than the
// silhouette mesh). Higher bias = silhouette only kicks in when
// occluder is clearly in front.
uniform float depth_bias : hint_range(0.0, 1.0) = 0.05;

varying vec3 view_pos;

void vertex() {
	view_pos = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Sample the depth texture at this screen pixel. The opaque
	// pass has already drawn buildings + terrain into it.
	float scene_depth_ndc = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	// Reconstruct view-space Z from the sampled NDC depth.
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, scene_depth_ndc);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	// Both view_pos.z and view.z are negative (camera looks -Z).
	// "Closer to camera" means LARGER z (less negative). The
	// occluder is in front of us if its z > our z. Equivalently,
	// |view.z| < |view_pos.z|.
	float scene_dist = -view.z;
	float my_dist = -view_pos.z;
	if (scene_dist >= my_dist - depth_bias) {
		discard;
	}
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}

shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform vec2 rect_size = vec2(300.0, 80.0);
uniform float blur_radius : hint_range(0.0, 4.0) = 1.6;
uniform float corner_radius : hint_range(0.0, 16.0) = 7.0;
uniform vec4 tint : source_color = vec4(0.035, 0.042, 0.055, 0.72);

void fragment() {
	// An explicit BackBufferCopy precedes all entries. No mipmaps or Forward+ features.
	vec2 step_uv = SCREEN_PIXEL_SIZE * blur_radius;
	vec3 blurred = texture(screen_texture, SCREEN_UV).rgb * 0.25;
	blurred += texture(screen_texture, SCREEN_UV + vec2(step_uv.x, 0.0)).rgb * 0.125;
	blurred += texture(screen_texture, SCREEN_UV - vec2(step_uv.x, 0.0)).rgb * 0.125;
	blurred += texture(screen_texture, SCREEN_UV + vec2(0.0, step_uv.y)).rgb * 0.125;
	blurred += texture(screen_texture, SCREEN_UV - vec2(0.0, step_uv.y)).rgb * 0.125;
	blurred += texture(screen_texture, SCREEN_UV + step_uv).rgb * 0.0625;
	blurred += texture(screen_texture, SCREEN_UV - step_uv).rgb * 0.0625;
	blurred += texture(screen_texture, SCREEN_UV + vec2(step_uv.x, -step_uv.y)).rgb * 0.0625;
	blurred += texture(screen_texture, SCREEN_UV + vec2(-step_uv.x, step_uv.y)).rgb * 0.0625;
	vec2 half_size = rect_size * 0.5;
	float radius = min(corner_radius, min(half_size.x, half_size.y));
	vec2 corner = abs(UV * rect_size - half_size) - (half_size - vec2(radius));
	float distance_to_edge = length(max(corner, vec2(0.0))) + min(max(corner.x, corner.y), 0.0) - radius;
	float coverage = 1.0 - smoothstep(-1.0, 0.0, distance_to_edge);
	COLOR = vec4(mix(blurred, tint.rgb, tint.a), coverage);
}

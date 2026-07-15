#include "common.glsl"

layout(origin_upper_left) in vec4 gl_FragCoord;

layout(binding = 0) uniform sampler2D image;

in vec2 tex_coord;

layout(location = 0) out vec4 out_FragColor;

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    if (scroll_cell_offset != 0.0 &&
        !in_terminal_vertical_clip(gl_FragCoord.y - grid_padding.x)) {
        out_FragColor = vec4(0.0);
        return;
    }

    vec4 rgba = texture(image, tex_coord);

    if (!use_linear_blending) {
        rgba = unlinearize(rgba);
    }

    rgba.rgb *= vec3(rgba.a);

    out_FragColor = rgba;
}

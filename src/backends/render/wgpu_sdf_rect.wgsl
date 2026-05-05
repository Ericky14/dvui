// SDF Rounded Rectangle shader for dvui wgpu backend
// Renders pixel-perfect rounded rects with analytical anti-aliasing.
// Each instance is one rounded rect (position, size, radii, colors, border).

struct Uniforms {
    projection: mat4x4<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct InstanceInput {
    // Rect position (top-left) in physical pixels
    @location(0) rect_pos: vec2<f32>,
    // Rect size in physical pixels
    @location(1) rect_size: vec2<f32>,
    // Corner radii: (top-left, top-right, bottom-right, bottom-left)
    @location(2) radii: vec4<f32>,
    // Fill color (premultiplied alpha)
    @location(3) fill_color: vec4<f32>,
    // Border color (premultiplied alpha)
    @location(4) border_color: vec4<f32>,
    // Border width (uniform for now), softness (AA width in pixels)
    @location(5) border_softness: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) local_pos: vec2<f32>,
    @location(1) rect_size: vec2<f32>,
    @location(2) radii: vec4<f32>,
    @location(3) fill_color: vec4<f32>,
    @location(4) border_color: vec4<f32>,
    @location(5) border_softness: vec2<f32>,
};

// Fullscreen quad vertices (2 triangles = 6 vertices)
// We generate the quad per-instance using vertex_index
@vertex
fn vs_main(@builtin(vertex_index) vi: u32, instance: InstanceInput) -> VertexOutput {
    // Quad corners: 0=TL, 1=TR, 2=BL, 3=BR
    // Triangle 1: 0,1,2  Triangle 2: 2,1,3
    var corner: vec2<f32>;
    switch (vi) {
        case 0u: { corner = vec2<f32>(0.0, 0.0); }
        case 1u: { corner = vec2<f32>(1.0, 0.0); }
        case 2u: { corner = vec2<f32>(0.0, 1.0); }
        case 3u: { corner = vec2<f32>(0.0, 1.0); }
        case 4u: { corner = vec2<f32>(1.0, 0.0); }
        default: { corner = vec2<f32>(1.0, 1.0); }
    }

    // Expand quad by 1px on each side for AA bleeding
    let aa_pad = 1.0;
    let padded_pos = instance.rect_pos - vec2<f32>(aa_pad);
    let padded_size = instance.rect_size + vec2<f32>(aa_pad * 2.0);

    let world_pos = padded_pos + corner * padded_size;

    var out: VertexOutput;
    out.position = uniforms.projection * vec4<f32>(world_pos, 0.0, 1.0);
    // Local position relative to rect center (not padded center)
    out.local_pos = (corner * padded_size) - vec2<f32>(aa_pad) - instance.rect_size * 0.5;
    out.rect_size = instance.rect_size;
    out.radii = instance.radii;
    out.fill_color = instance.fill_color;
    out.border_color = instance.border_color;
    out.border_softness = instance.border_softness;
    return out;
}

// SDF for a rounded rectangle centered at origin
// p: point relative to rect center
// half_size: half of rect dimensions
// r: corner radius for the nearest corner
fn sdf_rounded_rect(p: vec2<f32>, half_size: vec2<f32>, radii: vec4<f32>) -> f32 {
    // Select radius based on quadrant
    // radii: (top-left, top-right, bottom-right, bottom-left)
    var r: f32;
    if (p.x < 0.0) {
        if (p.y < 0.0) {
            r = radii.x; // top-left
        } else {
            r = radii.w; // bottom-left
        }
    } else {
        if (p.y < 0.0) {
            r = radii.y; // top-right
        } else {
            r = radii.z; // bottom-right
        }
    }

    let q = abs(p) - half_size + vec2<f32>(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2<f32>(0.0))) - r;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let half_size = in.rect_size * 0.5;
    let dist = sdf_rounded_rect(in.local_pos, half_size, in.radii);

    let border_width = in.border_softness.x;
    // AA softness: 1 pixel edge
    let softness = 1.0;

    if (border_width > 0.0) {
        // Outer edge alpha (fill + border region)
        let outer_alpha = 1.0 - smoothstep(-softness, 0.0, dist);
        // Inner edge (inside border)
        let inner_dist = dist + border_width;
        let inner_alpha = 1.0 - smoothstep(-softness, 0.0, inner_dist);

        // Border is the region between outer and inner
        let border_region = outer_alpha - inner_alpha;
        // Fill is the inner region
        let fill_region = inner_alpha;

        let color = in.fill_color * fill_region + in.border_color * border_region;
        if (color.a < 0.001) {
            discard;
        }
        return color;
    } else {
        // No border — just filled rounded rect
        let alpha = 1.0 - smoothstep(-softness, 0.0, dist);
        let color = in.fill_color * alpha;
        if (color.a < 0.001) {
            discard;
        }
        return color;
    }
}

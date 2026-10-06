#include <metal_stdlib>
using namespace metal;

struct MeshOutput {
	float4 position [[position]];
	float4 color;
};

float4 bernstein(float t) {
	float s = 1.0 - t;
	return float4(s*s*s, 3*s*s*t, 3*s*t*t, t*t*t);
}

vertex MeshOutput mesh_vertex(uint vid [[vertex_id]], uint patch [[instance_id]],
	device const float4 *data [[buffer(0)]], constant uint &subdivisions [[buffer(1)]]) {
	const uint2 corners[6] = { uint2(0,0), uint2(1,0), uint2(0,1), uint2(1,0), uint2(1,1), uint2(0,1) };
	uint cell = vid / 6;
	float2 uv = (float2(cell % subdivisions, cell / subdivisions) + float2(corners[vid % 6])) / float(subdivisions);
	float4 bu = bernstein(uv.x), bv = bernstein(uv.y);
	float4 p = 0, c = 0;
	for (uint y = 0; y < 4; ++y) {
		for (uint x = 0; x < 4; ++x) {
			float weight = bu[x] * bv[y];
			p += data[patch * 32 + y * 4 + x] * weight;
			c += data[patch * 32 + 16 + y * 4 + x] * weight;
		}
	}
	MeshOutput out;
	out.position = float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1);
	out.color = c;
	return out;
}

float3 encode_srgb(float3 c) {
	return select(12.92 * c, 1.055 * pow(max(c, 0.0), float3(1.0 / 2.4)) - 0.055, c > 0.0031308);
}

fragment float4 mesh_fragment(MeshOutput in [[stage_in]], constant uint &space [[buffer(0)]]) {
	float4 c = in.color;
	if (c.a <= 0.000001) { return float4(0); }
	c.rgb /= c.a;
	if (space == 1) {
		float l = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
		float m = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
		float s = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
		l = l*l*l; m = m*m*m; s = s*s*s;
		c.rgb = encode_srgb(float3(
			4.0767416621*l - 3.3077115913*m + 0.2309699292*s,
			-1.2684380046*l + 2.6097574011*m - 0.3413193965*s,
			-0.0041960863*l - 0.7034186147*m + 1.7076147010*s));
	}
	else if (space == 2) { c.rgb = encode_srgb(c.rgb); }
	c = clamp(c, 0.0, 1.0);
	return float4(c.rgb * c.a, c.a);
}

struct DebugVertex { float2 position; float2 padding; float4 color; };

vertex MeshOutput debug_vertex(uint vid [[vertex_id]], device const DebugVertex *vertices [[buffer(0)]]) {
	MeshOutput out;
	out.position = float4(vertices[vid].position.x * 2 - 1, 1 - vertices[vid].position.y * 2, 0, 1);
	out.color = vertices[vid].color;
	return out;
}

fragment float4 debug_fragment(MeshOutput in [[stage_in]]) {
	return float4(in.color.rgb * in.color.a, in.color.a);
}

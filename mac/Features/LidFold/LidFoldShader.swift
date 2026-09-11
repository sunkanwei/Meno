import Foundation

// Adapted from Mac Duo (MIT); see THIRD_PARTY_NOTICES.md.
enum LidFoldShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float progress; float perspective; float blur; float shadow; float2 size; };
    struct Varying { float4 position [[position]]; float2 uv; };

    vertex Varying foldVertex(uint id [[vertex_id]]) {
        const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
        Varying v;
        v.position = float4(p[id],0,1);
        v.uv = float2((p[id].x+1)*0.5f,1-(p[id].y+1)*0.5f);
        return v;
    }

    // Separable binomial filter [1,4,6,4,1]/16, evaluated with nine
    // bilinear reads while halving both dimensions. No random or time-based taps.
    kernel void foldDownsample(texture2d<float, access::sample> source [[texture(0)]],
                               texture2d<float, access::write> target [[texture(1)]],
                               uint2 pixel [[thread_position_in_grid]]) {
        if (pixel.x >= target.get_width() || pixel.y >= target.get_height()) return;
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(pixel)+0.5f)/float2(target.get_width(),target.get_height());
        float2 texel = 1.0f/float2(source.get_width(),source.get_height());
        const float offset[3] = {-1.2f,0,1.2f};
        const float weight[3] = {0.3125f,0.375f,0.3125f};
        float4 color = 0;
        for (uint y=0;y<3;y++) for (uint x=0;x<3;x++)
            color += source.sample(s,uv+float2(offset[x],offset[y])*texel)*weight[x]*weight[y];
        target.write(color,pixel);
    }

    fragment float4 foldFragment(Varying v [[stage_in]],
        texture2d<float> desktop [[texture(0)]], texture2d<float> pyramid [[texture(1)]],
        constant Uniforms& u [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
        float p = clamp(u.progress,0.0f,1.0f);
        if (p < 0.00001f) return float4(desktop.sample(s,v.uv).rgb,1);
        if (p >= 1.0f) return float4(0,0,0,1);
        // The physical lid already supplies the camera's trapezoid. Expand the
        // image around its bottom-centre hinge so icons swell and upper content
        // leaves through the top. A bounded map avoids singularities at closure.
        float height = 1.0f-v.uv.y;
        float expansion = 1.0f+p*(0.12f+mix(0.30f,0.66f,clamp(u.perspective,0.0f,1.0f))*height);
        float2 uv = float2(0.5f+(v.uv.x-0.5f)/expansion,1.0f-height/expansion);

        // Sigma is measured as a fraction of image height, matching the preview
        // and Retina desktop. The hinge stays more focused, but not pin-sharp.
        float focus = pow(p,0.7f);
        float spread = 0.12f+0.88f*pow(height,1.15f);
        float sigmaUV = clamp(u.blur,0.0f,1.0f)*0.052f*focus*spread;
        float sigma = sigmaUV*float(desktop.get_height());
        // Each 2x level contributes 1.25 source-pixel variance per axis.
        float lod = 0.5f*log2(1.0f+sigma*sigma*2.4f);
        lod = min(lod,float(pyramid.get_num_mip_levels()-1));
        float3 color = pyramid.sample(s,uv,level(lod)).rgb;
        // Feather in display coordinates: zooming the source beyond its borders
        // must not remove the dark surround. Side widths use height units to keep
        // the same optical width on different display aspect ratios.
        float softness = clamp(u.blur,0.0f,1.0f);
        float topWidth = p*(0.075f+0.15f*softness)+1.5f*sigmaUV;
        float sideWidth = (p*(0.055f+0.12f*softness)+1.5f*sigmaUV)*u.size.y/u.size.x;
        float bottomWidth = p*(0.012f+0.025f*softness)+0.5f*sigmaUV;
        float mask = smoothstep(0.0f,topWidth,v.uv.y)*smoothstep(0.0f,bottomWidth,height)
                   * smoothstep(0.0f,sideWidth,v.uv.x)*smoothstep(0.0f,sideWidth,1.0f-v.uv.x);
        float shade = 1.0f-clamp(u.shadow,0.0f,1.0f)*0.12f*p*p*height;
        float disappear = 1.0f-smoothstep(0.86f,1.0f,p);
        return float4(color*mask*shade*disappear,1);
    }
    """#
}

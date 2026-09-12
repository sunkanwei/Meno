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

    float3 encodeSRGB(float3 color) {
        color = max(color, 0.0f);
        return select(1.055f*pow(color, float3(1.0f/2.4f))-0.055f,
                      12.92f*color, color <= 0.0031308f);
    }

    kernel void foldLinearize(texture2d<float, access::sample> source [[texture(0)]],
                             texture2d<half, access::write> target [[texture(1)]],
                             uint2 pixel [[thread_position_in_grid]]) {
        if (pixel.x >= target.get_width() || pixel.y >= target.get_height()) return;
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
        float2 uv = (float2(pixel)+0.5f)/float2(target.get_width(),target.get_height());
        target.write(half4(half3(source.sample(s,uv).rgb), 1.0h), pixel);
    }

    // Positive cubic B-spline weights keep enlarged blur levels smooth without
    // ringing. Pair adjacent weights to evaluate sixteen texels in four reads.
    float4 cubicWeights(float f) {
        float g = 1.0f-f;
        return float4(g*g*g, 4.0f-6.0f*f*f+3.0f*f*f*f,
                      1.0f+3.0f*f+3.0f*f*f-3.0f*f*f*f, f*f*f)/6.0f;
    }

    float3 sampleCubic(texture2d<float> texture, float2 uv, uint mip) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::nearest);
        float2 size = float2(texture.get_width(mip), texture.get_height(mip));
        float2 position = uv*size-0.5f;
        float2 base = floor(position);
        float4 x = cubicWeights(fract(position.x));
        float4 y = cubicWeights(fract(position.y));
        float2 gx = float2(x.x+x.y, x.z+x.w);
        float2 gy = float2(y.x+y.y, y.z+y.w);
        float2 px = (base.x+float2(-0.5f+x.y/gx.x, 1.5f+x.w/gx.y))/size.x;
        float2 py = (base.y+float2(-0.5f+y.y/gy.x, 1.5f+y.w/gy.y))/size.y;
        float3 top = mix(texture.sample(s, float2(px.x,py.x), level(mip)).rgb,
                         texture.sample(s, float2(px.y,py.x), level(mip)).rgb, gx.y);
        float3 bottom = mix(texture.sample(s, float2(px.x,py.y), level(mip)).rgb,
                            texture.sample(s, float2(px.y,py.y), level(mip)).rgb, gx.y);
        return mix(top, bottom, gy.y);
    }

    float3 sampleBlur(texture2d<float> pyramid, float2 uv, float sigma) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        // Match blur variance rather than interpolating its logarithm. Include
        // cubic reconstruction's 1/3-texel variance when selecting pyramid levels.
        float variance = sigma*sigma;
        float lod = clamp(0.5f*log2(1.0f+max(0.0f,variance-1.0f/3.0f)/0.75f),
                          0.0f, float(pyramid.get_num_mip_levels()-1));
        uint lower = uint(floor(lod));
        uint upper = min(lower+1, pyramid.get_num_mip_levels()-1);
        float lowVariance = 0.75f*exp2(2.0f*float(lower))-5.0f/12.0f;
        float highVariance = 0.75f*exp2(2.0f*float(upper))-5.0f/12.0f;
        float blend = clamp((variance-lowVariance)/max(highVariance-lowVariance,0.0001f),0.0f,1.0f);
        float3 color = mix(sampleCubic(pyramid,uv,lower), sampleCubic(pyramid,uv,upper),blend);
        // Preserve a continuous transition from the unblurred image near zero.
        if (variance < 1.0f/3.0f)
            color = mix(pyramid.sample(s,uv,level(0)).rgb,color,variance*3.0f);
        return color;
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

        // Sigma is measured as a fraction of image height on the Retina desktop. The hinge stays more focused, but not pin-sharp.
        float focus = smoothstep(0.0f,1.0f,p);
        float spread = 0.08f+0.92f*smoothstep(0.0f,1.0f,height);
        float sigmaUV = clamp(u.blur,0.0f,1.0f)*0.045f*focus*spread;
        float sigma = sigmaUV*float(desktop.get_height());
        float3 color = u.blur > 0.0f ? encodeSRGB(sampleBlur(pyramid,uv,sigma))
                                     : desktop.sample(s,uv).rgb;
        // Feather in display coordinates: zooming the source beyond its borders
        // must not remove the dark surround. Side widths use height units to keep
        // the same optical width on different display aspect ratios.
        float softness = clamp(u.blur,0.0f,1.0f);
        float topWidth = p*(0.04f+0.075f*softness)+sigmaUV;
        float sideWidth = (p*(0.018f+0.045f*softness)+0.65f*sigmaUV)*u.size.y/u.size.x;
        float bottomWidth = p*(0.006f+0.012f*softness)+0.25f*sigmaUV;
        float mask = smoothstep(0.0f,topWidth,v.uv.y)*smoothstep(0.0f,bottomWidth,height)
                   * smoothstep(0.0f,sideWidth,v.uv.x)*smoothstep(0.0f,sideWidth,1.0f-v.uv.x);
        float shade = 1.0f-clamp(u.shadow,0.0f,1.0f)*0.12f*p*p*height;
        float disappear = 1.0f-smoothstep(0.86f,1.0f,p);
        return float4(color*mask*shade*disappear,1);
    }
    """#
}

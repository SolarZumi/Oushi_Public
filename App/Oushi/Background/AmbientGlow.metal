// 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
// Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

constant float TWO_PI = 6.28318530718;

static float3 hueToRGB(float hue) {
    float3 k = float3(1.0, 2.0 / 3.0, 1.0 / 3.0);
    float3 p = abs(fract(float3(hue) + k) * 6.0 - 3.0);
    return clamp(p - 1.0, 0.0, 1.0);
}

/// Soft glows of colored light on black, computed per pixel so no blur pass is needed. Everything that moves by
/// itself (drift, breathing, the flowing color's turn through the spectrum) is a function of `time` here, so the
/// view only hands over targets that change when something happens.
///
/// `glows` holds six floats per glow: center x and y as fractions of the view's width and height, radius as a
/// fraction of its height, then red, green, blue already scaled by the glow's intensity. `drift` (0 or 1) turns
/// the slow motion on. `colorful` (0 to 1) blends toward the flowing-color look: one dim hue shared by every glow,
/// slowly turning, the glows wandering wider around their places. `signal` is a color the glows lean toward (a
/// pull armed red, undo returning green) by its fourth component.
[[ stitchable ]] half4 ambientGlow(float2 position, half4 color, float2 size, float time, float drift, float colorful, float4 signal, device const float *glows, int count) {
    float2 point = position / size.y;
    float3 light = float3(0.0);
    // One color at a time, kept dim so the ground stays dark: a full turn through the spectrum in about a minute.
    float3 flowing = mix(float3(1.0), hueToRGB(fract(time / 60.0)), 0.6);
    int i = 0;
    for (int index = 0; index + 5 < count; index += 6, i++) {
        float fi = float(i);
        // Each glow circles on its own slow periods (20–40 s), the same for every photo so drift never jumps.
        float2 drifted = float2(
            glows[index] + drift * 0.09 * sin(time * TWO_PI / (23.0 + 3.0 * fi) + fi * 1.7),
            glows[index + 1] + drift * 0.04 * cos(time * TWO_PI / (31.0 + 2.0 * fi) + fi * 2.3)
        );
        float breathe = 1.0 + drift * 0.08 * sin(time * TWO_PI / (19.0 + 2.5 * fi) + fi);
        float radius = glows[index + 2] * breathe;
        float3 rgb = float3(glows[index + 3], glows[index + 4], glows[index + 5]);
        // The flowing look: wider wandering, one dim hue at an uneven brightness so nothing is lit flatly.
        float2 wandered = float2(
            glows[index] + drift * 0.12 * sin(time * TWO_PI / 14.0 + fi * 0.9),
            glows[index + 1] + drift * 0.08 * cos(time * TWO_PI / 17.0 + fi * 1.3)
        );
        float brightness = 0.25 + 0.15 * (0.5 + 0.5 * sin(time * TWO_PI / 11.0 + fi * 2.1));
        float2 center = mix(drifted, wandered, colorful);
        radius = mix(radius, 0.22, colorful);
        rgb = mix(rgb, flowing * brightness, colorful);
        // The signal keeps the glow's brightness (raised to a floor so even a dark ground shows it plainly) and
        // takes its hue almost entirely.
        float peak = max(max(max(rgb.r, rgb.g), rgb.b), 0.65);
        rgb = mix(rgb, signal.rgb * peak, 0.95 * signal.a);
        float2 offset = (point - float2(center.x * size.x / size.y, center.y)) / radius;
        light += rgb * exp(-dot(offset, offset));
    }
    // Overlapping glows brighten toward white like light does, instead of clipping. The factor sets how dark the
    // ground stays overall: the glows are a lit room's walls behind the card, not a light show.
    float3 rgb = 1.0 - exp(-light * 0.3);
    // Dark gradients band in 8 bits; half a step of fixed dither removes the bands without visible grain.
    float dither = fract(sin(dot(position, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    rgb += dither / 255.0;
    return half4(half3(rgb), 1.0h);
}

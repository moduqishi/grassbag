// Faithful Flutter Impeller GLSL replica of Kyant0 AndroidLiquidGlass:
// - Exact RoundedRect SDF & gradient (Shaders.kt: RoundedRectSDF)
// - Exact curved bevel lens refraction with circleMap & depthEffect (Lens.kt)
// - Exact 7-band corner-weighted rainbow chromatic dispersion (Shaders.kt)
// - Manual 4-tap bilinear backdrop sampling (fixes Impeller Nearest-Neighbor aliasing)
// - Exact Rec.709 colorControls / vibrancy (ColorFilter.kt)
// - Exact LiquidButton BlendMode.hue + alpha tinted glass & surfaceColor (LiquidButton.kt)
// - Exact Highlight.Default / Highlight.Ambient / Highlight.Plain 0.5dp rim (HighlightStyle.kt)
// - Exact pressed InnerShadow & InteractiveHighlight touch-point glow (InteractiveHighlight.kt)

#version 460 core
precision highp float;

#include <flutter/runtime_effect.glsl>

#if defined(IMPELLER_TARGET_OPENGLES) && \
    !defined(IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED)
#define KYANT_GLES_FLIP_SAMPLE_Y 1
#endif

// Slot 0..1: physical-pixel dimensions of the enclosing Impeller backdrop pass.
uniform vec2 uPassSize;

// Slot 2..5: glass shape bounds in pass-relative physical pixels:
// xy = top-left origin, zw = width, height
uniform vec4 uBoxBounds;

// Slot 6..9: per-corner radii in physical pixels (topLeft, topRight, bottomRight, bottomLeft).
uniform vec4 uCornerRadii;

// Slot 10..13: Kyant0 Lens.kt parameters:
// x = refractionHeight (physical px)
// y = refractionAmount (physical px, positive magnitude; negated inside shader like Lens.kt:49)
// z = depthEffect (0.0 or 1.0)
// w = chromaticAberration (0.0 = off, 1.0 = Kyant0 7-band corner spectral dispersion)
uniform vec4 uLensParams;

// Slot 14..17: Kyant0 ColorFilter.kt colorControls + materialization visibility:
// x = brightness (e.g. 0.0 default, +0.20 Light Dialog)
// y = contrast (1.0 default)
// z = saturation (1.5 for vibrancy(), 1.0 neutral)
// w = visibility (0.0..1.0)
uniform vec4 uColorControls;

// Slot 18..21: surfaceColor overlay (straight RGBA).
uniform vec4 uSurfaceColor;

// Slot 22..25: tintColor overlay (straight RGBA; applies Kyant0 BlendMode.hue + tint.a mix).
uniform vec4 uTintColor;

// Slot 26..29: Kyant0 HighlightStyle.kt:
// x = highlightStyle (<0 = none, 0 = Default [opposite corners, plus],
//                     1 = Ambient [directional white/dark split, srcOver],
//                     2 = Plain [uniform crisp edge, plus])
// y = highlightAlpha (0.0..1.0)
// z = highlightAngle (radians, Kyant0 default 45 deg = 0.785398)
// w = highlightFalloff (Kyant0 default 1.0..2.0)
uniform vec4 uHighlightParams;

// Slot 30..33: Highlight stroke width/blur + InnerShadow:
// x = highlightWidthPx (physical px, Kyant0 default 0.5dp * dpr)
// y = highlightBlurPx  (physical px, Kyant0 default 0.25dp * dpr)
// z = innerShadowRadiusPx (physical px, Kyant0 4..8dp * dpr * progress)
// w = innerShadowAlpha    (0.0..1.0, scaled by 0.15..0.22 inside shader)
uniform vec4 uEdgeParams;

// Slot 34..37: Kyant0 InteractiveHighlight.kt + blur-pass clamp mode:
// xy = touch position in widget-local physical pixels
// z  = pressIntensity (0.0..1.0)
// w  = clampToBox (1.0 when a shape-clipped blur pass ran right before this shader)
uniform vec4 uInteractiveParams;

// Slot 38..41: Fine optical calibration:
// x = ambientEdgeDarken (subtle Light-mode waist definition on bright canvases, 0.0..0.12)
// y = isDark (1.0 = dark theme, 0.0 = light theme)
// z = pad
// w = pad
uniform vec4 uExtraParams;

uniform sampler2D uBackdrop;

layout(location = 0) out vec4 fragColor;

// ---------------------------------------------------------------------------
// Exact Kyant0 RoundedRect SDF & analytical gradient (Shaders.kt)
// ---------------------------------------------------------------------------
float radiusAt(vec2 centeredCoord, vec4 radii) {
    if (centeredCoord.x >= 0.0) {
        if (centeredCoord.y <= 0.0) return radii.y;
        else return radii.z;
    } else {
        if (centeredCoord.y <= 0.0) return radii.x;
        else return radii.w;
    }
}

float sdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
    vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
    float outside = length(max(cornerCoord, vec2(0.0))) - radius;
    float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
    return outside + inside;
}

vec2 gradSdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
    vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
    vec2 sgn = vec2(coord.x < 0.0 ? -1.0 : 1.0, coord.y < 0.0 ? -1.0 : 1.0);
    if (cornerCoord.x >= 0.0 || cornerCoord.y >= 0.0) {
        vec2 m = max(cornerCoord, vec2(0.0));
        float mLen = length(m);
        return sgn * (mLen > 0.0001 ? m / mLen : vec2(0.70710678));
    } else {
        float gradX = step(cornerCoord.y, cornerCoord.x);
        return sgn * vec2(gradX, 1.0 - gradX);
    }
}

float circleMap(float x) {
    float cx = clamp(x, 0.0, 1.0);
    return 1.0 - sqrt(max(0.0, 1.0 - cx * cx));
}

// ---------------------------------------------------------------------------
// Manual 4-tap bilinear backdrop sampler (eliminates Impeller NN aliasing)
// ---------------------------------------------------------------------------
vec4 sampleRawTexel(vec2 px, vec2 invSize) {
    vec2 uv = (px + 0.5) * invSize;
#ifdef KYANT_GLES_FLIP_SAMPLE_Y
    uv.y = 1.0 - uv.y;
#endif
    return texture(uBackdrop, uv);
}

vec4 sampleBackdropBilinear(vec2 samplePx, vec2 minPx, vec2 maxPx, vec2 invSize) {
    vec2 clamped = clamp(samplePx, minPx, maxPx);
    vec2 p = clamped - 0.5;
    vec2 f = fract(p);
    vec2 lo = minPx - 0.5;
    vec2 hi = maxPx - 0.5;
    vec2 p0 = clamp(floor(p), lo, hi);
    vec2 p1 = clamp(p0 + vec2(1.0, 0.0), lo, hi);
    vec2 p2 = clamp(p0 + vec2(0.0, 1.0), lo, hi);
    vec2 p3 = clamp(p0 + vec2(1.0, 1.0), lo, hi);

    vec4 c0 = sampleRawTexel(p0, invSize);
    vec4 c1 = sampleRawTexel(p1, invSize);
    vec4 c2 = sampleRawTexel(p2, invSize);
    vec4 c3 = sampleRawTexel(p3, invSize);

    return mix(mix(c0, c1, f.x), mix(c2, c3, f.x), f.y);
}

// ---------------------------------------------------------------------------
// Exact W3C / Skia BlendMode.Hue (used by Kyant0 LiquidButton tinted glass)
// ---------------------------------------------------------------------------
float w3cLum(vec3 c) {
    return dot(c, vec3(0.3, 0.59, 0.11));
}

vec3 w3cClipColor(vec3 c) {
    float l = w3cLum(c);
    float n = min(min(c.r, c.g), c.b);
    float x = max(max(c.r, c.g), c.b);
    if (n < 0.0) {
        c = l + ((c - l) * l) / max(l - n, 0.0001);
    }
    if (x > 1.0) {
        c = l + ((c - l) * (1.0 - l)) / max(x - l, 0.0001);
    }
    return c;
}

vec3 w3cSetLum(vec3 c, float l) {
    return w3cClipColor(c + (l - w3cLum(c)));
}

float w3cSat(vec3 c) {
    return max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b);
}

vec3 w3cSetSat(vec3 c, float s) {
    float cMin = min(min(c.r, c.g), c.b);
    float cMax = max(max(c.r, c.g), c.b);
    if (cMax <= cMin + 0.0001) {
        return vec3(0.0);
    }
    return ((c - cMin) * s) / (cMax - cMin);
}

vec3 blendHue(vec3 bg, vec3 src) {
    return w3cSetLum(w3cSetSat(src, w3cSat(bg)), w3cLum(bg));
}

// ---------------------------------------------------------------------------
// Main fragment shader (single exit point for cross-backend shader safety)
// ---------------------------------------------------------------------------
void main() {
    vec2 passSize = max(uPassSize, vec2(1.0));
    vec2 invPassSize = 1.0 / passSize;
    vec2 fragPx = FlutterFragCoord().xy;

    vec2 boxOrigin = uBoxBounds.xy;
    vec2 boxSize = max(uBoxBounds.zw, vec2(1.0));
    vec2 halfSize = boxSize * 0.5;
    vec2 localPx = fragPx - boxOrigin;
    vec2 centered = localPx - halfSize;

    float minHalf = min(halfSize.x, halfSize.y);
    vec4 safeRadii = clamp(uCornerRadii, vec4(0.0), vec4(minHalf));
    float radius = radiusAt(centered, safeRadii);
    float sd = sdRoundedRect(centered, halfSize, radius);

    // Smooth anti-aliased edge mask inside the rounded rect.
    float visibility = clamp(uColorControls.w, 0.0, 1.0);
    float shapeAlpha = clamp(0.5 - sd, 0.0, 1.0) * visibility;

    // Sample bounds: keep inside pass, and inside shape box when a shape-clipped blur ran first.
    vec2 minSamplePx = vec2(0.5);
    vec2 maxSamplePx = passSize - vec2(0.5);
    if (uInteractiveParams.w > 0.5) {
        minSamplePx = max(minSamplePx, boxOrigin + vec2(1.0));
        maxSamplePx = min(maxSamplePx, boxOrigin + boxSize - vec2(1.0));
    }
    maxSamplePx = max(minSamplePx, maxSamplePx);

    vec4 origBg = sampleBackdropBilinear(fragPx, vec2(0.5), passSize - vec2(0.5), invPassSize);
    vec4 finalOut = origBg;

    if (shapeAlpha > 0.001) {
        float refractionHeight = max(uLensParams.x, 0.0);
        float refractionAmount = max(uLensParams.y, 0.0);
        float depthEffect = uLensParams.z;
        float chromaticAberration = max(uLensParams.w, 0.0);

        float gradRadius = min(radius * 1.5, minHalf);
        vec2 baseGrad = gradSdRoundedRect(centered, halfSize, gradRadius);

        vec4 sampledBg;
        if (refractionHeight > 0.01 && refractionAmount > 0.01 && -sd < refractionHeight) {
            float clampedSd = min(sd, 0.0);
            float rawD = circleMap(1.0 - (-clampedSd / refractionHeight)) * refractionAmount;
            // Negate refractionAmount identically to Kyant0 Lens.kt:49 so bevel refracts inward!
            // Cap max inward displacement so narrow pills never overshoot past opposite edges.
            float maxInward = minHalf * 1.35;
            float d = -min(rawD, maxInward);

            float cLen = length(centered);
            vec2 centerDir = cLen > 0.0001 ? centered / cLen : vec2(0.0);
            vec2 combinedGrad = baseGrad + depthEffect * centerDir;
            float gLen = length(combinedGrad);
            vec2 grad = gLen > 0.0001 ? combinedGrad / gLen : baseGrad;

            vec2 refractedPx = fragPx + d * grad;

            if (chromaticAberration > 0.001) {
                // Exact Kyant0 7-band corner-weighted rainbow spectral dispersion (Shaders.kt:120-157)
                float denom = max(halfSize.x * halfSize.y, 1.0);
                float dispersionIntensity =
                    clamp(chromaticAberration * ((centered.x * centered.y) / denom), -0.85, 0.85);
                vec2 dispersedPx = d * grad * dispersionIntensity;

                vec4 c = vec4(0.0);

                vec4 red = sampleBackdropBilinear(refractedPx + dispersedPx, minSamplePx, maxSamplePx, invPassSize);
                c.r += red.r / 3.5;
                c.a += red.a / 7.0;

                vec4 orange = sampleBackdropBilinear(refractedPx + dispersedPx * (2.0 / 3.0), minSamplePx, maxSamplePx, invPassSize);
                c.r += orange.r / 3.5;
                c.g += orange.g / 7.0;
                c.a += orange.a / 7.0;

                vec4 yellow = sampleBackdropBilinear(refractedPx + dispersedPx * (1.0 / 3.0), minSamplePx, maxSamplePx, invPassSize);
                c.r += yellow.r / 3.5;
                c.g += yellow.g / 3.5;
                c.a += yellow.a / 7.0;

                vec4 green = sampleBackdropBilinear(refractedPx, minSamplePx, maxSamplePx, invPassSize);
                c.g += green.g / 3.5;
                c.a += green.a / 7.0;

                vec4 cyan = sampleBackdropBilinear(refractedPx - dispersedPx * (1.0 / 3.0), minSamplePx, maxSamplePx, invPassSize);
                c.g += cyan.g / 3.5;
                c.b += cyan.b / 3.0;
                c.a += cyan.a / 7.0;

                vec4 blue = sampleBackdropBilinear(refractedPx - dispersedPx * (2.0 / 3.0), minSamplePx, maxSamplePx, invPassSize);
                c.b += blue.b / 3.0;
                c.a += blue.a / 7.0;

                vec4 purple = sampleBackdropBilinear(refractedPx - dispersedPx, minSamplePx, maxSamplePx, invPassSize);
                c.r += purple.r / 7.0;
                c.b += purple.b / 3.0;
                c.a += purple.a / 7.0;

                sampledBg = c;
            } else {
                sampledBg = sampleBackdropBilinear(refractedPx, minSamplePx, maxSamplePx, invPassSize);
            }
        } else {
            sampledBg = sampleBackdropBilinear(fragPx, minSamplePx, maxSamplePx, invPassSize);
        }

        // Unpremultiply backdrop color before colorControls / blending.
        vec3 rgb = sampledBg.a > 0.001 ? clamp(sampledBg.rgb / sampledBg.a, 0.0, 1.0) : sampledBg.rgb;

        // -------------------------------------------------------------------
        // Exact Kyant0 ColorFilter.kt: vibrancy() & colorControls()
        // -------------------------------------------------------------------
        float brightness = uColorControls.x;
        float contrast = uColorControls.y;
        float saturation = uColorControls.z;
        float luma = dot(rgb, vec3(0.213, 0.715, 0.072));
        rgb = mix(vec3(luma), rgb, saturation);
        rgb = (rgb - 0.5) * contrast + 0.5 + brightness;
        rgb = clamp(rgb, 0.0, 1.0);

        // -------------------------------------------------------------------
        // Exact Kyant0 LiquidButton onDrawSurface: BlendMode.hue + tint.a
        // -------------------------------------------------------------------
        if (uTintColor.a > 0.001) {
            vec3 hueShifted = blendHue(rgb, uTintColor.rgb);
            rgb = mix(hueShifted, uTintColor.rgb, clamp(uTintColor.a, 0.0, 1.0));
        }

        // Surface veil overlay (e.g. Color(0xFFFAFAFA).copy(0.4..0.6) or white * (1 - press))
        if (uSurfaceColor.a > 0.001) {
            rgb = mix(rgb, uSurfaceColor.rgb, clamp(uSurfaceColor.a, 0.0, 1.0));
        }

        // -------------------------------------------------------------------
        // Exact Kyant0 InnerShadow (for lifted slider/toggle/tab lenses)
        // -------------------------------------------------------------------
        float innerShadowRadius = uEdgeParams.z;
        float innerShadowAlpha = uEdgeParams.w;
        if (innerShadowAlpha > 0.001 && innerShadowRadius > 0.5) {
            float sdShifted = sdRoundedRect(centered - vec2(0.0, innerShadowRadius), halfSize, radius);
            float innerMask = smoothstep(-innerShadowRadius * 1.35, 0.0, sdShifted);
            rgb = mix(rgb, vec3(0.0), innerMask * clamp(innerShadowAlpha * 0.16, 0.0, 0.35));
        }

        // -------------------------------------------------------------------
        // Exact Kyant0 InteractiveHighlight touch-following glow
        // -------------------------------------------------------------------
        float pressIntensity = clamp(uInteractiveParams.z, 0.0, 1.0);
        if (pressIntensity > 0.001) {
            vec2 clampedTouch = clamp(uInteractiveParams.xy, vec2(0.0), boxSize);
            float dist = distance(localPx, clampedTouch);
            float glowRadius = min(boxSize.x, boxSize.y) * 1.5;
            float spot = smoothstep(glowRadius, glowRadius * 0.5, dist);
            float glowBoost = (0.08 + 0.15 * spot) * pressIntensity;
            rgb = clamp(rgb + vec3(glowBoost), 0.0, 1.0);
        }

        // -------------------------------------------------------------------
        // Exact Kyant0 HighlightStyle.kt + HighlightModifier.kt (0.5dp rim)
        // -------------------------------------------------------------------
        float hlStyle = uHighlightParams.x;
        float hlAlpha = clamp(uHighlightParams.y, 0.0, 1.0);
        if (hlStyle >= -0.5 && hlAlpha > 0.001) {
            float insetPx = max(0.0, -sd);
            float rimWidth = max(uEdgeParams.x, 1.0);
            float rimBlur = max(uEdgeParams.y, 0.45);
            float rimMask = 1.0 - smoothstep(rimWidth * 0.45, rimWidth + rimBlur * 1.7, insetPx);

            float angle = uHighlightParams.z;
            float falloff = max(uHighlightParams.w, 0.1);
            vec2 hlNormal = vec2(cos(angle), sin(angle));
            float hlDot = dot(baseGrad, hlNormal);
            float hlPow = pow(abs(hlDot), falloff);

            if (hlStyle < 0.5) {
                // HighlightStyle.Default: opposite-corner specular with BlendMode.Plus
                rgb = clamp(rgb + vec3(hlPow * hlAlpha * rimMask), 0.0, 1.0);
            } else if (hlStyle < 1.5) {
                // HighlightStyle.Ambient: directional white/dark split with srcOver
                float t = step(0.0, hlDot);
                rgb = mix(rgb, vec3(t), hlPow * hlAlpha * rimMask);
            } else {
                // HighlightStyle.Plain: uniform subtle luminous hairline with BlendMode.Plus
                rgb = clamp(rgb + vec3(hlAlpha * rimMask), 0.0, 1.0);
            }

            // Whisper-subtle Light-mode meniscus waist so bright white glass stays defined on bright paper
            float waistStrength = uExtraParams.x;
            if (waistStrength > 0.001) {
                float waist = clamp(1.0 - hlPow, 0.0, 1.0);
                rgb = mix(rgb, rgb * 0.84, waist * waistStrength * rimMask);
            }
        }

        vec4 glassOut = vec4(rgb, 1.0);
        finalOut = mix(origBg, glassOut, shapeAlpha);
    }

    fragColor = finalOut;
}

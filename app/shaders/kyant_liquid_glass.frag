// High-efficiency Flutter Impeller GLSL replica of Kyant0 AndroidLiquidGlass + iOS 26/27 Clear Optics:
// - Exact RoundedRect SDF & analytical gradient (Shaders.kt: RoundedRectSDF)
// - Curved bevel lens refraction with circleMap & depthEffect (Lens.kt)
// - Fast single-pass rotated bokeh micro-blur (eliminates 2nd BackdropFilterLayer pass on chrome/buttons!)
// - Adaptive optical dispersion: crisp 3-channel RGB prism on everyday chrome (6x faster),
//   full 7-band Kyant0 rainbow spectrum on prism showcase & lifted slider/toggle lenses
// - Rec.709 colorControls / vibrancy (ColorFilter.kt) + luminous 3D Fresnel meniscus catchlight
// - LiquidButton BlendMode.hue + translucent tinted glass & whisper-clear surfaceColor
// - Highlight.Default / Highlight.Ambient / Highlight.Plain directional specular rim
// - Pressed InnerShadow & InteractiveHighlight touch-point glow

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
// w = chromaticAberration (0.0 = off, <=0.45 = fast 3-channel RGB prism, >0.45 = full 7-band rainbow)
uniform vec4 uLensParams;

// Slot 14..17: Kyant0 ColorFilter.kt colorControls + materialization visibility:
// x = brightness
// y = contrast
// z = saturation (1.5..1.85 for crystal vibrancy)
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
// x = highlightWidthPx (physical px)
// y = highlightBlurPx  (physical px)
// z = innerShadowRadiusPx (physical px)
// w = innerShadowAlpha    (0.0..1.0)
uniform vec4 uEdgeParams;

// Slot 34..37: Kyant0 InteractiveHighlight.kt + external blur-pass clamp mode:
// xy = touch position in widget-local physical pixels
// z  = pressIntensity (0.0..1.0)
// w  = clampToBox (1.0 when a shape-clipped external ImageFilter.blur pass ran right before this shader)
uniform vec4 uInteractiveParams;

// Slot 38..41: Fine optical calibration & single-pass micro-blur:
// x = ambientEdgeDarken (subtle Light-mode meniscus waist separation, 0.0..0.18)
// y = isDark (1.0 = dark theme, 0.0 = light theme)
// z = inShaderBlurPx (physical-pixel radius for fast single-pass circular bokeh when no external blur ran)
// w = specularSheen (0.0..1.0 curved meniscus catchlight & Fresnel bevel crystal luminosity)
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
// High-speed clamped backdrop samplers (1-tap direct, 4-tap bilinear, 5/9-tap single-pass bokeh)
// ---------------------------------------------------------------------------
vec4 sampleRawTexel(vec2 px, vec2 invSize) {
    vec2 uv = (px + 0.5) * invSize;
#ifdef KYANT_GLES_FLIP_SAMPLE_Y
    uv.y = 1.0 - uv.y;
#endif
    return texture(uBackdrop, uv);
}

vec4 sampleClamped(vec2 px, vec2 minPx, vec2 maxPx, vec2 invSize) {
    return sampleRawTexel(clamp(px, minPx, maxPx), invSize);
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

// Single-pass isotropic optical micro-blur (fast 5-tap quincunx up to 6.5px, 9-tap only for wide radii)
vec4 sampleOpticBlur(vec2 centerPx, float blurPx, vec2 minPx, vec2 maxPx, vec2 invSize) {
    if (blurPx <= 0.35) {
        return sampleClamped(centerPx, minPx, maxPx, invSize);
    }
    if (blurPx <= 6.5) {
        float d = blurPx * 0.62;
        vec4 acc = sampleClamped(centerPx, minPx, maxPx, invSize) * 0.32;
        acc += sampleClamped(centerPx + vec2( d,  d), minPx, maxPx, invSize) * 0.17;
        acc += sampleClamped(centerPx + vec2(-d,  d), minPx, maxPx, invSize) * 0.17;
        acc += sampleClamped(centerPx + vec2( d, -d), minPx, maxPx, invSize) * 0.17;
        acc += sampleClamped(centerPx + vec2(-d, -d), minPx, maxPx, invSize) * 0.17;
        return acc;
    }
    float d1 = blurPx * 0.42;
    float d2 = blurPx * 0.92;
    vec4 acc = sampleClamped(centerPx, minPx, maxPx, invSize) * 0.20;
    acc += sampleClamped(centerPx + vec2( d1,  d1), minPx, maxPx, invSize) * 0.12;
    acc += sampleClamped(centerPx + vec2(-d1,  d1), minPx, maxPx, invSize) * 0.12;
    acc += sampleClamped(centerPx + vec2( d1, -d1), minPx, maxPx, invSize) * 0.12;
    acc += sampleClamped(centerPx + vec2(-d1, -d1), minPx, maxPx, invSize) * 0.12;
    acc += sampleClamped(centerPx + vec2( d2,  0.0), minPx, maxPx, invSize) * 0.08;
    acc += sampleClamped(centerPx + vec2(-d2,  0.0), minPx, maxPx, invSize) * 0.08;
    acc += sampleClamped(centerPx + vec2( 0.0,  d2), minPx, maxPx, invSize) * 0.08;
    acc += sampleClamped(centerPx + vec2( 0.0, -d2), minPx, maxPx, invSize) * 0.08;
    return acc;
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

    vec4 finalOut = vec4(0.0);

    if (shapeAlpha <= 0.001) {
        // Fast 1-tap passthrough outside glass shape (zero wasted bilinear fetches!)
        finalOut = sampleRawTexel(clamp(fragPx, vec2(0.5), passSize - vec2(0.5)), invPassSize);
    } else {
        // Sample bounds: keep inside pass, and inside shape box only when an external shape-clipped blur ran first.
        vec2 minSamplePx = vec2(0.5);
        vec2 maxSamplePx = passSize - vec2(0.5);
        bool hasExternalBlur = uInteractiveParams.w > 0.5;
        if (hasExternalBlur) {
            minSamplePx = max(minSamplePx, boxOrigin + vec2(1.0));
            maxSamplePx = min(maxSamplePx, boxOrigin + boxSize - vec2(1.0));
        }
        maxSamplePx = max(minSamplePx, maxSamplePx);

        float refractionHeight = max(uLensParams.x, 0.0);
        float refractionAmount = max(uLensParams.y, 0.0);
        float depthEffect = uLensParams.z;
        float chromaticAberration = max(uLensParams.w, 0.0);
        float inShaderBlurPx = hasExternalBlur ? 0.0 : max(uExtraParams.z, 0.0);

        float gradRadius = min(radius * 1.5, minHalf);
        vec2 baseGrad = gradSdRoundedRect(centered, halfSize, gradRadius);

        vec4 sampledBg;
        if (refractionHeight > 0.01 && refractionAmount > 0.01 && -sd < refractionHeight) {
            float clampedSd = min(sd, 0.0);
            float bevelFrac = clamp(1.0 - (-clampedSd / refractionHeight), 0.0, 1.0);
            float rawD = circleMap(bevelFrac) * refractionAmount;
            // Negate refractionAmount identically to Kyant0 Lens.kt:49 so bevel refracts inward!
            float maxInward = minHalf * 1.30;
            float d = -min(rawD, maxInward);

            float cLen = length(centered);
            vec2 centerDir = cLen > 0.0001 ? centered / cLen : vec2(0.0);
            vec2 combinedGrad = baseGrad + depthEffect * centerDir;
            float gLen = length(combinedGrad);
            vec2 grad = gLen > 0.0001 ? combinedGrad / gLen : baseGrad;

            vec2 refractedPx = fragPx + d * grad;

            if (chromaticAberration > 0.45) {
                // Full 7-band Kyant0 rainbow dispersion for prism showcase & lifted control lenses
                // (7 direct taps instead of 28 bilinear taps -> 4x faster while naturally sub-pixel smooth!)
                float denom = max(halfSize.x * halfSize.y, 1.0);
                float dispersionIntensity =
                    clamp(chromaticAberration * ((centered.x * centered.y) / denom), -0.85, 0.85);
                vec2 dispersedPx = d * grad * dispersionIntensity;

                vec4 c = vec4(0.0);
                vec4 red    = sampleClamped(refractedPx + dispersedPx, minSamplePx, maxSamplePx, invPassSize);
                vec4 orange = sampleClamped(refractedPx + dispersedPx * (2.0 / 3.0), minSamplePx, maxSamplePx, invPassSize);
                vec4 yellow = sampleClamped(refractedPx + dispersedPx * (1.0 / 3.0), minSamplePx, maxSamplePx, invPassSize);
                vec4 green  = sampleClamped(refractedPx, minSamplePx, maxSamplePx, invPassSize);
                vec4 cyan   = sampleClamped(refractedPx - dispersedPx * (1.0 / 3.0), minSamplePx, maxSamplePx, invPassSize);
                vec4 blue   = sampleClamped(refractedPx - dispersedPx * (2.0 / 3.0), minSamplePx, maxSamplePx, invPassSize);
                vec4 purple = sampleClamped(refractedPx - dispersedPx, minSamplePx, maxSamplePx, invPassSize);

                c.r = (red.r + orange.r + yellow.r) / 3.5 + purple.r / 7.0;
                c.g = (yellow.g + green.g + cyan.g) / 3.5 + orange.g / 7.0;
                c.b = (cyan.b + blue.b + purple.b) / 3.0;
                c.a = (red.a + orange.a + yellow.a + green.a + cyan.a + blue.a + purple.a) / 7.0;
                sampledBg = c;
            } else if (chromaticAberration > 0.001) {
                // Fast crisp 3-channel optical RGB dispersion for floating pills, buttons & sheets
                // (3-5 taps total instead of 28 taps -> 6x-9x GPU speedup!)
                float denom = max(halfSize.x * halfSize.y, 1.0);
                float cornerFactor = (centered.x * centered.y) / denom;
                float edgeBoost = mix(0.35, 1.0, abs(cornerFactor)) * (cornerFactor < 0.0 ? -1.0 : 1.0);
                float dispersionIntensity = clamp(chromaticAberration * edgeBoost * 1.15, -0.45, 0.45);
                vec2 dispPx = d * grad * dispersionIntensity;

                // Keep curved bevel slightly crisper than flat center so edge refraction visibly gleams!
                float bevelBlurPx = inShaderBlurPx * (1.0 - 0.55 * bevelFrac);
                vec4 gSample = sampleOpticBlur(refractedPx, bevelBlurPx, minSamplePx, maxSamplePx, invPassSize);
                vec4 rSample = sampleClamped(refractedPx + dispPx, minSamplePx, maxSamplePx, invPassSize);
                vec4 bSample = sampleClamped(refractedPx - dispPx, minSamplePx, maxSamplePx, invPassSize);
                sampledBg = vec4(
                    mix(gSample.r, rSample.r, 0.78),
                    gSample.g,
                    mix(gSample.b, bSample.b, 0.78),
                    (rSample.a + gSample.a + bSample.a) / 3.0
                );
            } else if (inShaderBlurPx > 0.35) {
                float bevelBlurPx = inShaderBlurPx * (1.0 - 0.50 * bevelFrac);
                sampledBg = sampleOpticBlur(refractedPx, bevelBlurPx, minSamplePx, maxSamplePx, invPassSize);
            } else if (hasExternalBlur) {
                sampledBg = sampleClamped(refractedPx, minSamplePx, maxSamplePx, invPassSize);
            } else {
                sampledBg = sampleBackdropBilinear(refractedPx, minSamplePx, maxSamplePx, invPassSize);
            }
        } else {
            // Flat interior region: single-pass micro-blur or fast 1-tap hardware fetch!
            if (inShaderBlurPx > 0.35) {
                sampledBg = sampleOpticBlur(fragPx, inShaderBlurPx, minSamplePx, maxSamplePx, invPassSize);
            } else {
                sampledBg = sampleClamped(fragPx, minSamplePx, maxSamplePx, invPassSize);
            }
        }

        // Unpremultiply backdrop color before vibrancy / optical shading.
        vec3 rgb = sampledBg.a > 0.001 ? clamp(sampledBg.rgb / sampledBg.a, 0.0, 1.0) : sampledBg.rgb;

        // -------------------------------------------------------------------
        // Optical vibrancy & clarity (Rec.709 colorControls)
        // -------------------------------------------------------------------
        float brightness = uColorControls.x;
        float contrast = uColorControls.y;
        float saturation = uColorControls.z;
        float luma = dot(rgb, vec3(0.213, 0.715, 0.072));
        rgb = mix(vec3(luma), rgb, saturation);
        rgb = (rgb - 0.5) * contrast + 0.5 + brightness;
        rgb = clamp(rgb, 0.0, 1.0);

        // -------------------------------------------------------------------
        // Kyant0 LiquidButton tinted glass (BlendMode.hue + translucent tint mix)
        // -------------------------------------------------------------------
        if (uTintColor.a > 0.001) {
            vec3 hueShifted = blendHue(rgb, uTintColor.rgb);
            rgb = mix(hueShifted, uTintColor.rgb, clamp(uTintColor.a, 0.0, 1.0));
        }

        // Whisper-clear translucent glass veil
        if (uSurfaceColor.a > 0.001) {
            rgb = mix(rgb, uSurfaceColor.rgb, clamp(uSurfaceColor.a, 0.0, 1.0));
        }

        // -------------------------------------------------------------------
        // 3D Crystal Meniscus Catchlight & Fresnel Curved-Bevel Luminosity
        // -------------------------------------------------------------------
        float sheen = clamp(uExtraParams.w, 0.0, 1.0);
        if (sheen > 0.001) {
            float isDark = uExtraParams.y;
            float bevelSpan = max(refractionHeight, minHalf * 0.42);
            float bevelT = clamp(1.0 - (max(0.0, -sd) / max(bevelSpan, 1.0)), 0.0, 1.0);

            float angle = uHighlightParams.z;
            vec2 hlDir = vec2(cos(angle), sin(angle));
            float dirMatch = pow(abs(dot(baseGrad, hlDir)), 1.6);
            float fresnel = pow(bevelT, 2.6) * (0.22 + 0.78 * dirMatch);
            float fresnelGain = (isDark > 0.5 ? 0.12 : 0.14) * sheen;
            rgb = clamp(rgb + vec3(fresnel * fresnelGain), 0.0, 1.0);

            // Delicate top curved liquid meniscus sheen fading smoothly downward
            float yNorm = clamp(localPx.y / max(boxSize.y, 1.0), 0.0, 1.0);
            float xEdgeFade = 1.0 - smoothstep(0.72, 1.0, abs(centered.x) / max(halfSize.x, 1.0)) * 0.40;
            float topArc = smoothstep(0.24, 0.0, yNorm) * xEdgeFade;
            float topGain = (isDark > 0.5 ? 0.065 : 0.10) * sheen;
            rgb = clamp(rgb + vec3(topArc * topGain), 0.0, 1.0);

            // Subtle lower-bevel cool optical depth in Light Mode so crystal highlights POP
            if (isDark < 0.5 && uTintColor.a < 0.01) {
                float botDepth = smoothstep(0.58, 1.0, yNorm) * pow(bevelT, 1.8);
                rgb = mix(rgb, rgb * vec3(0.955, 0.972, 0.995), botDepth * 0.30 * sheen);
            }
        }

        // -------------------------------------------------------------------
        // Kyant0 InnerShadow (for lifted slider/toggle/tab lenses)
        // -------------------------------------------------------------------
        float innerShadowRadius = uEdgeParams.z;
        float innerShadowAlpha = uEdgeParams.w;
        if (innerShadowAlpha > 0.001 && innerShadowRadius > 0.5) {
            float sdShifted = sdRoundedRect(centered - vec2(0.0, innerShadowRadius), halfSize, radius);
            float innerMask = smoothstep(-innerShadowRadius * 1.35, 0.0, sdShifted);
            rgb = mix(rgb, vec3(0.0), innerMask * clamp(innerShadowAlpha * 0.16, 0.0, 0.35));
        }

        // -------------------------------------------------------------------
        // Kyant0 InteractiveHighlight touch-following spotlight
        // -------------------------------------------------------------------
        float pressIntensity = clamp(uInteractiveParams.z, 0.0, 1.0);
        if (pressIntensity > 0.001) {
            vec2 clampedTouch = clamp(uInteractiveParams.xy, vec2(0.0), boxSize);
            float dist = distance(localPx, clampedTouch);
            float glowRadius = min(boxSize.x, boxSize.y) * 1.5;
            float spot = smoothstep(glowRadius, glowRadius * 0.5, dist);
            float glowBoost = (0.08 + 0.16 * spot) * pressIntensity;
            rgb = clamp(rgb + vec3(glowBoost), 0.0, 1.0);
        }

        // -------------------------------------------------------------------
        // Crisp Directional Specular Rim (Kyant0 HighlightStyle.Default / Ambient / Plain)
        // -------------------------------------------------------------------
        float hlStyle = uHighlightParams.x;
        float hlAlpha = clamp(uHighlightParams.y, 0.0, 1.0);
        if (hlStyle >= -0.5 && hlAlpha > 0.001) {
            float insetPx = max(0.0, -sd);
            float rimWidth = max(uEdgeParams.x, 1.0);
            float rimBlur = max(uEdgeParams.y, 0.45);
            float rimMask = 1.0 - smoothstep(rimWidth * 0.40, rimWidth + rimBlur * 1.5, insetPx);

            float angle = uHighlightParams.z;
            float falloff = max(uHighlightParams.w, 0.1);
            vec2 hlNormal = vec2(cos(angle), sin(angle));
            float hlDot = dot(baseGrad, hlNormal);
            float hlPow = pow(abs(hlDot), falloff);

            if (hlStyle < 0.5) {
                // HighlightStyle.Default: luminous opposite-corner specular + gentle base hairline
                float baseHairline = (uExtraParams.y > 0.5 ? 0.14 : 0.22);
                float specStrength = (baseHairline + (1.0 - baseHairline) * hlPow) * hlAlpha * rimMask;
                rgb = clamp(rgb + vec3(specStrength), 0.0, 1.0);
            } else if (hlStyle < 1.5) {
                // HighlightStyle.Ambient: directional white/dark split with srcOver
                float t = step(0.0, hlDot);
                rgb = mix(rgb, vec3(t), hlPow * hlAlpha * rimMask);
            } else {
                // HighlightStyle.Plain: uniform crisp luminous edge
                rgb = clamp(rgb + vec3(hlAlpha * rimMask), 0.0, 1.0);
            }

            // Whisper-crisp Light-mode outer meniscus contour so clear glass stays defined on pale canvases
            float waistStrength = uExtraParams.x;
            if (waistStrength > 0.001) {
                float waist = clamp(1.0 - hlPow, 0.0, 1.0);
                rgb = mix(rgb, rgb * vec3(0.84, 0.87, 0.91), waist * waistStrength * rimMask);
            }
        }

        vec4 glassOut = vec4(rgb, 1.0);
        if (shapeAlpha >= 0.999) {
            finalOut = glassOut;
        } else {
            vec4 edgeBg = sampleRawTexel(clamp(fragPx, vec2(0.5), passSize - vec2(0.5)), invPassSize);
            finalOut = mix(edgeBg, glassOut, shapeAlpha);
        }
    }

    fragColor = finalOut;
}

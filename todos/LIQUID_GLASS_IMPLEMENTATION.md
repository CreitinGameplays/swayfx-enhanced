# Liquid Glass Implementation Guide (SwayFX) — Expanded & Technical

This document details the implementation of the "Liquid Glass" effect, expanded with the full technical details and implementation notes distilled from the kube.io article on Liquid Glass (theoretical basis, SVG displacement-map approach, mappings, numeric details, and practical implementation guidance for GLES shaders). Use this as a single-source reference for reproducing the effect in SwayFX (GLES/Wayland) and for creating compatible displacement maps when using SVG/CSS approaches.

---

## Contents
1. Core Principles (refraction, normals, height functions)
2. Mathematical & numeric details (Snell's Law, derivative approximation)
3. Surface height functions (formulas & behavior)
4. Displacement vector field (precompute strategy, normalization, sampling)
5. SVG-specific mechanics (feImage → feDisplacementMap, channel mapping, scale)
6. Specular highlight (rim light model, parameters)
7. GLES/GLSL implementation strategy (on-the-fly vs precomputed map, shader pseudocode)
8. Performance, precision & practical notes (texture formats, sampling, edge cases)
9. SwayFX config proposal (parameters and recommended defaults)
10. Appendix: code snippets and formulas

---

## 1. Core Principles

- **Refraction**: The effect approximates a single refraction event where rays pass from air into glass; Snell–Descartes law governs direction change.
- **Specular highlight**: A rim-like rim-light produced by evaluating the surface normal vs a fixed light direction and compositing over the refracted background.
- **Displacement mapping**: The refracted background is implemented as a displacement map: each pixel encodes an (dx, dy) displacement; the render samples the background texture using UV + displacement.

---

## 2. Mathematical & numeric details

### Snell–Descartes (used in approximations)
\[
n_1 \sin(\theta_1) = n_2 \sin(\theta_2)
\]
- Typical values used in article:
  - \(n_1 = 1.0\) (air)
  - \(n_2 \approx 1.5\) (glass)
- Under the article's simplifications:
  - Rays from the background are treated as orthogonal to the background plane (no perspective), which simplifies geometry and means we mainly compute lateral displacement due to local surface normal variation. :contentReference[oaicite:6]{index=6}

### Numerical derivative (surface normal)
- Use a small delta to approximate derivative (central difference):
```js
const delta = 0.001;
const y1 = f(distanceFromSide - delta);
const y2 = f(distanceFromSide + delta);
const derivative = (y2 - y1) / (2 * delta);
const normal = { x: -derivative, y: 1 }; // then normalize
````

* The surface normal is the rotated derivative (derivative rotated by -90° in article's coordinate choice). ([kube.io][1])

---

## 3. Surface height functions

(Each function maps a normalized "distanceFromSide" in [0,1] to a height value used to compute the local normal.)

* **Convex Circle** (spherical cap)

  * ( y = 1 - (1 - x)^2 )
  * Produces a dome; sharper transition to flat interior.
* **Convex Squircle** (recommended for softer transition; Apple-like)

  * ( y = (1 - (1 - x)^4)^{1/4} )
  * Keeps gradients smooth under stretching into rectangles.
* **Concave**

  * ( y = 1 - \text{Convex}(x) )
  * Pushes rays outward (can require sampling outside the object boundary — often undesirable).
* **Lip**

  * ( y = \text{mix}(\text{Convex}(x), \text{Concave}(x), \text{Smootherstep}(x)) )
  * Provides a raised rim and shallow center dip.

Notes:

* The article favors **convex** profiles for UI elements because they keep displacements internal to the object and avoid sampling background pixels outside the object bounds. ([kube.io][1])

---

## 4. Displacement Vector Field (how to compute the map)

High-level strategy (from article):

1. For a single radius (half-slice) compute ray-trace results at many distances from the bezel edge out toward the center.
2. Each sample produces a displacement vector (angle, magnitude).
3. Convert polar→cartesian (x, y), normalize magnitudes by the maximum displacement observed on the radius (store `maximumDisplacement`).
4. Rotate the radius vectors around the object (z-axis symmetry) to produce a full 2D vector field for circular/rounded shapes.
5. Map each vector to 8-bit channels for the displacement image.

Important numeric details:

* **Radial sample count**: the article uses **127 ray simulations** for the radius (derived from SVG displacement map constraints / resolution tradeoffs). Precompute these and re-use them — do not recompute for each pixel. ([kube.io][1])
* **Normalization**: divide all magnitudes by the `maximumDisplacement` so values are in [0,1]; `maximumDisplacement` stored to re-scale into pixels during rendering (SVG `scale` or shader `scale`).

### Polar→RGB mapping (8-bit)

* Convert angle & magnitude → x,y:

  ```js
  const x = Math.cos(angle) * magnitude; // in [-1, 1]
  const y = Math.sin(angle) * magnitude;
  ```
* Map to red/green channels (neutral = 128):

  ```js
  r = 128 + x * 127
  g = 128 + y * 127
  b = 128    // ignored by feDisplacementMap
  a = 255
  ```

  * This maps normalized -1..1 to 0..255 with 128 == zero displacement. ([kube.io][1])

---

## 5. SVG `feDisplacementMap` mechanics (relevant if you generate SVG maps)

* `feDisplacementMap` interprets channel values as normalized displacements in [-1, 1] where channel value 128 is neutral (no displacement). The `scale` attribute multiplies the normalized displacement to map into pixel units.

  * Example usage:

    ```xml
    <filter id="glass">
      <feImage href="data:image/png;base64,..." result="displacement_map"/>
      <feDisplacementMap in="SourceGraphic"
                         in2="displacement_map"
                         scale="{maximumDisplacement}" 
                         xChannelSelector="R"
                         yChannelSelector="G"/>
    </filter>
    ```
  * Because channels are 8-bit, the displacement range per axis is limited to -128..127 (normalized ±1 using 128 neutral). Use `scale` to convert normalized numbers back to pixel displacement. ([kube.io][1])
* You can animate `scale` to smoothly fade the effect without recomputing the displacement image.

---

## 6. Specular (rim) highlight

* Implemented as a simple rim light: compute surface normal and evaluate dot(normal, lightDir). The highlight intensity varies with angle between the surface normal and a fixed light direction.
* Article example: specular angle ≈ **-60°** (this is the light direction used for the rim). Blend the rim highlight on top of refracted background (article uses separate `<feImage/>` for the highlight, then `<feBlend/>`). ([kube.io][1])
* Rough pseudocode for highlight:

  ```glsl
  float ndotl = max(dot(normal, lightDir), 0.0);
  float rim = pow(smoothstep(rimStart, rimEnd, ndotl), rimPower);
  color = mix(color, highlightColor, rim * specularOpacity);
  ```
* Tune `rimStart`, `rimEnd`, `rimPower`, and `specularOpacity` to match visual intensity.

---

## 7. GLES/GLSL Implementation Strategy (for SwayFX)

Two approaches:

**A. Precomputed displacement texture (recommended for complex shapes & performance)**

* Precompute a displacement texture (RGBA8 or float) from the radial samples.

  * Store normalized x,y in R,G channels using the `128 + x*127` mapping when targeting 8-bit textures (for SVG compatibility). For GLES shaders you can store full precision in a floating-point texture (GL_RGBA16F / GL_RGBA32F) to avoid quantization.
* At render time:

  1. Render the background to a texture (`bgTex`).
  2. Bind the displacement texture `dispTex`.
  3. In the glass shader: for each fragment sample `disp = texelFetch(dispTex, texCoord).rg;` convert to signed displacement (if stored as normalized -1..1 in float texture do `dx = disp.x * maximumDisplacement`).
  4. Sample `bg = texture(bgTex, uv + vec2(dx, dy) / bgResolution);` (convert pixel displacement to texture-coordinates).
  5. Compute specular and composite.

**B. On-the-fly computation in shader (works for simple shapes, fewer texture resources)**

* Evaluate the height function `f(x)` in the shader and compute derivative via small delta (central difference). From that derive normal, refracted direction, and displacement.
* Advantage: Saves texture storage, allows per-frame parameters (thickness, bezel width) without re-uploading a map. Disadvantage: more ALU per fragment and must ensure consistent sampling — also harder for arbitrary shapes.

### GLSL pseudocode (precomputed texture flow)

```glsl
// uniforms
uniform sampler2D u_bg;         // background texture
uniform sampler2D u_disp;       // displacement map (float or normalized)
uniform float u_maxDisplacement; // pixels
uniform vec2  u_bgTexSize;      // background texture size (pixels)
uniform float u_specularOpacity;
uniform vec3  u_lightDir;       // normalized
// varyings
in vec2 v_uv; // uv inside glass region (0..1 across the shape)

// main
void main() {
  // read displacement (assume stored in -1..1 in RG if float; or 0..255 mapped to 128 center)
  vec2 d = texture(u_disp, v_uv).rg; // if RG in 0..1 mapping: d = (d - 0.5) * 2.0;
  // If disp was stored already in pixels (float), directly scale:
  vec2 displacementPx = d * u_maxDisplacement; // px
  vec2 displacementUV = displacementPx / u_bgTexSize; // convert to texture coords
  vec4 refracted = texture(u_bg, v_uv + displacementUV);

  // compute or fetch normal (if precomputed, store in disp alpha or separate texture)
  vec3 normal = ...;

  // specular rim
  float nl = max(dot(normal, normalize(u_lightDir)), 0.0);
  float rim = pow(nl, 4.0); // tunable
  vec3 highlight = vec3(1.0) * rim * u_specularOpacity;

  // final composite
  vec3 finalColor = mix(refracted.rgb, highlight, rim);
  outColor = vec4(finalColor, 1.0);
}
```

### Notes for on-the-fly refracted displacement (if computing from height function)

* Compute `distanceFromSide` for current fragment in local shape-space.
* Evaluate `height = f(distanceFromSide)`.
* Use central difference to get derivative and normal (as shown earlier).
* Use Snell's law to get refracted vector. Under the article's orthogonal-ray assumption this reduces to computing a lateral displacement; derive how far the refracted ray intersects the background plane relative to the original ray origin to compute dx,dy.
* Convert computed pixel displacement to UV offsets and sample.

---

## 8. Precision, performance & practical notes

* **Texture precision**:

  * SVG approach limited to 8-bit channels; normalized displacement in [-1,1] quantized to 8 bits (±0.0039 steps).
  * For GLES, prefer floating point textures (RGBA16F) for higher fidelity and smoother gradients if available.
* **Sampling outside bounds**:

  * Avoid concave shapes that push rays outside the glass bounds (they require sampling background pixels outside the object's rectangle). Convex profiles avoid that.
* **Maximum displacement**:

  * Store `maximumDisplacement` when precomputing and pass it to the shader/filter; SVG's `scale` can use this value directly to map normalized vectors to pixel displacements.
* **Resolution**:

  * Use a displacement map resolution that matches the point density you need — the article used 127 radial samples because of SVG map resolution constraints; for GLES you can use larger textures, but precomputation cost increases.
* **Animation**:

  * Animate the `scale` to fade the refraction strength without recomputing displacement image.
* **Framebuffer feedback**:

  * When sampling the background, make sure you sample a previously rendered background texture (not the partially composed frame) to avoid feedback loops. Render background first to an offscreen texture.
* **Chrome / browser notes**:

  * The article's interactive demo required Chrome due to `backdrop-filter` / certain SVG filter features. For SwayFX (native), use the GLES approach described above and you are free of browser constraints. ([kube.io][1])

---

## 9. SwayFX Configuration Proposal (detailed)

Add these configurable parameters with recommended defaults. SwayFX can expose them via config flags and per-window rules.

```
# Enable liquid glass effect
liquid_glass enable
liquid_glass_surface convex_squircle
liquid_glass_bezel_width 20
liquid_glass_thickness 1.0
liquid_glass_refraction_index 1.5
liquid_glass_specular_opacity 0.4
liquid_glass_specular_angle -45

# Apply to specific windows
for_window [app_id="firefox"] liquid_glass enable
```

Implementation notes:

* `max_displacement` should be computed at map generation time and stored; pass same value to shader as `u_maxDisplacement`.
* If using float displacement textures internally, `liquid_glass_max_displacement` becomes advisory (can be higher precision).

Auto-disable rules:

* The article and UI considerations: **avoid** applying the effect in tabbed-mode windows (visual clutter and performance). Keep it enabled for freeform/stacked windows.

---

## 10. Appendix — Useful snippets & formulas

### Central derivative (JS)

```js
function derivative(f, x, delta = 0.001) {
  return (f(x + delta) - f(x - delta)) / (2 * delta);
}
```

### Polar→RGB (JS) — normalized magnitude in [0,1]

```js
const x = Math.cos(angle) * magnitude; // -1..1
const y = Math.sin(angle) * magnitude; // -1..1

const r = Math.round(128 + x * 127);
const g = Math.round(128 + y * 127);
const b = 128;
const a = 255;
```

### feDisplacementMap `scale` mapping

* If map vectors were normalized by `maximumDisplacement` (i.e. magnitude scaled to [0,1] using `maximumDisplacement`), then set:

  ```xml
  <feDisplacementMap scale="{maximumDisplacement}" ... />
  ```

  so normalized -1..1 maps to [-maximumDisplacement, maximumDisplacement] pixels.

---

### References

* Liquid Glass in the Browser: Refraction with CSS and SVG — kube.io (source of the equations, mappings, and numeric choices). ([kube.io][1])

---

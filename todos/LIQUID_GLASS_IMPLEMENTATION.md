# Liquid Glass Implementation Guide (SwayFX)

This document details the implementation of the "Liquid Glass" effect, based on the principles described at [kube.io/blog/liquid-glass-css-svg/](https://kube.io/blog/liquid-glass-css-svg/).

## 1. Core Principles

The Liquid Glass effect simulates curved, refractive glass by distorting the background behind a surface. It relies on:
- **Refraction**: The bending of light as it passes through materials of different refractive indices (Snell-Descartes Law).
- **Specular Highlight**: A bright rim light that follows the edges of the glass.
- **Displacement Mapping**: A technique to shift pixels based on a map (vector field).

### 1.1 Mathematical Foundation (Snell-Descartes Law)
Refraction is governed by $n_1 \sin(\theta_1) = n_2 \sin(\theta_2)$.
For implementation in a UI:
- $n_1$ (Air) = 1.0
- $n_2$ (Glass) $\approx$ 1.5
- We assume rays are orthogonal to the screen (background plane).
- The "bend" depends on the surface normal at each point.

### 1.2 Surface Height Functions
The surface curvature determines the displacement. Several functions can be used:
- **Convex Circle**: $y = \sqrt{1 - (1 - x)^2}$
- **Convex Squircle (Apple style)**: $y = (1 - (1 - x)^4)^{1/4}$ (smoother transitions).
- **Concave**: $y = 1 - \text{Convex}(x)$ (diverges light).
- **Lip**: A blend of convex and concave for a raised rim.

### 1.3 Displacement Vector Field
A displacement map encodes how many pixels $(dx, dy)$ to shift the background.
- Map $x, y$ components to RGB channels.
- $R = 128 + (\text{normalized\_dx} \cdot 127)$
- $G = 128 + (\text{normalized\_dy} \cdot 127)$
- $128$ represents zero displacement.

## 2. Implementation Strategy for SwayFX

SwayFX uses GLES/Wayland for rendering. Instead of SVG/CSS `backdrop-filter`, we must implement this in GLES shaders.

### 2.1 Shader Requirements
- **Input Texture**: The background (rendered to a buffer).
- **Displacement Map**: Can be calculated on-the-fly in the shader or passed as a texture.
- **Parameters**:
    - `scale`: Maximum displacement in pixels.
    - `refractive_index`: Usually 1.5.
    - `corner_radius`: To match window decorations.

### 2.2 Specular Highlight
- Calculate the gradient (normal) of the surface.
- Apply a dot product with a virtual light source to determine highlight intensity.
- Mix the highlight over the refracted background.

## 3. Configuration in SwayFX

The effect should be togglable via the config file:
```sway
# Enable liquid glass effect
liquid_glass enable
liquid_glass_surface convex_squircle
liquid_glass_bezel_width 20
liquid_glass_thickness 1.0
liquid_glass_refraction_index 1.5
liquid_glass_specular_opacity 0.4

# Apply to specific windows
for_window [app_id="firefox"] liquid_glass enable
```

This requires adding a new command `glass` and updating the rendering pipeline to apply the "Liquid Glass" shader to windows when enabled.

Liquid Glass should be automatically turned off in **tabbed mode window** only. Freeform and Stacked mode should be fine.

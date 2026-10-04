/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once
#include <cmath>

namespace CydiaAccessibilityColor {
struct RGBA { double red, green, blue, alpha; };

inline RGBA Over(RGBA front, RGBA back) {
    double alpha(front.alpha + back.alpha * (1 - front.alpha));
    if (alpha == 0)
        return {0, 0, 0, 0};
    double weight(back.alpha * (1 - front.alpha));
    return {(front.red * front.alpha + back.red * weight) / alpha,
        (front.green * front.alpha + back.green * weight) / alpha,
        (front.blue * front.alpha + back.blue * weight) / alpha, alpha};
}

inline double Linear(double component) {
    return component <= 0.04045 ? component / 12.92 :
        std::pow((component + 0.055) / 1.055, 2.4);
}

inline double Luminance(RGBA color) {
    return 0.2126 * Linear(color.red) + 0.7152 * Linear(color.green) +
        0.0722 * Linear(color.blue);
}

/* Caller must establish the painted background is opaque and solid.
 * This computes a ratio; it does not assign a WCAG/installed pass. */
inline double Contrast(RGBA foreground, RGBA opaqueBackground) {
    double a(Luminance(Over(foreground, opaqueBackground)));
    double b(Luminance(opaqueBackground));
    return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
}
} // namespace CydiaAccessibilityColor

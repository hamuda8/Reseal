//! Reseal's colours: the TwOP scheme of Wufour/private/site/apps.js (Reseal), its dark theme
//! derived with the OKLCH transforms of Wufour's public/styles/style.css, and the semantic
//! tokens the views use, computed in Zig so they are the same on every platform.
//!
//! Every token is one of the ten roles, or a role with alpha: zui draws with alpha, so a tint
//! comes out as `color-mix(in oklab, X N%, transparent)` does in the browser. Nothing is a blend
//! of two roles and nothing is hand-picked for dark mode.

const std = @import("std");
const zui = @import("zui");
const Color = zui.Color;

// The ten roles (apps.js `colors` for Reseal; the signals Reseal does not define are the shared
// ones of the scheme).
pub const base = Color.hex("#ffffff");
pub const core = Color.hex("#12141c");
pub const accent = Color.hex("#6c5cff");
pub const variant = Color.hex("#4f8cff");
pub const surface = Color.hex("#e9ebf3");
pub const depth = Color.hex("#c9c2ff");
pub const optimal = Color.hex("#1fb37a");
pub const risky = Color.hex("#F0F054");
pub const fatal = Color.hex("#F05454");
/// apps.js defines no prime for Reseal: the accent stands in until the owner adds one.
pub const prime = accent;

/// `oklch(from C clamp(lo, 1 - l*l, hi) c*k h)`, with k = max(floor, 1 - l*slope): the
/// dark-mode transforms at the top of style.css.
fn darkOf(c: Color, lo: f32, hi: f32, floor: f32, slope: f32) Color {
    var o = c.toOklch();
    const k = @max(floor, 1 - o.l * slope);
    o.l = std.math.clamp(1 - o.l * o.l, lo, hi);
    o.c *= k;
    return o.toColor();
}

pub fn darkCanvas(x: Color) Color {
    return darkOf(x, 0.10, 0.25, 0.5, 0);
}
pub fn darkText(x: Color) Color {
    return darkOf(x, 0.85, 0.95, 0.6, 0);
}
pub fn darkBorder(x: Color) Color {
    return darkOf(x, 0.25, 0.40, 0.4, 0);
}
pub fn darkBrand(x: Color) Color {
    return darkOf(x, 0.25, 0.55, 0.60, 0.40);
}
pub fn darkAction(x: Color) Color {
    return darkOf(x, 0.45, 0.75, 0.70, 0.30);
}
pub fn darkSignal(x: Color) Color {
    return darkOf(x, 0.45, 0.80, 0.75, 0.25);
}

/// Of two roles, the one further in lightness from `bg` (text and icons on a coloured box).
pub fn furtherFrom(bg: Color, x: Color, y: Color) Color {
    const l = bg.toOklch().l;
    return if (@abs(x.toOklch().l - l) >= @abs(y.toOklch().l - l)) x else y;
}

fn darkerOf(x: Color, y: Color) Color {
    return if (x.toOklch().l <= y.toOklch().l) x else y;
}

fn lighterOf(x: Color, y: Color) Color {
    return if (x.toOklch().l > y.toOklch().l) x else y;
}

pub const Colors = struct {
    // The roles after the light/dark transform.
    b: Color,
    c: Color,
    a: Color,
    v: Color,
    s: Color,
    d: Color,
    o: Color,
    r: Color,
    f: Color,
    p: Color,

    canvas: Color,
    surface: Color,
    surface_2: Color,
    surface_3: Color,
    hover: Color,
    active: Color,
    text: Color,
    text_2: Color,
    text_3: Color,
    border: Color,
    border_strong: Color,
    danger: Color,
    danger_soft: Color,
    success: Color,
    warning: Color,
    online: Color,
    accent: Color,
    accent_2: Color,
    /// The brand colour on buttons and outgoing bubbles: the accent, flat.
    brand: Color,
    accent_soft: Color,
    accent_softer: Color,
    on_accent: Color,
    bubble_in: Color,
    bubble_in_text: Color,
    bubble_out: Color,
    bubble_out_text: Color,
    bubble_meta_in: Color,
    bubble_meta_out: Color,
    dots: Color,
    glass: Color,
    /// The scrim under dialogs and sheets.
    overlay: Color,
    toast: Color,
    toast_text: Color,
    toast_accent: Color,
    /// The darker of base and core: the call stage, the story viewer, scrims on photos and
    /// video (with alpha).
    shade: Color,
    /// The lighter of base and core: text and icons on `shade`.
    on_shade: Color,
    dark: bool,

    /// Base or core, whichever reads better on `bg`.
    pub fn onOf(k: *const Colors, bg: Color) Color {
        return furtherFrom(bg, k.b, k.c);
    }
};

/// `override` is the accent a white-label app gives the embedded widget (`theme.primary`);
/// Reseal itself always uses its own accent.
pub fn colors(dark: bool, override: ?Color) Colors {
    const acc = override orelse accent;
    const b = if (dark) darkCanvas(base) else base;
    const c = if (dark) darkText(core) else core;
    const a = if (dark) darkAction(acc) else acc;
    const v = if (dark) darkAction(variant) else variant;
    const s = if (dark) darkCanvas(surface) else surface;
    const d = if (dark) darkBorder(depth) else depth;
    const o = if (dark) darkSignal(optimal) else optimal;
    const r = if (dark) darkSignal(risky) else risky;
    const f = if (dark) darkSignal(fatal) else fatal;
    const p = if (dark) darkBrand(prime) else prime;
    // Light: a tinted canvas with cards on the base. Dark: the base is the canvas and the
    // (slightly lighter) surface lifts the cards.
    const canvas = if (dark) b else s;
    const card = if (dark) s else b;
    const on_accent = furtherFrom(a, b, c);
    const shade = darkerOf(b, c);
    const on_shade = lighterOf(b, c);
    return .{
        .b = b,
        .c = c,
        .a = a,
        .v = v,
        .s = s,
        .d = d,
        .o = o,
        .r = r,
        .f = f,
        .p = p,
        .canvas = canvas,
        .surface = card,
        .surface_2 = d.withAlpha(0.10),
        .surface_3 = d.withAlpha(0.18),
        .hover = c.withAlpha(0.05),
        .active = c.withAlpha(0.09),
        .text = c,
        .text_2 = c.withAlpha(0.64),
        .text_3 = c.withAlpha(0.44),
        .border = d.withAlpha(0.22),
        .border_strong = d.withAlpha(0.40),
        .danger = f,
        .danger_soft = f.withAlpha(0.14),
        .success = o,
        .warning = r,
        .online = o,
        .accent = a,
        .accent_2 = v,
        .brand = a,
        .accent_soft = a.withAlpha(if (dark) 0.22 else 0.12),
        .accent_softer = a.withAlpha(if (dark) 0.12 else 0.06),
        .on_accent = on_accent,
        .bubble_in = s,
        .bubble_in_text = c,
        .bubble_out = a,
        .bubble_out_text = on_accent,
        .bubble_meta_in = c.withAlpha(0.56),
        .bubble_meta_out = on_accent.withAlpha(0.78),
        .dots = c.withAlpha(0.07),
        .glass = card.withAlpha(0.72),
        .overlay = shade.withAlpha(0.5),
        .toast = if (dark) s else c,
        .toast_text = if (dark) c else b,
        .toast_accent = a,
        .shade = shade,
        .on_shade = on_shade,
        .dark = dark,
    };
}

/// Avatar colours .c0-.c7: tints of the accent, variant, prime and optimal, each as its
/// light-mode role and as the same role through its dark-mode transform.
pub fn avatarColor(index: i64) Color {
    return switch (@as(usize, @intCast(@mod(index, 8)))) {
        0 => accent,
        1 => variant,
        2 => prime,
        3 => optimal,
        4 => darkAction(accent),
        5 => darkAction(variant),
        6 => darkBrand(prime),
        else => darkSignal(optimal),
    };
}

/// Sender name colours in groups: the accent, variant, prime and optimal of the current mode.
pub fn nameColor(k: *const Colors, index: i64) Color {
    return switch (@as(usize, @intCast(@mod(index, 4)))) {
        0 => k.a,
        1 => k.v,
        2 => k.p,
        else => k.o,
    };
}

// Sizes (app.css)
pub const rail_w: f32 = 76;
pub const sidebar_w: f32 = 380;
pub const sidebar_w_narrow: f32 = 330;
pub const info_w: f32 = 360;
pub const header_h: f32 = 68;
pub const gap: f32 = 10;
pub const radius: f32 = 12;
pub const r_panel: f32 = 24;
pub const bubble_radius: f32 = 18;
/// Phones: under this width the app shows one pane at a time with a tab bar.
pub const phone_max: f32 = 760;

test "light mode is the palette, dark mode is derived" {
    const k = colors(false, null);
    try std.testing.expect(k.surface.eql(base));
    try std.testing.expect(k.canvas.eql(surface));
    try std.testing.expect(k.accent.eql(accent));
    try std.testing.expect(k.on_accent.eql(base));
    try std.testing.expect(k.shade.eql(core));
    const dk = colors(true, null);
    try std.testing.expect(dk.canvas.toOklch().l <= 0.26);
    try std.testing.expect(dk.text.toOklch().l >= 0.84);
    try std.testing.expect(dk.surface.toOklch().l >= dk.canvas.toOklch().l);
    try std.testing.expect(dk.shade.eql(dk.b));
}

//! Reseal's look ("Aurora"), from Reseal-js public/css/base.css and app.css: the colour tokens for
//! light and dark, the accent colours, avatar colours and the type scale. CSS gradients (the
//! brand gradient on buttons and outgoing bubbles, the aurora canvas) are drawn as their mid
//! colour, since zui boxes have solid backgrounds.

const zui = @import("zui");
const Color = zui.Color;

pub const Colors = struct {
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
    /// var(--brand): the accent gradient, drawn as its middle.
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
    overlay: Color,
    toast: Color,
    dark: bool,
};

/// The accents users can pick, with their gradient partners (theme.js).
pub const accents = [_][2]Color{
    .{ Color.hex("#6c5cff"), Color.hex("#4f8cff") },
    .{ Color.hex("#3d7bff"), Color.hex("#22c3ee") },
    .{ Color.hex("#0ea5a8"), Color.hex("#3bd18f") },
    .{ Color.hex("#1fb37a"), Color.hex("#9bd44a") },
    .{ Color.hex("#f08c2b"), Color.hex("#f5c543") },
    .{ Color.hex("#ef4561"), Color.hex("#f78a4d") },
    .{ Color.hex("#d946ef"), Color.hex("#8b5cf6") },
    .{ Color.hex("#475569"), Color.hex("#7c8aa3") },
};

pub fn colors(dark: bool, accent: Color, accent_2: Color) Colors {
    const brand = accent.mix(0.5, accent_2);
    const soft_share: f32 = if (dark) 0.22 else 0.11;
    const softer_share: f32 = if (dark) 0.12 else 0.06;
    if (dark) return .{
        .canvas = Color.hex("#07080d"),
        .surface = Color.hex("#11131b"),
        .surface_2 = Color.hex("#181b26"),
        .surface_3 = Color.hex("#1f2330"),
        .hover = Color.hex("#ffffff0b"),
        .active = Color.hex("#ffffff14"),
        .text = Color.hex("#eceef5"),
        .text_2 = Color.hex("#9097a8"),
        .text_3 = Color.hex("#636a7c"),
        .border = Color.hex("#ffffff0f"),
        .border_strong = Color.hex("#ffffff1f"),
        .danger = Color.hex("#ef4561"),
        .danger_soft = Color.hex("#ef456129"),
        .success = Color.hex("#1fb37a"),
        .warning = Color.hex("#f2a33a"),
        .online = Color.hex("#22c58b"),
        .accent = accent,
        .accent_2 = accent_2,
        .brand = brand,
        .accent_soft = accent.mix(soft_share, Color.transparent),
        .accent_softer = accent.mix(softer_share, Color.transparent),
        .on_accent = Color.white,
        .bubble_in = Color.hex("#1c202c"),
        .bubble_in_text = Color.hex("#eceef5"),
        .bubble_out = brand,
        .bubble_out_text = Color.white,
        .bubble_meta_in = Color.hex("#7a8193"),
        .bubble_meta_out = Color.hex("#ffffffc7"),
        .dots = Color.hex("#ffffff0d"),
        .glass = Color.hex("#11131bb8"),
        .overlay = Color.hex("#0a0c1861"),
        .toast = Color.hex("#12141eeb"),
        .dark = true,
    };
    return .{
        .canvas = Color.hex("#e9ebf3"),
        .surface = Color.hex("#ffffff"),
        .surface_2 = Color.hex("#f4f5f9"),
        .surface_3 = Color.hex("#eceef4"),
        .hover = Color.hex("#161a2e0b"),
        .active = Color.hex("#161a2e14"),
        .text = Color.hex("#12141c"),
        .text_2 = Color.hex("#5f6678"),
        .text_3 = Color.hex("#9aa0b0"),
        .border = Color.hex("#12142012"),
        .border_strong = Color.hex("#12142021"),
        .danger = Color.hex("#ef4561"),
        .danger_soft = Color.hex("#ef45611a"),
        .success = Color.hex("#1fb37a"),
        .warning = Color.hex("#f2a33a"),
        .online = Color.hex("#22c58b"),
        .accent = accent,
        .accent_2 = accent_2,
        .brand = brand,
        .accent_soft = accent.mix(soft_share, Color.transparent),
        .accent_softer = accent.mix(softer_share, Color.transparent),
        .on_accent = Color.white,
        .bubble_in = Color.hex("#f1f2f8"),
        .bubble_in_text = Color.hex("#12141c"),
        .bubble_out = brand,
        .bubble_out_text = Color.white,
        .bubble_meta_in = Color.hex("#8d93a5"),
        .bubble_meta_out = Color.hex("#ffffffc7"),
        .dots = Color.hex("#1e223c12"),
        .glass = Color.hex("#ffffffb8"),
        .overlay = Color.hex("#0a0c1861"),
        .toast = Color.hex("#12141eeb"),
        .dark = false,
    };
}

/// Avatar colours .c0-.c7: linear-gradient(150deg, c1, c2), drawn as their mid colour.
pub const avatar_pairs = [_][2]Color{
    .{ Color.hex("#ff9a7a"), Color.hex("#f0566c") },
    .{ Color.hex("#ffd27a"), Color.hex("#f59a3d") },
    .{ Color.hex("#a69cff"), Color.hex("#6c5cff") },
    .{ Color.hex("#8ee6a8"), Color.hex("#24b47e") },
    .{ Color.hex("#7ee8dc"), Color.hex("#1aa6b8") },
    .{ Color.hex("#8cc8ff"), Color.hex("#3d7bff") },
    .{ Color.hex("#f0a8ff"), Color.hex("#b55cf0") },
    .{ Color.hex("#ffa3c4"), Color.hex("#e44a85") },
};

pub fn avatarColor(index: i64) Color {
    const p = avatar_pairs[@intCast(@mod(index, 8))];
    return p[0].mix(0.45, p[1]);
}

/// Sender name colours in groups (.name-c0-.name-c7).
const names_light = [_]Color{ Color.hex("#e24a5f"), Color.hex("#d9822b"), Color.hex("#6a5af5"), Color.hex("#1b9d6c"), Color.hex("#148fa0"), Color.hex("#2f6fe8"), Color.hex("#a64ad9"), Color.hex("#d43f7a") };
const names_dark = [_]Color{ Color.hex("#ff8a98"), Color.hex("#ffbf6b"), Color.hex("#ada4ff"), Color.hex("#6ee3a6"), Color.hex("#6fe0e8"), Color.hex("#86b8ff"), Color.hex("#e19bff"), Color.hex("#ff8fbb") };

pub fn nameColor(index: i64, dark: bool) Color {
    const i: usize = @intCast(@mod(index, 8));
    return if (dark) names_dark[i] else names_light[i];
}

// Sizes (app.css)
pub const rail_w: f32 = 76;
pub const sidebar_w: f32 = 380;
pub const sidebar_w_narrow: f32 = 330;
pub const info_w: f32 = 360;
pub const header_h: f32 = 68;
pub const gap: f32 = 10;
pub const radius: f32 = 14;
pub const r_panel: f32 = 24;
pub const bubble_radius: f32 = 20;
/// Phones: under this width the app shows one pane at a time with a tab bar.
pub const phone_max: f32 = 760;

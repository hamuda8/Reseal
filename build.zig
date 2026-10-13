const std = @import("std");
const core = @import("zig_core");

pub fn build(b: *std.Build) void {
    // Where the phone apps reach the Reseal server. For development over USB:
    //   adb reverse tcp:<port> tcp:<port>  and  zig build android -Dserver=http://127.0.0.1:<port>
    const options = b.addOptions();
    options.addOption([]const u8, "server", b.option([]const u8, "server", "Reseal server for the phone apps") orelse "https://reseal.wreseal.com");
    // Wufour (Reseal-js's AUTH_HOST), where the phone apps sign in: POST <auth>/api/auth/login.
    // The default is AUTH_HOST's own default in Reseal-js (src/config.js); set it for real builds:
    //   zig build android -Dserver=https://... -Dauth=https://...
    options.addOption([]const u8, "auth", b.option([]const u8, "auth", "Wufour sign-in host (AUTH_HOST) for the phone apps") orelse "http://localhost:4000");

    core.addApp(b, b.dependency("zig_core", .{}), .{
        .client_config = options.createModule(),
        .name = "reseal",
        .client = b.path("src/client/app.zig"),
        .server = b.path("src/server/main.zig"),
        .web = b.path("shells/web"),
        .android_manifest = b.path("shells/android/AndroidManifest.xml"),
        // The launcher icon: Reseal-js's public/img/icons/icon-192.png.
        .android_res = b.path("shells/android/res"),
        .android_res_files = &.{"mipmap-xxxhdpi/ic_launcher.png"},
        .ios_info_plist = b.path("shells/ios/Info.plist"),
        .optimize = b.standardOptimizeOption(.{}),
    });
}

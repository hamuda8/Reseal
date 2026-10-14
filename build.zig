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
    options.addOption([]const u8, "auth", b.option([]const u8, "auth", "Wufour sign-in host (AUTH_HOST) for the phone apps") orelse "https://www.wreseal.com");

    core.addApp(b, b.dependency("zig_core", .{}), .{
        .client_config = options.createModule(),
        // Calls on the phones: Reseal's WebRTC engine (zui openMedia/openPeer use it through app.rtc).
        .client_imports = &.{.{ .name = "reseal_rtc", .module = b.dependency("reseal_rtc", .{}).module("reseal_rtc") }},
        .name = "reseal",
        .client = b.path("src/client/app.zig"),
        .server = b.path("src/server/main.zig"),
        .web = b.path("shells/web"),
        .android_manifest = b.path("shells/android/AndroidManifest.xml"),
        // The launcher icon: Reseal-js's public/img/icons/icon-192.png.
        .android_res = b.path("shells/android/res"),
        .android_res_files = &.{"mipmap-xxxhdpi/ic_launcher.png"},
        .ios_info_plist = b.path("shells/ios/Info.plist"),
        // The unread-chats widget on iOS too (WidgetKit, through the app group group.<bundle id>).
        .ios_widget = true,
        // FCM: google-services.json stays outside the repository (C:/MProjects/secrets).
        .android_push = .{ .google_services = "../secrets/reseal-google-services.json" },
        .optimize = b.standardOptimizeOption(.{}),
    });
}

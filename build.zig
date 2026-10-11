const std = @import("std");
const core = @import("zig_core");

pub fn build(b: *std.Build) void {
    // Where the phone apps reach the Reseal server. For development over USB:
    //   adb reverse tcp:<port> tcp:<port>  and  zig build android -Dserver=http://127.0.0.1:<port>
    const options = b.addOptions();
    options.addOption([]const u8, "server", b.option([]const u8, "server", "Reseal server for the phone apps") orelse "https://reseal.wreseal.com");

    core.addApp(b, b.dependency("zig_core", .{}), .{
        .client_config = options.createModule(),
        .name = "reseal",
        .client = b.path("src/client/app.zig"),
        .server = b.path("src/server/main.zig"),
        .web = b.path("shells/web"),
        .android_manifest = b.path("shells/android/AndroidManifest.xml"),
        .ios_info_plist = b.path("shells/ios/Info.plist"),
        .optimize = b.standardOptimizeOption(.{}),
    });
}

//! Shared setup for the KVM and HVF kernel boot harnesses.

const std = @import("std");

const max_boot_file = 256 * 1024 * 1024;

pub const Options = struct {
    kernel_path: []const u8,
    cmdline: ?[]const u8 = null,
    mem_mib: u64 = 512,
    initrd_path: ?[]const u8 = null,
    disk_path: ?[]const u8 = null,
    snapshot_after_ms: ?u64 = null,
    spore_dir: ?[]const u8 = null,
    resume_dir: ?[]const u8 = null,
    lazy_ram: bool = false,
    lazy_ram_trace_path: ?[]const u8 = null,
    dirty_track: bool = false,
    dirty_epoch_ms: u64 = 250,
};

pub const Prepared = struct {
    options: Options,
    kernel: []const u8,
    initrd: ?[]const u8,
    disk_fd: ?std.c.fd_t,
    lazy_ram_trace_fd: ?std.c.fd_t,
    cmdline: []const u8,

    pub fn deinit(self: *Prepared) void {
        if (self.disk_fd) |fd| _ = std.c.close(fd);
        if (self.lazy_ram_trace_fd) |fd| _ = std.c.close(fd);
        self.* = undefined;
    }
};

pub fn prepare(init: std.process.Init, arena: std.mem.Allocator, args: []const []const u8, program_name: []const u8) !Prepared {
    const options = parseArgs(args) catch |err| switch (err) {
        error.BadUsage => usageExit(program_name),
        else => |e| return e,
    };

    const lazy_ram_trace_fd = try openLazyRamTrace(arena, options.lazy_ram_trace_path);
    errdefer if (lazy_ram_trace_fd) |fd| {
        _ = std.c.close(fd);
    };

    const kernel = try std.Io.Dir.cwd().readFileAlloc(init.io, options.kernel_path, arena, .limited(max_boot_file));
    const initrd = if (options.initrd_path) |path|
        try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(max_boot_file))
    else
        null;

    const disk_fd = try openDisk(arena, options.disk_path);
    errdefer if (disk_fd) |fd| {
        _ = std.c.close(fd);
    };

    const cmdline = effectiveCmdline(options.cmdline, disk_fd != null, initrd != null);

    return .{
        .options = options,
        .kernel = kernel,
        .initrd = initrd,
        .disk_fd = disk_fd,
        .lazy_ram_trace_fd = lazy_ram_trace_fd,
        .cmdline = cmdline,
    };
}

pub fn parseArgs(args: []const []const u8) !Options {
    if (args.len < 2) return error.BadUsage;

    var options = Options{ .kernel_path = args[1] };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cmdline") and i + 1 < args.len) {
            i += 1;
            options.cmdline = args[i];
        } else if (std.mem.eql(u8, args[i], "--mem-mib") and i + 1 < args.len) {
            i += 1;
            options.mem_mib = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--initrd") and i + 1 < args.len) {
            i += 1;
            options.initrd_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--disk") and i + 1 < args.len) {
            i += 1;
            options.disk_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--snapshot-after-ms") and i + 1 < args.len) {
            i += 1;
            options.snapshot_after_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--spore") and i + 1 < args.len) {
            i += 1;
            options.spore_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--dirty-track")) {
            options.dirty_track = true;
        } else if (std.mem.eql(u8, args[i], "--dirty-epoch-ms") and i + 1 < args.len) {
            i += 1;
            options.dirty_epoch_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--resume") and i + 1 < args.len) {
            i += 1;
            options.resume_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--lazy-ram")) {
            options.lazy_ram = true;
        } else if (std.mem.eql(u8, args[i], "--lazy-ram-trace") and i + 1 < args.len) {
            i += 1;
            options.lazy_ram_trace_path = args[i];
        } else {
            return error.BadUsage;
        }
    }

    if ((options.snapshot_after_ms == null) != (options.spore_dir == null)) return error.BadUsage;
    if (options.resume_dir != null and options.snapshot_after_ms != null) return error.BadUsage;
    if (options.dirty_track and options.snapshot_after_ms == null) return error.BadUsage;
    if (options.lazy_ram and options.resume_dir == null) return error.BadUsage;
    if (options.lazy_ram_trace_path != null and !options.lazy_ram) return error.BadUsage;

    return options;
}

fn openLazyRamTrace(arena: std.mem.Allocator, maybe_path: ?[]const u8) !?std.c.fd_t {
    const path = maybe_path orelse return null;
    const pathz = try arena.dupeZ(u8, path);
    const fd = std.c.open(pathz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c_uint, 0o644));
    if (fd < 0) {
        std.debug.print("cannot open lazy RAM trace: {s}\n", .{path});
        std.process.exit(1);
    }
    return fd;
}

fn openDisk(arena: std.mem.Allocator, maybe_path: ?[]const u8) !?std.c.fd_t {
    const path = maybe_path orelse return null;
    const pathz = try arena.dupeZ(u8, path);
    const fd = std.c.open(pathz, .{ .ACCMODE = .RDWR }, @as(c_uint, 0));
    if (fd < 0) {
        std.debug.print("cannot open disk: {s}\n", .{path});
        std.process.exit(1);
    }
    return fd;
}

fn usageExit(program_name: []const u8) noreturn {
    std.debug.print("usage: {s} <kernel-Image> [--cmdline \"...\"] [--mem-mib N] [--initrd root.cpio] [--disk rootfs.ext4] [--snapshot-after-ms N --spore DIR] [--dirty-track] [--dirty-epoch-ms N] [--resume DIR] [--lazy-ram] [--lazy-ram-trace PATH]\n", .{program_name});
    std.process.exit(2);
}

fn effectiveCmdline(explicit: ?[]const u8, has_disk: bool, has_initrd: bool) []const u8 {
    return explicit orelse if (has_disk)
        "console=hvc0 root=/dev/vda rw init=/bin/sh"
    else if (has_initrd)
        "console=hvc0 rdinit=/init"
    else
        "console=hvc0 loglevel=8";
}

test "boot harness parses common options" {
    const args = [_][]const u8{
        "kvm-boot",
        "Image",
        "--cmdline",
        "console=hvc0",
        "--mem-mib",
        "1024",
        "--initrd",
        "root.cpio",
        "--disk",
        "rootfs.ext4",
        "--snapshot-after-ms",
        "10",
        "--spore",
        "out.spore",
        "--dirty-track",
        "--dirty-epoch-ms",
        "50",
    };
    const options = try parseArgs(&args);

    try std.testing.expectEqualStrings("Image", options.kernel_path);
    try std.testing.expectEqualStrings("console=hvc0", options.cmdline.?);
    try std.testing.expectEqual(@as(u64, 1024), options.mem_mib);
    try std.testing.expectEqualStrings("root.cpio", options.initrd_path.?);
    try std.testing.expectEqualStrings("rootfs.ext4", options.disk_path.?);
    try std.testing.expectEqual(@as(u64, 10), options.snapshot_after_ms.?);
    try std.testing.expectEqualStrings("out.spore", options.spore_dir.?);
    try std.testing.expect(options.dirty_track);
    try std.testing.expectEqual(@as(u64, 50), options.dirty_epoch_ms);
}

test "boot harness rejects trace without lazy RAM" {
    const args = [_][]const u8{ "kvm-boot", "Image", "--lazy-ram-trace", "trace.txt" };
    try std.testing.expectError(error.BadUsage, parseArgs(&args));
}

test "boot harness selects default command line" {
    try std.testing.expectEqualStrings("custom", effectiveCmdline("custom", true, true));
    try std.testing.expectEqualStrings("console=hvc0 root=/dev/vda rw init=/bin/sh", effectiveCmdline(null, true, false));
    try std.testing.expectEqualStrings("console=hvc0 rdinit=/init", effectiveCmdline(null, false, true));
    try std.testing.expectEqualStrings("console=hvc0 loglevel=8", effectiveCmdline(null, false, false));
}

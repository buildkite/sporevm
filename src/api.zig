//! Internal product API boundary used by the CLI and future embedding layers.

const std = @import("std");

const bundle = @import("bundle.zig");
const local_paths = @import("local_paths.zig");
const platform = @import("platform.zig");
const resume_mod = @import("resume.zig");
const run_mod = @import("run.zig");

pub const CacheRoot = union(enum) {
    env,
    none,
    path: []const u8,
};

pub const PullOptions = struct {
    source: []const u8,
    out_dir: []const u8,
    rootfs_cache: CacheRoot = .env,
    bundle_cache: CacheRoot = .env,
    child_id: ?[]const u8 = null,
    allow_metadata_only_rootfs: bool = false,
    aws_region: ?[]const u8 = null,
    aws_executable: []const u8 = "aws",
};

pub fn hostInfo(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !platform.HostInfo {
    return platform.hostInfo(allocator, environ_map);
}

pub fn inspectBundle(
    allocator: std.mem.Allocator,
    options: bundle.InspectBundleOptions,
) !bundle.InspectBundleResult {
    return bundle.inspectBundle(allocator, options);
}

pub fn pull(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: PullOptions,
) !bundle.PullResult {
    return bundle.pull(allocator, .{
        .io = init.io,
        .source = options.source,
        .out_dir = options.out_dir,
        .rootfs_cache_dir = cacheRoot(options.rootfs_cache, allocator, init.environ_map, .rootfs),
        .bundle_cache_dir = cacheRoot(options.bundle_cache, allocator, init.environ_map, .bundle),
        .child_id = options.child_id,
        .allow_metadata_only_rootfs = options.allow_metadata_only_rootfs,
        .aws_region = options.aws_region,
        .aws_executable = options.aws_executable,
    });
}

pub fn runCommand(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: run_mod.Options,
) !run_mod.Result {
    return run_mod.execute(init, allocator, options);
}

pub fn resumeCommand(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: resume_mod.Options,
) !run_mod.Result {
    return resume_mod.execute(init, allocator, options);
}

const CacheKind = enum {
    rootfs,
    bundle,
};

fn cacheRoot(
    requested: CacheRoot,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    kind: CacheKind,
) ?[]const u8 {
    return switch (requested) {
        .none => null,
        .path => |path| path,
        .env => switch (kind) {
            .rootfs => local_paths.rootfsCacheRootPath(allocator, environ_map) catch null,
            .bundle => local_paths.bundleCacheRootPath(allocator, environ_map) catch null,
        },
    };
}

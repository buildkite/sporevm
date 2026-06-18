//! Minimal `spore-netd` helper.
//!
//! This first helper slice owns only a bounded Ethernet frame stream and ARP
//! replies for the fixed gateway address. DNS, TCP, policy, and zmoltcp
//! integration land in later slices.

const std = @import("std");
const Io = std.Io;

const virtio_net = @import("virtio/net.zig");

pub const max_frame_len = virtio_net.max_frame_len;
pub const frame_header_len = 4;

pub const guest_mac = virtio_net.default_mac;
pub const gateway_mac: [6]u8 = .{ 0x02, 0x53, 0x50, 0x4f, 0x52, 0x01 };
pub const guest_ipv4: [4]u8 = .{ 100, 96, 0, 2 };
pub const gateway_ipv4: [4]u8 = .{ 100, 96, 0, 1 };

const ethernet_header_len = 14;
const arp_packet_len = 28;
const arp_frame_len = ethernet_header_len + arp_packet_len;
const ether_type_arp: u16 = 0x0806;
const ether_type_ipv4: u16 = 0x0800;
const arp_hardware_ethernet: u16 = 1;
const arp_op_request: u16 = 1;
const arp_op_reply: u16 = 2;

pub const FrameIoError = error{
    EndOfStream,
    FrameTooLarge,
    ShortWrite,
    IoFailed,
};

pub fn cli(init: std.process.Init, args: []const []const u8, stdout: *Io.Writer) !void {
    _ = init;
    _ = stdout;
    if (args.len != 1 or !std.mem.eql(u8, args[0], "--stdio")) {
        std.debug.print("usage: spore netd --stdio\n", .{});
        std.process.exit(2);
    }

    try writeAllFd(2, "ready\n");
    var in_buf: [max_frame_len]u8 = undefined;
    while (true) {
        const frame = readFrameFd(0, &in_buf) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
        std.log.debug("spore-netd rx frame len={d}", .{frame.len});
        var reply_buf: [max_frame_len]u8 = undefined;
        if (arpReply(frame, &reply_buf)) |reply| {
            try writeFrameFd(1, reply);
        }
    }
}

pub fn writeFrameFd(fd: std.c.fd_t, frame: []const u8) FrameIoError!void {
    if (frame.len > max_frame_len) return error.FrameTooLarge;
    var header: [frame_header_len]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(frame.len), .little);
    try writeAllFd(fd, &header);
    try writeAllFd(fd, frame);
}

pub fn readFrameFd(fd: std.c.fd_t, out: *[max_frame_len]u8) FrameIoError![]const u8 {
    var header: [frame_header_len]u8 = undefined;
    try readExactFd(fd, &header);
    const len = try decodeFrameLen(header[0..frame_header_len]);
    try readExactFd(fd, out[0..len]);
    return out[0..len];
}

pub fn arpReply(frame: []const u8, out: *[max_frame_len]u8) ?[]const u8 {
    const request = parseArpRequest(frame) orelse return null;
    const reply = out[0..arp_frame_len];
    @memcpy(reply[0..6], &request.sender_mac);
    @memcpy(reply[6..12], &gateway_mac);
    std.mem.writeInt(u16, reply[12..14], ether_type_arp, .big);

    std.mem.writeInt(u16, reply[14..16], arp_hardware_ethernet, .big);
    std.mem.writeInt(u16, reply[16..18], ether_type_ipv4, .big);
    reply[18] = 6;
    reply[19] = 4;
    std.mem.writeInt(u16, reply[20..22], arp_op_reply, .big);
    @memcpy(reply[22..28], &gateway_mac);
    @memcpy(reply[28..32], &gateway_ipv4);
    @memcpy(reply[32..38], &request.sender_mac);
    @memcpy(reply[38..42], &request.sender_ipv4);
    return reply;
}

const ArpRequest = struct {
    sender_mac: [6]u8,
    sender_ipv4: [4]u8,
};

fn parseArpRequest(frame: []const u8) ?ArpRequest {
    if (frame.len < arp_frame_len) return null;
    if (std.mem.readInt(u16, frame[12..14], .big) != ether_type_arp) return null;
    const arp = frame[ethernet_header_len..][0..arp_packet_len];
    if (std.mem.readInt(u16, arp[0..2], .big) != arp_hardware_ethernet) return null;
    if (std.mem.readInt(u16, arp[2..4], .big) != ether_type_ipv4) return null;
    if (arp[4] != 6 or arp[5] != 4) return null;
    if (std.mem.readInt(u16, arp[6..8], .big) != arp_op_request) return null;
    if (!std.mem.eql(u8, arp[24..28], &gateway_ipv4)) return null;

    var sender_mac: [6]u8 = undefined;
    var sender_ipv4: [4]u8 = undefined;
    @memcpy(&sender_mac, arp[8..14]);
    @memcpy(&sender_ipv4, arp[14..18]);
    return .{ .sender_mac = sender_mac, .sender_ipv4 = sender_ipv4 };
}

fn decodeFrameLen(header: *const [frame_header_len]u8) FrameIoError!usize {
    const len = std.mem.readInt(u32, header, .little);
    if (len > max_frame_len) return error.FrameTooLarge;
    return @intCast(len);
}

fn readExactFd(fd: std.c.fd_t, out: []u8) FrameIoError!void {
    var remaining = out;
    while (remaining.len > 0) {
        const n = std.posix.read(fd, remaining) catch return error.IoFailed;
        if (n == 0) return error.EndOfStream;
        remaining = remaining[n..];
    }
}

fn writeAllFd(fd: std.c.fd_t, bytes: []const u8) FrameIoError!void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n < 0) return error.IoFailed;
        if (n == 0) return error.ShortWrite;
        remaining = remaining[@intCast(n)..];
    }
}

fn testArpRequest(sender_mac: [6]u8, sender_ipv4: [4]u8, target_ipv4: [4]u8) [arp_frame_len]u8 {
    var frame: [arp_frame_len]u8 = undefined;
    frame[0..6].* = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    @memcpy(frame[6..12], &sender_mac);
    std.mem.writeInt(u16, frame[12..14], ether_type_arp, .big);
    std.mem.writeInt(u16, frame[14..16], arp_hardware_ethernet, .big);
    std.mem.writeInt(u16, frame[16..18], ether_type_ipv4, .big);
    frame[18] = 6;
    frame[19] = 4;
    std.mem.writeInt(u16, frame[20..22], arp_op_request, .big);
    @memcpy(frame[22..28], &sender_mac);
    @memcpy(frame[28..32], &sender_ipv4);
    frame[32..38].* = .{ 0, 0, 0, 0, 0, 0 };
    @memcpy(frame[38..42], &target_ipv4);
    return frame;
}

test "spore-netd answers ARP for the gateway" {
    const sender_mac: [6]u8 = .{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    const sender_ip: [4]u8 = .{ 100, 96, 0, 2 };
    const request = testArpRequest(sender_mac, sender_ip, gateway_ipv4);

    var out: [max_frame_len]u8 = undefined;
    const reply = arpReply(&request, &out).?;

    try std.testing.expectEqual(@as(usize, arp_frame_len), reply.len);
    try std.testing.expectEqualSlices(u8, &sender_mac, reply[0..6]);
    try std.testing.expectEqualSlices(u8, &gateway_mac, reply[6..12]);
    try std.testing.expectEqual(@as(u16, ether_type_arp), std.mem.readInt(u16, reply[12..14], .big));
    try std.testing.expectEqual(@as(u16, arp_op_reply), std.mem.readInt(u16, reply[20..22], .big));
    try std.testing.expectEqualSlices(u8, &gateway_mac, reply[22..28]);
    try std.testing.expectEqualSlices(u8, &gateway_ipv4, reply[28..32]);
    try std.testing.expectEqualSlices(u8, &sender_mac, reply[32..38]);
    try std.testing.expectEqualSlices(u8, &sender_ip, reply[38..42]);
}

test "spore-netd drops malformed and non-gateway ARP frames" {
    var out: [max_frame_len]u8 = undefined;
    try std.testing.expect(arpReply("short", &out) == null);

    const sender_mac: [6]u8 = .{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    const sender_ip: [4]u8 = .{ 100, 96, 0, 2 };
    const other_ip: [4]u8 = .{ 100, 96, 0, 3 };
    const request = testArpRequest(sender_mac, sender_ip, other_ip);
    try std.testing.expect(arpReply(&request, &out) == null);
}

test "spore-netd frame stream round trips bounded frames" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    try writeFrameFd(fds[1], "frame");
    var out: [max_frame_len]u8 = undefined;
    const frame = try readFrameFd(fds[0], &out);
    try std.testing.expectEqualStrings("frame", frame);
}

test "spore-netd frame stream rejects oversized frames before payload read" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var header: [frame_header_len]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], max_frame_len + 1, .little);
    try writeAllFd(fds[1], &header);

    var out: [max_frame_len]u8 = undefined;
    try std.testing.expectError(error.FrameTooLarge, readFrameFd(fds[0], &out));
}

fn fuzzFrameStreamAndArp(_: void, s: *std.testing.Smith) !void {
    var bytes: [frame_header_len + max_frame_len]u8 = undefined;
    const len = @min(s.slice(&bytes), bytes.len);
    var out: [max_frame_len]u8 = undefined;

    _ = arpReply(bytes[0..len], &out);

    if (len < frame_header_len) return;
    const frame_len = decodeFrameLen(bytes[0..frame_header_len]) catch return;
    if (frame_header_len + frame_len > len) return;
    _ = arpReply(bytes[frame_header_len..][0..frame_len], &out);
}

test "fuzz spore-netd frame stream and ARP handling" {
    try std.testing.fuzz({}, fuzzFrameStreamAndArp, .{});
}

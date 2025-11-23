const std = @import("std");
const fs = std.fs;
const posix = std.posix;
const tetris = @import("tetris.zig");

// const c = @cImport({
//     @cInclude("unistd.h");
//     @cInclude("termios.h");
// });

fn readKey(buf: []u8) tetris.Keys {
    const in = posix.STDIN_FILENO;
    const n = posix.read(in, buf) catch |e| switch (e) {
        error.WouldBlock => 0,
        else => 0,
    };

    if (n == 1) {
        return switch (buf[0]) {
            'j' => tetris.Keys.Left,
            'k' => tetris.Keys.Down,
            'l' => tetris.Keys.Right,
            ' ' => tetris.Keys.Rotate,
            27 => tetris.Keys.Quite,
            'q' => tetris.Keys.Quite,
            else => tetris.Keys.NOP,
        };
    } else if (n > 2 and std.mem.eql(u8, buf[0..2], &[_]u8{ 27, 91 })) {
        return switch (buf[2]) {
            68 => tetris.Keys.Left,
            66 => tetris.Keys.Down,
            67 => tetris.Keys.Right,
            else => tetris.Keys.NOP,
        };
    }

    return tetris.Keys.NOP;
}

pub fn main() !void {
    var memory: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const alloc = fba.allocator();

    const out = fs.File.stdout();
    var state = try tetris.GameState.Init(alloc, 26, 30);
    defer state.deinit(alloc);

    const in = posix.STDIN_FILENO;
    const origTerm = try posix.tcgetattr(in);
    defer posix.tcsetattr(in, .NOW, origTerm) catch {};

    var rawTerm = origTerm;
    rawTerm.lflag.ECHO = false;
    rawTerm.lflag.ICANON = false;
    rawTerm.cc[@intFromEnum(posix.V.MIN)] = 0;
    rawTerm.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(in, .NOW, rawTerm);

    const origFlags = try posix.fcntl(in, posix.F.GETFL, 0);
    _ = try posix.fcntl(in, posix.F.SETFL, origFlags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    defer _ = posix.fcntl(in, posix.F.SETFL, origFlags) catch {};

    state.currentPiece = tetris.nextShape(&state);

    const targetFPS = 60;
    const targetFrameTime = std.time.ns_per_s / targetFPS;
    var frameCount: usize = 0;

    var inputBuf: [64]u8 = undefined;

    // const interval_ms: i64 = 1000 / 66;
    var timer = try std.time.Timer.start();
    var lastTick = timer.read();

    while (state.running) {
        const ts = timer.read();
        state.nextKey = readKey(&inputBuf);
        try tetris.updateAndDrawGame(out, &state);
        const te = timer.read();
        const frameDuration = te - ts;

        if (frameDuration < targetFrameTime) {
            const sleep = targetFrameTime - frameDuration;
            // std.debug.print("sleeping for: {d}\n", .{sleep});
            // std.debug.print("FPS: {}\n", .{frameCount});
            std.Thread.sleep(sleep);
        }

        frameCount += 1;
        const now = timer.read();
        if (now - lastTick >= std.time.ns_per_s) {
            // std.debug.print("FPS: {}\n", .{frameCount});
            frameCount = 0;
            lastTick = now;
            state.moveOnTick = true;
        }
    }
}

// test "simple test" {
//     const gpa = std.testing.allocator;
//     var list: std.ArrayList(i32) = .empty;
//     defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
//     try list.append(gpa, 42);
//     try std.testing.expectEqual(@as(i32, 42), list.pop());
// }
//
// test "fuzz example" {
//     const Context = struct {
//         fn testOne(context: @This(), input: []const u8) anyerror!void {
//             _ = context;
//             // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
//             try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
//         }
//     };
//     try std.testing.fuzz(Context{}, Context.testOne, .{});
// }

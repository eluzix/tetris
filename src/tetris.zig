//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const fs = std.fs;

const ESC = "\x1B";
const CSI = ESC ++ "[";
const EMPTY = ' ';
const PIECE_SIZE = 4;

const Shape = enum { I, L, S, O, T };

const Rotate = usize;

const MASKS = [2][4]u16{
    [_]u16{
        0b0110011001100110,
        0b0000111111110000,
        0b0110011001100110,
        0b0000111111110000,
    },
    [_]u16{ 0b1000100010001110, 0b1111100010000000, 0b0111000100010001, 0b0001000100010111 },
};

const SHAPES = [_][4]u8{
    [_]u8{ EMPTY, EMPTY, EMPTY, EMPTY },
    [_]u8{ EMPTY, EMPTY, EMPTY, '1' },
    [_]u8{ EMPTY, EMPTY, '1', EMPTY },
    [_]u8{ EMPTY, EMPTY, '1', '1' },
    [_]u8{ EMPTY, '1', EMPTY, EMPTY },
    [_]u8{ EMPTY, '1', EMPTY, '1' },
    [_]u8{ EMPTY, '1', '1', EMPTY },
    [_]u8{ EMPTY, '1', '1', '1' },
    [_]u8{ '1', EMPTY, EMPTY, EMPTY },
    [_]u8{ '1', EMPTY, EMPTY, '1' },
    [_]u8{ '1', EMPTY, '1', '1' },
    [_]u8{ '1', EMPTY, '1', EMPTY },
    [_]u8{ '1', '1', EMPTY, EMPTY },
    [_]u8{ '1', '1', EMPTY, '1' },
    [_]u8{ '1', '1', '1', EMPTY },
    [_]u8{ '1', '1', '1', '1' },
};

pub const Piece = struct {
    shape: Shape,
    rotate: Rotate,
    x: u8,
    y: u8,

    const Self = @This();

    pub fn rotateRight(self: *Self) void {
        var ci = self.rotate;
        ci += 1;
        if (ci > 3) {
            ci = 0;
        }

        self.*.rotate = ci;
    }

    fn mask(self: Self) u16 {
        return MASKS[@intFromEnum(self.shape)][self.rotate];
    }
};

pub const Keys = enum { Rotate, Left, Right, Down, Quite, NOP };

pub const GameState = struct {
    running: bool,
    moveOnTick: bool,
    nextKey: Keys,
    width: usize,
    height: usize,
    currentPiece: Piece,
    board: [][]u8,
    renderbuffer: [][]u8,

    pub fn Init(allocator: std.mem.Allocator, width: usize, height: usize) !GameState {
        const ar = try allocator.alloc([]u8, height);
        for (ar) |*row| {
            row.* = try allocator.alloc(u8, width);
            @memset(row.*, '-');
        }

        const ar2 = try allocator.alloc([]u8, height);
        for (ar2) |*row| {
            row.* = try allocator.alloc(u8, width);
            @memset(row.*, ' ');
        }

        const gs = GameState{
            .running = true,
            .moveOnTick = false,
            .nextKey = Keys.NOP,
            .width = width,
            .height = height,
            .currentPiece = undefined,
            .board = ar,
            .renderbuffer = ar2,
        };

        return gs;
    }

    pub fn deinit(self: GameState, allocator: std.mem.Allocator) void {
        for (self.board) |*row| {
            allocator.free(row.*);
        }
        allocator.free(self.board);

        for (self.renderbuffer) |*row| {
            allocator.free(row.*);
        }
        allocator.free(self.renderbuffer);
    }
};

pub fn clearSreen(f: fs.File) !void {
    try f.writeAll(CSI ++ "2J " ++ ESC ++ "H");
}

fn copyBoardToRenderBuffer(state: *GameState) void {
    for (state.board, state.renderbuffer) |*brd, *buf| {
        @memcpy(buf.*, brd.*);
    }
}

fn updateMovement(state: *GameState) void {
    var baseY = state.currentPiece.y;

    if (state.moveOnTick and baseY + PIECE_SIZE < state.height) {
        baseY += 1;
    }

    switch (state.nextKey) {
        .NOP => {},
        .Left => {
            if (state.currentPiece.x > 0) {
                state.currentPiece.x -= 1;
            }
        },
        .Right => {
            if (state.currentPiece.x + PIECE_SIZE < state.width) {
                state.currentPiece.x += 1;
            }
        },
        .Down => {
            if (baseY + PIECE_SIZE < state.height) {
                baseY += 1;
            }
        },

        .Rotate => state.currentPiece.rotateRight(),
        .Quite => state.running = false,
    }

    state.currentPiece.y = baseY;
    state.moveOnTick = false;
}

pub fn updateAndDrawGame(f: fs.File, state: *GameState) !void {
    updateMovement(state);
    copyBoardToRenderBuffer(state);
    drawPiece(state.currentPiece, state.renderbuffer);
    try render(f, state.renderbuffer);
}

fn drawPiece(piece: Piece, board: [][]u8) void {
    const baseX = piece.x;
    const baseY = piece.y;
    const shape: u16 = piece.mask();

    for (0..4) |i| {
        const sft: u4 = @as(u4, @intCast(12 - (4 * i)));
        const n: u8 = @truncate((shape >> sft) & 0xF);
        // std.debug.print("n :::: {b}, {any}\n", .{ n, SHAPES[n] });

        const shapeRow = SHAPES[n];
        const targetRow = board[baseY + i][baseX .. baseX + 4];
        @memcpy(targetRow, &shapeRow);
    }
}

fn writeOrWait(f: fs.File, bytes: []const u8) void {
    f.writeAll(bytes) catch |e| {
        if (e == error.WouldBlock) {
            std.Thread.sleep(50);
            f.writeAll(bytes) catch {};
        }
    };
}

fn render(f: fs.File, board: [][]u8) !void {
    writeOrWait(f, CSI ++ "2J " ++ ESC ++ "H");
    writeOrWait(f, CSI ++ "?25l\r");
    for (board) |*row| {
        writeOrWait(f, row.*);
        writeOrWait(f, "\n\r");
    }
    writeOrWait(f, CSI ++ "?25l\r");
}

test "Rotatation" {
    const t = std.testing;

    var p: Piece = .{ .shape = .I, .rotate = 0, .x = 0, .y = 0 };

    try t.expectEqual(p.mask(), MASKS[0][0]);
    p.rotateRight();
    try t.expectEqual(p.mask(), MASKS[0][1]);
    p.rotateRight();
    try t.expectEqual(p.mask(), MASKS[0][2]);
    p.rotateRight();
    try t.expectEqual(p.mask(), MASKS[0][3]);
    p.rotateRight();
    try t.expectEqual(p.mask(), MASKS[0][0]);
}

// test "Init state" {
//     const gpa = std.testing.allocator;
//
//     const st = try GameState.Init(gpa, 10, 20);
//     defer st.deinit(gpa);
//
//     st.board[0][2] = ' ';
//     std.debug.print(">>> {any}\n", .{st});
// }

test "Draw Piece" {
    const gpa = std.testing.allocator;
    const t = std.testing;
    var p: Piece = .{ .shape = .I, .rotate = 0, .x = 0, .y = 0 };
    var st = try GameState.Init(gpa, 4, 4);
    defer st.deinit(gpa);

    copyBoardToRenderBuffer(&st);
    drawPiece(p, st.renderbuffer);

    try t.expectEqual(EMPTY, st.renderbuffer[0][0]);
    try t.expectEqual('1', st.renderbuffer[0][1]);
    try t.expectEqual('1', st.renderbuffer[0][2]);
    try t.expectEqual('1', st.renderbuffer[1][1]);
    try t.expectEqual('1', st.renderbuffer[1][2]);
    try t.expectEqual(EMPTY, st.renderbuffer[0][3]);

    p.rotateRight();

    copyBoardToRenderBuffer(&st);
    drawPiece(p, st.renderbuffer);

    try t.expect(std.mem.allEqual(u8, st.renderbuffer[0], EMPTY));
    try t.expect(std.mem.eql(u8, st.renderbuffer[1], "1111"));
}

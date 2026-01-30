//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const fs = std.fs;
const Io = std.Io;

const ESC = "\x1B";
const CSI = ESC ++ "[";
const BOARD_BG = '-';
const EMPTY = '-';
const FULL = '@';
const PIECE_SIZE = 4;

const Shape = enum { I, L, S, O, T };

const Rotate = usize;

const RIGHT_BORDER_MASK = 0b0001000100010001;

const MASKS = [_][4]u16{
    [_]u16{ 0b0110011001100110, 0b0000111111110000, 0b0110011001100110, 0b0000111111110000 },
    [_]u16{ 0b1000100010001110, 0b1111100010000000, 0b0111000100010001, 0b0001000100010111 },
    // S shape: rot0/180 = -@@- over @@--, rot90/270 = @--- over @@-- over -@--
    [_]u16{ 0b0110110000000000, 0b1000110001000000, 0b0110110000000000, 0b1000110001000000 },
    [_]u16{ 0b0110100110010110, 0b0110100110010110, 0b0110100110010110, 0b0110100110010110 },
    [_]u16{ 0b1110010001000100, 0b0001111100010000, 0b0010001000100111, 0b0000100011111000 },
};

const SHAPES = [_][4]u8{
    [_]u8{ EMPTY, EMPTY, EMPTY, EMPTY },
    [_]u8{ EMPTY, EMPTY, EMPTY, FULL },
    [_]u8{ EMPTY, EMPTY, FULL, EMPTY },
    [_]u8{ EMPTY, EMPTY, FULL, FULL },
    [_]u8{ EMPTY, FULL, EMPTY, EMPTY },
    [_]u8{ EMPTY, FULL, EMPTY, FULL },
    [_]u8{ EMPTY, FULL, FULL, EMPTY },
    [_]u8{ EMPTY, FULL, FULL, FULL },
    [_]u8{ FULL, EMPTY, EMPTY, EMPTY },
    [_]u8{ FULL, EMPTY, EMPTY, FULL },
    [_]u8{ FULL, EMPTY, FULL, FULL },
    [_]u8{ FULL, EMPTY, FULL, EMPTY },
    [_]u8{ FULL, FULL, EMPTY, EMPTY },
    [_]u8{ FULL, FULL, EMPTY, FULL },
    [_]u8{ FULL, FULL, FULL, EMPTY },
    [_]u8{ FULL, FULL, FULL, FULL },
};

pub const Piece = struct {
    shape: Shape,
    rotate: Rotate,
    x: u8,
    y: u8,
    stuck: bool,
    width: u4 = PIECE_SIZE,

    const Self = @This();

    pub fn rotateRight(self: *Self) void {
        var ci = self.rotate;
        ci += 1;
        if (ci > 3) {
            ci = 0;
        }

        self.*.rotate = ci;
        self.setWidth();
    }

    pub fn setWidth(self: *Self) void {
        const msk = self.mask() & RIGHT_BORDER_MASK;
        if (msk == 0) {
            self.*.width = PIECE_SIZE - 1;
        } else {
            self.*.width = PIECE_SIZE;
        }
    }

    fn mask(self: Self) u16 {
        return MASKS[@intFromEnum(self.shape)][self.rotate];
    }
};

pub const Keys = enum { Rotate, Left, Right, Down, Quite, NOP, TOGGLE_DEBUG };

pub const GameState = struct {
    running: bool,
    debug: bool,
    currentFps: usize,
    moveOnTick: bool,
    nextKey: Keys,
    width: usize,
    height: usize,
    currentPiece: Piece,
    rnd: std.Random.DefaultPrng,
    board: [][]u8,
    renderbuffer: [][]u8,

    pub fn Init(allocator: std.mem.Allocator, width: usize, height: usize) !GameState {
        const ar = try allocator.alloc([]u8, height);
        for (ar) |*row| {
            row.* = try allocator.alloc(u8, width);
            @memset(row.*, BOARD_BG);
        }

        const ar2 = try allocator.alloc([]u8, height);
        for (ar2) |*row| {
            row.* = try allocator.alloc(u8, width);
            @memset(row.*, EMPTY);
        }

        const seed: u64 = @intCast(std.time.timestamp());
        // var prng = std.Random.DefaultPrng.init(seed);

        const gs = GameState{
            .running = true,
            .debug = false,
            .currentFps = 0,
            .moveOnTick = false,
            .nextKey = Keys.NOP,
            .width = width,
            .height = height,
            .currentPiece = undefined,
            .rnd = std.Random.DefaultPrng.init(seed),
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

fn copyRenderBufferToBoard(state: *GameState) void {
    for (state.board, state.renderbuffer) |*brd, *buf| {
        @memcpy(brd.*, buf.*);
    }
}

pub fn nextShape(state: *GameState) Piece {
    const tags = std.meta.tags(Shape);
    const s = tags[state.rnd.random().intRangeLessThan(usize, 0, tags.len)];

    return Piece{
        .shape = s,
        .rotate = 0,
        .x = 1,
        .y = 1,
        .stuck = false,
    };
}

fn handleInputAndTick(state: *GameState) [2]u8 {
    var ret = [2]u8{ state.currentPiece.x, state.currentPiece.y };
    const pw = state.currentPiece.width;

    if (state.moveOnTick and ret[1] + pw < state.height) {
        ret[1] += 1;
    }

    switch (state.nextKey) {
        .NOP => {},
        .Left => {
            if (ret[0] > 0) {
                ret[0] -= 1;
            }
        },
        .Right => {
            if (ret[0] + pw < state.width) {
                ret[0] += 1;
            }
        },
        .Down => {
            if (ret[1] + PIECE_SIZE < state.height) {
                ret[1] += 1;
            }
        },

        .Rotate => state.currentPiece.rotateRight(),
        .Quite => state.running = false,
        .TOGGLE_DEBUG => state.debug = !state.debug,
    }

    state.moveOnTick = false;

    return ret;
}

fn copyRow(src: []u8, dest: []u8) void {
    for (0..@min(src.len, dest.len)) |i| {
        if (src[i] == FULL) {
            dest[i] = FULL;
        }
    }
}

pub fn updateAndDrawGame(out: *Io.Writer, state: *GameState) !void {
    copyBoardToRenderBuffer(state);

    var shape = translatePiceForRender(state.currentPiece);
    const desiredMovment = handleInputAndTick(state);
    const baseX = desiredMovment[0];
    const baseY = desiredMovment[1];

    var board = state.renderbuffer;
    var pieceHeight = @as(usize, PIECE_SIZE);

    renderLoop: for (0..4) |i| {
        const row = 3 - i;
        if (std.mem.allEqual(u8, &shape[row], EMPTY)) {
            pieceHeight -= 1;
            continue;
        }

        const pw = state.currentPiece.width;
        var targetRow = board[baseY + row][baseX .. baseX + pw];
        for (0..pw) |y| {
            const column = pw - 1 - y;

            if (targetRow[column] == FULL and shape[row][column] == FULL) {
                // hit rock bottom
                state.currentPiece.stuck = true;

                for (0..pieceHeight) |nrow| {
                    targetRow = board[baseY + nrow - 1][baseX .. baseX + pw];
                    copyRow(&shape[nrow], targetRow);
                }

                break :renderLoop;
            }

            if (targetRow[column] == FULL and shape[row][column] == EMPTY) {
                shape[row][column] = FULL;
            }
        }

        copyRow(&shape[row], targetRow);
    }

    if (baseY + pieceHeight == state.height) {
        state.currentPiece.stuck = true;
    }

    state.currentPiece.x = desiredMovment[0];
    state.currentPiece.y = desiredMovment[1];

    if (state.currentPiece.stuck) {
        copyRenderBufferToBoard(state);
        state.currentPiece = nextShape(state);
    }
    // todo uzix - should we use a writer ?
    render(out, state.renderbuffer) catch {};

    if (state.debug) {
        renderDebugData(out, state) catch {};
    }

    out.flush() catch {};
}

fn translatePiceForRender(piece: Piece) [PIECE_SIZE][PIECE_SIZE]u8 {
    var ret: [PIECE_SIZE][PIECE_SIZE]u8 = undefined;
    const shape: u16 = piece.mask();

    for (0..4) |loop_i| {
        const i = 3 - loop_i;
        const sft: u4 = @as(u4, @intCast(12 - (4 * i)));
        const n: u8 = @truncate((shape >> sft) & 0xF);

        const shapeRow = SHAPES[n];
        @memcpy(ret[i][0..PIECE_SIZE], &shapeRow);
    }

    return ret;
}

fn render(out: *Io.Writer, board: [][]u8) !void {
    try out.writeAll(CSI ++ "5;1H");
    for (board) |*row| {
        try out.writeAll(row.*);
        try out.writeAll(CSI ++ "K\r\n");
    }
}

fn renderDebugData(out: *Io.Writer, state: *GameState) !void {
    try out.writeAll(CSI ++ "1;1H");

    var buf: [25]u8 = undefined;
    const fmt = std.fmt.bufPrint(&buf, "Frame count: {d}\n", .{state.currentFps}) catch {
        return;
    };
    try out.writeAll(fmt);
}

test "Rotatation" {
    const t = std.testing;

    var p: Piece = .{ .shape = .I, .rotate = 0, .x = 0, .y = 0, .stuck = false };

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

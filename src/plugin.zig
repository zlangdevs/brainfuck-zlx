const std = @import("std");

const HostApi = extern struct {
    api_version: u32,
    register_syntax_block: *const fn (host: *HostApi, name: [*:0]const u8, syntax: *const BlockSyntax, handler: BlockHandler) callconv(.c) c_int,
    register_help_section: *const fn (host: *HostApi, id: [*:0]const u8, text: [*:0]const u8) callconv(.c) c_int,
    register_cli_flag: *const fn (host: *HostApi, name: [*:0]const u8, help: ?[*:0]const u8, mandatory: c_int) callconv(.c) c_int,
    register_module: *const fn (host: *HostApi, name: [*:0]const u8, path: [*:0]const u8) callconv(.c) c_int,
    register_link_flag: *const fn (host: *HostApi, flag: [*:0]const u8) callconv(.c) c_int,
    diagnostic: *const fn (host: *HostApi, level: c_int, file: ?[*:0]const u8, line: u32, column: u32, message: [*:0]const u8, hint: ?[*:0]const u8) callconv(.c) void,
};

const BlockSyntax = extern struct { mode: c_int, terminator: ?[*:0]const u8 };
const BlockInput = extern struct { file: [*:0]const u8, line: u32, column: u32, raw_source: [*]const u8, raw_source_len: u32 };
const BlockOutput = extern struct { generated_zlang_source: [*]const u8, generated_zlang_source_len: u32 };
const BlockHandler = *const fn (host: *HostApi, input: *const BlockInput, output: *BlockOutput) callconv(.c) c_int;

const ProbeResult = extern struct {
    api_min: u32,
    api_max: u32,
    name: [*:0]const u8,
    version: [*:0]const u8,
    requires_host_features: ?[*:null]const ?[*:0]const u8,
};

const PluginDesc = extern struct {
    api_min: u32,
    api_max: u32,
    name: [*:0]const u8,
    version: [*:0]const u8,
    register_plugin: *const fn (host: *HostApi) callconv(.c) c_int,
};

var probe_singleton: ProbeResult = .{
    .api_min = 1,
    .api_max = 1,
    .name = "brainfuck",
    .version = "0.2.0",
    .requires_host_features = null,
};

var desc_singleton: PluginDesc = .{
    .api_min = 1,
    .api_max = 1,
    .name = "brainfuck",
    .version = "0.2.0",
    .register_plugin = registerPlugin,
};

const alloc = std.heap.c_allocator;
var output_buf: std.ArrayList(u8) = .empty;
var block_counter: u32 = 0;

const LoadRequest = struct {
    var_name: []u8,
    pos: i32,
    bits: i32,
    signed: bool,
    typed: bool,
};

fn parseTypeBits(spec: []const u8) struct { bits: i32, signed: bool } {
    if (spec.len < 2) return .{ .bits = 32, .signed = true };
    const signed = spec[0] == 'i';
    if (spec[0] != 'i' and spec[0] != 'u') return .{ .bits = 32, .signed = true };
    const bits = std.fmt.parseInt(i32, spec[1..], 10) catch 32;
    return .{ .bits = bits, .signed = signed };
}

const BfCtx = struct {
    cell_size: i32 = 8,
    len: i32 = 100,
    code: std.ArrayList(u8) = .empty,
    loads: std.ArrayList(LoadRequest) = .empty,

    fn deinit(self: *BfCtx) void {
        self.code.deinit(alloc);
        for (self.loads.items) |l| alloc.free(l.var_name);
        self.loads.deinit(alloc);
    }
};

fn parseConfig(input: []const u8) !BfCtx {
    var ctx: BfCtx = .{};
    errdefer ctx.deinit();
    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '?' and input[i + 1] == '?') {
            const nl = std.mem.indexOfScalarPos(u8, input, i, '\n') orelse input.len;
            i = nl;
            continue;
        }
        if (input[i] == '?') {
            const close = std.mem.indexOfScalarPos(u8, input, i + 1, '?') orelse break;
            const inner = std.mem.trim(u8, input[i + 1 .. close], " \t");
            i = close + 1;
            const space = std.mem.indexOfAny(u8, inner, " \t");
            if (space) |sp| {
                const name = inner[0..sp];
                const value = std.mem.trim(u8, inner[sp + 1 ..], " \t");
                if (std.mem.eql(u8, name, "cell_size")) {
                    ctx.cell_size = std.fmt.parseInt(i32, value, 10) catch ctx.cell_size;
                } else if (std.mem.eql(u8, name, "len")) {
                    ctx.len = std.fmt.parseInt(i32, value, 10) catch ctx.len;
                } else if (std.mem.eql(u8, name, "load")) {
                    var parts = std.mem.splitScalar(u8, value, ' ');
                    const raw_name = parts.next() orelse continue;
                    const pos_str = parts.next() orelse continue;
                    const pos = std.fmt.parseInt(i32, std.mem.trim(u8, pos_str, " \t"), 10) catch continue;
                    const trimmed = std.mem.trim(u8, raw_name, " \t");
                    var bits: i32 = 32;
                    var signed_flag: bool = true;
                    var typed_flag: bool = false;
                    var var_only = trimmed;
                    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                        var_only = trimmed[0..colon];
                        const t = parseTypeBits(trimmed[colon + 1 ..]);
                        bits = t.bits;
                        signed_flag = t.signed;
                        typed_flag = true;
                    }
                    const name_dup = try alloc.dupe(u8, var_only);
                    try ctx.loads.append(alloc, .{ .var_name = name_dup, .pos = pos, .bits = bits, .signed = signed_flag, .typed = typed_flag });
                }
            }
            continue;
        }
        const ch = input[i];
        i += 1;
        switch (ch) {
            '+', '-', '<', '>', '.', ',', '[', ']' => try ctx.code.append(alloc, ch),
            else => {},
        }
    }
    return ctx;
}

const BfOp = union(enum) {
    inc_ptr: i32,
    add_val: i32,
    output,
    input,
    loop_start,
    loop_end,
    set_zero,
    linear_loop: std.ArrayList(LinearOp),
    scan_left,
    scan_right,
};

const LinearOp = struct { offset: i32, factor: i32 };

fn freeOps(ops: []const BfOp) void {
    for (ops) |op| switch (op) {
        .linear_loop => |list| {
            var m = list;
            m.deinit(alloc);
        },
        else => {},
    };
}

fn parseOps(code: []const u8) !std.ArrayList(BfOp) {
    var ops: std.ArrayList(BfOp) = .empty;
    for (code) |ch| switch (ch) {
        '>' => try ops.append(alloc, .{ .inc_ptr = 1 }),
        '<' => try ops.append(alloc, .{ .inc_ptr = -1 }),
        '+' => try ops.append(alloc, .{ .add_val = 1 }),
        '-' => try ops.append(alloc, .{ .add_val = -1 }),
        '.' => try ops.append(alloc, .output),
        ',' => try ops.append(alloc, .input),
        '[' => try ops.append(alloc, .loop_start),
        ']' => try ops.append(alloc, .loop_end),
        else => {},
    };
    return ops;
}

fn checkLinearLoop(body: []const BfOp) !?std.ArrayList(LinearOp) {
    var effects = std.AutoHashMap(i32, i32).init(alloc);
    defer effects.deinit();
    var off: i32 = 0;
    for (body) |op| switch (op) {
        .inc_ptr => |v| off += v,
        .add_val => |v| {
            const entry = try effects.getOrPut(off);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += v;
        },
        else => return null,
    };
    if (off != 0) return null;
    const start = effects.get(0) orelse return null;
    if (start != -1) return null;
    var factors: std.ArrayList(LinearOp) = .empty;
    var it = effects.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.* == 0) continue;
        if (e.value_ptr.* == 0) continue;
        try factors.append(alloc, .{ .offset = e.key_ptr.*, .factor = e.value_ptr.* });
    }
    return factors;
}

fn checkScanLoop(body: []const BfOp) ?i32 {
    if (body.len != 1) return null;
    return switch (body[0]) {
        .inc_ptr => |v| if (v == 1) @as(i32, 1) else if (v == -1) @as(i32, -1) else null,
        else => null,
    };
}

fn skipDeadLoop(ops: []const BfOp, start: usize) ?usize {
    if (ops[start] != .loop_start) return null;
    var depth: i32 = 1;
    var j = start + 1;
    while (j < ops.len) : (j += 1) {
        if (ops[j] == .loop_start) depth += 1
        else if (ops[j] == .loop_end) {
            depth -= 1;
            if (depth == 0) return j + 1;
        }
    }
    return null;
}

fn optimize(initial: []const BfOp, initial_cell_zero: bool) !std.ArrayList(BfOp) {
    var contracted: std.ArrayList(BfOp) = .empty;
    defer contracted.deinit(alloc);
    var i: usize = 0;
    while (i < initial.len) {
        const op = initial[i];
        switch (op) {
            .inc_ptr => |v| {
                var total = v;
                var j = i + 1;
                while (j < initial.len and initial[j] == .inc_ptr) : (j += 1) total += initial[j].inc_ptr;
                if (total != 0) try contracted.append(alloc, .{ .inc_ptr = total });
                i = j;
            },
            .add_val => |v| {
                var total = v;
                var j = i + 1;
                while (j < initial.len and initial[j] == .add_val) : (j += 1) total += initial[j].add_val;
                if (total != 0) try contracted.append(alloc, .{ .add_val = total });
                i = j;
            },
            else => {
                try contracted.append(alloc, op);
                i += 1;
            },
        }
    }

    var out: std.ArrayList(BfOp) = .empty;
    errdefer {
        freeOps(out.items);
        out.deinit(alloc);
    }
    const ops = contracted.items;
    var cell_known_zero = initial_cell_zero;
    i = 0;
    while (i < ops.len) {
        const op = ops[i];
        if (op == .loop_start and cell_known_zero) {
            if (skipDeadLoop(ops, i)) |after| {
                i = after;
                continue;
            }
        }
        if (op == .loop_start) {
            var depth: i32 = 1;
            var j = i + 1;
            var possible_linear = true;
            while (j < ops.len) : (j += 1) {
                if (ops[j] == .loop_start) {
                    depth += 1;
                    possible_linear = false;
                } else if (ops[j] == .loop_end) {
                    depth -= 1;
                }
                if (depth == 0) break;
            }
            if (depth == 0) {
                const body = ops[i + 1 .. j];
                if (body.len == 1 and body[0] == .add_val) {
                    const v = body[0].add_val;
                    if (v == 1 or v == -1) {
                        try out.append(alloc, .set_zero);
                        cell_known_zero = true;
                        i = j + 1;
                        continue;
                    }
                }
                if (checkScanLoop(body)) |dir| {
                    try out.append(alloc, if (dir == 1) .scan_right else .scan_left);
                    cell_known_zero = true;
                    i = j + 1;
                    continue;
                }
                if (possible_linear) {
                    if (try checkLinearLoop(body)) |factors| {
                        try out.append(alloc, .{ .linear_loop = factors });
                        cell_known_zero = true;
                        i = j + 1;
                        continue;
                    }
                }
            }
        }
        try out.append(alloc, op);
        cell_known_zero = switch (op) {
            .set_zero, .linear_loop, .loop_end => true,
            .input => false,
            .add_val, .inc_ptr, .output, .scan_right, .scan_left, .loop_start => false,
        };
        i += 1;
    }
    return out;
}

fn emit(s: []const u8) void {
    output_buf.appendSlice(alloc, s) catch {};
}

fn emitFmt(comptime fmt: []const u8, args: anytype) void {
    output_buf.print(alloc, fmt, args) catch {};
}

fn cellTypeName(cell_size: i32) []const u8 {
    return switch (cell_size) {
        16 => "u16",
        32 => "u32",
        64 => "u64",
        else => "u8",
    };
}

fn flushOffset(off: *i32, id: u32) void {
    if (off.* == 0) return;
    if (off.* > 0) {
        emitFmt("__bf_p_{d} = __bf_p_{d} + ({d});\n", .{ id, id, off.* });
    } else {
        emitFmt("__bf_p_{d} = __bf_p_{d} - ({d});\n", .{ id, id, -off.* });
    }
    off.* = 0;
}

fn emitAt(off: i32, id: u32, suffix: []const u8) void {
    if (off == 0) {
        emitFmt("__bf_tape_{d}[__bf_p_{d}]", .{ id, id });
    } else if (off > 0) {
        emitFmt("__bf_tape_{d}[__bf_p_{d} + {d}]", .{ id, id, off });
    } else {
        emitFmt("__bf_tape_{d}[__bf_p_{d} - {d}]", .{ id, id, -off });
    }
    emit(suffix);
}

fn emitOps(ops: []const BfOp, cell_t: []const u8, id: u32) void {
    var off: i32 = 0;
    for (ops) |op| switch (op) {
        .inc_ptr => |v| off += v,
        .add_val => |v| {
            emitAt(off, id, " = ");
            emitAt(off, id, "");
            if (v >= 0) emitFmt(" + ({d});\n", .{v}) else emitFmt(" - ({d});\n", .{-v});
        },
        .set_zero => {
            emitAt(off, id, " = 0;\n");
        },
        .output => {
            emit("@printf(\"%c\", ");
            emitAt(off, id, ");\n");
        },
        .input => {
            emit("@scanf(\"%c\", &");
            emitAt(off, id, ");\n");
        },
        .loop_start => {
            flushOffset(&off, id);
            emitFmt("for (__bf_tape_{d}[__bf_p_{d}] != 0) {{\n", .{ id, id });
        },
        .loop_end => {
            flushOffset(&off, id);
            emit("}\n");
        },
        .scan_right => {
            flushOffset(&off, id);
            emitFmt("for (__bf_tape_{d}[__bf_p_{d}] != 0) {{ __bf_p_{d} = __bf_p_{d} + 1; }}\n", .{ id, id, id, id });
        },
        .scan_left => {
            flushOffset(&off, id);
            emitFmt("for (__bf_tape_{d}[__bf_p_{d}] != 0) {{ __bf_p_{d} = __bf_p_{d} - 1; }}\n", .{ id, id, id, id });
        },
        .linear_loop => |factors| {
            emit("if (");
            emitAt(off, id, " != 0) {\n");
            for (factors.items) |f| {
                const target_off = off + f.offset;
                emitAt(target_off, id, " = ");
                emitAt(target_off, id, "");
                if (f.factor == 1) {
                    emit(" + ");
                    emitAt(off, id, ";\n");
                } else if (f.factor == -1) {
                    emit(" - ");
                    emitAt(off, id, ";\n");
                } else if (f.factor > 0) {
                    emitFmt(" + ({d} as {s}) * ", .{ f.factor, cell_t });
                    emitAt(off, id, ";\n");
                } else {
                    emitFmt(" - ({d} as {s}) * ", .{ -f.factor, cell_t });
                    emitAt(off, id, ";\n");
                }
            }
            emitAt(off, id, " = 0;\n");
            emit("}\n");
        },
    };
    flushOffset(&off, id);
}

fn brainfuckHandler(host: *HostApi, input: *const BlockInput, output: *BlockOutput) callconv(.c) c_int {
    _ = host;
    output_buf.clearRetainingCapacity();

    const raw = input.raw_source[0..input.raw_source_len];
    var ctx = parseConfig(raw) catch return 1;
    defer ctx.deinit();

    var ops = parseOps(ctx.code.items) catch return 1;
    defer ops.deinit(alloc);
    const initial_zero = ctx.loads.items.len == 0;
    var opt = optimize(ops.items, initial_zero) catch return 1;
    defer {
        freeOps(opt.items);
        opt.deinit(alloc);
    }

    const cell_t = cellTypeName(ctx.cell_size);
    const id = block_counter;
    block_counter += 1;

    emitFmt("arr<{s}, {d}> __bf_tape_{d};\n", .{ cell_t, ctx.len, id });
    emitFmt("for i32 __bf_i_{d} = 0; __bf_i_{d} < {d}; __bf_i_{d}++ {{ __bf_tape_{d}[__bf_i_{d}] = 0; }}\n", .{ id, id, ctx.len, id, id, id });
    emitFmt("i32 __bf_p_{d} = 0;\n", .{id});

    const cs: i32 = ctx.cell_size;

    for (ctx.loads.items) |l| {
        if (!l.typed) {
            emitFmt("__bf_tape_{d}[{d}] = {s} as {s};\n", .{ id, l.pos, l.var_name, cell_t });
            continue;
        }
        const cells: i32 = @max(1, @divTrunc(l.bits + cs - 1, cs));
        if (cells == 1) {
            emitFmt("__bf_tape_{d}[{d}] = {s} as {s};\n", .{ id, l.pos, l.var_name, cell_t });
        } else {
            var k: i32 = 0;
            while (k < cells) : (k += 1) {
                const shift = cs * (cells - 1 - k);
                emitFmt("__bf_tape_{d}[{d}] = (({s} >> {d}) as {s});\n", .{ id, l.pos + k, l.var_name, shift, cell_t });
            }
        }
    }

    emitOps(opt.items, cell_t, id);

    for (ctx.loads.items) |l| {
        if (!l.typed) {
            emitFmt("{s} = __bf_tape_{d}[{d}];\n", .{ l.var_name, id, l.pos });
            continue;
        }
        const var_t_str = if (l.signed) "i" else "u";
        const cells: i32 = @max(1, @divTrunc(l.bits + cs - 1, cs));
        if (cells == 1) {
            emitFmt("{s} = __bf_tape_{d}[{d}] as {s}{d};\n", .{ l.var_name, id, l.pos, var_t_str, l.bits });
        } else {
            emitFmt("{s} = 0;\n", .{l.var_name});
            var k: i32 = 0;
            while (k < cells) : (k += 1) {
                const shift = cs * (cells - 1 - k);
                emitFmt("{s} = {s} | ((__bf_tape_{d}[{d}] as {s}{d}) << {d});\n", .{ l.var_name, l.var_name, id, l.pos + k, var_t_str, l.bits, shift });
            }
        }
    }

    output.* = .{
        .generated_zlang_source = output_buf.items.ptr,
        .generated_zlang_source_len = @intCast(output_buf.items.len),
    };
    return 0;
}

fn registerPlugin(host: *HostApi) callconv(.c) c_int {
    const syntax = BlockSyntax{ .mode = 1, .terminator = null };
    _ = host.register_syntax_block(host, "brainfuck", &syntax, brainfuckHandler);
    _ = host.register_cli_flag(host, "-b", "Compile Brainfuck (8-bit cells)", 0);
    _ = host.register_cli_flag(host, "-b8", "Compile Brainfuck (8-bit cells)", 0);
    _ = host.register_cli_flag(host, "-b16", "Compile Brainfuck (16-bit cells)", 0);
    _ = host.register_cli_flag(host, "-b32", "Compile Brainfuck (32-bit cells)", 0);
    _ = host.register_cli_flag(host, "-b64", "Compile Brainfuck (64-bit cells)", 0);
    return 0;
}

export fn zlang_plugin_probe(host_api_version: u32) callconv(.c) ?*ProbeResult {
    _ = host_api_version;
    return &probe_singleton;
}

export fn zlang_plugin_init(host: *HostApi) callconv(.c) ?*PluginDesc {
    _ = host;
    return &desc_singleton;
}

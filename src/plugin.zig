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
    .version = "0.1.0",
    .requires_host_features = null,
};

var desc_singleton: PluginDesc = .{
    .api_min = 1,
    .api_max = 1,
    .name = "brainfuck",
    .version = "0.1.0",
    .register_plugin = registerPlugin,
};

var output_buf: std.ArrayList(u8) = .empty;
const buf_alloc = std.heap.c_allocator;

const prelude: []const u8 =
    \\arr<u8, 30000> __bf_tape;
    \\for i32 __bf_i = 0; __bf_i < 30000; __bf_i++ { __bf_tape[__bf_i] = 0; }
    \\i32 __bf_p = 0;
    \\
;

const postlude: []const u8 = "";

fn emit(s: []const u8) void {
    output_buf.appendSlice(buf_alloc, s) catch {};
}

fn translate(code: []const u8) void {
    output_buf.clearRetainingCapacity();
    emit(prelude);
    for (code) |ch| switch (ch) {
        '+' => emit("__bf_tape[__bf_p] = __bf_tape[__bf_p] + 1;\n"),
        '-' => emit("__bf_tape[__bf_p] = __bf_tape[__bf_p] - 1;\n"),
        '>' => emit("__bf_p = __bf_p + 1;\n"),
        '<' => emit("__bf_p = __bf_p - 1;\n"),
        '.' => emit("@printf(\"%c\", __bf_tape[__bf_p]);\n"),
        '[' => emit("for { if (__bf_tape[__bf_p] == 0) { break; }\n"),
        ']' => emit("}\n"),
        else => {},
    };
    emit(postlude);
}

fn brainfuckHandler(host: *HostApi, input: *const BlockInput, output: *BlockOutput) callconv(.c) c_int {
    _ = host;
    const code = input.raw_source[0..input.raw_source_len];
    translate(code);
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

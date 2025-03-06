const std = @import("std");
const spa = @import("../spa.zig");
const pod = spa.pod;
const Pod = pod.Pod;

fn Iterator(Container: type, Field: type, comptime opts: ContainerOptions, comptime kind: enum { map, list }) type {
    const fields_per_entry = if (opts.inline_fields == .yes) std.meta.fields(Field).len else 1;
    return struct {
        container: *const Container,
        cursor: usize = 0,

        pub fn next(self: *@This()) ?Field {
            if (self.cursor >= self.container.fields.len) return null;
            defer self.cursor += fields_per_entry;

            if (opts.inline_fields == .yes) {
                var entry: Field = undefined;
                inline for (std.meta.fields(Field), 0..) |field, idx| {
                    const pod_field = self.container.fields[self.cursor + idx];
                    // containers are validated on init so the unreachable should never happen
                    @field(entry, field.name) = pod_field.map(field.type) catch unreachable;
                }
                return entry;
            }

            // containers are validated on init so the unreachable should never happen
            return self.container.fields[self.cursor].map(Field) catch unreachable;
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            var iter = self;
            while (iter.next()) |kv| try writer.print("{}", .{kv});
        }

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            var iter = self;
            try if (kind == .list) jws.beginArray() else jws.beginObject();
            while (iter.next()) |kv| {
                if (@hasDecl(Field, "jsonStringifyInline")) {
                    if (kind == .list) try jws.beginObject();
                    try kv.jsonStringifyInline(jws);
                    if (kind == .list) try jws.endObject();
                } else {
                    comptime std.debug.assert(kind != .map);
                    try jws.write(kv);
                }
            }
            try if (kind == .list) jws.endArray() else jws.endObject();
        }
    };
}

pub const ContainerOptions = struct {
    length_header: enum { no, yes, maybe } = .yes,
    inline_fields: enum { no, yes } = .yes,
};

fn extractFields(comptime FieldTypes: []const Pod.Type, Field: type, st: pod.types.Struct, comptime opts: ContainerOptions) ![]const Pod {
    const fields_per_entry = if (opts.inline_fields == .yes) std.meta.fields(Field).len else 1;
    comptime std.debug.assert(FieldTypes.len == fields_per_entry);

    const fields = switch (opts.length_header) {
        .no => st.fields,
        .yes, .maybe => D: {
            const has_header = blk: {
                if (st.fields.len <= 0) break :blk false;
                if (st.fields[0] != .int) break :blk false;
                break :blk true;
            };
            if (!has_header) {
                if (opts.length_header == .maybe) break :D st.fields;
                return error.InvlidFields;
            }
            const n_fields: usize = @intCast(@intFromEnum(st.fields[0].int));
            if (n_fields * fields_per_entry > st.fields.len - 1) return error.InvalidFields;
            break :D st.fields[1..][0 .. n_fields * fields_per_entry];
        },
    };

    var cursor: usize = 0;
    while (cursor < fields.len) : (cursor += fields_per_entry) {
        if (opts.inline_fields == .yes) {
            inline for (std.meta.fields(Field), FieldTypes, 0..) |field, ptype, idx| {
                if (ptype != .pod and fields[cursor + idx] != ptype) return error.InvalidFields;
                _ = try fields[cursor + idx].map(field.type);
            }
        } else {
            _ = try fields[cursor].map(Field);
        }
    }

    return fields;
}

pub fn MapContainer(comptime FieldTypes: []const Pod.Type, Field: type, comptime opts: ContainerOptions) type {
    std.debug.assert(FieldTypes.len == 2);
    std.debug.assert(opts.inline_fields == .yes);
    const KeyType = std.meta.fields(Field)[0].type;
    const ValueType = std.meta.fields(Field)[1].type;
    return struct {
        fields: []const Pod,

        pub fn init(val: Pod) !@This() {
            if (val != .@"struct") return error.InvalidMap;
            const fields = extractFields(FieldTypes, Field, val.@"struct", opts) catch return error.InvalidMap;
            return .{ .fields = fields };
        }

        fn keyName(self: @This(), idx: usize) []const u8 {
            const key = self.fields[idx].map(KeyType) catch unreachable;
            return switch (@typeInfo(KeyType)) {
                .pointer => key,
                .@"enum" => @tagName(key),
                else => @compileError("unsupported key"),
            };
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{}", .{self.iterator()});
        }

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            try jws.write(self.iterator());
        }

        pub fn iterator(self: *const @This()) Iterator(@This(), Field, opts, .map) {
            return .{ .container = self };
        }

        pub fn get(self: @This(), key: KeyType) ?ValueType {
            const fields = std.meta.fields(Field);
            var iter = self.iterator();
            while (iter.next()) |kv| {
                const is_eql = switch (@typeInfo(KeyType)) {
                    .pointer => std.mem.eql(std.meta.Child(KeyType), key, @field(kv, fields[0].name)),
                    else => key == @field(kv, fields[0].name),
                };
                if (!is_eql) continue;
                return @field(kv, fields[1].name);
            }
            return null;
        }

        pub fn map(self: @This(), T: type) !T {
            const ti = @typeInfo(T);
            if (ti != .@"struct") @compileError("T must be a struct");
            var st: T = undefined;
            inline for (ti.@"struct".fields) |dst_field| {
                comptime var error_if_not_found = true;
                if (dst_field.defaultValue()) |def| {
                    @field(st, dst_field.name) = def;
                    error_if_not_found = false;
                } else if (@typeInfo(dst_field.type) == .optional) {
                    @field(st, dst_field.name) = null;
                    error_if_not_found = false;
                }
                var found: bool = false;
                var idx: usize = 0;
                while (idx < self.fields.len) : (idx += 2) {
                    if (std.mem.eql(u8, self.keyName(idx), dst_field.name)) {
                        const value = self.fields[idx + 1];
                        @field(st, dst_field.name) = try value.map(dst_field.type);
                        found = true;
                        break;
                    }
                }
                if (error_if_not_found and !found) {
                    return error.IncompatibleDestinationType;
                }
            }
            return st;
        }
    };
}

pub fn ListContainer(comptime FieldTypes: []const Pod.Type, Field: type, comptime opts: ContainerOptions) type {
    return struct {
        fields: []const Pod,

        pub fn init(val: Pod) !@This() {
            if (val != .@"struct") return error.InvalidList;
            const fields = extractFields(FieldTypes, Field, val.@"struct", opts) catch return error.InvalidList;
            return .{ .fields = fields };
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{}", .{self.iterator()});
        }

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            try jws.write(self.iterator());
        }

        pub fn iterator(self: *const @This()) Iterator(@This(), Field, opts, .list) {
            return .{ .container = self };
        }
    };
}

pub const Prop = struct {
    pub const Map = MapContainer(&.{ .string, .string }, @This(), .{});

    key: spa.wire.Key,
    value: [:0]const u8,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{} = {s}", .{ self.key, self.value });
    }

    pub fn jsonStringifyInline(self: @This(), jws: anytype) !void {
        try jws.objectField(@tagName(self.key));
        try jws.write(self.value);
    }
};

pub const KeyValue = struct {
    pub const Map = MapContainer(&.{ .string, .string }, @This(), .{});

    key: [:0]const u8,
    value: [:0]const u8,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s} = {s}", .{ self.key, self.value });
    }

    pub fn jsonStringifyInline(self: @This(), jws: anytype) !void {
        try jws.objectField(self.key);
        try jws.write(self.value);
    }
};

pub const KeyPod = struct {
    pub const Map = MapContainer(&.{ .string, .pod }, @This(), .{ .length_header = .no });

    key: [:0]const u8,
    pod: Pod,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s} = {}", .{ self.key, self.pod });
    }

    pub fn jsonStringifyInline(self: @This(), jws: anytype) !void {
        try jws.objectField(self.key);
        try jws.write(self.pod);
    }
};

pub const ParamInfo = struct {
    pub const Map = MapContainer(&.{ .id, .int }, @This(), .{});

    id: spa.wire.ParamType,
    flags: spa.flags.Param,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{} = {}", .{ self.id, self.flags });
    }

    pub fn jsonStringifyInline(self: @This(), jws: anytype) !void {
        try jws.objectField(@tagName(self.id));
        try jws.write(self.flags);
    }
};

pub const IdPermission = struct {
    pub const List = ListContainer(&.{ .id, .int }, @This(), .{});

    id: pod.types.Id,
    permission: spa.flags.Permission,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{} = {}", .{ self.id, self.permission });
    }
};

pub const Label = struct {
    pub const List = ListContainer(&.{ .pod, .string }, @This(), .{ .length_header = .no });

    type: Pod,
    value: [:0]const u8,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{} = {s}", .{ self.type, self.value });
    }

    pub fn jsonStringifyInline(self: @This(), jws: anytype) !void {
        const key = switch (self.type) {
            .string => |v| v.slice,
            else => @tagName(self.type),
        };
        try jws.objectField(key);
        try jws.write(self.value);
    }
};

pub const Class = struct {
    pub const List = ListContainer(&.{.@"struct"}, @This(), .{ .length_header = .maybe, .inline_fields = .no });

    name: [:0]const u8,
    num_nodes: u32,
    prop: [:0]const u8,
    devices: []const u32,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s} = {}, {s}, {any}", .{ self.name, self.num_nodes, self.prop, self.devices });
    }
};

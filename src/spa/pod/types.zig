const std = @import("std");
const spa = @import("../spa.zig");
const Pod = spa.pod.Pod;
const containers = spa.pod.containers;

pub const WriteOptions = struct {
    header: enum { write, dont_write } = .write,
    alignment: enum { align_after, dont_align } = .align_after,
};

pub const Header = struct {
    size: u32,
    type: Pod.Type,

    pub fn read(reader: anytype) !@This() {
        var header: @This() = undefined;
        _ = try reader.readAll(std.mem.asBytes(&header));
        _ = std.meta.intToEnum(Pod.Type, @intFromEnum(header.type)) catch return error.InvalidPodHeader;
        return header;
    }

    pub fn write(self: @This(), writer: anytype, opts: WriteOptions) !void {
        if (opts.header != .write) return;
        try writer.writeAll(std.mem.asBytes(&self));
    }
};

pub fn Convert(T: type) type {
    for (std.meta.fields(Pod)) |field| if (T == field.type) return T;
    return switch (T) {
        Pod => Self,
        spa.id.Pod, // Pod.Type
        spa.id.Object,
        spa.wire.ParamType,
        spa.wire.NodeCommand,
        => Id,
        spa.wire.Key, spa.wire.Name => String,
        []const containers.Prop,
        []const containers.KeyValue,
        []const containers.ParamInfo,
        []const containers.IdPermission,
        => Container,
        else => switch (@typeInfo(T)) {
            .void => None,
            .bool => Bool,
            .int => |ti| D: {
                if (ti.bits <= 32) {
                    break :D Int;
                } else if (ti.bits <= 64) {
                    break :D Long;
                } else {
                    @compileError("integers larger than 64 bits are not supported");
                }
            },
            .@"enum" => |ti| Convert(ti.tag_type),
            .float => |ti| D: {
                if (ti.bits <= 32) {
                    break :D Float;
                } else if (ti.bits <= 64) {
                    break :D Double;
                } else {
                    @compileError("floats larger than 64 bits are not supported");
                }
            },
            .pointer => |ti| switch (ti.size) {
                .slice => switch (ti.child) {
                    u8 => switch (ti.sentinel() == 0) {
                        true => String,
                        false => Bytes,
                    },
                    else => Array,
                },
                else => Pointer,
            },
            .array => |ti| switch (ti.child) {
                u8 => switch (ti.sentinel() == 0) {
                    true => String,
                    false => Bytes,
                },
                else => Array,
            },
            .@"struct" => |ti| switch (ti.layout) {
                .@"packed" => Convert(ti.backing_integer.?),
                else => Struct,
            },
            .optional => Container,
            else => @compileError(std.fmt.comptimePrint("type `{}` cannot be converted into a pod type", .{T})),
        },
    };
}

pub const None = struct {
    pub const pod_type: Pod.Type = .none;
    pub const pod_size: u32 = 0;

    pub fn read(_: std.mem.Allocator, size: u32, _: anytype) !@This() {
        if (size != pod_size) return error.InvalidNone;
        return .{};
    }

    pub fn write(val: anytype, writer: anytype, opts: WriteOptions) !void {
        const T = @TypeOf(val);
        switch (T) {
            void, @This() => {},
            else => @compileError(std.fmt.comptimePrint("type `{}` cannot be converted into a pod none type", .{T})),
        }
        try Header.write(.{ .type = .none, .size = pod_size }, writer, opts);
    }

    pub fn map(self: @This(), T: type) !T {
        if (T == @This()) return self;
        return switch (@typeInfo(T)) {
            .void => {},
            else => error.IncompatibleDestinationType,
        };
    }

    pub fn format(_: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll("none");
    }

    pub fn jsonStringify(_: @This(), jws: anytype) !void {
        try jws.write(null);
    }
};

pub const Bool = enum(u1) {
    pub const pod_type: Pod.Type = .bool;
    pub const pod_size: u32 = 4;

    false,
    true,

    pub fn read(_: std.mem.Allocator, size: u32, reader: anytype) !@This() {
        if (size != pod_size) return error.InvalidBool;
        var val: u32 = undefined;
        if (try reader.readAll(std.mem.asBytes(&val)) != pod_size) return error.InvalidBool;
        return if (val > 0) .true else .false;
    }

    pub fn write(val: anytype, writer: anytype, opts: WriteOptions) !void {
        const T = @TypeOf(val);
        if (T == @This()) return write(val == .true, writer, opts);
        var int: u32 = switch (@typeInfo(T)) {
            .bool => @intFromBool(val),
            .int => @intFromBool(val > 0),
            else => @compileError(std.fmt.comptimePrint("type `{}` cannot be written as a pod bool", .{T})),
        };
        try Header.write(.{ .type = .bool, .size = pod_size }, writer, opts);
        try writer.writeAll(std.mem.asBytes(&int));
        if (opts.alignment == .align_after) try writer.writeByteNTimes(0, pod_size);
    }

    pub fn map(self: @This(), T: type) !T {
        if (T == @This()) return self;
        return switch (@typeInfo(T)) {
            .bool => self == .true,
            .int => @intFromBool(self == .true),
            else => error.IncompatibleDestinationType,
        };
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(@tagName(self));
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.write(self == .true);
    }
};

fn IntegerBacked(BackingInteger: type, pod_type_: Pod.Type, cast: enum { upcast, bitcast }, read_err: anytype) type {
    return enum(BackingInteger) {
        pub const pod_type: Pod.Type = pod_type_;
        pub const pod_size: u32 = @sizeOf(@This());
        _,

        pub fn read(_: std.mem.Allocator, size: u32, reader: anytype) !@This() {
            if (size != pod_size) return error.InvalidId;
            var val: @This() = undefined;
            if (try reader.readAll(std.mem.asBytes(&val)) != pod_size) return read_err;
            return val;
        }

        pub fn write(val: anytype, writer: anytype, opts: WriteOptions) !void {
            const T = @TypeOf(val);
            const int: BackingInteger = switch (cast) {
                .bitcast => switch (@typeInfo(T)) {
                    .int => @bitCast(val),
                    .@"enum" => @intFromEnum(val),
                    .@"struct" => |ti| switch (ti.layout) {
                        .@"packed" => @bitCast(val),
                        else => @compileError(std.fmt.comptimePrint("type `{}` cannot be written as a pod {s}", .{ T, @tagName(pod_type) })),
                    },
                    else => @compileError(std.fmt.comptimePrint("type `{}` cannot be written as a pod {s}", .{ T, @tagName(pod_type) })),
                },
                .upcast => switch (@typeInfo(T)) {
                    .int => @intCast(val),
                    .@"enum" => @intFromEnum(val),
                    .@"struct" => |ti| switch (ti.layout) {
                        .@"packed" => @intCast(@as(ti.backing_integer.?, @bitCast(val))),
                        else => @compileError(std.fmt.comptimePrint("type `{}` cannot be written as a pod {s}", .{ T, @tagName(pod_type) })),
                    },
                    else => @compileError(std.fmt.comptimePrint("type `{}` cannot be written as a pod {s}", .{ T, @tagName(pod_type) })),
                },
            };
            try Header.write(.{ .type = pod_type, .size = pod_size }, writer, opts);
            try writer.writeAll(std.mem.asBytes(&int));
            if (opts.alignment == .align_after) {
                try writer.writeByteNTimes(0, std.mem.alignForward(usize, pod_size, 8) - pod_size);
            }
        }

        pub fn map(self: @This(), T: type) !T {
            if (T == @This()) return self;
            return switch (@typeInfo(T)) {
                .@"enum" => std.meta.intToEnum(T, @intFromEnum(self)) catch error.IncompatibleDestinationType,
                .int => std.math.cast(T, @intFromEnum(self)) orelse error.IncompatibleDestinationType,
                .@"struct" => |ti| switch (ti.layout) {
                    .@"packed" => @bitCast(std.math.cast(ti.backing_integer.?, @intFromEnum(self)) orelse return error.IncompatibleDestinationType),
                    else => error.IncompatibleDestinationType,
                },
                else => error.IncompatibleDestinationType,
            };
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{s}:{}", .{ @tagName(pod_type), @intFromEnum(self) });
        }
    };
}

pub const Id = IntegerBacked(u32, .id, .bitcast, error.InvalidId);
pub const Int = IntegerBacked(u32, .int, .upcast, error.InvalidInt);
pub const Long = IntegerBacked(u64, .long, .upcast, error.InvalidLong);

fn FloatBacked(BackingFloat: type, pod_type_: Pod.Type, read_err: anytype) type {
    return struct {
        pub const pod_type: Pod.Type = pod_type_;
        pub const pod_size: u32 = @sizeOf(BackingFloat);
        value: BackingFloat,

        pub fn read(_: std.mem.Allocator, size: u32, reader: anytype) !@This() {
            if (size != pod_size) return read_err;
            var val: BackingFloat = undefined;
            if (try reader.readAll(std.mem.asBytes(&val)) != pod_size) return read_err;
            return .{ .value = val };
        }

        pub fn write(val: anytype, writer: anytype, opts: WriteOptions) !void {
            const T = @TypeOf(val);
            if (T == @This()) return write(val.value, writer, opts);
            var flt: BackingFloat = switch (@typeInfo(T)) {
                .float => @floatCast(val),
                else => @compileError(std.fmt.comptimePrint("type `{}` cannot be written as a pod {s}", .{ T, @tagName(pod_type) })),
            };
            try Header.write(.{ .type = pod_type, .size = pod_size }, writer, opts);
            try writer.writeAll(std.mem.asBytes(&flt));
            if (opts.alignment == .align_after) {
                try writer.writeByteNTimes(0, std.mem.alignForward(usize, pod_size, 8) - pod_size);
            }
        }

        pub fn map(self: @This(), T: type) !T {
            if (T == @This()) return self;
            return switch (@typeInfo(T)) {
                .float => @floatCast(self.value),
                else => error.IncompatibleDestinationType,
            };
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{s}:{}", .{ @tagName(pod_type), self.value });
        }

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            try jws.write(self.value);
        }
    };
}

pub const Float = FloatBacked(f32, .float, error.InvalidFloat);
pub const Double = FloatBacked(f64, .double, error.InvalidDouble);

pub const String = struct {
    pub const pod_type: Pod.Type = .string;
    slice: [:0]const u8,

    pub fn read(arena: std.mem.Allocator, size: u32, reader: anytype) !@This() {
        if (size <= 0) return error.InvalidString;
        const bytes = Bytes.read(arena, size, reader) catch return error.InvalidString;
        if (bytes.slice[size - 1] != 0) return error.InvalidString;
        // XXX: There might be a bug in pipewire as it sends some strings with lots of 0s
        //      Anyway, use sliceTo for now to get slice to the first null terminator
        return .{ .slice = @ptrCast(std.mem.sliceTo(bytes.slice, 0)) };
    }

    pub fn write(val: anytype, writer: anytype, opts: WriteOptions) !void {
        const T = @TypeOf(val);
        if (T == @This()) return write(val.slice, writer, opts);
        const str: [:0]const u8 = switch (@typeInfo(T)) {
            .@"enum" => @tagName(val),
            else => val,
        };
        const len = str.len + 1;
        try Header.write(.{ .type = .string, .size = @intCast(len) }, writer, opts);
        try writer.writeAll(str[0..len]);
        if (opts.alignment == .align_after) {
            try writer.writeByteNTimes(0, std.mem.alignForward(usize, len, 8) - len);
        }
    }

    pub fn map(self: @This(), T: type) !T {
        if (T == @This()) return self;
        return switch (@typeInfo(T)) {
            .bool => std.mem.eql(u8, self.slice, "true"),
            .int => std.fmt.parseInt(T, self.slice, 10) catch error.IncompatibleDestinationType,
            .float => std.fmt.parseFloat(T, self.slice) catch error.IncompatibleDestinationType,
            .@"enum" => |ti| switch (ti.is_exhaustive) {
                true => std.meta.stringToEnum(T, self.slice) orelse error.IncompatibleDestinationType,
                false => std.meta.intToEnum(T, std.fmt.parseInt(ti.tag_type, self.slice, 10) catch return error.IncompatibleDestinationType) catch error.IncompatibleDestinationType,
            },
            .pointer => |ti| switch (ti.size) {
                .slice => switch (ti.child) {
                    u8 => self.slice,
                    else => error.IncompatibleDestinationType,
                },
                else => error.IncompatibleDestinationType,
            },
            .array => |ti| switch (ti.child) {
                u8 => D: {
                    if (self.slice.len < ti.len) break :D error.IncompatibleDestinationType;
                    break :D self.slice[0..ti.len].*;
                },
                else => error.IncompatibleDestinationType,
            },
            else => error.IncompatibleDestinationType,
        };
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("\"{s}\"", .{self.slice});
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.write(self.slice);
    }
};

pub const Bytes = struct {
    pub const pod_type: Pod.Type = .bytes;
    slice: []const u8,

    pub fn read(arena: std.mem.Allocator, size: u32, reader: anytype) !@This() {
        var buf = try arena.alloc(u8, size);
        errdefer arena.free(buf);
        if (try reader.readAll(buf[0..]) != size) return error.InvalidBytes;
        return .{ .slice = buf };
    }

    pub fn write(val: anytype, writer: anytype, opts: WriteOptions) !void {
        const T = @TypeOf(val);
        switch (T) {
            []const u8 => {},
            @This() => return write(val.slice, writer, opts),
            else => @compileError(std.fmt.comptimePrint("type `{}` cannot be converted into a pod bytes type", .{T})),
        }
        try Header.write(.{ .type = .bytes, .size = @intCast(val.len) }, writer, opts);
        try writer.writeAll(val[0..]);
        if (opts.alignment == .align_after) {
            try writer.writeByteNTimes(0, std.mem.alignForward(usize, val.len, 8) - val.len);
        }
    }

    pub fn map(self: @This(), T: type) !T {
        if (T == @This()) return self;
        return switch (@typeInfo(T)) {
            .bool, .int, .float => std.mem.bytesToValue(T, self.slice),
            .@"enum" => |ti| std.meta.intToEnum(T, std.mem.bytesToValue(ti.tag_type, self.slice)) catch error.IncompatibleDestinationType,
            .pointer => |ti| switch (ti.size) {
                .slice => switch (ti.child) {
                    u8 => if (ti.sentinel()) |_| error.IncompatibleDestinationType else self.slice,
                    else => error.IncompatibleDestinationType,
                },
                else => error.IncompatibleDestinationType,
            },
            .array => |ti| switch (ti.child) {
                u8 => if (self.slice.len >= ti.len) self.slice[0..ti.len].* else error.IncompatibleDestinationType,
                else => error.IncompatibleDestinationType,
            },
            .@"struct" => |ti| switch (ti.layout) {
                .@"packed", .@"extern" => std.mem.bytesToValue(T, self.slice),
                else => error.IncompatibleDestinationType,
            },
            else => error.IncompatibleDestinationType,
        };
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll("bytes:");
        var encoder = std.base64.standard_no_pad.Encoder;
        try encoder.encodeWriter(writer, self.slice);
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginWriteRaw();
        _ = try jws.stream.write("\"");
        var encoder = std.base64.standard_no_pad.Encoder;
        try encoder.encodeWriter(jws.stream, self.slice);
        _ = try jws.stream.write("\"");
        jws.endWriteRaw();
    }
};

pub const Rectangle = extern struct {
    pub const pod_type: Pod.Type = .rectangle;
    pub const pod_size: u32 = @sizeOf(@This());
    width: u32,
    height: u32,

    pub fn read(_: std.mem.Allocator, size: u32, reader: anytype) !@This() {
        if (size != pod_size) return error.InvalidRectangle;
        var val: @This() = undefined;
        if (try reader.readAll(std.mem.asBytes(&val)) != pod_size) return error.InvalidRectangle;
        return val;
    }

    pub fn write(val: @This(), writer: anytype, opts: WriteOptions) !void {
        try Header.write(.{ .type = .rectangle, .size = pod_size }, writer, opts);
        try writer.writeAll(std.mem.asBytes(&val));
    }

    pub fn map(self: @This(), T: type) !T {
        if (T != @This()) return error.IncompatibleDestinationType;
        return self;
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("rectangle:{},{}", .{ self.width, self.height });
    }
};

pub const Fraction = extern struct {
    pub const pod_type: Pod.Type = .fraction;
    pub const pod_size: u32 = @sizeOf(@This());
    num: u32,
    denom: u32,

    pub fn read(_: std.mem.Allocator, size: u32, reader: anytype) !@This() {
        if (size != pod_size) return error.InvalidFraction;
        var val: @This() = undefined;
        if (try reader.readAll(std.mem.asBytes(&val)) != pod_size) return error.InvalidFraction;
        return val;
    }

    pub fn write(val: @This(), writer: anytype, opts: WriteOptions) !void {
        try Header.write(.{ .type = .fraction, .size = pod_size }, writer, opts);
        try writer.writeAll(std.mem.asBytes(&val));
    }

    pub fn map(self: @This(), T: type) !T {
        if (T != @This()) return error.IncompatibleDestinationType;
        return self;
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("fraction:{}/{}", .{ self.num, self.denom });
    }
};

pub const Bitmap = struct {
    pub const pod_type: Pod.Type = .bitmap;
    bits: []const u8,

    pub fn read(arena: std.mem.Allocator, size: u32, reader: anytype) !@This() {
        const bytes = Bytes.read(arena, size, reader) catch return error.InvalidBitmap;
        return .{ .bits = bytes.slice };
    }

    pub fn write(val: anytype, writer: anytype, opts: WriteOptions) !void {
        const T = @TypeOf(val);
        switch (T) {
            []const u8 => {},
            @This() => return write(val.bits, writer, opts),
            else => @compileError(std.fmt.comptimePrint("type `{}` cannot be converted into a pod bitmap type", .{T})),
        }
        try Header.write(.{ .type = .bitmap, .size = @intCast(val.len) }, writer, opts);
        try Bytes.write(val, writer, .{ .header = .dont_write });
    }

    pub fn map(self: @This(), T: type) !T {
        if (T == @This()) return self;
        return switch (@typeInfo(T)) {
            .pointer => |ti| switch (ti.size) {
                .slice => switch (ti.child) {
                    u8 => if (ti.sentinel()) |_| error.IncompatibleDestinationType else self.bits,
                    else => error.IncompatibleDestinationType,
                },
                else => error.IncompatibleDestinationType,
            },
            .array => |ti| switch (ti.child) {
                u8 => if (self.slice.len >= ti.len) self.bits[0..ti.len].* else error.IncompatibleDestinationType,
                else => error.IncompatibleDestinationType,
            },
            else => error.IncompatibleDestinationType,
        };
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll("bitmap:");
        var encoder = std.base64.standard_no_pad.Encoder;
        try encoder.encodeWriter(writer, self.bits);
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try Bytes.jsonStringify(.{ .slice = self.bits }, jws);
    }
};

pub const Array = union(Pod.Type) {
    pub const pod_type: Pod.Type = .array;
    none: void,
    bool: []const Bool,
    id: []const Id,
    int: []const Int,
    long: []const Long,
    float: []const Float,
    double: []const Double,
    string: void,
    bytes: void,
    rectangle: []const Rectangle,
    fraction: []const Fraction,
    bitmap: void,
    array: void,
    @"struct": void,
    object: void,
    sequence: void,
    pointer: []const Pointer,
    fd: []const Fd,
    choice: void,
    pod: void,

    pub fn read(arena: std.mem.Allocator, size: u32, reader: anytype) !@This() {
        const header = Header.read(reader) catch return error.InvalidArray;
        const array_size = size - 8;
        inline for (std.meta.fields(Pod.Type)) |field| {
            const Field = @FieldType(@This(), field.name);
            if (Field != void and field.value == @intFromEnum(header.type)) {
                const Child = std.meta.Child(Field);
                const items = try arena.alloc(Child, array_size / header.size);
                errdefer arena.free(items);
                for (items) |*item| {
                    const pod: Pod = try .readType(arena, header.type, header.size, .dont_align, reader);
                    item.* = try pod.map(Child);
                }
                return @unionInit(@This(), field.name, items);
            }
        }
        return error.InvalidArray;
    }

    pub fn write(slice: anytype, writer: anytype, opts: WriteOptions) !void {
        const T = @TypeOf(slice);
        switch (T) {
            @This() => switch (slice) {
                inline else => |items| return write(items, writer, opts),
            },
            void => return error.InvalidArray,
            else => switch (@typeInfo(T)) {
                .pointer => |ti| switch (ti.size) {
                    .slice => {},
                    else => @compileError(std.fmt.comptimePrint("type `{}` cannot be written as a pod array", .{T})),
                },
                .array => {},
                else => @compileError(std.fmt.comptimePrint("type `{}` cannot be written as a pod array", .{T})),
            },
        }

        const Child = std.meta.Child(T);
        const PodChild = Convert(Child);
        if (!@hasDecl(PodChild, "pod_size")) {
            @compileError(std.fmt.comptimePrint("type `{}` cannot be used as a element for a pod array", .{Child}));
        }

        var counter = std.io.countingWriter(std.io.null_writer);
        try Header.write(.{ .type = PodChild.pod_type, .size = PodChild.pod_size }, counter.writer(), .{});
        for (slice) |val| try PodChild.write(val, counter.writer(), .{ .header = .dont_write, .alignment = .dont_align });

        try Header.write(.{ .type = .array, .size = @intCast(counter.bytes_written) }, writer, opts);
        try Header.write(.{ .type = PodChild.pod_type, .size = PodChild.pod_size }, writer, .{});
        for (slice) |val| try PodChild.write(val, writer, .{ .header = .dont_write, .alignment = .dont_align });

        if (opts.alignment == .align_after) {
            try writer.writeByteNTimes(0, std.mem.alignForward(usize, counter.bytes_written, 8) - counter.bytes_written);
        }
    }

    pub fn map(self: @This(), T: type) !T {
        switch (self) {
            inline else => |items| {
                if (@TypeOf(items) == void) return error.InvalidArray;
                const Child = std.meta.Child(@TypeOf(items));
                return switch (@typeInfo(T)) {
                    .pointer => |ti| D: {
                        if (@sizeOf(ti.child) != @sizeOf(Child)) break :D error.IncompatibleDestinationType;
                        break :D @ptrCast(items);
                    },
                    .array => |ti| D: {
                        if (@sizeOf(ti.child) != @sizeOf(Child)) break :D error.IncompatibleDestinationType;
                        if (items.len < ti.len) break :D error.IncompatibleDestinationType;
                        break :D @bitCast(items[0..ti.len].*);
                    },
                    else => error.IncompatibleDestinationType,
                };
            },
        }
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            inline else => |items| {
                try writer.print("array:{any}", .{items});
            },
        }
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        switch (self) {
            inline else => |items| {
                if (@TypeOf(items) == void) return;
                try jws.write(items);
            },
        }
    }
};

pub const Struct = struct {
    pub const pod_type: Pod.Type = .@"struct";
    fields: []const Pod,

    pub fn read(arena: std.mem.Allocator, size: u32, reader: anytype) !@This() {
        const bytes = Bytes.read(arena, size, reader) catch return error.InvalidStruct;
        var pods: std.ArrayListUnmanaged(Pod) = .empty;
        errdefer pods.deinit(arena);

        var stream = std.io.fixedBufferStream(bytes.slice);
        while (stream.pos < bytes.slice.len) {
            const field: Pod = try .read(arena, @intCast(bytes.slice.len - stream.pos), stream.reader());
            try pods.append(arena, field);
        }

        return .{ .fields = try pods.toOwnedSlice(arena) };
    }

    pub fn write(val: anytype, writer: anytype, opts: WriteOptions) !void {
        const T = @TypeOf(val);
        if (T == @This()) {
            var counter = std.io.countingWriter(std.io.null_writer);
            for (val.fields) |field| try Pod.write(field, counter.writer());
            try Header.write(.{ .type = .@"struct", .size = @intCast(counter.bytes_written) }, writer, opts);
            for (val.fields) |field| try Pod.write(field, writer);
            return;
        }
        switch (@typeInfo(T)) {
            .@"struct" => |ti| {
                var counter = std.io.countingWriter(std.io.null_writer);
                inline for (ti.fields) |field| try Pod.write(@field(val, field.name), counter.writer());
                try Header.write(.{ .type = .@"struct", .size = @intCast(counter.bytes_written) }, writer, opts);
                inline for (ti.fields) |field| try Pod.write(@field(val, field.name), writer);
            },
            else => @compileError(std.fmt.comptimePrint("type `{}` cannot be written as a struct pod type", .{T})),
        }
    }

    pub fn map(self: @This(), T: type) !T {
        if (T == @This()) return self;
        return switch (@typeInfo(T)) {
            .@"struct" => |ti| D: {
                var st: T = undefined;
                if (ti.fields.len < self.fields.len) return error.IncompatibleDestinationType;
                inline for (ti.fields, 0..) |dst_field, idx| {
                    if (idx >= self.fields.len) break;
                    var src_field = &self.fields[idx];
                    @field(st, dst_field.name) = try src_field.map(dst_field.type);
                }
                break :D st;
            },
            else => error.IncompatibleDestinationType,
        };
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll("struct:{");
        for (self.fields) |field| try writer.print("  {}", .{field});
        try writer.writeAll("}");
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        for (self.fields, 0..) |field, idx| {
            var buf: [8]u8 = undefined;
            const len = std.fmt.formatIntBuf(&buf, idx, 10, .lower, .{});
            try jws.objectField(buf[0..len]);
            try jws.write(field);
        }
        try jws.endObject();
    }
};

fn GenericHeader(TA: type, TB: type, read_err: anytype) type {
    return extern struct {
        type: TA,
        other: TB,

        pub fn read(reader: anytype) !@This() {
            var header: @This() = undefined;
            _ = try reader.readAll(std.mem.asBytes(&header));
            if (@typeInfo(TA) == .@"enum") {
                _ = std.meta.intToEnum(TA, @intFromEnum(header.type)) catch return read_err;
            }
            return header;
        }

        pub fn write(self: @This(), writer: anytype, opts: WriteOptions) !void {
            if (opts.header != .write) return;
            try writer.writeAll(std.mem.asBytes(&self));
        }
    };
}

pub const Object = union(spa.id.Object) {
    pub const pod_type: Pod.Type = .object;

    const PropertyHeader = GenericHeader(u32, u32, error.InvalidProperty);

    pub const AnyProperty = struct {
        key: u32,
        flags: u32,
        pod: Pod,

        pub fn read(arena: std.mem.Allocator, size: u32, reader: anytype) !@This() {
            const header = try PropertyHeader.read(reader);
            return .{
                .key = header.type,
                .flags = header.other,
                .pod = try .read(arena, @intCast(size - 8), reader),
            };
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("prop:{}, {}: {}", .{ self.key, self.flags, self.pod });
        }
    };

    fn Property(T: anytype) type {
        return struct {
            id: Id,
            props: []const T,

            pub fn read(arena: std.mem.Allocator, id: Id, size: u32, reader: anytype) !@This() {
                var counter = std.io.countingReader(reader);
                var props: std.ArrayListUnmanaged(T) = .empty;
                errdefer props.deinit(arena);
                loop: while (counter.bytes_read < size) {
                    var any: AnyProperty = try .read(arena, size, counter.reader());
                    inline for (std.meta.fields(std.meta.Tag(T))) |field| {
                        if (field.value == any.key) {
                            try props.append(arena, @unionInit(T, field.name, try any.pod.map(@FieldType(T, field.name))));
                            continue :loop;
                        }
                    }
                    return error.InvalidProperty;
                }
                return .{ .id = id, .props = try props.toOwnedSlice(arena) };
            }

            pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                try writer.print("{}: {any}", .{ self.id, self.props });
            }

            pub fn jsonStringify(self: @This(), jws: anytype) !void {
                try jws.beginObject();
                try jws.objectField("~id");
                try jws.write(self.id);
                for (self.props) |prop| switch (prop) {
                    inline else => |payload, tag| {
                        try jws.objectField(@tagName(tag));
                        if (@TypeOf(payload) == void) {
                            try jws.write(null);
                        } else {
                            try jws.write(payload);
                        }
                    },
                };
                try jws.endObject();
            }
        };
    }

    prop_info: Property(spa.param.PropInfo),
    props: Property(spa.param.Prop),
    media_format: Property(spa.param.Format),
    param_buffers: Property(spa.param.Buffers),
    param_meta: Property(spa.param.Meta),
    param_io: Property(spa.param.Io),
    param_profile: Property(spa.param.Profile),
    param_port_config: Property(spa.param.PortConfig),
    param_route: Property(spa.param.Route),
    profiler: Property(spa.param.Profiler),
    param_latency: Property(spa.param.Latency),
    param_process_latency: Property(spa.param.ProcessLatency),
    param_tag: Property(spa.param.Tag),

    const ObjectHeader = GenericHeader(spa.id.Object, Id, error.InvalidObject);

    pub fn read(arena: std.mem.Allocator, size: u32, reader: anytype) !@This() {
        const header = try ObjectHeader.read(reader);
        const props = Bytes.read(arena, size - 8, reader) catch return error.InvalidObject;
        var child_reader = std.io.fixedBufferStream(props.slice);
        switch (header.type) {
            inline else => |tag| {
                return @unionInit(
                    @This(),
                    @tagName(tag),
                    try .read(arena, header.other, @intCast(props.slice.len), child_reader.reader()),
                );
            },
        }
    }

    pub fn write(_: anytype, _: anytype, _: WriteOptions) !void {
        @panic("fixme");
    }

    pub fn map(self: @This(), T: type) !T {
        if (T != @This()) return error.IncompatibleDestinationType;
        return self;
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            inline else => |payload, tag| {
                try writer.print("{s}!{}", .{ @tagName(tag), payload });
            },
        }
    }
};

pub const Sequence = struct {
    pub const pod_type: Pod.Type = .sequence;

    pub const Control = struct {
        offset: u32,
        type: u32,
        pod: Pod,

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("Control: {}, {}: {}", .{ self.offset, self.type, self.pod });
        }
    };

    unit: u32,
    pad: u32,
    controls: []const Control,

    pub fn read(_: std.mem.Allocator, _: u32, _: anytype) !@This() {
        @panic("fixme");
    }

    pub fn write(_: anytype, _: anytype, _: WriteOptions) !void {
        @panic("fixme");
    }

    pub fn map(self: @This(), T: type) !T {
        if (T != @This()) return error.IncompatibleDestinationType;
        return self;
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("seq:{}, {}: {any}", .{ self.unit, self.pad, self.controls });
    }
};

pub const Pointer = IntegerBacked(usize, .pointer, .bitcast, error.InvalidPointer);
pub const Fd = IntegerBacked(u64, .fd, .upcast, error.InvalidFd);

pub const Choice = struct {
    pub const pod_type: Pod.Type = .choice;

    pub const Kind = enum(u32) {
        none,
        range,
        step,
        @"enum",
        flags,
    };

    kind: Kind,
    choices: []const Pod,

    const ChoiceHeader = GenericHeader(Kind, u32, error.InvalidChoice);

    pub fn read(arena: std.mem.Allocator, size: u32, reader: anytype) !@This() {
        const chdr = try ChoiceHeader.read(reader);
        if (chdr.other != 0) return error.InvalidChoice; // flags must be 0

        const phdr = Header.read(reader) catch return error.InvalidChoice;
        const array_size = size - 16;
        const n_items = array_size / phdr.size;

        switch (chdr.type) {
            .none => if (n_items == 0) return error.InvalidChoice,
            .range => if (n_items != 3) return error.InvalidChoice,
            .step => if (n_items != 4) return error.InvalidChoice,
            .@"enum" => if (n_items == 0) return error.InvalidChoice,
            .flags => if (n_items == 0) return error.InvalidChoice,
        }

        const items = try arena.alloc(Pod, n_items);
        errdefer arena.free(items);
        for (items) |*item| item.* = try .readType(arena, phdr.type, phdr.size, .dont_align, reader);
        return .{ .kind = chdr.type, .choices = items };
    }

    pub fn write(val: anytype, writer: anytype, opts: WriteOptions) !void {
        const T = @TypeOf(val);
        const payload_size = switch (T) {
            @This() => D: {
                const child_size = X: {
                    if (val.kind == .none) break :X 0;
                    break :X switch (val.choices[0]) {
                        inline else => |_, tag| {
                            const Child = @FieldType(Pod, @tagName(tag));
                            if (@hasDecl(Child, "pod_size")) break :X Child.pod_size;
                            return error.InvalidChoice;
                        },
                    };
                };

                const has_children: usize = @intFromBool(child_size > 0);
                const payload_size = val.choices.len * child_size + 8 + (has_children * 8);
                try Header.write(.{ .type = .choice, .size = @intCast(payload_size) }, writer, opts);
                try ChoiceHeader.write(.{ .type = val.kind, .other = 0 }, writer, .{});

                if (child_size > 0) {
                    const tag = std.meta.activeTag(val.choices[0]);
                    try Header.write(.{ .type = tag, .size = child_size }, writer, .{});
                    for (val.choices) |choice| {
                        if (choice != tag) return error.InvalidChoice;
                        try switch (choice) {
                            .pod => error.InvalidChoice,
                            inline else => |v| @TypeOf(v).write(v, writer, .{ .header = .dont_write, .alignment = .dont_align }),
                        };
                    }
                }

                break :D payload_size;
            },
            else => switch (@typeInfo(T)) {
                .void => {
                    try Header.write(.{ .type = .choice, .size = 8 }, writer, .{});
                    try ChoiceHeader.write(.{ .type = .none, .size = 0 }, writer, .{});
                },
                .array => |ti| switch (ti.len) {
                    3, 4 => D: {
                        const child_size = @sizeOf(ti.child);
                        const BackingInt = if (child_size <= 4) Int else Long;
                        const payload_size = ti.len * child_size + 16;
                        try Header.write(.{ .type = if (ti.len == 3) .range else .step, .size = payload_size }, writer, .{});
                        try BackingInt.write(val[0], writer, .{ .alignment = .dont_align });
                        for (val[1..]) |v| try BackingInt.write(v, writer, .{ .header = .dont_write, .alignment = .dont_align });
                        break :D payload_size;
                    },
                    else => @compileError("only range ([3]T) and step ([4]T) can be written"),
                },
                .@"enum" => |ti| D: {
                    const child_size = 4;
                    const payload_size = (ti.fields.len + 1) * child_size + 16;
                    try Header.write(.{ .type = .choice, .size = payload_size }, writer, .{});
                    try ChoiceHeader.write(.{ .type = .@"enum", .size = 0 }, writer, .{});
                    try Id.write(val, writer, .{ .alignment = .dont_align });
                    inline for (ti.fields) |field| try Id.write(field.value, .writer, .{ .header = .dont_write, .alignment = .dont_align });
                    break :D payload_size;
                },
                .@"struct" => |ti| switch (ti.layout) {
                    .@"packed" => D: {
                        const child_size = @sizeOf(ti.backing_integer.?);
                        const BackingInt = if (child_size <= 4) Int else Long;
                        const payload_size = (ti.fields.len + 1) * child_size + 16;
                        try Header.write(.{ .type = .choice, .size = payload_size }, writer, .{});
                        try ChoiceHeader.write(.{ .type = .flags, .size = 0 }, writer, .{});
                        try BackingInt.write(val, writer, .{ .alignment = .dont_align });
                        inline for (ti.fields) |field| try BackingInt.write(field.value, .writer, .{ .header = .dont_write, .alignment = .dont_align });
                        break :D payload_size;
                    },
                    else => @compileError(std.fmt.comptimePrint("type `{}` cannot be converted into a choice pod type", .{T})),
                },
                else => @compileError(std.fmt.comptimePrint("type `{}` cannot be converted into a choice pod type", .{T})),
            },
        };

        if (opts.alignment == .align_after) {
            try writer.writeByteNTimes(0, std.mem.alignForward(usize, payload_size, 8) - payload_size);
        }
    }

    pub fn map(self: @This(), T: type) !T {
        if (T == @This()) return self;
        return self.choices[0].map(T);
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try switch (self.kind) {
            .none => writer.print("none: {}", .{self.choices[0]}),
            .range => writer.print("range: {} ({}..{})", .{ self.choices[0], self.choices[1], self.choices[2] }),
            .step => writer.print("step: {} ({}..{} + {})", .{ self.choices[0], self.choices[1], self.choices[2], self.choices[3] }),
            .@"enum" => writer.print("enum: {} ({any})", .{ self.choices[0], self.choices[1..] }),
            .flags => writer.print("flags: {} ({any})", .{ self.choices[0], self.choices[1..] }),
        };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        switch (self.kind) {
            .none => try jws.write(self.choices[0]),
            .range => {
                try jws.beginObject();
                try jws.objectField("default");
                try jws.write(self.choices[0]);
                try jws.objectField("min");
                try jws.write(self.choices[1]);
                try jws.objectField("max");
                try jws.write(self.choices[2]);
                try jws.endObject();
            },
            .step => {
                try jws.beginObject();
                try jws.objectField("default");
                try jws.write(self.choices[0]);
                try jws.objectField("min");
                try jws.write(self.choices[1]);
                try jws.objectField("max");
                try jws.write(self.choices[2]);
                try jws.objectField("step");
                try jws.write(self.choices[3]);
                try jws.endObject();
            },
            .@"enum", .flags => {
                try jws.beginObject();
                try jws.objectField("default");
                try jws.write(self.choices[0]);
                try jws.objectField("choices");
                try jws.write(self.choices[1..]);
                try jws.endObject();
            },
        }
    }
};

pub const Self = struct {
    pub const pod_type: Pod.Type = .pod;

    pub fn read(_: std.mem.Allocator, _: u32, _: anytype) !@This() {
        return error.InvalidPod;
    }

    pub fn write(val: Pod, writer: anytype, opts: WriteOptions) !void {
        try switch (val) {
            .pod => error.InvalidPod,
            // Using method sugar here causes the parameter to be passed as a pointer
            inline else => |v| @TypeOf(v).write(v, writer, opts),
        };
    }

    pub fn map(_: @This(), T: type) !T {
        unreachable;
    }
};

// Not a Pod type, handles serialiation for complex types
pub const Container = struct {
    fn writeKvs(val: anytype, writer: anytype) !void {
        var counter = std.io.countingWriter(std.io.null_writer);

        const len: u32 = @intCast(val.len);
        try Int.write(len, counter.writer(), .{});
        for (val) |kv| inline for (std.meta.fields(std.meta.Child(@TypeOf(val)))) |field| {
            try Pod.write(@field(kv, field.name), counter.writer());
        };

        try Header.write(.{ .type = .@"struct", .size = @intCast(counter.bytes_written) }, writer, .{});
        try Int.write(len, writer, .{});
        for (val) |kv| inline for (std.meta.fields(std.meta.Child(@TypeOf(val)))) |field| {
            try Pod.write(@field(kv, field.name), writer);
        };
    }

    pub fn write(val: anytype, writer: anytype, opts: WriteOptions) !void {
        const T = @TypeOf(val);
        try switch (T) {
            []const containers.Prop,
            []const containers.KeyValue,
            []const containers.ParamInfo,
            []const containers.IdPermission,
            => writeKvs(val, writer),
            else => switch (@typeInfo(T)) {
                .optional => if (val) |v| Pod.write(v, writer) else None.write({}, writer, opts),
                else => @compileError(std.fmt.comptimePrint("type `{}` cannot be converted into a pod type", .{T})),
            },
        };
    }
};

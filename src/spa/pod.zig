//! Pipewire POD type
//! <https://docs.pipetypes.org/page_spa_pod.html>

const std = @import("std");
const spa = @import("spa.zig");
pub const types = @import("pod/types.zig");
pub const containers = @import("pod/containers.zig");

pub const MapError = error{
    InvalidArray,
    InvalidMap,
    InvalidList,
    IncompatibleDestinationType,
};

pub const ReadError = error{
    InvalidPod,
    InvalidPodHeader,
    InvalidNone,
    InvalidBool,
    InvalidId,
    InvalidInt,
    InvalidLong,
    InvalidFloat,
    InvalidDouble,
    InvalidString,
    InvalidBytes,
    InvalidRectangle,
    InvalidFraction,
    InvalidBitmap,
    InvalidArray,
    InvalidStruct,
    InvalidObject,
    InvalidProperty,
    InvalidPointer,
    InvalidFd,
    InvalidChoice,
    EndOfStream,
    OutOfMemory,
} || MapError || std.net.Stream.ReadError;

pub const WriteError = error{
    InvalidPod,
    InvalidArray,
    InvalidChoice,
} || std.net.Stream.WriteError;

pub const Pod = union(spa.id.Pod) {
    pub const Type = spa.id.Pod;
    none: types.None,
    bool: types.Bool,
    id: types.Id,
    int: types.Int,
    long: types.Long,
    float: types.Float,
    double: types.Double,
    string: types.String,
    bytes: types.Bytes,
    rectangle: types.Rectangle,
    fraction: types.Fraction,
    bitmap: types.Bitmap,
    array: types.Array,
    @"struct": types.Struct,
    object: types.Object,
    sequence: types.Sequence,
    pointer: types.Pointer,
    fd: types.Fd,
    choice: types.Choice,
    pod: types.Self,

    pub fn readType(arena: std.mem.Allocator, kind: Type, size: u32, alignment: enum { align_after, dont_align }, reader: anytype) ReadError!@This() {
        switch (kind) {
            inline else => |tag| {
                const WireType = @FieldType(@This(), @tagName(tag));
                const payload = try WireType.read(arena, size, reader);
                const pod = @unionInit(@This(), @tagName(tag), payload);
                if (alignment == .align_after) try reader.skipBytes(std.mem.alignForward(usize, size, 8) - size, .{});
                return pod;
            },
        }
    }

    pub fn read(arena: std.mem.Allocator, size: u24, reader: anytype) ReadError!@This() {
        if (size < @sizeOf(types.Header)) return error.InvalidPod;
        const header = try types.Header.read(reader);
        return readType(arena, header.type, header.size, .align_after, reader);
    }

    pub fn map(self: @This(), T: type) MapError!T {
        return switch (@typeInfo(T)) {
            .optional => |ti| self.map(ti.child) catch null,
            else => switch (T) {
                Pod => self,
                containers.Prop.Map,
                containers.KeyValue.Map,
                containers.KeyPod.Map,
                containers.ParamInfo.Map,
                containers.IdPermission.List,
                containers.Label.List,
                containers.Class.List,
                => .init(self),
                else => switch (self) {
                    inline else => |pod| pod.map(T),
                },
            },
        };
    }

    pub fn writeSelf(self: @This(), writer: anytype) WriteError!void {
        switch (self) {
            inline else => |v| try v.writeSelf(writer, .{}),
        }
    }

    pub fn write(val: anytype, writer: anytype) WriteError!void {
        try types.Convert(@TypeOf(val)).write(val, writer, .{});
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return switch (self) {
            inline else => |tag| writer.print("{any}", .{tag}),
        };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        return switch (self) {
            inline else => |tag| jws.write(tag),
        };
    }
};

pub const Object = enum(u32) {
    prop_info = 0x40001,
    props,
    media_format,
    buffers,
    meta,
    io,
    profile,
    port_config,
    route,
    profiler,
    latency,
    process_latency,
    tag,
};

pub const param = @import("spa/param.zig");
pub const audio = @import("spa/audio.zig");

// TODO: Move things to their own namespaces
// TODO: Consider generating most of this from pipewire source

pub const AllocFlags = packed struct(u32) {
    /// add metadata data in the skeleton
    inline_meta: bool,
    /// add chunk data in the skeleton
    inline_chunk: bool,
    /// add buffer data to the skeleton
    inline_data: bool,
    /// don't set data pointers
    no_data: bool,

    pub const all: @This() = .{
        .inline_meta = true,
        .inline_chunk = true,
        .inline_data = true,
        .no_data = false,
    };
};

pub const ChunkFlags = packed struct(u32) {
    /// chunk data is corrupted in some way
    corrupted: bool,
    /// chunk data is empty with media specific neutral data such as silence or black
    empty: bool,
};

pub const DataFlags = packed struct(u32) {
    /// data is readable
    readable: bool,
    /// data is writable
    writable: bool,
    /// data pointer can be changed
    dynamic: bool,
    /// data is mappable with simple mmap/munmap
    mappable: bool,
    _: u28,

    pub fn canReadWrite(self: @This()) bool {
        return self.readable and self.writable;
    }
};

pub const MetaHeaderFlags = packed struct(u32) {
    /// data is not continuous with previous buffer
    discont: bool,
    /// data might be corrupted
    corrupted: bool,
    /// media specific marker
    marker: bool,
    /// data contains a codec specific header
    header: bool,
    /// data contains media neutral data
    gap: bool,
    /// cannot be decoded independently
    delta_unit: bool,
};

pub const MetaVideoTranform = enum(u32) {
    /// no transform
    none,
    /// 90 degree counter-clockwise
    ccw_90,
    /// 180 degree counter-clockwise
    ccw_180,
    /// 270 degree counter-clockwise
    ccw_270,
    /// 180 degree flipped around the vertical axis
    /// Equivalent to a reflexion through the vertical line splitting the buffer in two equal sized parts
    flipped,
    /// flip then rotate around 90 degree counter-clockwise
    flipped_ccw_90,
    /// flip then rotate around 180 degree counter-clockwise
    flipped_ccw_180,
    /// flip then rotate around 270 degree counter-clockwise
    flipped_ccw_270,
};

pub const Permission = packed struct(u32) {
    _0: u2,
    metadata: bool,
    link: bool,
    _1: u2,
    exec: bool,
    write: bool,
    read: bool,
    _2: u23,
};

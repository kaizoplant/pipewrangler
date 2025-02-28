const std = @import("std");
const pod = @import("../pod.zig");
const Pod = pod.Pod;
const audio = @import("audio.zig");

pub const Type = enum(u32) {
    prop_info = 1,
    props,
    enum_media_format,
    media_format,
    buffers,
    meta,
    io,
    enum_profile,
    profile,
    enum_port_config,
    port_config,
    enum_route,
    route,
    control,
    latency,
    process_latency,
    tag,
};

pub const InfoFlags = packed struct(u32) {
    serial: bool,
    read: bool,
    write: bool,
    _: u29,
};

pub const Info = D: {
    var fields: [std.meta.fields(Type).len]std.builtin.Type.StructField = undefined;
    for (&fields, std.meta.fields(Type)) |*dst, src| dst.* = .{
        .name = src.name,
        .type = ?InfoFlags,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(?InfoFlags),
    };
    break :D @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
};

pub const Bitorder = enum {
    unknown,
    msb,
    lsb,
};

pub const Availability = enum {
    unknown,
    no,
    yes,
};

pub const MetaType = enum(u32) {
    /// struct spa_meta_header
    header = 1,
    /// struct spa_meta_region with cropping data
    video_crop,
    /// array of struct spa_meta_region with damage, where an invalid entry or end-of-array marks the end.
    video_damage,
    /// struct spa_meta_bitmap
    bitmap,
    /// struct spa_meta_cursor
    cursor,
    /// metadata contains a spa_meta_control associated with the data
    control,
    /// don't write to buffer when count > 0
    busy,
    /// struct spa_meta_transform
    video_transform,
    /// struct spa_meta_sync_timeline
    sync_timeline,
};

pub const Meta = enum(u32) {
    type = 1,
    size,

    pub const Union = union(Meta) {
        type: MetaType,
        size: u32,
    };
};

pub const IoType = enum(u32) {
    buffers = 1,
    range,
    clock,
    latency,
    control,
    notify,
    position,
    ratematch,
    memory,
    asyncbuffers,
};

pub const Io = enum(u32) {
    id = 1,
    size,

    pub const Union = union(Io) {
        id: IoType,
        size: u32,
    };
};

pub const DataType = enum(u32) {
    /// pointer to memory, the data field in struct spa_data is set
    mem_ptr = 1,
    /// memfd, mmap to get to memory
    mem_fd,
    /// fd to dmabuf memory
    /// This might not be readily mappable (unless the MAPPABLE flag is set) and should normally be handled with DMABUF apis
    dma_buf,
    /// memory is identified with an id
    /// The actual memory can be obtained in some other way and can be identified with this id
    mem_id,
    /// a syncobj, usually requires a spa_meta_sync_timeline metadata with timeline points
    sync_obj,
};

pub const Buffers = enum(u32) {
    buffers = 1,
    blocks,
    size,
    stride,
    alignment,
    data_type,
    meta_type,

    pub const Union = union(Buffers) {
        buffers: u32,
        blocks: u32,
        size: u32,
        stride: u32,
        alignment: u32,
        data_type: DataType,
        meta_type: MetaType,
    };
};

pub const MediaType = enum(u32) {
    unknown,
    audio,
    video,
    image,
    binary,
    stream,
    application,
};

pub const MediaSubType = enum(u32) {
    unknown,
    raw,
    dsp,
    iec958,
    dsd,

    // audio types
    mp3 = 0x10001,
    aac,
    vorbis,
    wma,
    ra,
    sbc,
    adpcm,
    g723,
    g726,
    g729,
    amr,
    gsm,
    alac,
    flac,
    ape,
    opus,

    // video types
    h264 = 0x20001,
    mjpg,
    dv,
    mpegts,
    h263,
    mpeg1,
    mpeg2,
    mpeg4,
    xvid,
    vc1,
    vp8,
    vp9,
    bayer,

    // image types
    jpeg = 0x30001,

    _reserved_binary = 0x40001,

    // stream types
    midi = 0x50001,

    // application types
    control = 0x60001,
};

pub const MediaFormat = enum(u32) {
    media_type = 1,
    media_sub_type = 2,

    // audio format keys
    audio_format = 0x10001,
    audio_flags,
    audio_rate,
    audio_channels,
    audio_position,
    audio_iec958Codec,
    audio_bitorder,
    audio_interleave,
    audio_bitrate,
    audio_block_align,
    audio_aac_stream_format,
    audio_wma_profile,
    audio_amr_band_mode,

    // video format keys
    video_format = 0x20001,
    video_modifier,
    video_size,
    video_framerate,
    video_max_framerate,
    video_views,
    video_interlace_mode,
    video_pixel_aspect_ratio,
    video_multiview_mode,
    video_multiview_flags,
    video_chroma_site,
    video_color_range,
    video_color_matrix,
    video_transfer_function,
    video_color_primaries,
    video_profile,
    video_level,
    video_h264_stream_format,
    video_h264_alignment,

    _reserved_image = 0x30001,
    _reserved_binary = 0x40001,
    _reserved_stream = 0x50001,

    // application format keys
    control_types = 0x60001,

    pub const Union = union(MediaFormat) {
        media_type: MediaType,
        media_sub_type: MediaSubType,
        audio_format: audio.Format,
        audio_flags: audio.Flags,
        audio_rate: u32,
        audio_channels: u32,
        audio_position: []const audio.Channel,
        audio_iec958Codec: audio.Iec958Codec,
        audio_bitorder: Bitorder,
        audio_interleave: u32,
        audio_bitrate: u32,
        audio_block_align: u32,
        audio_aac_stream_format: pod.wire.Id, // TODO
        audio_wma_profile: pod.wire.Id, // TODO
        audio_amr_band_mode: pod.wire.Id, // TODO
        video_format: pod.wire.Id, // TODO
        video_modifier: u64,
        video_size: pod.wire.Rectangle,
        video_framerate: pod.wire.Fraction,
        video_max_framerate: pod.wire.Fraction,
        video_views: u32,
        video_interlace_mode: pod.wire.Id, // TODO
        video_pixel_aspect_ratio: pod.wire.Fraction,
        video_multiview_mode: pod.wire.Id, // TODO
        video_multiview_flags: pod.wire.Id, // TODO
        video_chroma_site: pod.wire.Id, // TODO
        video_color_range: pod.wire.Id, // TODO
        video_color_matrix: pod.wire.Id, // TODO
        video_transfer_function: pod.wire.Id, // TODO
        video_color_primaries: pod.wire.Id, // TODO
        video_profile: u32,
        video_level: u32,
        video_h264_stream_format: pod.wire.Id, // TODO
        video_h264_alignment: pod.wire.Id, // TODO
        _reserved_image: void,
        _reserved_binary: void,
        _reserved_stream: void,
        control_types: pod.wire.Id, // TODO
    };
};

pub const Latency = enum(u32) {
    direction = 1,
    min_quantum,
    max_quantum,
    min_rate,
    max_rate,
    min_ns,
    max_ns,

    pub const Union = union(Latency) {
        direction: Direction,
        min_quantum: f32,
        max_quantum: f32,
        min_rate: u32,
        max_rate: u32,
        min_ns: u64,
        max_ns: u64,
    };
};

pub const ProcessLatency = enum(u32) {
    quantum = 1,
    rate,
    ns,

    pub const Union = union(ProcessLatency) {
        quantum: f32,
        rate: u32,
        ns: u64,
    };
};

pub const PortConfigMode = enum {
    none,
    passthrough,
    convert,
    dsp,
};

pub const Direction = enum {
    in,
    out,
};

pub const PortConfig = enum(u32) {
    direction = 1,
    mode,
    monitor,
    control,
    format,

    pub const Union = union(PortConfig) {
        direction: Direction,
        mode: PortConfigMode,
        monitor: bool,
        control: bool,
        format: pod.wire.Object,
    };
};

pub const Profile = enum(u32) {
    index = 1,
    name,
    description,
    priority,
    available,
    info,
    classes,
    save,

    pub const Union = union(Profile) {
        index: u32,
        name: [:0]const u8,
        description: [:0]const u8,
        priority: u32,
        available: Availability,
        info: pod.wire.Struct,
        classes: pod.wire.Struct,
        save: bool,
    };
};

pub const Profiler = enum(u32) {
    // driver related props
    info = 0x10001,
    clock,
    driver_block,

    // follower related props
    follower_block = 0x20001,

    _reserved = 0x1000000,

    // rest is custom
    _,
};

pub const PropInfo = enum(u32) {
    id = 1,
    name,
    type,
    labels,
    container,
    params,
    description,

    pub const Union = union(PropInfo) {
        id: Props,
        name: [:0]const u8,
        type: Pod,
        labels: pod.wire.Struct,
        container: pod.wire.Id,
        params: u32,
        description: [:0]const u8,
    };
};

pub const Props = enum(u32) {
    unknown = 1,

    // device props
    device = 0x101,
    device_name,
    device_fd,
    card,
    card_name,
    min_latency,
    max_latency,
    periods,
    period_size,
    period_event,
    live,
    rate,
    quality,
    bluetooth_audio_codec,
    bluetooth_offload_active,

    // audio props
    wave_type = 0x10001,
    frequency,
    volume,
    mute,
    pattern_type,
    dither_type,
    truncate,
    channel_volumes,
    volume_base,
    volume_step,
    channel_map,
    monitor_mute,
    monitor_volumes,
    latency_offset_nsec,
    soft_mute,
    soft_volumes,
    iec958_codecs,
    volume_ramp_samples,
    volume_ramp_step_samples,
    volume_ramp_time,
    volume_ramp_step_time,
    volume_ramp_scale,

    // video props
    brightness = 0x20001,
    contrast,
    saturation,
    hue,
    gamma,
    exposure,
    gain,
    sharpness,

    // other props
    params = 0x80001,

    _reserved = 0x1000000,

    // rest is custom
    _,

    pub const Union = union(Props) {
        unknown: void,
        device: [:0]const u8,
        device_name: [:0]const u8,
        device_fd: pod.wire.Fd,
        card: [:0]const u8,
        card_name: [:0]const u8,
        min_latency: u32,
        max_latency: u32,
        periods: u32,
        period_size: u32,
        period_event: bool,
        live: bool,
        rate: f64,
        quality: u32,
        bluetooth_audio_codec: audio.BluetoothCodec,
        bluetooth_offload_active: bool,
        wave_type: pod.wire.Id,
        frequency: u32,
        volume: f32,
        mute: bool,
        pattern_type: pod.wire.Id,
        dither_type: pod.wire.Id,
        truncate: bool,
        channel_volumes: []const f32,
        volume_base: f32,
        volume_step: f32,
        channel_map: []const audio.Channel,
        monitor_mute: bool,
        monitor_volumes: []const f32,
        latency_offset_nsec: u64,
        soft_mute: bool,
        soft_volumes: []const f32,
        iec958_codecs: []const audio.Iec958Codec,
        volume_ramp_samples: u32,
        volume_ramp_step_samples: u32,
        volume_ramp_time: u32,
        volume_ramp_step_time: u32,
        volume_ramp_scale: audio.VolumeRampScale,
        brightness: f32,
        contrast: f32,
        saturation: f32,
        hue: u32,
        gamma: u32,
        exposure: u32,
        gain: f32,
        sharpness: f32,
        params: pod.wire.Struct,
        _reserved: void,
    };
};

pub const Route = enum(u32) {
    index = 1,
    direction,
    device,
    name,
    description,
    priority,
    available,
    info,
    profiles,
    props,
    devices,
    profile,
    save,

    pub const Union = union(Route) {
        index: u32,
        direction: Direction,
        device: u32,
        name: [:0]const u8,
        description: [:0]const u8,
        priority: u32,
        available: Availability,
        info: pod.wire.Struct,
        profiles: []const u32,
        props: pod.wire.Object,
        devices: []const u32,
        profile: u32,
        save: bool,
    };
};

pub const Tag = enum(u32) {
    direction = 1,
    info,

    pub const Union = union(Tag) {
        direction: Direction,
        info: pod.wire.Struct,
    };
};

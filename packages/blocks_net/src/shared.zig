pub const message_header_v1 = extern struct {
    magic: [8]u8 = "MSG_H_V1".*,
    tag: message_tag_v1,
    block_id: block_id_v1,
    remaining_length: u64,
};
pub const message_tag_v1 = enum(u64) {
    create_block = 0,
    apply_operation = 1,
    fetch_block = 2,
};

pub const create_block_v1 = extern struct {
    id: block_id_v1,
};
pub const apply_operation_v1 = extern struct {
    id: block_id_v1,
};
pub const fetch_block_v1 = extern struct {
    id: block_id_v1,
};

pub const block_id_v1 = extern struct {
    value: u128,

    pub fn from(a: anytype) block_id_v1 {
        return .{ .value = @intFromEnum(a) };
    }
};

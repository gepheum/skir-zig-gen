// =============================================================================
// UnrecognizedFields
// =============================================================================

/// Holds raw field data encountered during deserialization that does not
/// correspond to any declared field in the struct.
///
/// Every generated struct has a `_unrecognized: ?UnrecognizedFields = null`
/// field. Assign it `null` when constructing a struct — the deserializer fills
/// it in automatically when needed. You never need to read or write this field
/// in normal usage.
pub const UnrecognizedFields = struct {
    /// Dense-array trailing values rendered as JSON snippets, used to preserve
    /// unknown slot values across `fromJson(..., keep_unrecognized=true)` ->
    /// `toJson` roundtrips.
    dense_tail_json: ?[]const []const u8 = null,

    /// Count of unknown dense slots encountered beyond recognized fields.
    dense_extra_count: usize = 0,

    /// Raw wire bytes for unknown trailing dense slots encountered when
    /// decoding binary input. Each entry is one encoded value blob.
    dense_tail_wire: ?[]const []const u8 = null,
};

// =============================================================================
// UnrecognizedVariant
// =============================================================================

/// Holds raw enum payload data encountered during deserialization for an
/// unrecognized enum variant.
pub const UnrecognizedVariant = struct {
    /// Unknown enum variant number (kind discriminator).
    number: i32 = 0,

    /// Unknown wrapper payload rendered as dense JSON text.
    payload_json: ?[]const u8 = null,

    /// Unknown wrapper payload captured as raw wire bytes.
    payload_wire: ?[]const u8 = null,
};

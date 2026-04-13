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
    // The real library stores raw deserialized field bytes here.
    // This stub is a placeholder — instances are never created directly by
    // user code (the `_unrecognized` field always starts as null).
};

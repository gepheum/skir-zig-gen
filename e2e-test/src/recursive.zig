pub fn Recursive(comptime T: type) type {
    return union(enum) {
        default_value,
        value: *const T,
    };
}

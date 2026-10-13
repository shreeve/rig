//! `std.unicode`: the panics of its UTF-16 functions.

pub fn not_a_pair() void {
    @panic("unicode.surrogate_pair_to_code_point: not a high and a low surrogate");
}

pub fn not_a_code_point() void {
    @panic("unicode.utf16_len: not a code point");
}

const std = @import("std");
const expect = std.testing.expect;
const str = []const u8;
const tools = @import("tools.zig");
const streql = tools.streql;

/// A "formatted struct" encapsulates a complex type like slice, array or struct
/// into a new struct that defines how it can be parsed.
/// If a struct has this enum in its declarations, it is a formatted struct.
const FormattedStruct = enum {
    join_struct,
    match_struct,
};

/// Join(T, sep) returns a formatted struct given a type T.
/// It specifies that the elements in the type T are separated by S.
pub fn Join(comptime T: type, comptime sep: str) type {
    //TODO Join(u32, " ") makes no sense b/c u32 is not composed of several
    // elements. I tried to return TypeError in this case, but keyword try
    // is not accepted in struct definition. Which means that every Join()
    // types should be pre-declared in consts... the thing becomes cumbersome?
    // switch (@typeInfo(T)) {
    //     .Struct, .Pointer, .Array => {},
    //     else => return TypeError.TypeError,
    // }
    return struct {
        child: T,
        pub const fmt_struct: FormattedStruct = .join_struct;
        pub const child_type: type = T;

        pub fn tokenize(val: str) std.mem.TokenIterator {
            return std.mem.tokenize(val, sep);
        }
    };
}

/// A formatted struct that matches a string without storing data.
/// Useful to assert that some syntactic element (keyword, brackets, ...) is
/// present.
pub fn Match(comptime match: str) type {
    return struct {
        // no fields! no data.
        pub const fmt_struct: FormattedStruct = .match_struct;
        pub const to_match = match;
    };
}

/// Returns true if the struct T contains any nested formatted struct.
pub fn isFormattedStruct(comptime T: type) bool {
    if (@typeInfo(T) != .Struct)
        return false;
    inline for (@typeInfo(T).Struct.decls) |decl, i| {
        if (decl.data == .Var) {
            if (decl.data.Var == FormattedStruct) {
                return true;
            }
        }
    }
    return false;
}

/// When we parse a formatted struct of type T, we want to return the unformatted type Unformat(T). Indeed, formatted types are cumbersome (they add one nesting level per formatted struct) and are not what the user want to obtain in the end.
/// This helper casts all the a new type cast converts
pub fn castUnformatRecur(comptime T: type, parsed: *T, unformatted: *Unformat(T)) void {
    const typeinfo_T = @typeInfo(T);
    switch (typeinfo_T) {
        .Struct => {
            comptime const is_formatted_struct = isFormattedStruct(T);
            if (!is_formatted_struct) {
                inline for (typeinfo_T.Struct.fields) |f, i| {
                    // this is not a formatted struct, so both formatted and
                    // unformatted structs should have the same field names
                    const corresponding_field_name = @typeInfo(Unformat(T)).Struct.fields[i].name;
                    comptime expect(streql(f.name, corresponding_field_name));
                    comptime expect(T == @TypeOf(parsed.*));
                    castUnformatRecur(
                        f.field_type,
                        &@field(parsed.*, f.name),
                        &@field(unformatted.*, f.name),
                    );
                }
            } else if (is_formatted_struct) {
                if (T.fmt_struct == .join_struct) {
                    const cast = @ptrCast(*Unformat(T), &(parsed.*.child));
                    unformatted.* = cast.*;
                } else if (T.fmt_struct == .match_struct) {
                    // do nothing: match structs do not hold data.
                }
            }
        },
        .Pointer => {
            castUnformatRecur(
                typeinfo_T.Pointer.child,
                parsed.*,
                unformatted.*,
            );
        },
        else => {
            unformatted.* = parsed.*;
        },
    }
}

/// Transform a formatted struct, or any type containing nested formatted
/// structs, into a type without.
pub fn Unformat(comptime T: type) type {
    comptime var typeinfo = @typeInfo(T);
    switch (typeinfo) {
        .Struct => {
            comptime const is_fmt_struct: bool = isFormattedStruct(T);
            if (is_fmt_struct) {
                if (T.fmt_struct == .join_struct) {
                    return Unformat(T.child_type);
                }
            }
            // return a new type where all fields are recursively Unformatted
            // Match fields should be ommited, so we are going to count them
            const fields = typeinfo.Struct.fields;
            const StructField = std.builtin.TypeInfo.StructField;
            comptime var new_fields: [fields.len]StructField = undefined;
            comptime var fields_have_changed: bool = false;
            std.mem.copy(StructField, new_fields[0..], fields);
            // if the type is already unformatted and Unformat(T) = T, we do
            // not want to recreate a new type with a different name: we
            // simply return the current type.
            comptime var i: u32 = 0;
            inline for (fields) |f, j| {
                const unfmt_type = Unformat(f.field_type);
                new_fields[j].field_type = unfmt_type;
                if (f.field_type != unfmt_type) { // type has been modified:
                    fields_have_changed = true;
                    new_fields[j].default_value = null; //nested_type
                }
            }
            if (!fields_have_changed) {
                return T;
            }
            // TODO Warning! The new type can't have decls! Limitation of @Type
            // at least until Zig 0.7
            const dummy_decls: [0]std.builtin.TypeInfo.Declaration = undefined;
            const s = std.builtin.TypeInfo.Struct{
                .layout = typeinfo.Struct.layout,
                .fields = new_fields[0..],
                .decls = &dummy_decls,
                .is_tuple = typeinfo.Struct.is_tuple,
            };
            const nested_type = @Type(std.builtin.TypeInfo{
                .Struct = s,
            });
            return nested_type;
        },
        .Pointer => {
            // TODO: why doesn't the following work?:
            // return *Unformat(typeinfo.Pointer.child);
            const tp = typeinfo.Pointer;
            var s: std.builtin.TypeInfo.Pointer = tp;
            s.child = Unformat(tp.child);
            return @Type(std.builtin.TypeInfo{ .Pointer = s });
        },
        .Array => {
            const tp = typeinfo.Array;
            var s: std.builtin.TypeInfo.Array = tp;
            s.child = Unformat(tp.child);
            return @Type(std.builtin.TypeInfo{ .Array = s });
        },
        .Int => return T,
        else => return T,
    }
}

test "join and unformat" {
    const u32_joined: type = Join([]u32, " ");
    expect(isFormattedStruct(u32_joined));
    const ufmt_u: type = Unformat(u32_joined);
    expect(ufmt_u == []u32);
    const ufmt: type = Unformat(u32);
    expect(ufmt == u32);
}

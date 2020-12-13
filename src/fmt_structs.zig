const std = @import("std");
const expect = std.testing.expect;
const str = []const u8;

/// A "formatted struct" encapsulates a complex type like slice, array or struct
/// into a new struct that defines how it can be parsed.
/// If a struct has this enum in its declarations, it is a formatted struct.
const FormattedStruct = enum {
    formatted_struct,
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
        const fmt_struct: FormattedStruct = .formatted_struct;
        const child_type: type = T;

        fn tokenize(val: str) std.mem.TokenIterator {
            return std.mem.tokenize(val, sep);
        }
    };
}

/// Returns true if the struct T contains any nested formatted struct.
pub fn isFormattedStruct(comptime T: type) bool {
    if (@typeInfo(T) != .Struct)
        return false;
    inline for (@typeInfo(T).Struct.decls) |decl, i| {
        if (decl.data.Var == FormattedStruct) {
            return true;
        }
    }
    return false;
}

/// When we parse a formatted struct of type T, we want to return the unformatted type Unformat(T). Indeed, formatted types are cumbersome (they add one nesting level per formatted struct) and are not what the user want to obtain in the end.
/// This helper casts all the a new type cast converts
fn castUnformatRecur(comptime T: type, parsed: *T, unformatted: *Unformat(T)) void {
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
            }
            if (is_formatted_struct) {
                const formatted_child = @ptrCast(
                    *Unformat(T),
                    &(parsed.*.child),
                );
                unformatted.* = formatted_child.*;
            }
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
                return Unformat(T.child_type);
            } else {
                const StructField = std.builtin.TypeInfo.StructField;
                comptime const n_fields = typeinfo.Struct.fields.len;
                comptime var fields: [n_fields]StructField = undefined;
                std.mem.copy(StructField, fields[0..], typeinfo.Struct.fields);
                // recursively Unformat the fields
                var fields_have_changed: bool = false;
                inline for (fields) |f, i| {
                    const unfmt_type = Unformat(f.field_type);
                    fields[i].field_type = unfmt_type;
                    if (f.field_type != unfmt_type) { // type has been modified:
                        fields_have_changed = true;
                        fields[i].default_value = null; //nested_type
                    }
                }
                if (!fields_have_changed) {
                    return T;
                }
                const s = std.builtin.TypeInfo.Struct{
                    .layout = typeinfo.Struct.layout,
                    .fields = fields[0..],
                    .decls = typeinfo.Struct.decls, //new_decls[0..],
                    .is_tuple = typeinfo.Struct.is_tuple,
                };
                const nested_type = @Type(std.builtin.TypeInfo{
                    .Struct = s,
                });

                return nested_type;
            }
        },
        .Pointer => {
            // Create a new type info where the child type is unformatted
            const tp = typeinfo.Pointer;
            var s: std.builtin.TypeInfo.Pointer = tp;
            s.child = Unformat(tp.child);
            return @Type(std.builtin.TypeInfo{ .Pointer = s });
        },
        .Array => {
            return Error.NotImplementedError;
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

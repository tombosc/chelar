const std = @import("std");
const expect = std.testing.expect;
const str = []const u8;
const tools = @import("tools.zig");
const streql = tools.streql;
const print = std.debug.print;

/// A "formatted struct" encapsulates a complex type like slice, array or struct
/// into a new struct that defines how it can be parsed.
/// If a struct has this enum in its declarations, it is a formatted struct.
const FormattedStruct = enum {
    join_struct,
    match_struct,
    wrap_struct,
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

/// A formatted struct that matches a string match without storing any data.
/// Useful to assert that some syntactic element (keyword, brackets, ...) is
/// present.
pub fn Match(comptime match: str) type {
    return struct {
        // no fields! no data.
        pub const fmt_struct: FormattedStruct = .match_struct;
        pub const to_match = match;
    };
}

pub fn Wrap(comptime T: type, comptime match_left: str, comptime match_right: str) type {
    return struct {
        _0: Match(match_left) = .{},
        child: wrapSubtypes(T),
        _1: Match(match_right) = .{},
        pub const fmt_struct: FormattedStruct = .wrap_struct;
        pub const child_type: type = wrapSubtypes(T);

        fn wrapSubtypes(comptime t: type) type {
            if (T == t) {
                //return @This(); //Wrap(@This(), match_left, match_right);
                //return Wrap(@This(), match_left, match_right);
                // return *@This();
                return @This();
            }
            if (@typeInfo(t) == .Optional) {
                return ?wrapSubtypes(@typeInfo(t).Optional.child);
            } else if (@typeInfo(t) == .Pointer) {
                var child_: type = wrapSubtypes(@typeInfo(t).Pointer.child);
                if (@typeInfo(t).Pointer.size == .Slice) {
                    return []child_;
                } else {
                    // const tp = @typeInfo(t).Pointer;
                    // var s: std.builtin.TypeInfo.Pointer = tp;
                    // s.child = wrapSubtypes(child_);
                    // return @Type(std.builtin.TypeInfo{ .Pointer = s });
                    // TODO why not:
                    return *child_;
                }
            } else if (@typeInfo(t) != .Struct) {
                return t;
            }
            // print("{}\n", .{T});
            const struct_info = @typeInfo(t).Struct;
            const StructField = std.builtin.TypeInfo.StructField;
            comptime const n_fields = struct_info.fields.len;
            comptime var fields: [n_fields]StructField = undefined;
            std.mem.copy(StructField, fields[0..], struct_info.fields);
            var fields_have_changed: bool = false;
            inline for (fields) |f, i| {
                //const wrapped_type: type = wrapSubtypes(f.field_type);
                const wrapped_type: type = f.field_type;
                fields[i].field_type = wrapped_type;
                if (f.field_type != wrapped_type) { // type has been modified:
                    fields_have_changed = true;
                    fields[i].default_value = null; //nested_type
                }
            }
            if (!fields_have_changed) {
                return t;
            }
            const dummy_decls: [0]std.builtin.TypeInfo.Declaration = undefined;
            const s = std.builtin.TypeInfo.Struct{
                .layout = struct_info.layout,
                .fields = fields[0..],
                .decls = &dummy_decls, // TODO @Type doesn't work with structs with decls
                .is_tuple = struct_info.is_tuple,
            };
            return @Type(std.builtin.TypeInfo{
                .Struct = s,
            });
        }
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
                // TODO deal with recursive types?
            } else if (is_formatted_struct) {
                if (T.fmt_struct == .join_struct or T.fmt_struct == .wrap_struct) {
                    const cast = @ptrCast(*Unformat(T), &(parsed.*.child));
                    //print("DBG{} {}\n", .{ cast, unformatted });
                    unformatted.* = cast.*;
                } else if (T.fmt_struct == .match_struct) {
                    // do nothing: match structs do not hold data.
                }
            }
        },
        .Pointer => {
            print("forgotten?{}\n", .{@ptrToInt(parsed)});
            // const unfmt_child_type = Unformat(typeinfo_T.Pointer.child);
            // const cast = @ptrCast(
            //     *unfmt_child_type,
            //     &(parsed.*.child),
            // );
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

pub fn countNonMatchFields(comptime Struct: type) u32 {
    comptime var n_match_fields = 0;
    comptime const fields = @typeInfo(Struct).Struct.fields;
    inline for (fields) |f, i| {
        if (isFormattedStruct(f.field_type)) {
            if (f.field_type.fmt_struct == .match_struct) {
                n_match_fields += 1;
            }
        }
    }
    return fields.len - n_match_fields;
}

/// Transform a formatted struct, or any type containing nested formatted
/// structs, into a type without.
pub fn Unformat(comptime T: type) type {
    comptime var typeinfo = @typeInfo(T);
    switch (typeinfo) {
        .Struct => {
            comptime const is_fmt_struct: bool = isFormattedStruct(T);
            if (is_fmt_struct) {
                if (T.fmt_struct == .join_struct or T.fmt_struct == .wrap_struct) {
                    return Unformat(T.child_type);
                }
            }
            // return a new type where all fields are recursively Unformatted
            // Match fields should be ommited, so we are going to count them
            const fields = typeinfo.Struct.fields;
            const StructField = std.builtin.TypeInfo.StructField;
            // first tried to make Unformat remove Match fields.
            // this could be elegant but we can't create a type with decls.
            // it's better to use Wrap and keep the match fields.
            //const n_nonmatch_fields: u32 = countNonMatchFields(T);
            //comptime var new_fields: [n_nonmatch_fields]StructField = undefined;
            // comptime var fields_have_changed: bool = n_nonmatch_fields != fields.len;
            comptime var new_fields: [fields.len]StructField = undefined;
            comptime var fields_have_changed: bool = false;
            // std.mem.copy(StructField, new_fields[0..], typeinfo.Struct.fields);
            // if the type is already unformatted and Unformat(T) = T, we do
            // not want to recreate a new type with a different name: we
            // simply return the current type.
            comptime var i: u32 = 0;
            inline for (fields) |f, j| {
                // if (isFormattedStruct(f.field_type)) {
                //     if (f.field_type.fmt_struct == .match_struct) {
                //         continue;
                //     }
                // }
                new_fields[i] = f;
                const unfmt_type = Unformat(f.field_type);
                new_fields[i].field_type = unfmt_type;
                if (f.field_type != unfmt_type) { // type has been modified:
                    fields_have_changed = true;
                    new_fields[i].default_value = null; //nested_type
                }
                i += 1;
            }
            if (!fields_have_changed) {
                return T;
            }
            const dummy_decls: [0]std.builtin.TypeInfo.Declaration = undefined;
            const s = std.builtin.TypeInfo.Struct{
                .layout = typeinfo.Struct.layout,
                .fields = new_fields[0..],
                .decls = &dummy_decls, // TODO @Type doesn't work with structs with decls
                .is_tuple = typeinfo.Struct.is_tuple,
            };
            const nested_type = @Type(std.builtin.TypeInfo{
                .Struct = s,
            });
            return nested_type;
        },
        .Pointer => {
            // TODO: why doesn't the following work?:
            //return *Unformat(typeinfo.Pointer.child);
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

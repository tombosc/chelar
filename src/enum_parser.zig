const std = @import("std");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const print = std.debug.print;

pub const Error = error{
    NotExhaustiveEnumError,
    ParseError,
};

/// Get a parser function for the exhaustive enum E.
pub fn EnumParser(comptime E: type) Error!(fn ([]const u8) Error!E) {
    if (@typeInfo(E) != .Enum or !@typeInfo(E).Enum.is_exhaustive) {
        return Error.NotExhaustiveEnumError;
    }
    return struct {
        const EntryList = std.ArrayListUnmanaged(HashMap.Entry);
        const HashMap = std.StringArrayHashMapUnmanaged(E);

        const hash_map: HashMap = .{
            .entries = enumToEntries(),
        };

        fn enumToEntries() EntryList {
            const n_values: u32 = @typeInfo(E).Enum.fields.len;
            var entries: [n_values]HashMap.Entry = undefined;
            inline for (@typeInfo(E).Enum.fields) |f, i| {
                // no fields have duplicated values
                entries[i] = .{
                    .hash = std.array_hash_map.hashString(f.name),
                    .key = f.name,
                    // f.value are comptime_ints, so need a cast
                    .value = @intToEnum(E, f.value),
                };
            }
            return EntryList{
                .items = entries[0..],
                .capacity = n_values,
            };
        }

        pub fn parse(string: []const u8) Error!E {
            const entry = @This().hash_map.get(string);
            if (entry) |e| {
                return e;
            } else {
                return Error.ParseError;
            }
        }
    }.parse;
}

test "non-exhaustive enum" {
    const Amount = enum(u8) {
        one, two, five, twenty, _
    };
    expectError(Error.NotExhaustiveEnumError, EnumParser(Amount));
}

test "basic" {
    const EyeColor = enum {
        blu, hzl, gry, mag, ppl, grn, azure, blk, wht, ggg, pdp, rainbow, ddd, pqpqpd, da, z, q, dz0dz
    };
    const ecParser = try EnumParser(EyeColor);
    expect((try ecParser("blu")) == EyeColor.blu);
    expectError(Error.ParseError, ecParser("???"));
}

# chelar

Create simple parsers in [Zig](https://ziglang.org/) projects at compile-time. Warning: Hacky and experimental. 

Example taken (modified) from [advent of code 2020](https://adventofcode.com/), day 8:

```Zig
test "AoC day8 (modified)" {
    const alloc = std.testing.allocator;
    const Opcode = enum {
        nop,
        acc,
        jmp,
    };
    const Instruction = struct {
        opcode: Opcode,
        operand: ?i32,
    };
    // Parser definition:
    // within a struct, opcodes and operands are space-separated:
    const PInstruction = Join(Instruction, " ");
    // parse unknown number of space-separated instructions, separated by \n:
    const PInstructions = Join([]PInstruction, "\n");
    // name the data structure without formatting
    const Instructions = Unformat(PInstructions);
    expect(Instructions == []Instruction);
    const parser = ParserStr(PInstructions);

    const raw_instructions =
        \\jmp +109
        \\acc +10
        \\jmp +18
        \\nop
    ;
    const parsed = try parser(alloc, raw_instructions);
    defer alloc.free(parsed);
    expect(parsed.len == 4);
    expect(parsed[2].opcode == .jmp and parsed[2].operand.? == 18);
    expect(parsed[3].opcode == .nop and parsed[3].operand == null);
}
```

# Details

To be more precise, here is the correspondence between types and regex/formal grammar rules:

- `?T`: regex `T?`
- `[]T`: regex `T*`
- `[19]T`: regex `T{19}`
- `enum { a, b, c }`: regex `(a|b|c)`
- `const X = struct { a: T, b: U}`: formal grammar rule `X → TU` (**but** does not handle recursive languages, i.e. setting the type `U` to `*X` for instance)

The parser is a very naive and WIP [recursive descent parser](https://en.wikipedia.org/wiki/Recursive_descent_parser) with **many** caveats:

- does not backtrack, so it cannot even parse data type `struct { a: ?u32, b: u32 }` correctly
- does not deal with runtime errors gracefully
- does not deal with compile time errors of types. For instance, `Join(u32, " ")` should fail but doesn't. That's because either we write `struct { a: try Join(u32, " "), ...` and it segfaults, or we have to declare all intermediary types used nested.

Right now, the way it is implemented is that `Join([]u32, sep)` creates a new type `struct { child: []u32, const tokenizer = std.mem.tokenize(val, sep); }`. Not great. We could avoid deeper nestings if we could reify types with declarations as [proposed here (#6709)](https://github.com/ziglang/zig/issues/6709).

We could have more cool stuff, like:

- Proper error handling, not sure how yet.
- Tagged unions.
- Handle recursive languages by dealing with pointers.
- A new type transformer `Ignore(T)`, corresponding to data that we don't want to capture. For example, if a struct has a first field `a: Ignore(u32)`, it means we need to parse it but do not store it.
- A new type transformer `Wrap(T, '{', '}')`.
- Serialization? Should be quite straightforward.

# chelar

Create simple parsers in your [zig](https://ziglang.org/) projects for data structures, at compile-time. Warning: Hacky and experimental. 

Here is an example taken (modified) from [advent of code 2020, day 8](https://adventofcode.com/):

```
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
- `const X = struct { a: T, b: U}`: formal grammar rule `X → TU` (**but** does not handle `U = *X` for instance! not recursive/context-free languages!)

The parser is a very stupid, WIP [recursive descent parser](https://en.wikipedia.org/wiki/Recursive_descent_parser) with **many**, **huge** caveats:

- does not backtrack! It cannot even parse data type `struct { a: ?u32, b: u32 }` correctly. 
- does not deal with runtime errors gracefully.
- does not deal with errors in building parser at compile time. For instance, right now `Join(u32, " ")` could fail but doesn't, because `try` segfault in structs. If `Join` can fail, the syntax slightly more cumbersome and we have to declare all intermediary types used nested. Maybe not a bad tradeoff...

Right now, the way it is implemented is that `Join([]u32, sep)` creates a new type `struct { child: []u32, const tokenizer = std.mem.tokenize(val, sep); }`. Not great. We could avoid deeper nestings if we could reify types with declarations as [proposed here (#6709)](https://github.com/ziglang/zig/issues/6709).

We could have more cool stuff, like:

- Proper error handling, not sure how yet.
- Tagged unions.
- Handle recursive languages by dealing with pointers.
- A new type transformer `Ignore(T)`, corresponding to data that we don't want to capture. For example, if a struct has a first field `a: Ignore(u32)`, it means we need to parse it but do not store it.
- A new type transformer `Wrap(T, '{', '}')`.
- Serialization? Should be quite straightforward.

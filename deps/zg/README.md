# zg

zg provides Unicode text processing for Zig projects.


## Unicode Version

The Unicode version supported by zg is `16.0.0`.


## Zig Version

The minimum Zig version required is `0.14`.


## Integrating zg into your Zig Project

You first need to add zg as a dependency in your `build.zig.zon` file. In your
Zig project's root directory, run:

```plain
zig fetch --save https://codeberg.org/atman/zg/archive/v0.14.1.tar.gz
```

Then instantiate the dependency in your `build.zig`:

```zig
const zg = b.dependency("zg", .{});
```


## A Modular Approach

zg is a modular library. This approach minimizes binary file size and memory
requirements by only including the Unicode data required for the specified module.
The following sections describe the various modules and their specific use case.


### Init and Setup

The code examples will show the use of `Module.init(allocator)` to create the
various modules.  All of the allocating modules have a `setup` variant, which
takes a pointer and allocates in-place.

Example use:

```zig
test "Setup form" {
    var graphemes = try allocator.create(Graphemes);
    defer allocator.destroy(graphemes);
    try graphemes.setup(allocator);
    defer graphemes.deinit(allocator);
}
```


## Code Points

In the `code_point` module, you'll find a data structure representing a single code
point, `CodePoint`, and an `Iterator` to iterate over the code points in a string.

In your `build.zig`:

```zig
exe.root_module.addImport("code_point", zg.module("code_point"));
```

In your code:

```zig
const code_point = @import("code_point");

test "Code point iterator" {
    const str = "Hi 😊";
    var iter: code_point.Iterator = .init(str);
    var i: usize = 0;

    while (iter.next()) |cp| : (i += 1) {
        // The `code` field is the actual code point scalar as a `u21`.
        if (i == 0) try expect(cp.code == 'H');
        if (i == 1) try expect(cp.code == 'i');
        if (i == 2) try expect(cp.code == ' ');

        if (i == 3) {
            try expect(cp.code == '😊');
            // The `offset` field is the byte offset in the
            // source string.
            try expect(cp.offset == 3);
            try expectEqual(cp, code_point.decodeAtIndex(str, cp.offset).?);
            // The `len` field is the length in bytes of the
            // code point in the source string.
            try expect(cp.len == 4);
            // There is also a 'cursor' decode, like so:
            {
                var cursor = cp.offset;
                try expectEqual(cp, code_point.decodeAtCursor(str, &cursor).?);
                // Which advances the cursor variable to the next possible
                // offset, in this case, `str.len`.  Don't forget to account
                // for this possibility!
                try expectEqual(cp.offset + cp.len, cursor);
            }
            // There's also this, for when you aren't sure if you have the
            // correct start for a code point:
            try expectEqual(cp, code_point.codepointAtIndex(str, cp.offset + 1).?);
        }
        // Reverse iteration is also an option:
        var r_iter: code_point.ReverseIterator = .init(str);
        // Both iterators can be peeked:
        try expectEqual('😊', r_iter.peek().?.code);
        try expectEqual('😊', r_iter.prev().?.code);
        // Both kinds of iterators can be reversed:
        var fwd_iter = r_iter.forwardIterator(); // or iter.reverseIterator();
        // This will always return the last codepoint from
        // the prior iterator, _if_ it yielded one:
        try expectEqual('😊', fwd_iter.next().?.code);
    }
}
```

Note that it's safe to call CodePoint functions on invalid
UTF-8. Iterators and decode functions will return the Unicode
Replacement Character `U+FFFD`, according to the Substitution of Maximal
Subparts algorithm, for any invalid code unit sequences encountered.


## Grapheme Clusters

Many characters are composed from more than one code point. These
are known as Grapheme Clusters, and the `Graphemes` module has a
data structure to represent them, `Grapheme`, and an `Iterator` and
`ReverseIterator` to iterate over them in a string.

There is also `graphemeAtIndex`, which returns whatever grapheme
belongs to the index; this does not have to be on a valid grapheme
or codepoint boundary, but it is illegal to call on an empty string.
Last, `iterateAfterGrapheme` or `iterateBeforeGrapheme` will provide
forward or backward grapheme iterators of the string, from the grapheme
provided.  Thus, given an index, you can begin forward or backward
iteration at that index without needing to slice the string.

In your `build.zig`:

```zig
exe.root_module.addImport("Graphemes", zg.module("Graphemes"));
```

In your code:

```zig
const Graphemes = @import("Graphemes");

test "Grapheme cluster iterator" {
    const graph = try Graphemes.init(allocator);
    defer graph.deinit(allocator);

    const str = "He\u{301}"; // Hé
    var iter = graph.iterator(str);

    var i: usize = 0;

    while (iter.next()) |gc| : (i += 1) {
        // The `len` field is the length in bytes of the
        // grapheme cluster in the source string.
        if (i == 0) try expect(gc.len == 1);

        if (i == 1) {
            try expect(gc.len == 3);

            // The `offset` in bytes of the grapheme cluster
            // in the source string.
            try expect(gc.offset == 1);

            // The `bytes` method returns the slice of bytes
            // that comprise this grapheme cluster in the
            // source string `str`.
            try expectEqualStrings("e\u{301}", gc.bytes(str));
        }
    }
}
```


## Words

Unicode has a standard word segmentation algorithm, which gives good
results for most languages.  Some languages, such as Thai, require a
dictionary to find the boundary between words; these cases are not
handled by the standard algorithm.

`zg` implements that algorithm in the `Words` module.  As a note,
the iterators and functions provided here will yield segments which
are not a "word" in the conventional sense, but word _boundaries_.
Specifically, the iterators in this module will return every segment of
a string, ensuring that words are kept whole when encountered.  If the
word breaks are of primary interest, you'll want to use the `.offset`
field of each iterated value, and handle `string.len` as the final case
when the iteration returns `null`.

The API is congruent with `Graphemes`: forward and backward iterators,
`wordAtIndex`, and `iterateAfter` and before.

In your `build.zig`:

```zig
exe.root_module.addImport("Words", zg.module("Words"));
```

In your code:

```zig
const Words = @import("Words");

test "Words" {
    const wb = try Words.init(testing.allocator);
    defer wb.deinit(testing.allocator);
    const word_str = "Metonym   Μετωνύμιο メトニム";
    var w_iter = wb.iterator(word_str);
    try testing.expectEqualStrings("Metonym", w_iter.next().?.bytes(word_str));
    // Spaces are "words" too!
    try testing.expectEqualStrings("   ", w_iter.next().?.bytes(word_str));
    const in_greek = w_iter.next().?;
    // wordAtIndex doesn't care if the index is valid for a codepoint:
    for (in_greek.offset..in_greek.offset + in_greek.len) |i| {
        const at_index = wb.wordAtIndex(word_str, i).bytes(word_str);
        try testing.expectEqualStrings("Μετωνύμιο", at_index);
    }
    _ = w_iter.next();
    try testing.expectEqualStrings("メトニム", w_iter.next().?.bytes(word_str));
}
```

## Unicode General Categories

To detect the general category for a code point, use the `GeneralCategories` module.

In your `build.zig`:

```zig
exe.root_module.addImport("GeneralCategories", zg.module("GeneralCategories"));
```

In your code:

```zig
const GeneralCategories = @import("GeneralCategories");

test "General Categories" {
    const gen_cat = try GeneralCategories.init(allocator);
    defer gen_cat.deinit(allocator);

    // The `gc` method returns the abbreviated General Category.
    // These abbreviations and descriptive comments can be found
    // in the source file `src/GenCatData.zig` as en enum.
    try expect(gen_cat.gc('A') == .Lu); // Lu: uppercase letter
    try expect(gen_cat.gc('3') == .Nd); // Nd: decimal number

    // The following are convenience methods for groups of General
    // Categories. For example, all letter categories start with `L`:
    // Lu, Ll, Lt, Lo.
    try expect(gen_cat.isControl(0));
    try expect(gen_cat.isLetter('z'));
    try expect(gen_cat.isMark('\u{301}'));
    try expect(gen_cat.isNumber('3'));
    try expect(gen_cat.isPunctuation('['));
    try expect(gen_cat.isSeparator(' '));
    try expect(gen_cat.isSymbol('©'));
}
```

## Unicode Properties

You can detect common properties of a code point with the `Properties` module.

In your `build.zig`:

```zig
exe.root_module.addImport("Properties", zg.module("Properties"));
```

In your code:

```zig
const Properties = @import("Properties");

test "Properties" {
    const props = try Properties.init(allocator);
    defer props.deinit(allocator);

    // Mathematical symbols and letters.
    try expect(props.isMath('+'));
    // Alphabetic only code points.
    try expect(props.isAlphabetic('Z'));
    // Space, tab, and other separators.
    try expect(props.isWhitespace(' '));
    // Hexadecimal digits and variations thereof.
    try expect(props.isHexDigit('f'));
    try expect(!props.isHexDigit('z'));

    // Accents, dieresis, and other combining marks.
    try expect(props.isDiacritic('\u{301}'));

    // Unicode has a specification for valid identifiers like
    // the ones used in programming and regular expressions.
    try expect(props.isIdStart('Z')); // Identifier start character
    try expect(!props.isIdStart('1'));
    try expect(props.isIdContinue('1'));

    // The `X` versions add some code points that can appear after
    // normalizing a string.
    try expect(props.isXidStart('\u{b33}')); // Extended identifier start character
    try expect(props.isXidContinue('\u{e33}'));
    try expect(!props.isXidStart('1'));

    // Note surprising Unicode numeric type properties!
    try expect(props.isNumeric('\u{277f}'));
    try expect(!props.isNumeric('3')); // 3 is not numeric!
    try expect(props.isDigit('\u{2070}'));
    try expect(!props.isDigit('3')); // 3 is not a digit!
    try expect(props.isDecimal('3')); // 3 is a decimal digit
}
```

## Letter Case Detection and Conversion

To detect and convert to and from different letter cases, use the `LetterCasing`
module.

In your `build.zig`:

```zig
exe.root_module.addImport("LetterCasing", zg.module("LetterCasing"));
```

In your code:

```zig
const LetterCasing = @import("LetterCasing");

test "LetterCasing" {
    const case = try LetterCasing.init(allocator);
    defer case.deinit(allocator);

    // Upper and lower case.
    try expect(case.isUpper('A'));
    try expect('A' == case.toUpper('a'));
    try expect(case.isLower('a'));
    try expect('a' == case.toLower('A'));

    // Code points that have case.
    try expect(case.isCased('É'));
    try expect(!case.isCased('3'));

    // Case detection and conversion for strings.
    try expect(case.isUpperStr("HELLO 123!"));
    const ucased = try case.toUpperStr(allocator, "hello 123");
    defer allocator.free(ucased);
    try expectEqualStrings("HELLO 123", ucased);

    try expect(case.isLowerStr("hello 123!"));
    const lcased = try case.toLowerStr(allocator, "HELLO 123");
    defer allocator.free(lcased);
    try expectEqualStrings("hello 123", lcased);
}
```

## Normalization

Unicode normalization is the process of converting a string into a uniform
representation that can guarantee a known structure by following a strict set
of rules. There are four normalization forms:

**Canonical Composition (NFC)**
: The most compact representation obtained by first
decomposing to Canonical Decomposition and then composing to NFC.

**Compatibility Composition (NFKC)**
: The most comprehensive composition obtained
by first decomposing to Compatibility Decomposition and then composing to NFKC.

**Canonical Decomposition (NFD)**
: Only code points with canonical decompositions
are decomposed. This is a more compact and faster decomposition but will not
provide the most comprehensive normalization possible.

**Compatibility Decomposition (NFKD)**
: The most comprehensive decomposition method
where both canonical and compatibility decompositions are performed recursively.

`zg` has methods to produce all four normalization forms in the `Normalize` module.

In your `build.zig`:

```zig
exe.root_module.addImport("Normalize", zg.module("Normalize"));
```

In your code:

```zig
const Normalize = @import("Normalize");

test "Normalize" {
    const normalize = try Normalize.init(allocator);
    defer normalize.deinit(allocator);

    // NFC: Canonical composition
    const nfc_result = try normalize.nfc(allocator, "Complex char: \u{3D2}\u{301}");
    defer nfc_result.deinit(allocator);
    try expectEqualStrings("Complex char: \u{3D3}", nfc_result.slice);

    // NFKC: Compatibility composition
    const nfkc_result = try normalize.nfkc(allocator, "Complex char: \u{03A5}\u{0301}");
    defer nfkc_result.deinit(allocator);
    try expectEqualStrings("Complex char: \u{038E}", nfkc_result.slice);

    // NFD: Canonical decomposition
    const nfd_result = try normalize.nfd(allocator, "Héllo World! \u{3d3}");
    defer nfd_result.deinit(allocator);
    try expectEqualStrings("He\u{301}llo World! \u{3d2}\u{301}", nfd_result.slice);

    // NFKD: Compatibility decomposition
    const nfkd_result = try normalize.nfkd(allocator, "Héllo World! \u{3d3}");
    defer nfkd_result.deinit(allocator);
    try expectEqualStrings("He\u{301}llo World! \u{3a5}\u{301}", nfkd_result.slice);

    // Test for equality of two strings after normalizing to NFC.
    try expect(try normalize.eql(allocator, "foé", "foe\u{0301}"));
    try expect(try normalize.eql(allocator, "foϓ", "fo\u{03D2}\u{0301}"));
}
```
The `Result` returned by normalization functions may or may not be copied from the
inputs given.  For example, an all-ASCII input does not need to be a copy, and will
be a view of the original slice.  Calling `result.deinit(allocator)` will only free
an allocated `Result`, not one which is a view.  Thus it is safe to do
unconditionally.

This does mean that the validity of a `Result` can depend on the original string
staying in memory.  To ensure that your `Result` is always a copy, you may call
`try result.toOwned(allocator)`, which will only make a copy if one was not
already made.


## Caseless Matching via Case Folding

Unicode provides a more efficient way of comparing strings while ignoring letter
case differences: case folding. When you case fold a string, it's converted into a
normalized case form suitable for efficient matching. Use the `CaseFold` module
for this.

In your `build.zig`:

```zig
exe.root_module.addImport("CaseFolding", zg.module("CaseFolding"));
```

In your code:

```zig
const CaseFolding = @import("CaseFolding");

test "Caseless matching" {
    // We need Unicode case fold data.
    const case_fold = try CaseFolding.init(allocator);
    defer case_fold.deinit(allocator);

    // `compatCaselessMatch` provides the deepest level of caseless
    // matching because it decomposes fully to NFKD.
    const a = "Héllo World! \u{3d3}";
    const b = "He\u{301}llo World! \u{3a5}\u{301}";
    try expect(try case_fold.compatCaselessMatch(allocator, a, b));

    const c = "He\u{301}llo World! \u{3d2}\u{301}";
    try expect(try case_fold.compatCaselessMatch(allocator, a, c));

    // `canonCaselessMatch` isn't as comprehensive as `compatCaselessMatch`
    // because it only decomposes to NFD. Naturally, it's faster because of this.
    try expect(!try case_fold.canonCaselessMatch(allocator, a, b));
    try expect(try case_fold.canonCaselessMatch(allocator, a, c));
}
```
Case folding needs to use the `Normalize` module in order to produce the compatibility
forms for comparison.  If you are already using a `Normalize` for other purposes,
`CaseFolding` can borrow it:

```zig
const CaseFolding = @import("CaseFolding");
const Normalize = @import("Normalize");

test "Initialize With a Normalize" {
    const normalize = try Normalize.init(allocator);
    // You're responsible for freeing this:
    defer normalize.deinit(allocator);
    const case_fold = try CaseFolding.initWithNormalize(allocator, normalize);
    // This will not free your normalize when it runs first.
    defer case_fold.deinit(allocator);
}
```
This has a `setupWithNormalize` variant as well, note that this also takes
a `Normalize` struct, and not a pointer to it.


## Display Width of Characters and Strings

When displaying text with a fixed-width font on a terminal screen, it's very
important to know exactly how many columns or cells each character should take.
Most characters will use one column, but there are many, like emoji and East-
Asian ideographs that need more space. The `DisplayWidth` module provides
methods for this purpose. It also has methods that use the display width calculation
to `center`, `padLeft`, `padRight`, and `wrap` text.

In your `build.zig`:

```zig
exe.root_module.addImport("DisplayWidth", zg.module("DisplayWidth"));
```

In your code:

```zig
const DisplayWidth = @import("DisplayWidth");

test "Display width" {
    const dw = try DisplayWidth.init(allocator);
    defer dw.deinit(allocator);

    // String display width
    try expectEqual(@as(usize, 5), dw.strWidth("Hello\r\n"));
    try expectEqual(@as(usize, 8), dw.strWidth("Hello 😊"));
    try expectEqual(@as(usize, 8), dw.strWidth("Héllo 😊"));
    try expectEqual(@as(usize, 9), dw.strWidth("Ẓ̌á̲l͔̝̞̄̑͌g̖̘̘̔̔͢͞͝o̪̔T̢̙̫̈̍͞e̬͈͕͌̏͑x̺̍ṭ̓̓ͅ"));
    try expectEqual(@as(usize, 17), dw.strWidth("슬라바 우크라이나"));

    // Centering text
    const centered = try dw.center(allocator, "w😊w", 10, "-");
    defer allocator.free(centered);
    try expectEqualStrings("---w😊w---", centered);

    // Pad left
    const right_aligned = try dw.padLeft(allocator, "abc", 9, "*");
    defer allocator.free(right_aligned);
    try expectEqualStrings("******abc", right_aligned);

    // Pad right
    const left_aligned = try dw.padRight(allocator, "abc", 9, "*");
    defer allocator.free(left_aligned);
    try expectEqualStrings("abc******", left_aligned);

    // Wrap text
    const input = "The quick brown fox\r\njumped over the lazy dog!";
    const wrapped = try dw.wrap(allocator, input, 10, 3);
    defer allocator.free(wrapped);
    const want =
        \\The quick
        \\brown fox
        \\jumped
        \\over the
        \\lazy dog!
    ;
    try expectEqualStrings(want, wrapped);
}
```

This module has build options.  The first is `cjk`, which will consider [ambiguous characters](https://www.unicode.org/reports/tr11/tr11-6.html) as double-width.

To choose this option, add it to the dependency like so:

```zig
const zg = b.dependency("zg", .{
    .cjk = true,
});
```

The other options are `c0_width` and `c1_width`.  The standard behavior is to treat
C0 and C1 control codes as zero-width, except for delete and backspace, which are
-1 (the logic ensures that a `strWidth` is always at least 0).  If printing
control codes with replacement characters, it's necessary to assign these a width,
hence the options.  When provided these values must fit in an `i4`, this allows
for C1s to be printed as `\u{80}` if desired.

`DisplayWidth` uses the `Graphemes` module internally.  If you already have one,
it can be borrowed using `DisplayWidth.initWithGraphemes(allocator, graphemes)`
in the same fashion as shown for `CaseFolding` and `Normalize`.

## Scripts

Unicode categorizes code points by the Script in which they belong.  A Script
collects letters and other symbols that belong to a particular writing system.
You can detect the Script for a code point with the `Scripts` module.

In your `build.zig`:

```zig
exe.root_module.addImport("Scripts", zg.module("Scripts"));
```

In your code:

```zig
const Scripts= @import("Scripts");

test "Scripts" {
    const scripts = try Scripts.init(allocator);
    defer scripts.deinit(allocator);

    // To see the full list of Scripts, look at the
    // `src/Scripts.zig` file. They are list in an enum.
    try expect(scripts.script('A') == .Latin);
    try expect(scripts.script('Ω') == .Greek);
    try expect(scripts.script('צ') == .Hebrew);
}
```

## Limits

Iterators, and fragment types such as `CodePoint`, `Grapheme` and
`Word`, use a `u32` to store the offset into a string, and the length of
the fragment (`CodePoint` uses a `u3` for length, actually).

4GiB is a lot of string.  There are a few reasons to work with that much
string, log files primarily, but fewer to bring it all into memory at
once, and practically no reason at all to do anything to such a string
without breaking it into smaller piece to work with.

Also, Zig compiles on 32 bit systems, where `usize` is a `u32`.  Code
running on such systems has no choice but to handle slices in smaller
pieces.  In general, if you want code to perform correctly when
encountering multi-gigabyte strings, you'll need to code for that, at a
level one or two steps above that in which you'll want to, for example,
iterate some graphemes of that string.

That all said, `zg` modules can be passed the Boolean config option
`fat_offset`, which will make all of those data structures use a `u64`
instead.  I added this option not because you should use it, which you
should not, but to encourage awareness that code operating on strings
needs to pay attention to the size of those strings, and have a plan for
when sizes get out of specification.  What would your code do with a
1MiB region of string with no newline?  There are many questions of this
nature, and robust code must detect when data is out of the expected
envelope, so it can respond accordingly.

Code which does pay attention to these questions has no need for `u64`
sized offsets, and code which does not will not be helped by them.  But
perhaps yours is an exception, in which case, by all means, configure
accordingly.

const Expect = @import("Expect.zig");

test "flex row with justify-start places two boxes at the beginning of the container" {
    try Expect.layoutExample(
        \\<?xml version="1.0" standalone="yes" ?>
        \\<root class="flex flex-row bg-glyph-[.]">
        \\  <box class="w-4 h-3 bg-glyph-[a]" />
        \\  <box class="w-4 h-3 bg-glyph-[b]" />
        \\</root>
    ,
        \\aaaabbbb.......
        \\aaaabbbb.......
        \\aaaabbbb.......
        \\aaaabbbb.......
        \\aaaabbbb.......
    );
}

test "flex row with items-stretch makes children fill the container's cross axis" {
    try Expect.layoutExample(
        \\<?xml version="1.0" standalone="yes" ?>
        \\<root class="h-5 bg-glyph-[.]">
        \\  <box class="h-3 flex flex-row items-stretch">
        \\    <box class="w-4 bg-glyph-[a]" />
        \\    <box class="w-4 bg-glyph-[b]" />
        \\  </box>
        \\</root>
    ,
        \\aaaabbbb.......
        \\aaaabbbb.......
        \\aaaabbbb.......
        \\aaaabbbb.......
        \\aaaabbbb.......
    );
}

test "flex row with justify-center centers boxes horizontally in the container" {
    try Expect.layoutExample(
        \\<root class="flex flex-row justify-center bg-glyph-[.]">
        \\  <box class="w-4 h-3 bg-glyph-[a]" />
        \\  <box class="w-4 h-3 bg-glyph-[b]" />
        \\</root>
    ,
        \\...aaaabbbb...
        \\...aaaabbbb...
        \\...aaaabbbb...
        \\...aaaabbbb...
        \\...aaaabbbb...
        \\
    );
}

test "flex row with justify-between places first and last items at container edges" {
    try Expect.layoutExample(
        \\<root class="flex flex-row justify-between bg-glyph-[.]">
        \\  <box class="w-4 h-3 bg-glyph-[a]" />
        \\  <box class="w-4 h-3 bg-glyph-[b]" />
        \\</root>
    ,
        \\aaaa......bbbb
        \\aaaa......bbbb
        \\aaaa......bbbb
        \\aaaa......bbbb
        \\aaaa......bbbb
        \\
    );
}

test "flex-grow distributes available space proportionally among growing children" {
    try Expect.layoutExample(
        \\<root class="flex flex-row bg-glyph-[.]">
        \\  <box class="w-2 h-2 grow-1 bg-glyph-[a]" />
        \\  <box class="w-2 h-2 grow-2 bg-glyph-[b]" />
        \\  <box class="w-2 h-2 grow-1 bg-glyph-[c]" />
        \\</root>
    ,
        \\aaaabbbbbccc
        \\aaaabbbbbccc
        \\aaaabbbbbccc
        \\aaaabbbbbccc
        \\
    );
}

test "flex row with justify-around creates equal space around each item" {
    try Expect.layoutExample(
        \\<root class="flex flex-row justify-around bg-glyph-[.]">
        \\  <box class="w-2 h-2 bg-glyph-[a]" />
        \\  <box class="w-2 h-2 bg-glyph-[b]" />
        \\  <box class="w-2 h-2 bg-glyph-[c]" />
        \\</root>
    ,
        \\.aa..bb..cc.
        \\.aa..bb..cc.
        \\.aa..bb..cc.
        \\.aa..bb..cc.
        \\
    );
}

test "align-self property overrides the container's align-items for individual children" {
    try Expect.layoutExample(
        \\<root class="flex flex-row items-start bg-glyph-[.] h-4">
        \\  <box class="w-4 h-2 self-center bg-glyph-[a]" />
        \\  <box class="w-4 h-2 bg-glyph-[b]" />
        \\</root>
    ,
        \\....bbbb....
        \\aaaabbbb....
        \\aaaa........
        \\............
        \\
    );
}

test "flex column with single growing child fills entire container height" {
    try Expect.layoutExample(
        \\<root class="flex flex-col bg-glyph-[.] h-16">
        \\  <box class="w-4 grow-1 bg-glyph-[a]" />
        \\</root>
    ,
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
    );
}

test "flex column with one growing and one fixed child distributes space correctly" {
    try Expect.layoutExample(
        \\<root class="flex flex-col bg-glyph-[.] h-16">
        \\  <box class="w-4 grow-1 bg-glyph-[a]" />
        \\  <box class="w-4 h-1 bg-glyph-[b]" />
        \\</root>
    ,
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\aaaa
        \\bbbb
    );
}

test "flex column with items-center aligns children horizontally while growing vertically" {
    try Expect.layoutExample(
        \\<root class="flex flex-col items-center bg-glyph-[.] w-8 h-16">
        \\  <box class="w-4 grow-1 bg-glyph-[a]" />
        \\  <box class="w-4 h-1 bg-glyph-[b]" />
        \\</root>
    ,
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..aaaa..
        \\..bbbb..
    );
}

test "text nodes render inside flex containers and respect their layout properties" {
    try Expect.layoutExample(
        \\<root class="flex flex-col bg-glyph-[.] h-4">
        \\  <box class="w-3 grow-1 bg-glyph-[a]">foo</box>
        \\  <box class="w-3 grow-1 bg-glyph-[b]">bar</box>
        \\</root>
    ,
        \\fooa
        \\aaaa
        \\barb
        \\bbbb
    );
}

test "text nodes containing newline characters render on multiple lines" {
    try Expect.layoutExample(
        \\<root class="w-5 h-5 bg-glyph-[.]">Line1
        \\Line2
        \\Line3</root>
    ,
        \\Line1
        \\Line2
        \\Line3
        \\.....
        \\.....
    );
}

test "overflow-y-scroll containers automatically scroll to show bottom content" {
    try Expect.layoutExample(
        \\<root class="flex flex-col w-6 h-5 bg-glyph-[.]">
        \\  <box class="h-1 w-6 bg-glyph-[.]"></box>
        \\  <box class="flex flex-col overflow-y-scroll h-4 w-6">
        \\    <box class="h-2 w-6 bg-glyph-[a]"></box>
        \\    <box class="h-2 w-6 bg-glyph-[b]"></box>
        \\    <box class="h-2 w-6 bg-glyph-[c]"></box>
        \\  </box>
        \\</root>
    ,
        \\......
        \\bbbbbb
        \\bbbbbb
        \\cccccc
        \\cccccc
    );
}

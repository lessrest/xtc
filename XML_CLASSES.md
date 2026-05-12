# XTC XML Class Cheatsheet

XTC XML uses Tailwind-like utility tokens in the `class` attribute:

```xml
<root class="flex flex-col bg-gray-900 text-white">
  <box class="w-10 h-2 bg-glyph-[#]" />
</root>
```

Unknown tokens are ignored by the current parser.

## Display

- `inline` default
- `block`
- `flex`
- `inline-flex`

## Flex Layout

- Direction: `flex-row`, `flex-col`, `flex-row-reverse`, `flex-col-reverse`
- Grow: `grow`, `grow-N`, `flex-1`
- Justify: `justify-start`, `justify-end`, `justify-center`, `justify-between`, `justify-around`, `justify-evenly`
- Align items: `items-start`, `items-end`, `items-center`, `items-stretch`, `items-baseline`
- Align self: `self-start`, `self-end`, `self-center`, `self-stretch`

`flex-1` sets grow and shrink to `1`. There is no parsed `shrink-*` token yet.

## Size

- Width: `w-N`
- Height: `h-N`

Sizes are terminal cells.

## Padding

- All sides: `p-N`
- Horizontal: `px-N`
- Vertical: `py-N`
- Edges: `pl-N`, `pr-N`, `pt-N`, `pb-N`

Padding values are clamped to `0..15`.

## Border

- Width/style: `border`, `border-N`
- Styles: `border-solid`, `border-double`, `border-dashed`, `border-block`
- Color: `border-COLOR`

`border-block` is an XTC extension that paints filled border cells.

## Overflow

- Y-axis shorthand: `overflow-visible`, `overflow-hidden`, `overflow-scroll`
- X-axis: `overflow-x-visible`, `overflow-x-hidden`, `overflow-x-scroll`
- Y-axis: `overflow-y-visible`, `overflow-y-hidden`, `overflow-y-scroll`

## Colors

Use the same color suffixes with:

- Foreground: `text-COLOR`
- Background: `bg-COLOR`
- Border: `border-COLOR`

Supported color families:

- `red`, `orange`, `amber`, `yellow`, `lime`, `green`, `emerald`, `teal`, `cyan`, `sky`, `blue`, `indigo`, `violet`, `purple`, `fuchsia`, `pink`, `rose`
- `slate`, `gray`, `zinc`, `neutral`, `stone`

Supported shades for those families:

- `50`, `100`, `200`, `300`, `400`, `500`, `600`, `700`, `800`, `900`, `950`

Special colors:

- `black`
- `white`

Examples:

- `text-cyan-300`
- `bg-gray-900`
- `border-blue-500`
- `text-white`
- `bg-black`

## Glyph Fill

`bg-glyph-[x]` fills an element's box with one UTF-8 scalar/glyph.

Examples:

- `bg-glyph-[a]`
- `bg-glyph-[#]`
- `bg-glyph-[.]`

This is especially useful with `--xml` stdout rendering:

```sh
zig-out/bin/xtc --xml '<root class="flex"><box class="w-4 h-2 bg-glyph-[a]"/></root>' --width 8 --height 4
```

Plain XML output omits ANSI color escapes. Add `--ansi` to see `text-*`,
`bg-*`, and `border-*` colors in a terminal:

```sh
zig-out/bin/xtc --xml '<root class="flex bg-black"><box class="w-10 h-3 bg-blue-600 text-yellow-200 bg-glyph-[#]"/></root>' --width 12 --height 5 --ansi
```

## Common Gotchas

These tokens appear in some demos but are not currently parsed by `src/miniflex/tailwind.zig`:

- Margins: `m-*`, `mt-*`, `mb-*`, `mx-*`, etc.
- Positioning: `absolute`, `relative`, `left-*`, `top-*`
- Text flags/sizes: `bold`, `font-bold`, `text-xs`, `text-center`
- Opacity/gradients: `opacity-*`, `bg-gradient-*`, `from-*`, `to-*`
- Gaps and wrapping: `gap-*`, `flex-wrap`, `flex-nowrap`
- Order/z-index: `order-*`, `z-*`

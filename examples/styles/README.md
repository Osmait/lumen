# Styles

Four complete looks for Lumen, each an `init.lua` (the window's structure
with `lumen.layout`, a theme, a few settings) and a `style.css` (the finer
details).

![Raycast, Spotlight, Alfred and Minimal](../../assets/screenshots/styles.png)

| | |
|---|---|
| [`raycast`](raycast) | One panel, a footer that says what Enter does, subtitles beside titles, a grey selection. |
| [`spotlight`](spotlight) | A large search field with a magnifier, compact rows with titles only, macOS blue. |
| [`alfred`](alfred) | A framed search field inside the panel, tall rows with large icons. |
| [`minimal`](minimal) | rofi-like: text only, monospace, square, the search field at the bottom. |

To use one:

```sh
cp examples/styles/raycast/init.lua ~/.config/lumen/init.lua
cp examples/styles/raycast/style.css ~/.config/lumen/style.css
lumen --reload
```

If you already have an `init.lua`, paste the style's `lumen.theme`,
`lumen.set` and `lumen.layout` calls into it instead. Every option is in
[EXTENSIONS.md](../../EXTENSIONS.md#layout).

They imitate the look, not the trade marks: no logos, and the fonts are the
ones on your system (the originals use Apple's SF Pro).

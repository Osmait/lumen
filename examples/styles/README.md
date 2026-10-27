# Styles

Complete looks for Lumen, each an `init.lua` (the window's structure with
`lumen.layout`, themes, a few settings) and a `style.css` (the finer
details). They are built into Lumen: search **Change Theme**, and the
**Styles** at the top switch the whole look at once; the themes below them
then recolour it.

![Raycast, Spotlight, Alfred and Minimal](../../assets/screenshots/styles.png)

| | |
|---|---|
| [`raycast`](raycast) | One panel, a footer that says what Enter does, subtitles beside titles, a grey selection. |
| [`spotlight`](spotlight) | A large search field with a magnifier, compact rows with titles only, macOS blue. |
| [`alfred`](alfred) | A framed search field inside the panel, tall rows with large icons. |
| [`minimal`](minimal) | rofi-like: text only, monospace, square, the search field at the bottom. |
| [`omarchy`](omarchy) | Omarchy's menu: a square card with a 2px border, monospace, "Go…", the screen dimmed behind. All 23 Omarchy palettes, and on Omarchy it follows the theme you pick there. |

![Lumen styled as Omarchy's menu, Tokyo Night](../../assets/screenshots/style-omarchy.png)

On Omarchy, make Lumen switch with the system theme at once: install the
hook that comes with the style,

```sh
install -Dm755 examples/styles/omarchy/theme-set-hook ~/.config/omarchy/hooks/theme-set.d/lumen
```

(without it, Lumen picks the new theme up the next time its window opens).

## Your own

A folder in `~/.config/lumen/styles` is a style too, listed under
**Custom**: an `init.lua`, a `style.css`, or both. Start from one of these:

```sh
mkdir -p ~/.config/lumen/styles
cp -r examples/styles/omarchy ~/.config/lumen/styles/my-look
```

A folder named like a built-in style (`styles/raycast`) replaces it. How a
style is loaded, and the options, are in
[EXTENSIONS.md](../../EXTENSIONS.md#styles).

They imitate the look, not the trade marks: no logos, and no fonts shipped.
The Raycast, Spotlight and Alfred styles use Apple's SF Pro when it is
installed on your system and Inter otherwise. Any font can be used the same
way, in style.css:

```css
.shell, .actions { font-family: "Your Font", "Inter", sans-serif; }
```

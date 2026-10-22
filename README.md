# Kosmolit Lockscreen

A [KOReader](https://github.com/koreader/koreader) plugin that turns your sleep
screen into a random glitch-art collage. Each time the device goes to sleep it
picks two images from its `img/` folder and combines them with one of 21
effects: scanline glitches, halftone print, 1-bit dithering, wave distortion,
mirrored panels, cut-out windows and more.

Images with transparency keep it: with **No fill** set as the sleep screen
background, the page you were reading shows through the transparent parts. The
effects only touch the images, so the text underneath stays clean.

## Installation

1. **Download the plugin.** Either clone this repository or download it as a
   ZIP (green **Code** button → **Download ZIP**) and unzip it.

2. **Rename the folder to `kosmolitifier.koplugin`.** KOReader only loads
   plugin folders whose names end in `.koplugin`. The folder must contain
   `_meta.lua`, `main.lua`, `composer.lua` and the `img/` folder directly, not
   inside another subfolder.

3. **Copy it into KOReader's `plugins` folder** on your device. Connect the
   device over USB (or use KOReader's SSH / file manager) and copy the whole
   folder to:

   | Device     | Plugins folder                                    |
   |------------|---------------------------------------------------|
   | Kindle     | `koreader/plugins/` (on the Kindle drive's root)  |
   | Kobo       | `.adds/koreader/plugins/` (hidden folder)         |
   | PocketBook | `applications/koreader/plugins/`                  |
   | Android    | `koreader/plugins/` in internal storage           |

   You should end up with, for example on a Kindle:

   ```
   koreader/plugins/kosmolitifier.koplugin/_meta.lua
   koreader/plugins/kosmolitifier.koplugin/main.lua
   koreader/plugins/kosmolitifier.koplugin/composer.lua
   koreader/plugins/kosmolitifier.koplugin/img/...
   ```

4. **Restart KOReader** (top menu → **Exit** → **Restart KOReader**, or just
   close and reopen it).

5. **Check the plugin is enabled:** top menu → **Tools** (wrench) →
   **More tools** → **Plugin management**. **Kosmolit Lockscreen** should be
   ticked.

## Turning it on

1. Open the top menu → **Settings** (gear) → **Screen** → **Sleep screen** →
   **Wallpaper**.
2. Select **Kosmolit (randomised wallpaper)**.
3. Optional: to see your book page behind transparent images, go to
   **Wallpaper** → **Border fill, rotation, and fit** and choose **No fill**.
   **White fill** or **Black fill** fills transparent areas with that colour
   instead.

Put the device to sleep to see the result. Every sleep gives a new combination.

## Adding your own images

Drop `.png`, `.jpg` or `.jpeg` files into the plugin's `img/` folder. Any
size works (images are stretched to fill the screen), but they look best close
to your screen's resolution and aspect ratio, e.g. 1072×1448 on a Kindle
Paperwhite. PNGs with transparent backgrounds work especially well with
**No fill**.

## Effects

| #  | Effect            | What it does                                                    |
|----|-------------------|-----------------------------------------------------------------|
| 1  | `scanline_glitch` | Bands from two images, some shifted sideways                    |
| 2  | `pixel_dither`    | Checkerboard interleave of two images                           |
| 3  | `data_corrupt`    | A few bursts of horizontally shifted rows                       |
| 4  | `inversion_zones` | Random inverted rectangles over a base image                    |
| 5  | `double_exposure` | Two images blended by keeping the darker or lighter pixel       |
| 6  | `column_drift`    | Wide column bands with random vertical offsets                  |
| 7  | `slice_offset`    | Some vertical slices nudged up or down                          |
| 8  | `threshold_mix`   | One image shows through the dark (or light) areas of the other  |
| 9  | `tile_shuffle`    | Grid of tiles, some swapped with tiles from either image        |
| 10 | `mirror_split`    | One side of the image mirrored onto the other                   |
| 11 | `wave_shift`      | Rows displaced along a sine wave                                |
| 12 | `melt`            | Pixels dripping down from a wandering line                      |
| 13 | `pixelate_zones`  | A few rectangles turned into big blocky pixels                  |
| 14 | `echo_stack`      | One image shrunk into a framed window, repeated diagonally      |
| 15 | `scanner_smear`   | A row frozen and dragged down, like a page moved mid-scan       |
| 16 | `halftone_blocks` | Newspaper-style black squares sized by darkness                 |
| 17 | `bayer_1bit`      | Pure black-and-white ordered dither                             |
| 18 | `window_cutouts`  | Framed holes showing the background through the image           |
| 19 | `stencil`         | One image's silhouette filled with the other image              |
| 20 | `shadow_echo`     | The silhouette repeated at an offset behind the image           |
| 21 | `split_flip`      | 2–4 panels from either image, some flipped or mirrored          |

## Troubleshooting

- **The Kosmolit option doesn't appear in the Wallpaper menu:** make sure the
  folder name ends in `.koplugin`, the plugin is ticked in **Plugin
  management**, and KOReader has been restarted.
- **The normal sleep screen shows instead:** if the plugin can't find or load
  any images it falls back to KOReader's default. Check that `img/` is inside
  the plugin folder and contains PNG/JPG files.
- **Which effect was used?** Enable debug logging (top menu → **Tools** →
  **More tools** → **Developer options** → **Enable debug logging**). Each sleep
  writes a line like `Kosmolitifier: style = halftone_blocks` to
  `koreader/crash.log`.
- **Landscape reading:** the sleep screen is always shown in portrait. With
  **No fill**, a page read in landscape appears sideways behind the images,
  the same as with KOReader's built-in sleep screen.

## Uninstalling

Pick a different option under **Sleep screen** → **Wallpaper**, then delete the
`kosmolitifier.koplugin` folder from KOReader's `plugins` folder and restart
KOReader.

## License

GNU AGPL v3, see [LICENSE](LICENSE).

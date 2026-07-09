# FontForge Fusion Right-Click Helper

A tiny Windows helper for making fonts behave better in Autodesk Fusion 360.

If you normally open a font in FontForge, select every glyph, run **Overlap > Remove Overlap**, rename the font so Windows sees it as a new font, and then install it, this project automates that workflow from the Windows right-click menu.

## What It Does

- Adds a **Make Fusion Font** right-click action for `.ttf` and `.otf` files.
- Adds a fallback context-menu entry for Windows' special Fonts shell view.
- Runs FontForge headlessly through its bundled `ffpython.exe`.
- Removes overlaps from every glyph in the font.
- Creates a separate font identity named `FUSION <original font name>`.
- Uses a human-readable installed filename such as `FUSION Bahnschrift Regular.ttf` so Windows' Fonts search has a better chance of finding it.
- Installs the repaired font into `C:\Windows\Fonts`.
- Stops if a matching `FUSION ...` font already appears to be installed.
- Runs only when you right-click a font. There is no background service.

The source font is never modified.

## Requirements

- Windows
- [FontForge for Windows](https://fontforge.org/en-US/downloads/windows/)
- PowerShell 5.1 or newer
- Administrator permission when installing the repaired font system-wide

By default the helper looks for FontForge here:

```powershell
C:\Program Files\FontForgeBuilds\bin\ffpython.exe
```

If your FontForge install is somewhere else, set `FUSION_FONTFORGE_FFPYTHON` to the full path of `ffpython.exe`.

## Install

Clone or download this repository, open PowerShell in the project folder, and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-ContextMenu.ps1
```

After that, right-click a `.ttf` or `.otf` file and choose **Make Fusion Font**.

On Windows 11 the item may appear under **Show more options** depending on your Explorer settings. The installer also adds an all-file fallback entry so the command can appear inside Windows' virtual Fonts folder; the repair script still refuses non-font files.

## Use

1. Right-click a `.ttf` or `.otf` font file.
2. Choose **Make Fusion Font**.
3. Approve the Windows administrator prompt.
4. Wait for the success message.
5. Restart Fusion 360 if it was already open.
6. Pick the new `FUSION ...` font in Fusion 360.

The generated font uses:

- Family name: `FUSION <original full font name>`
- Full name: `FUSION <original full font name>`
- PostScript name: `FUSION-<sanitized-original-name>`

## Generate Without Installing

For testing or manual inspection, you can generate the repaired font without installing it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Repair-FusionFont.ps1 "C:\Path\To\Font.ttf" -NoInstall
```

To choose an output folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Repair-FusionFont.ps1 "C:\Path\To\Font.ttf" -NoInstall -OutputDirectory "C:\Path\To\Output"
```

## Uninstall The Right-Click Menu

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-ContextMenu.ps1
```

This removes the Explorer context-menu entry. It does not uninstall any fonts you already generated.

## Duplicate Font Behavior

The helper intentionally stops if a matching `FUSION ...` font file or Windows Fonts registry entry already exists.

That keeps accidental reruns from overwriting an installed font. If you want to regenerate a font, uninstall the previous `FUSION ...` font from Windows first, then run the helper again.

## Supported Files

Supported in v1:

- `.ttf`
- `.otf`

Not currently supported:

- `.ttc`
- `.otc`
- folders or batch processing

## How It Works

`Repair-FusionFont.ps1` is the Windows entrypoint. It validates the font file, self-elevates when a system-wide install is needed, calls `fusion_font_repair.py` through FontForge's Python runtime, copies the generated font into `C:\Windows\Fonts`, writes the Windows font registry entry, and broadcasts a font-change notification.

`fusion_font_repair.py` opens the source font through FontForge, rewrites the internal name table, runs `glyph.removeOverlap()` for each glyph, and generates the repaired font file.

## Troubleshooting

**FontForge cannot be found**

Install FontForge for Windows or set `FUSION_FONTFORGE_FFPYTHON`:

```powershell
$env:FUSION_FONTFORGE_FFPYTHON = "C:\Path\To\ffpython.exe"
```

**The menu item does not appear**

Run `Install-ContextMenu.ps1` again. On Windows 11, also check **Show more options** in the right-click menu.

**Fusion 360 does not show the new font**

Close and reopen Fusion 360. Some apps only refresh the font list on startup.

**The helper says the Fusion font already exists**

Uninstall the old `FUSION ...` font from Windows Settings or Control Panel, then run the helper again.

**A PowerShell window flashes and disappears**

Check the log at:

```powershell
$env:TEMP\FusionFontRepair\FusionFontRepair.log
```

The helper also tries to resolve Windows' virtual Fonts-folder display paths back to the real `.ttf` or `.otf` file before installing.

## License

MIT. Use it, tweak it, share it.

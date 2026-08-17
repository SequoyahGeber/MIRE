# MIRE inventory icons

Batch A-042a renders 24 inventory icons — every A-002 world pickup and every A-004 tool and weapon —
as transparent 256×256 PNGs. Runtime files are in `exports/`; `catalog.json` records the source GLB,
framing, and polygon count behind each one.

**There is no icon art.** Each icon is an orthographic render of a GLB that already ships in
`assets/`, so an icon cannot drift from the model it stands for. The generator
(`tools/blender/render_item_icons.py`) is a camera, not a second art pass — when a model changes,
re-running it is the entire update.

## Included icons

| Family | Icons |
|---|---|
| Wood | `log`, `branch`, `fibre_bundle` |
| Minerals | `stone`, `flint`, `coal`, `iron_ore`, `iron_ingot`, `salvage_fragment` |
| Food | `berry`, `mushroom`, `raw_meat` |
| Currency | `coin`, `coin_stack` |
| Tools | `wooden_axe`, `stone_axe`, `wooden_pickaxe`, `stone_pickaxe`, `iron_pickaxe`, `repair_hammer` |
| Weapons | `cleaver`, `skewer`, `short_bow`, `arrow` |

File names are `icon_<id>.png`, where `<id>` matches the `ItemDef.id` for items that have one. Wire an
icon by setting `icon` on the `.tres` in `content/items/`; `iron_ore`, `log`, `stone`, and `stone_axe`
are already wired. `preview/item_icons_sheet.png` is the full set over the UI background.

## Framing

Framing is measured, not hand-tuned. Each asset's vertices are projected into camera space, the
script tries the icon upright and rolled 45°, keeps whichever packs the silhouette into the smaller
square, then centres and scales the camera on those bounds. That is how a 1.97 m skewer and a 12 cm
coin both fill their slot without per-item numbers. Only the yaw is authored, in `AZIMUTH`, for assets
whose default face is not their best one.

The rig renders in **Cycles with a pinned seed**, not EEVEE. EEVEE resolved anti-aliasing on thin
silhouettes — a cleaver edge, a pick tip — a few samples differently between runs, so the icons were
not reproducible; the whole 24-icon pass costs about 10 seconds in Cycles. Two consecutive rebuilds
are pixel-identical on every channel of every icon. The PNG bytes themselves can still differ by a
few bytes of encoder metadata, so compare decoded pixels, not file hashes.

These are presentation assets. They carry no item definition, stack rule, value, or network
authority: what a stack holds stays host-authoritative (`docs/ARCHITECTURE.md` §2.2).

## Rebuild and verify

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python tools/blender/render_item_icons.py
```

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/item_icons_check.gd
```

The check asserts all 24 icons import as 256×256 `Texture2D`, that each catalog source GLB still
exists, that every `ItemDef` in `content/items/` carries an icon, and that the A-004 exports still
load and instantiate with geometry.

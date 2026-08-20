extends RefCounted

## IslandMinimap — MENU-4: a silhouette of the island a seed actually produces (docs/MENU.md §5).
##
## Used by the expedition dock so choosing a seed stops being an act of faith: you type a word and
## see the coastline you would land on. `MENU-7`'s run summary reuses it to show the island a run
## was lost on.
##
## Use by preload, never as a bare identifier (SPECS.md standing rule 1):
##     const IslandMinimap := preload("res://ui/frontend/island_minimap.gd")
##
## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2): none — pure presentation, derived from a seed by
## the same pure function the world generates from. Nothing here is replicated; a client rendering
## a preview of the host's seed is drawing a picture, not claiming any world state.
##
## Sampling the real `IslandHeightmap` rather than approximating it is the whole point: an
## approximation would eventually disagree with the island the player lands on, and a preview you
## cannot trust is worse than no preview.

const Heightmap := preload("res://world/gen/island_heightmap.gd")
const MireTheme := preload("res://ui/theme/mire_theme.gd")

## Half-width of the sampled square, in metres. A little past the island's own radius so the
## coastline is never clipped by the frame.
const PATCH_EXTENT: float = 132.0

## Pixels per side. 128 is ~16k height samples — under a tenth of a second, and enough to read a
## coastline's lobes and inlets at the size the dock shows it. Raising it buys detail nobody can see
## at 200 px on screen and makes every keystroke in the seed field cost real time.
const RESOLUTION: int = 128

const COLOUR_DEEP := Color(0.035, 0.070, 0.065)
const COLOUR_SHALLOW := Color(0.075, 0.135, 0.120)
const COLOUR_BEACH := Color(0.62, 0.57, 0.42)
const COLOUR_LOW := Color(0.26, 0.40, 0.23)
const COLOUR_HIGH := Color(0.42, 0.42, 0.39)

## Height thresholds in metres, matching the backdrop's banding so the preview and the title screen
## describe the same island the same way.
const BAND_BEACH: float = 1.2
const BAND_LOW: float = 9.0


## Renders the island for `world_seed` as a top-down silhouette.
static func texture_for_seed(world_seed: int, resolution: int = RESOLUTION) -> ImageTexture:
	return ImageTexture.create_from_image(image_for_seed(world_seed, resolution))


static func image_for_seed(world_seed: int, resolution: int = RESOLUTION) -> Image:
	var image: Image = Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)
	var noise_set: Variant = Heightmap.make_noise_set(world_seed)
	var step: float = (PATCH_EXTENT * 2.0) / float(resolution)

	for py: int in resolution:
		var z: float = -PATCH_EXTENT + (float(py) + 0.5) * step
		for px: int in resolution:
			var x: float = -PATCH_EXTENT + (float(px) + 0.5) * step
			var height: float = float(Heightmap.height_from_set(x, z, noise_set, world_seed))
			image.set_pixel(px, py, _band(height))
	return image


## Land above water, water below, with a shallows band so the coastline reads as a shore rather than
## as a hard cut — at 128 px the difference between "an island" and "a green blob" is mostly this.
static func _band(height: float) -> Color:
	if height <= 0.0:
		# Shallow water hugs the coast: the closer to zero, the closer to the beach colour.
		var shallowness: float = clampf((height + 6.0) / 6.0, 0.0, 1.0)
		return COLOUR_DEEP.lerp(COLOUR_SHALLOW, shallowness)
	if height < BAND_BEACH:
		return COLOUR_BEACH
	if height < BAND_LOW:
		return COLOUR_LOW
	return COLOUR_HIGH


## The framed control the dock and the summary both drop straight into a layout: the silhouette at a
## fixed square size, nearest-neighbour so the sampling stays crisp instead of turning to mush.
static func preview_rect(world_seed: int, side: float = 200.0) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture_for_seed(world_seed)
	rect.custom_minimum_size = Vector2(side, side)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect

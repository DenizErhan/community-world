extends RefCounted
## Loads generated SVG art (assets/) and rasterizes it at runtime.
## Rasterizing at a fixed supersample (grid.raster_scale in design/tokens.json) keeps
## sprites crisp at the maximum zoom while mipmaps keep them smooth when zoomed out.

static var _cache: Dictionary = {}


static func ground_path(age: String, variant: String) -> String:
	return "res://assets/ground/ground_%s_%s.svg" % [age, variant]


static func building_path(id: String, age: String) -> String:
	return "res://assets/buildings/%s_%s.svg" % [id, age]


static func load_svg(path: String, scale: float) -> Texture2D:
	if _cache.has(path):
		return _cache[path]
	var svg_text := FileAccess.get_file_as_string(path)
	if svg_text == "":
		push_error("Missing asset: " + path)
		return null
	var img := Image.new()
	if img.load_svg_from_string(svg_text, scale) != OK:
		push_error("Could not rasterize asset: " + path)
		return null
	img.fix_alpha_edges()  # bleed color into transparent texels so mipmaps don't darken sprite edges
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_cache[path] = tex
	return tex

extends RefCounted
## Tiny localization layer.
## Strings live in res://data/locales/<code>.json (flat "key": "text" maps).
## To add a language: drop <code>.json next to en.json and add the code to SUPPORTED.
## Missing keys fall back to English, then to the key itself (so gaps are visible, never crash).
## Text uses {placeholder} style: Loc.t("toast.built", {"name": "Farm"}).

const SUPPORTED := ["en"]
const FALLBACK := "en"
const LOCALE_DIR := "res://data/locales/"

static var lang: String = "en"
static var _strings: Dictionary = {}
static var _fallback: Dictionary = {}


static func init_locale(preferred: String = "") -> void:
	var code := preferred
	if code == "":
		code = OS.get_locale_language()
	if not SUPPORTED.has(code):
		code = FALLBACK
	lang = code
	_fallback = _read(FALLBACK)
	if code == FALLBACK:
		_strings = _fallback
	else:
		_strings = _read(code)


static func t(key: String, args: Dictionary = {}) -> String:
	var s: String = String(_strings.get(key, _fallback.get(key, key)))
	if args.is_empty():
		return s
	return s.format(args)


static func _read(code: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LOCALE_DIR + code + ".json"))
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	return {}

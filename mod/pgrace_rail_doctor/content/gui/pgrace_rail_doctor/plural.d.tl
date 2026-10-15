-- Pure plural rules (no api.* calls), so tests/plural_test.lua can run them in plain Lua.
global record PgraceRailDoctorPlural
	-- The CLDR plural category ("one", "few", "many" or "other") for a count in a language code from
	-- app.getUserProfile():getLanguage().code. Copied from Commuter Compass's rank.pluralCategory.
	category : function(language : string, count : integer) : string
end

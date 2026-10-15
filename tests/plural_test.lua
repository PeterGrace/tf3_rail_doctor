local t = ...
local plural = t.requireTl("gui/pgrace_rail_doctor/plural.tl")

t.test("plural: one/other languages", function()
	for _, lang in ipairs({ "en", "de", "es", "it", "nl" }) do
		t.eq(plural.category(lang, 1), "one")
		t.eq(plural.category(lang, 0), "other")
		t.eq(plural.category(lang, 3), "other")
	end
end)

t.test("plural: French and Brazilian Portuguese count 0 as one", function()
	for _, lang in ipairs({ "fr", "pt_BR" }) do
		t.eq(plural.category(lang, 0), "one")
		t.eq(plural.category(lang, 3), "other")
	end
end)

t.test("plural: Polish one/few/many", function()
	t.eq(plural.category("pl", 1), "one")
	t.eq(plural.category("pl", 3), "few")
	t.eq(plural.category("pl", 5), "many")
	t.eq(plural.category("pl", 12), "many")
	t.eq(plural.category("pl", 22), "few")
end)

t.test("plural: Russian one/few/many", function()
	t.eq(plural.category("ru", 21), "one")
	t.eq(plural.category("ru", 11), "many")
	t.eq(plural.category("ru", 3), "few")
	t.eq(plural.category("ru", 14), "many")
end)

t.test("plural: Japanese, Korean, Chinese have one form", function()
	for _, lang in ipairs({ "ja", "ko", "zh_CN", "zh_TW" }) do
		t.eq(plural.category(lang, 1), "other")
		t.eq(plural.category(lang, 3), "other")
	end
end)

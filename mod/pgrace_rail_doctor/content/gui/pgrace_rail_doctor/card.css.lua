local ssu = require "::/gui/main/stylesheetutil.lua"

-- The locate pin on clickable rows. An AutoFit ImageView in a card shrinks to nothing without a size.
function data()
	local result = {}
	local a = ssu.makeAdder(result)
	a("ImageView!pgrace-rail-doctor-pin", { size = { 16, 16 } })
	return result
end

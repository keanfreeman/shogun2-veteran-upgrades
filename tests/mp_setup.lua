-- Multiplayer runs: each clan has one army with a general and four units (the same addresses on every
-- machine, like the game's unit ids), and helpers for the runner (tests/run_tests.py, run_mp).
-- The unit type under test: Yari Ashigaru, whatever this edition's data calls its key and lines.
for _, f in ipairs(VU_UNDER_TEST.families) do if f.name == "Yari Ashigaru" and #f.copies > 0 then MOCK.yari = f end end
assert(MOCK.yari, "no Yari Ashigaru unit type with an ability")
MOCK.yari_key = MOCK.yari.copies[1].base
for _, l in ipairs(MOCK.yari.lines) do if l.kind == "ability" and not MOCK.yari_ability then MOCK.yari_ability = l.label end end
MOCK.forces = {
	shimazu = { { Address = "CHAR:shimazu1", Name = "Shimazu army", PosX = 0, PosY = 0 } },
	oda = { { Address = "CHAR:oda1", Name = "Oda army", PosX = 50, PosY = 50 } },
}
MOCK.force_units = {}
for faction, armies in pairs(MOCK.forces) do
	local units = {}
	for i = 1, 4 do
		local u = "UNIT:" .. faction .. i
		units[i] = u
		MOCK.unit_details[u] = { UnitRecord = { Key = MOCK.yari_key }, Experience = 0, Men = 160,
			CharacterPtr = i == 1 and armies[1].Address or nil }
		MOCK.names[u] = ""
	end
	MOCK.force_units[armies[1].Address] = units
end

-- Applied game state, for comparing machines: bundles and copy locks, sorted.
function MOCK.model()
	local out = {}
	for k in pairs(MOCK.bundles) do out[#out + 1] = "bundle " .. k end
	for k in pairs(MOCK.locks) do out[#out + 1] = "lock " .. k end
	table.sort(out)
	return table.concat(out, "\n")
end

-- Every human clan's points and upgrades as this machine sees them.
function MOCK.humans_state()
	local out = {}
	for faction, h in pairs(VU_UNDER_TEST.state.hum or {}) do
		local lv = {}
		for fam, lines in pairs(h.levels) do
			for line, l in pairs(lines) do lv[#lv + 1] = fam .. "." .. line .. "=" .. l end
		end
		table.sort(lv)
		out[#out + 1] = faction .. " pool " .. h.pool .. " seq " .. h.seq .. " " .. table.concat(lv, ",")
	end
	table.sort(out)
	return table.concat(out, "\n")
end

function MOCK.pool_shown()
	return tonumber(MOCK.find("dy_points_to_spend").text)
end

-- Buy n levels of a line for a unit type from the Veterans list, then OK.
function MOCK.buy(fam_label, line_label, n)
	MOCK.click(MOCK.find("vu_button"))
	MOCK.click(MOCK.node_labelled(fam_label))
	local node = MOCK.node_labelled(line_label)
	assert(node, "no node " .. line_label)
	for _ = 1, n or 1 do MOCK.click(node) end
	MOCK.click(MOCK.find("button_ok"))   -- confirm (back to the list)
	MOCK.click(MOCK.find("button_ok"))   -- close the list
end

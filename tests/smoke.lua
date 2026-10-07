-- Smoke scenario for any campaign: start, list, a battle point, buy and confirm the first stat.
local failures, passed = {}, 0
local function check(cond, what) if cond then passed = passed + 1 else failures[#failures + 1] = what end end
local F = MOCK.fire
local fams, player = VU_UNDER_TEST.families, MOCK.player
F("LoadingGame", {}) F("NewCampaignStarted", {})
F("UICreated", { string = "Campaign UI", component = MOCK.root })
F("FactionTurnStart", { string = player })
check(#fams > 0, "campaign has unit types")
local mine = {}
for _, f in ipairs(fams) do for _, c in ipairs(f.factions) do if c == player then mine[#mine + 1] = f end end end
check(#mine > 0, "player clan " .. player .. " can upgrade something")
MOCK.battle({ mine[1].units[1] })
MOCK.click(MOCK.find("vu_button"))
check(MOCK.find("dy_points_to_spend").text == "1", "battle point shown")
local seen, pages = {}, 1
local pb = MOCK.find("vu_page")
if pb and pb.visible then pages = tonumber(string.match(MOCK.label_of(pb), "of (%d+)")) end
for page = 1, pages do
	for i = 1, 300 do
		local n = MOCK.find("vu_list_" .. i)
		if n and n.visible then seen[MOCK.label_of(n)] = true end
		if n and n.visible and n.y > 300 + 5 * 100 then check(false, "list entry below row 5: " .. MOCK.label_of(n)) end
	end
	if page < pages then MOCK.click(MOCK.find("vu_page")) end
end
local shown = 0
for _ in pairs(seen) do shown = shown + 1 end
check(shown == #mine, "list pages show exactly the clan's unit types (" .. shown .. " of " .. #mine .. ", " .. pages .. " pages)")
if pages > 1 then MOCK.click(MOCK.find("vu_page")) end   -- back to page 1
local fam = mine[1]
MOCK.click(MOCK.node_labelled(fam.name))
local stat
for _, l in ipairs(fam.lines) do if l.kind == "stat" and l.levels[1].cost <= 1 then stat = l break end end
if stat then
	MOCK.click(MOCK.node_labelled(stat.label))
	MOCK.click(MOCK.find("button_ok"))
	check(MOCK.bundles[player .. "/" .. stat.levels[1].bundle], "bought " .. stat.label .. " for " .. fam.name)
end
RESULT = { passed = passed, failures = failures }

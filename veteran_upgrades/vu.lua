-------------------------------------------------------------------------------
-- Veteran Upgrades (see VU_VERSION), appended to CA's export_advice.lua by build.py (started from SetCampaign)
--
-- Clan-wide upgrades per unit family, using the multiplayer skill-tree popup as the panel.
--   * Points: the clan earns 1 point per battle its units fight in (win or lose), into one pool
--             for any unit type; AI clans earn the same and auto-buy stat upgrades at turn start.
--   * Open:   the "Veterans" button under the advisor button lists unit types (full colour =
--             upgrades affordable); pick one to open its tree.
--   * Buy:    click upgrade nodes (staged); OK applies, Cancel discards, Reset refunds everything.
--   * Abilities: each combination is a unit copy; the clan recruits the copy matching its unlocks,
--             and Retrain (in the tree, with an army selected) swaps that army's units for it.
--   * Multiplayer campaigns: purchases are sent to the other machines and take effect when the
--             buyer ends the turn (see "Multiplayer campaigns" below).
-- VU_FAMILIES and VU_START_POINTS are generated above this file by build.py.
-- Log: vu_log.txt in the game folder.
-------------------------------------------------------------------------------
local VU = {
	root = nil, root_addr = nil, player = nil,
	points = {}, levels = {},          -- per family id; levels[fam][line_key] = owned level
	panel = nil, panel_addr = nil,     -- the popup component
	nodes = {},                        -- discovered skill nodes { addr, key, name_addr }
	node_line = {},                    -- node address string -> line (for the open family)
	open_family = nil,
	last_card = nil, last_card_time = 0,
}

local function vu_log(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
	pcall(function()
		local f = io.open("vu_log.txt", "a")
		f:write(os.date("%H:%M:%S") .. " " .. table.concat(parts, " ") .. "\n")
		f:close()
	end)
end

local function vu_guard(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then vu_log("!! error in", label, tostring(err)) end
end

-- Debug builds trace every game_interface / CampaignUI call: "->" before it, "<-" after it. After a
-- native crash, the last "->" line without a "<-" in vu_log.txt names the call that crashed.
-- vu_skip.txt in the game folder (one method name per line, # comments) lists calls to log and
-- skip instead, so a crash can be bisected without a rebuild, e.g. apply_effect_bundle, create_force.
local VU_SKIP = {}
if VU_DEBUG then
	pcall(function()
		local f = io.open("vu_skip.txt", "r")
		if not f then return end
		for l in f:lines() do
			l = l:match("^%s*(.-)%s*$")
			if l ~= "" and l:sub(1, 1) ~= "#" then VU_SKIP[l] = true end
		end
		f:close()
	end)
end

local function vu_args(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
	return table.concat(parts, ", ")
end

local function vu_trace_ret(name, ok, ...)
	if not ok then vu_log("<- ERROR", name, tostring((...))) error((...), 0) end
	vu_log("<-", name, vu_args(...))
	return ...
end

local function vu_trace_call(name, method, call, ...)
	if VU_SKIP[method] then vu_log("-- SKIPPED (vu_skip.txt)", name .. "(" .. vu_args(...) .. ")") return nil end
	vu_log("->", name .. "(" .. vu_args(...) .. ")")
	return vu_trace_ret(name, pcall(call, ...))
end

local vu_gi_proxy = setmetatable({}, { __index = function(_, m)
	return function(_, ...)
		local real = EpisodicScripting.game_interface
		return vu_trace_call("gi:" .. m, m, function(...) return real[m](real, ...) end, ...)
	end
end })
local function vu_gi() return VU_DEBUG and vu_gi_proxy or EpisodicScripting.game_interface end

local function vu_real_campaign_ui() return CampaignUI end
local CampaignUI = VU_DEBUG and setmetatable({}, { __index = function(_, m)
	return function(...)
		local real = vu_real_campaign_ui()
		return vu_trace_call("CampaignUI." .. m, m, real[m], ...)
	end
end }) or CampaignUI

local function addr_key(addr) return tostring(addr) end
local VU_RETRAIN_ICON = "data/ui/frontend ui/skills/skill_morale.tga"
local VU_PAGE_ICON = "data/ui/frontend ui/skills/skill_speed.tga"

-- Lookups built from the generated data -------------------------------------
local VU_BY_ID, VU_BY_NAME = {}, {}
for _, fam in ipairs(VU_FAMILIES) do
	fam.faction_set = {}
	for _, f in ipairs(fam.factions) do fam.faction_set[f] = true end
	VU_BY_ID[fam.id] = fam
	for _, n in ipairs(fam.names) do VU_BY_NAME[n] = fam end
end

local VU_FAM_INDEX = {}   -- family id -> position in VU_FAMILIES (multiplayer messages name families by it)
for i, fam in ipairs(VU_FAMILIES) do VU_FAM_INDEX[fam.id] = i - 1 end

-- Multiplayer campaign? (CampaignUI only exists once the campaign UI is up; until then: no.)
local function vu_is_mp()
	if VU.mp == nil then
		local ok, r = pcall(function() return CampaignUI.IsMultiplayer() end)
		if ok and r ~= nil then VU.mp = r == true end
	end
	return VU.mp == true
end

-- One clan-wide pool: the clan earns points per battle and spends them on any unit type.
-- In multiplayer the local player's view also counts purchases not yet sent (VU.outbox).
local vu_mp_view_points, vu_mp_view_level, vu_hum, vu_mp_send, vu_mp_settle_legacy   -- defined with the multiplayer code below
local function vu_points(fam_id)
	if vu_is_mp() then return vu_mp_view_points() end
	return VU.pool or 0
end
local function vu_level(fam_id, line_key)
	if vu_is_mp() then return vu_mp_view_level(fam_id, line_key) end
	return (VU.levels[fam_id] and VU.levels[fam_id][line_key]) or 0
end

-------------------------------------------------------------------------------
-- Upgrades: the panel edits a *pending* copy; OK commits it, Cancel discards it.
-------------------------------------------------------------------------------
local function vu_cost_of(line, level) return line.levels[level].cost end

-- An Advanced line needs the basic line of the same stat maxed first.
local function vu_basic_of(fam, line)
	if not line.advanced then return nil end
	for _, other in ipairs(fam.lines) do
		if not other.advanced and other.bonus == line.bonus then return other end
	end
	return nil
end

local function vu_locked_by(fam, line, levels)
	local basic = vu_basic_of(fam, line)
	if basic and (levels[basic.key] or 0) < #basic.levels then return basic end
	return nil
end

local function vu_spent(fam, levels)
	local total = 0
	for _, line in ipairs(fam.lines) do
		for lvl = 1, levels[line.key] or 0 do total = total + vu_cost_of(line, lvl) end
	end
	return total
end

local function vu_begin_edit(fam)
	local copy = {}
	for _, line in ipairs(fam.lines) do copy[line.key] = vu_level(fam.id, line.key) end
	VU.pending = { fam = fam, levels = copy, points = vu_points(fam.id) }
end

local function vu_pending_buy(line)
	local p = VU.pending
	local owned = p.levels[line.key] or 0
	local nxt = line.levels[owned + 1]
	if not nxt then vu_log("buy:", line.key, "already maxed") return end
	local lock = vu_locked_by(p.fam, line, p.levels)
	if lock then vu_log("buy:", line.key, "locked until", lock.key, "is maxed") return end
	if p.points < nxt.cost then vu_log("buy:", line.key, "needs", nxt.cost, "have", p.points) return end
	p.levels[line.key] = owned + 1
	p.points = p.points - nxt.cost
	vu_log("pending:", p.fam.id, line.key, "->", owned + 1, "points", p.points)
end

local function vu_committed_levels_of(fam)
	local lv = {}
	for _, line in ipairs(fam.lines) do lv[line.key] = vu_level(fam.id, line.key) end
	return lv
end

-- Reset = respec: refunds everything spent on the unit type, minus a flat fee on what was already
-- committed (capped at that amount). Charged only when confirmed with OK; Cancel undoes it for free.
local VU_RESPEC_FEE = 2

local function vu_respec_fee(fam)
	local committed = vu_spent(fam, vu_committed_levels_of(fam))
	return math.min(VU_RESPEC_FEE, committed), committed
end

local function vu_pending_reset()
	local p = VU.pending
	local fee = vu_respec_fee(p.fam)
	if p.reset_fee_charged then fee = 0 end   -- one fee per respec, however often Reset is pressed
	p.points = p.points + vu_spent(p.fam, p.levels) - fee
	p.reset_fee_charged = p.reset_fee_charged or fee > 0
	for k in pairs(p.levels) do p.levels[k] = 0 end
	vu_log("pending reset:", p.fam.id, "fee", fee, "points", p.points)
end

local VU_AFTER_COMMIT   -- set by the recruitment code below
local vu_mp_commit      -- set by the multiplayer code below
local function vu_commit()
	local p = VU.pending
	if not p then return end
	if vu_is_mp() then vu_mp_commit(p) return end   -- sent now, applied on every machine at turn end
	local fam, gi = p.fam, vu_gi()
	VU.levels[fam.id] = VU.levels[fam.id] or {}
	for _, line in ipairs(fam.lines) do
		local old, new = vu_level(fam.id, line.key), p.levels[line.key] or 0
		if old ~= new then
			if old > 0 and line.levels[old].bundle ~= "" then gi:remove_effect_bundle(line.levels[old].bundle, VU.player) end
			if new > 0 and line.levels[new].bundle ~= "" then gi:apply_effect_bundle(line.levels[new].bundle, VU.player, 0) end
			VU.levels[fam.id][line.key] = new
			vu_log("COMMIT", fam.id, line.key, old, "->", new)
		end
	end
	VU.pool = p.points
	vu_log("committed", fam.id, "points now", p.points)
	if VU_AFTER_COMMIT then VU_AFTER_COMMIT(fam) end
end

-------------------------------------------------------------------------------
-- Panel (multiplayer popup_skill_tree layout, repurposed)
-------------------------------------------------------------------------------
-- Preferred skill-tree node (by its MP avatar skill id) for each bonus, so upgrades sit
-- under a sensible column heading and keep the layout's own spacing.
local VU_NODE_PREF = {
	accuracy_mod      = { "avatar_skill_marksmanship", "avatar_skill_bow_damage", "avatar_skill_ammo_quantity", "avatar_skill_fire_arrows" },
	melee_attack_mod  = { "avatar_skill_melee_attack", "avatar_skill_charge", "avatar_skill_banzai" },
	melee_defence_mod = { "avatar_skill_melee_defence", "avatar_skill_no_spear_penalty", "avatar_skill_hitpoint" },
	armour_mod        = { "avatar_skill_armour", "avatar_skill_hitpoint", "avatar_skill_stamina" },
	morale            = { "avatar_skill_morale", "avatar_skill_inspire", "avatar_skill_rally", "avatar_skill_army_morale" },
}

local vu_make_hoverable, vu_log_bounds, vu_refresh_retrain, vu_show_title, vu_refresh_page_button, vu_hide_page_button   -- defined with the list code below
local function vu_child(addr, id)
	local ok, r = pcall(function() return UIComponent(addr):Find(id) end)
	if ok then return r end
	return nil
end

local function vu_set_text(addr, text)
	if addr then pcall(function() UIComponent(addr):SetStateText(text) end) end
end

-- Bottom bar: "<context> - points to spend:" and the clan pool, in the popup's own points display.
local function vu_set_buttons(tree, fam)
	local tips = tree and {
		button_ok = "Confirm\nApply the upgrades chosen for " .. fam.name .. " and return to the list."
			.. (vu_is_mp() and "\nMultiplayer: they take effect when you end your turn." or ""),
		button_cancel = "Cancel\nDiscard the changes made here (nothing is charged) and return to the list.",
	} or {
		button_ok = "Close", button_cancel = "Close",
	}
	for id, tip in pairs(tips) do
		pcall(function() UIComponent(vu_child(VU.panel_addr, id)):SetTooltipText(tip, true) end)
	end
	pcall(function() UIComponent(vu_child(VU.panel_addr, "button_reset")):SetVisible(tree) end)
end

local function vu_set_header(context_text, points)
	local dy = vu_child(VU.panel_addr, "dy_points_to_spend")
	if not dy then return end
	vu_set_text(dy, tostring(points))
	local txt = vu_child(dy, "points_txt")
	vu_set_text(txt, "Points to spend:")
	local tip = string.format("Clan points: %d\nYour clan earns 1 point for every battle its units fight in,\nand can spend them on any unit type.", points)
	if vu_is_mp() then
		tip = tip .. "\nMultiplayer: upgrades take effect when you end your turn." .. (VU.mp_problem and ("\n" .. VU.mp_problem) or "")
	end
	for _, a in ipairs({ dy, txt }) do
		if a then pcall(function() UIComponent(a):SetTooltipText(tip, true) end) end
	end
end

-- Walk the popup: collect skill nodes (components with skill_icon + skill_name children),
-- every arrow (inside nodes too), and log the tree once for layout work.
local vu_walk
-- Debug builds: log each view of our UI once per session, after our texts and tooltips are set.
local function vu_audit(mode)
	if not VU_DEBUG then return end
	VU.audited = VU.audited or {}
	if VU.audited[mode] then return end
	VU.audited[mode] = true
	if VU.panel_addr then vu_walk(VU.panel_addr, 0, nil, {}, "ui[" .. mode .. "]") end
	if VU.button then vu_walk(VU.button, 0, nil, {}, "ui[hud]") end
end

vu_walk = function(addr, depth, nodes, arrows, log_tree)
	if depth > 10 then return end
	local c = UIComponent(addr)
	local id = tostring(c:Id())
	local n = c:ChildCount()
	if log_tree then   -- true, or a tag such as "ui[tree]" (debug audit, tools/vu_ui_audit.py)
		local txt, tip, vis, inter = "", "", "?", "?"
		pcall(function() txt = tostring(c:GetStateText()) end)
		pcall(function() tip = tostring(c:GetTooltipText()) end)
		pcall(function() vis = tostring(c:Visible()) end)
		pcall(function() inter = tostring(c:IsInteractive()) end)
		vu_log(type(log_tree) == "string" and log_tree or "tree", string.rep(". ", depth) .. id, "| children", n,
			"| visible", vis, "| interactive", inter,
			txt ~= "" and ("| text " .. (string.gsub(txt, "\n", " / "))) or "",
			tip ~= "" and ("| tooltip " .. (string.gsub(tip, "\n", " / "))) or "")
	end
	if string.sub(id, 1, 5) == "arrow" then arrows[#arrows + 1] = addr end
	local icon, name = nil, nil
	for i = 0, n - 1 do
		local child = c:Find(i)
		local cid = tostring(UIComponent(child):Id())
		if cid == "skill_icon" then icon = child end
		if cid == "skill_name" then name = child end
	end
	if icon and name and nodes then
		nodes[#nodes + 1] = { addr = addr, key = addr_key(addr), id = id, icon_addr = icon, name_addr = name }
	end
	for i = 0, n - 1 do vu_walk(c:Find(i), depth + 1, nodes, arrows, log_tree) end
end

local function vu_create_panel()
	if VU.panel then return true end
	local addr = Component.CreateFromLayout("data/ui/frontend ui/popup_skill_tree", "vu_panel", VU.root_addr, 0, 0)
	if not addr then vu_log("panel: CreateFromLayout returned nil") return false end
	VU.panel_addr, VU.panel = addr, UIComponent(addr)
	local nodes, arrows = {}, {}
	if VU_DEBUG then vu_walk(addr, 0, nil, {}, true) end   -- debug builds: UI tree + tooltips (tools/vu_ui_audit.py)
	local tree = vu_child(addr, "shogun_subpanel") or addr
	VU.tree_addr = tree
	vu_walk(tree, 0, nodes, arrows, false)
	for _, nd in ipairs(nodes) do
		pcall(function() nd.x, nd.y = UIComponent(nd.addr):Position() end)
		nd.x, nd.y = nd.x or 0, nd.y or 0
	end
	table.sort(nodes, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
	VU.nodes, VU.arrows = nodes, arrows
	VU.nodes_by_id = {}
	for _, nd in ipairs(nodes) do
		VU.nodes_by_id[nd.id] = nd
		vu_make_hoverable(nd)
		-- The multiplayer level pips sit on top of the node with no tooltip of their own: let the
		-- mouse through to the node so its tooltip shows (found by tools/vu_ui_audit.py).
		for _, pip in ipairs({ "level_max", "level_unlocked" }) do
			local a = vu_child(nd.addr, pip)
			if a then pcall(function() UIComponent(a):SetInteractive(false) end) end
		end
	end
	-- Multiplayer-only bits: clan tokens and the Fall of the Samurai tree.
	-- The clan-token box (stats_list_bg: icon + "Clan Tokens" label) becomes the title box.
	local tok = vu_child(addr, "clan_token_icon")
	if tok then
		pcall(function() UIComponent(tok):SetVisible(false) end)
		local box = UIComponent(tok):Parent()
		-- The whole clan-token box goes: its frame showed as an empty red box. The popup's own
		-- "Points to spend" display carries the title instead (vu_set_header).
		pcall(function() UIComponent(box):SetVisible(false) end)
	end
	pcall(function() UIComponent(vu_child(addr, "boshin_subpanel")):SetVisible(false) end)
	-- The "?" opens an empty Encyclopaedia page in the campaign.
	pcall(function() UIComponent(vu_child(addr, "button_encyclopaedia")):SetVisible(false) end)
	local ids = {}
	for _, nd in ipairs(nodes) do ids[#ids + 1] = nd.id end
	vu_log("panel created: nodes", #nodes, "arrows", #arrows, ":", table.concat(ids, " "))
	return true
end

-- Assign a node to each line and lay the tree out: one column per heading, basic upgrades on
-- the top row, Advanced upgrades two rows below the basic upgrade of the same stat.
local function vu_layout(fam)
	local assign, top_y, row_h = {}, nil, 100
	for _, nd in ipairs(VU.nodes) do if top_y == nil or nd.y < top_y then top_y = nd.y end end
	top_y = top_y or 0
	if #VU.nodes > 1 then
		local ys = {}
		for _, nd in ipairs(VU.nodes) do if nd.y > top_y then ys[#ys + 1] = nd.y end end
		table.sort(ys)
		if ys[1] then row_h = ys[1] - top_y end
	end
	-- stats per column, in line order
	local col_stats, stat_seen = {}, {}
	for _, line in ipairs(fam.lines) do
		-- Lines sharing a column and row sit side by side; a stat's Advanced line sits under its basic line.
		local col, slot = line.column, line.kind == "ability" and line.key or line.bonus
		col_stats[col] = col_stats[col] or {}
		local tag = col .. ":" .. (line.kind == "stat" and "stat" or "unlock")
		col_stats[tag] = col_stats[tag] or {}
		if not stat_seen[slot] then stat_seen[slot] = true table.insert(col_stats[tag], slot) end
	end
	VU.geom = { top_y = top_y, row_h = row_h }
	local spare = 1
	for i, line in ipairs(fam.lines) do
		local nd = VU.nodes[spare]
		if not nd then break end
		spare = spare + 1
		assign[i] = nd
		local col = line.column
		local hx, hw = nil, 0
		pcall(function()
			local h = UIComponent(vu_child(VU.tree_addr or VU.panel_addr, col))
			hx = h:Position()
			hw = h:Width()
		end)
		local nw = 0
		pcall(function() nw = UIComponent(nd.addr):Width() end)
		local slot = line.kind == "ability" and line.key or line.bonus
		local stats, k = col_stats[col .. ":" .. (line.kind == "stat" and "stat" or "unlock")], 1
		for j, b in ipairs(stats) do if b == slot then k = j end end
		local spacing = nw + 40
		local cx = (hx or nd.x) + hw / 2 + (k - (#stats + 1) / 2) * spacing
		local y = top_y + line.row * row_h
		pcall(function() UIComponent(nd.addr):MoveTo(math.floor(cx - nw / 2), y) end)
	end
	return assign
end

local function vu_refresh_panel()
	local p = VU.pending
	if not p or not VU.panel then return end
	local fam = p.fam
	for _, nd in ipairs(VU.list_nodes or {}) do pcall(function() UIComponent(nd.addr):SetVisible(false) end) end
	for _, h in pairs(VU.cat_headers or {}) do pcall(function() UIComponent(h.addr):SetVisible(false) end) end
	vu_set_header(fam.name .. " (all in clan)", p.points)
	vu_set_buttons(true, fam)
	vu_hide_page_button()
	vu_guard("title", vu_show_title, fam)
	local fee, committed = vu_respec_fee(fam)
	pcall(function()
		UIComponent(vu_child(VU.panel_addr, "button_reset")):SetTooltipText(committed > 0 and not p.reset_fee_charged
			and string.format("Respec %s: refund all %d points spent on it, minus a %d-point fee.\nCharged when you press OK; Cancel undoes it.", fam.name, committed, fee)
			or string.format("Reset: undo this session's choices for %s (free; a respec of confirmed upgrades costs %d points).", fam.name, VU_RESPEC_FEE), true)
	end)
	-- Title: which unit type this panel upgrades (clan-wide).
	VU.node_line = {}
	local shown = {}
	local assign = VU.layout_for == fam.id and VU.assign or vu_layout(fam)
	VU.assign, VU.layout_for = assign, fam.id
	for i, line in ipairs(fam.lines) do
		local nd = assign[i]
		if VU_DEBUG then vu_log("refresh:", line.key, "level", p.levels[line.key] or 0, "node", nd and nd.key, "icon", line.icon) end
		if nd then
			shown[nd.key] = true
			VU.node_line[nd.key] = line
			local owned = p.levels[line.key] or 0
			local nxt = line.levels[owned + 1]
			local label = string.format("%s %d/%d", line.label, owned, #line.levels)
			vu_set_text(nd.name_addr, label)
			pcall(function() UIImage(line.icon):SetComponentTexture(nd.icon_addr, 0) end)
			local lock = vu_locked_by(fam, line, p.levels)
			local tip
			if lock then
				tip = string.format("%s\nRequires %s at %d/%d first.", line.label, lock.label, #lock.levels, #lock.levels)
			elseif line.kind == "ability" then
				tip = string.format("Ability: %s\n%s\n%s\nNew recruits get it from your next turn; use Retrain for units you already have.%s", line.label, line.desc,
					owned > 0 and "Unlocked for every " .. fam.name .. "." or string.format("Cost: %d points (you have %d).", line.levels[1].cost, p.points),
					line.gated and "\nAlso needs the usual research before it can be used." or "")
			elseif line.kind == "passive" then
				tip = string.format("%s\nThis unit frightens nearby enemies, lowering their morale.\n%s", line.label,
					owned > 0 and "Unlocked." or string.format("Cost: %d points (you have %d).", line.levels[1].cost, p.points))
			elseif nxt then
				tip = string.format("%s %s\n+%g %s for %s.\nCost: %d point%s (you have %d).",
					line.label, owned + 1, nxt.value, line.stat, fam.name, nxt.cost, nxt.cost == 1 and "" or "s", p.points)
			else
				tip = string.format("%s (max)\n+%g %s for %s.", line.label, line.levels[owned].value, line.stat, fam.name)
			end
			for _, a in ipairs({ nd.addr, nd.icon_addr, nd.name_addr }) do
				pcall(function() UIComponent(a):SetTooltipText(tip, true) end)
			end
			if i == 1 then vu_log_bounds("tree", nd) end
			local state
			if owned > 0 then state = "down"                                 -- owned: full colour
			elseif lock then state = "inactive"                               -- prerequisite missing
			elseif nxt and p.points >= nxt.cost then state = "active"         -- buyable
			else state = "inactive" end                                       -- can't afford
			pcall(function() UIComponent(nd.addr):SetState(state) end)
			-- The greyscale look lives on the icon element itself, so set its shader directly.
			pcall(function() UIComponent(nd.icon_addr):SetState(state) end)
			pcall(function()
				UIComponent(nd.icon_addr):ShaderTechniqueSet(owned > 0 and "normal_t0" or "set_greyscale_t0", true)
			end)
		end
	end
	for _, nd in ipairs(VU.nodes) do
		pcall(function() UIComponent(nd.addr):SetVisible(shown[nd.key] == true) end)
	end
	for _, a in ipairs(VU.arrows or {}) do pcall(function() UIComponent(a):SetVisible(false) end) end
	vu_guard("refresh retrain", vu_refresh_retrain, fam)
	vu_audit("tree")
	if VU_DEBUG then vu_log("refresh: done", fam.id) end
end

local VU_HEADERS = { "leadership", "ranged", "physical", "melee" }

local VU_HEADER_TIPS = {
	leadership = "Leadership\nMorale, and command abilities such as Inspire Unit, Rally and Hold Firm.",
	ranged = "Ranged\nAccuracy, and missile abilities such as Increased Range and Rapid Volley.",
	physical = "Physical\nArmour, and abilities such as Blinding Grenades.",
	melee = "Melee\nMelee attack and defence, and abilities such as Banzai.",
}

local function vu_show_headers(show)
	for _, h in ipairs(VU_HEADERS) do
		pcall(function()
			local addr = vu_child(VU.tree_addr, h)
			UIComponent(addr):SetVisible(show)
			UIComponent(addr):SetTooltipText(VU_HEADER_TIPS[h], true)
			local label = vu_child(addr, "label_" .. h)
			if label then UIComponent(label):SetTooltipText(VU_HEADER_TIPS[h], true) end
		end)
	end
end

-- Can this family buy anything right now (points, an unmaxed line, prerequisites met)?
local function vu_buyable(fam)
	local pts = vu_points(fam.id)
	if pts <= 0 then return false end
	local lv = {}
	for _, l in ipairs(fam.lines) do lv[l.key] = vu_level(fam.id, l.key) end
	for _, l in ipairs(fam.lines) do
		local nxt = l.levels[lv[l.key] + 1]
		if nxt and pts >= nxt.cost and not vu_locked_by(fam, l, lv) then return true end
	end
	return false
end

-- Make a node clone (icon + label only) under the Sengoku tree, for the unit-type list.
local function vu_clone_node(name)
	local tpl = VU.nodes[#VU.nodes]
	local addr = Component.CreateFromComponent(tpl.addr, name, VU.tree_addr, 0, 0, {}, {})
	if not addr then return nil end
	local c = UIComponent(addr)
	local icon, label
	for i = 0, c:ChildCount() - 1 do
		local child = c:Find(i)
		local cid = tostring(UIComponent(child):Id())
		if cid == "skill_icon" then icon = child
		elseif cid == "skill_name" then label = child
		else pcall(function() UIComponent(child):SetVisible(false) end) end
	end
	return { addr = addr, key = addr_key(addr), icon_addr = icon, name_addr = label }
end

-- Icon and label sit on top of the node; make them interactive so hovering/clicking them works.
vu_make_hoverable = function(nd)
	for _, a in ipairs({ nd.icon_addr, nd.name_addr }) do
		if a then pcall(function() UIComponent(a):SetInteractive(true) end) end
	end
end

vu_log_bounds = function(label, nd)
	if VU.bounds_logged and VU.bounds_logged[label] then return end
	VU.bounds_logged = VU.bounds_logged or {}
	VU.bounds_logged[label] = true
	for _, part in ipairs({ { "node", nd.addr }, { "icon", nd.icon_addr }, { "name", nd.name_addr } }) do
		pcall(function()
			local c = UIComponent(part[2])
			local x, y = c:Position()
			local w, h = c:Dimensions()
			vu_log("bounds", label, part[1], "pos", x, y, "size", w, h, "interactive", tostring(c:IsInteractive()))
		end)
	end
end

-- Retrain button (tree mode): a node clone under the tree; two clicks (the first warns).
local VU_RETRAIN_CANDIDATES, VU_RETRAIN, vu_count_rows   -- set by the retraining code below
local function vu_retrain_node()
	if VU.retrain_node then return VU.retrain_node end
	local nd = vu_clone_node("vu_retrain")
	if not nd then vu_log("retrain: clone failed") return nil end
	vu_make_hoverable(nd)
	pcall(function() UIImage(VU_RETRAIN_ICON):SetComponentTexture(nd.icon_addr, 0) end)
	VU.retrain_node = nd
	return nd
end

-- Tree title: the unit type's portrait and name (a node clone, like the list entries), in the
-- bottom bar where the clan-token box was.
vu_show_title = function(fam)
	if not VU.title_node then
		VU.title_node = vu_clone_node("vu_title")
		if not VU.title_node then return end
		for _, a in ipairs({ VU.title_node.addr, VU.title_node.icon_addr, VU.title_node.name_addr }) do
			pcall(function() UIComponent(a):SetInteractive(a == VU.title_node.addr) end)
		end
	end
	local nd = VU.title_node
	if not fam then pcall(function() UIComponent(nd.addr):SetVisible(false) end) return end
	vu_set_text(nd.name_addr, fam.name)
	pcall(function() UIImage(fam.portrait):SetComponentTexture(nd.icon_addr, 0) end)
	pcall(function() UIComponent(nd.icon_addr):ShaderTechniqueSet("normal_t0", true) end)
	pcall(function() UIComponent(nd.addr):SetState("active") end)
	pcall(function() UIComponent(nd.addr):SetTooltipText("Upgrades bought here apply to every " .. fam.name .. " in your clan.", true) end)
	pcall(function()
		-- In the bottom bar, where the (hidden) clan-token box was: there is room there.
		local box = UIComponent(vu_child(VU.panel_addr, "stats_list_bg"))
		local bx, by = box:Position()
		local c = UIComponent(nd.addr)
		c:MoveTo(math.floor(bx), math.floor(by + (box:Height() - c:Height()) / 2))
		c:SetVisible(true)
		local cx, cy = c:Position()
		local tx, ty, lx, ly = bx, by, 0, 0
		vu_log("title at", cx, cy, "| token box at", tx, ty)
	end)
end

local VU_LIST_ROWS = 5

-- List page button: a node clone in the bottom bar, shown only when a column has more than
-- VU_LIST_ROWS unit types.
local function vu_page_node()
	if VU.page_node then return VU.page_node end
	local nd = vu_clone_node("vu_page")
	if not nd then return nil end
	vu_make_hoverable(nd)
	pcall(function() UIImage(VU_PAGE_ICON):SetComponentTexture(nd.icon_addr, 0) end)
	VU.page_node = nd
	return nd
end

vu_hide_page_button = function()
	if VU.page_node then pcall(function() UIComponent(VU.page_node.addr):SetVisible(false) end) end
end

vu_refresh_page_button = function()
	if (VU.list_pages or 1) <= 1 then vu_hide_page_button() return end
	local nd = vu_page_node()
	if not nd then return end
	vu_set_text(nd.name_addr, string.format("Page %d of %d", VU.list_page, VU.list_pages))
	local tip = string.format("More unit types\nShowing page %d of %d - click for the next page.", VU.list_page, VU.list_pages)
	for _, a in ipairs({ nd.addr, nd.icon_addr, nd.name_addr }) do pcall(function() UIComponent(a):SetTooltipText(tip, true) end) end
	pcall(function() UIComponent(nd.addr):SetState("active") end)
	-- Full colour: cloned skill nodes start in the greyscale "not bought" look.
	pcall(function() UIComponent(nd.icon_addr):SetState("active") end)
	pcall(function() UIComponent(nd.icon_addr):ShaderTechniqueSet("normal_t0", true) end)
	pcall(function()
		-- In the bottom bar, where the (hidden) clan-token box was.
		local box = UIComponent(vu_child(VU.panel_addr, "stats_list_bg"))
		local bx, by = box:Position()
		local c = UIComponent(nd.addr)
		c:MoveTo(math.floor(bx), math.floor(by + (box:Height() - c:Height()) / 2))
		c:SetVisible(true)
	end)
end

local function vu_hide_retrain()
	if VU.retrain_node then pcall(function() UIComponent(VU.retrain_node.addr):SetVisible(false) end) end
	VU.retrain_armed = false
end

vu_refresh_retrain = function(fam)
	local nd = vu_retrain_node()
	if not nd then return end
	local armies = VU_RETRAIN_CANDIDATES and VU_RETRAIN_CANDIDATES(fam, VU.pending and VU.pending.levels) or {}
	local count, xp = vu_count_rows(armies)
	VU.retrain_count = count
	local show = count > 0
	vu_log("retrain button:", fam.id, "units", count, "armies", #armies, VU.retrain_why or "")
	pcall(function() UIComponent(nd.addr):SetVisible(show) end)
	if not show then VU.retrain_armed = false return end
	local scope = VU.retrain_all and string.format("across %d arm%s", #armies, #armies == 1 and "y" or "ies") or "in this army"
	local text, tip
	if VU.retrain_armed then
		text = string.format("Confirm retrain (%d)", count)
		tip = string.format("Click again to retrain %d %s %s.\nThe retrained units appear beside each army as their own stack; drag them back in.%s",
			count, fam.name, scope, xp > 0 and string.format("\n%d of them will LOSE their experience.", xp) or "")
	else
		text = string.format(VU.retrain_all and "Retrain all (%d)" or "Retrain (%d)", count)
		tip = string.format("Retrain %d %s %s so they get the abilities chosen here\n(this also confirms your purchases, like OK).%s\nRetrained units lose their experience.",
			count, fam.name, scope, VU.retrain_all and "\nSelect an army first to retrain only that army." or "")
	end
	vu_set_text(nd.name_addr, text)
	for _, a in ipairs({ nd.addr, nd.icon_addr, nd.name_addr }) do pcall(function() UIComponent(a):SetTooltipText(tip, true) end) end
	pcall(function() UIComponent(nd.addr):SetState("active") end)
	pcall(function() UIComponent(nd.icon_addr):ShaderTechniqueSet(VU.retrain_armed and "normal_t0" or "set_greyscale_t0", true) end)
	-- Left of the OK / Cancel pair, level with them (Reset sits apart at the window's left edge).
	pcall(function()
		local ok = UIComponent(vu_child(VU.panel_addr, "button_ok"))
		local x, y = ok:Position()
		local where = { "ok " .. x }
		for _, id in ipairs({ "button_cancel", "button_reset" }) do
			local ox = UIComponent(vu_child(VU.panel_addr, id)):Position()
			where[#where + 1] = id .. " " .. ox
			if id == "button_cancel" and ox < x then x = ox end
		end
		vu_log("retrain: dialog buttons at", table.concat(where, ", "))
		local c = UIComponent(nd.addr)
		c:MoveTo(math.floor(x - c:Width() - 30), math.floor(y + (ok:Height() - c:Height()) / 2))
		local px, py = c:Position()
		vu_log("retrain button at", px, py, "visible", tostring(c:Visible()))
	end)
end

local function vu_is_node(addr, nd)
	local cur = addr
	for _ = 1, 3 do
		if cur == nil then return false end
		if addr_key(cur) == nd.key then return true end
		local ok, p = pcall(function() return UIComponent(cur):Parent() end)
		if not ok then return false end
		cur = p
	end
	return false
end

local function vu_is_retrain(addr)
	if not VU.retrain_node then return false end
	local cur = addr
	for _ = 1, 3 do
		if cur == nil then return false end
		if addr_key(cur) == VU.retrain_node.key then return true end
		local ok, p = pcall(function() return UIComponent(cur):Parent() end)
		if not ok then return false end
		cur = p
	end
	return false
end

-- List columns for this campaign, generated by build.py (CAMPAIGNS): id, label, tooltip and which
-- of the popup's own Sengoku heading emblems to clone (the Fall of the Samurai emblems in
-- boshin_subpanel are drawn in a different style).
local VU_CATEGORIES = VU_CATEGORY_LIST

-- One heading per category: clones of the popup's own "leadership" heading container.
local function vu_category_headers()
	if VU.cat_headers then return VU.cat_headers end
	VU.cat_headers = {}
	local boshin = vu_child(VU.panel_addr, "boshin_subpanel")
	for i, cat in ipairs(VU_CATEGORIES) do
		local tpl
		if string.sub(cat.tpl, 1, 7) == "boshin_" then tpl = boshin and vu_child(boshin, string.sub(cat.tpl, 8))
		else tpl = vu_child(VU.tree_addr, cat.tpl) end
		tpl = tpl or vu_child(VU.tree_addr, "leadership")
		local addr = tpl and Component.CreateFromComponent(tpl, "vu_cat_" .. cat.id, VU.tree_addr, 0, 0, {}, {})
		if addr then
			local c = UIComponent(addr)
			local label = nil
			pcall(function() label = c:Find(0) end)
			vu_set_text(label, cat.label)
			local tip = cat.tip .. "\nUnit types your clan can recruit, cheapest at the top. Click one to upgrade it."
			for _, a in ipairs({ addr, label }) do
				if a then pcall(function() UIComponent(a):SetTooltipText(tip, true) end) end
			end
			VU.cat_headers[i] = { addr = addr, label = label }
		end
	end
	return VU.cat_headers
end

-- "List" mode: one node per unit type, full colour if it has upgrades it can buy.
local function vu_refresh_list()
	VU.node_line, VU.node_fam = {}, {}
	vu_hide_retrain()
	vu_guard("title", vu_show_title, nil)
	vu_show_headers(false)
	for _, nd in ipairs(VU.nodes) do pcall(function() UIComponent(nd.addr):SetVisible(false) end) end
	for _, a in ipairs(VU.arrows or {}) do pcall(function() UIComponent(a):SetVisible(false) end) end
	vu_set_header("Choose a unit type", vu_points())
	vu_set_buttons(false)
	VU.list_nodes = VU.list_nodes or {}
	-- Only unit types the player's clan can recruit (build.py family_factions).
	local shown = {}
	for _, fam in ipairs(VU_FAMILIES) do
		if not VU.player or fam.faction_set[VU.player] then shown[#shown + 1] = fam end
	end
	while #VU.list_nodes < #shown do
		local nd = vu_clone_node("vu_list_" .. (#VU.list_nodes + 1))
		if not nd then vu_log("list: clone failed at", #VU.list_nodes + 1) break end
		vu_make_hoverable(nd)
		VU.list_nodes[#VU.list_nodes + 1] = nd
	end
	-- Columns: one per category, spread across the width the four headings normally span.
	local left, right, top_y, row_h, head_y = nil, nil, nil, 100, nil
	pcall(function()
		local l = UIComponent(vu_child(VU.tree_addr, "leadership"))
		left = l:Position()
		local _, hy = l:Position()
		head_y = hy
		local m = UIComponent(vu_child(VU.tree_addr, "melee"))
		right = m:Position() + m:Width()
	end)
	for _, nd in ipairs(VU.nodes) do if top_y == nil or nd.y < top_y then top_y = nd.y end end
	for _, nd in ipairs(VU.nodes) do
		if nd.y > top_y and nd.y - top_y < row_h then row_h = nd.y - top_y end
	end
	local headers = vu_category_headers()
	local ncat = #VU_CATEGORIES
	local col_of, filled = {}, {}
	for ci, cat in ipairs(VU_CATEGORIES) do col_of[cat.id] = ci filled[ci] = 0 end
	for ci, h in pairs(headers) do
		pcall(function()
			local c = UIComponent(h.addr)
			c:SetVisible(true)
			if left and right then
				local cx = left + (ci - 0.5) * (right - left) / ncat
				c:MoveTo(math.floor(cx - c:Width() / 2), head_y)
			end
		end)
	end
	-- Paging: each column shows VU_LIST_ROWS entries per page; a page button cycles when a column
	-- has more (the panel fits about five rows).
	local rank, per_col = {}, {}
	for _, fam in ipairs(shown) do
		local ci = col_of[fam.category] or ncat
		per_col[ci] = (per_col[ci] or 0) + 1
		rank[fam] = per_col[ci] - 1
	end
	local most = 0
	for _, n in pairs(per_col) do if n > most then most = n end end
	VU.list_pages = math.max(1, math.ceil(most / VU_LIST_ROWS))
	VU.list_page = math.min(VU.list_page or 1, VU.list_pages)
	vu_refresh_page_button()
	for i, nd in ipairs(VU.list_nodes) do
		local fam = shown[i]
		local on_page = fam and math.floor(rank[fam] / VU_LIST_ROWS) + 1 == VU.list_page
		pcall(function() UIComponent(nd.addr):SetVisible(on_page == true) end)
		if on_page then
			VU.node_fam[nd.key] = fam
			local can = vu_buyable(fam)
			local pts = vu_points(fam.id)
			vu_set_text(nd.name_addr, fam.name)
			pcall(function() UIImage(fam.portrait):SetComponentTexture(nd.icon_addr, 0) end)
			pcall(function() UIComponent(nd.addr):SetState("active") end)
			pcall(function() UIComponent(nd.icon_addr):SetState("active") end)
			pcall(function() UIComponent(nd.icon_addr):ShaderTechniqueSet(can and "normal_t0" or "set_greyscale_t0", true) end)
			local tip = string.format("%s\nClan points: %d\n%s", fam.name, pts,
				can and "Upgrades available - click to spend points."
				or (pts > 0 and "Nothing affordable yet - click to view upgrades." or "No points yet - your clan earns 1 point per battle it fights."))
			for _, a in ipairs({ nd.addr, nd.icon_addr, nd.name_addr }) do pcall(function() UIComponent(a):SetTooltipText(tip, true) end) end
			local ci = col_of[fam.category] or ncat
			if left and right then
				local nw = 0
				pcall(function() nw = UIComponent(nd.addr):Width() end)
				local cx = left + (ci - 0.5) * (right - left) / ncat
				pcall(function() UIComponent(nd.addr):MoveTo(math.floor(cx - nw / 2), top_y + (rank[fam] % VU_LIST_ROWS) * row_h) end)
			end
			if i == 1 then vu_log_bounds("list", nd) end
		end
	end
	vu_audit("list")
end

local function vu_show_list()
	if not vu_create_panel() then return end
	VU.mode, VU.open_family, VU.pending = "list", nil, nil
	VU.panel:SetVisible(true)
	vu_refresh_list()
	vu_log("list opened")
end

local function vu_open(fam, from_list)
	if not vu_create_panel() then return end
	vu_begin_edit(fam)
	VU.retrain_armed = false
	if VU.layout_for ~= fam.id then VU.layout_for = nil end
	VU.mode, VU.open_family, VU.from_list = "tree", fam, from_list == true
	vu_show_headers(true)
	VU.panel:SetVisible(true)
	vu_refresh_panel()
	vu_log("panel opened for", fam.id, "points", vu_points(fam.id), from_list and "(from list)" or "")
	if VU_DEBUG then
		vu_log("family:", fam.id, "player", VU.player, "recruitable here", fam.faction_set[VU.player] == true,
			"units", table.concat(fam.units, ","), "abilities", table.concat(fam.abilities, ","))
		for _, line in ipairs(fam.lines) do
			vu_log("  line", line.key, "kind", line.kind, "owned", vu_level(fam.id, line.key), "/", #line.levels,
				"bundle(1)", line.levels[1].bundle, "gated", line.gated)
		end
		for _, copy in ipairs(fam.copies) do
			local st = {}
			local locked = VU.locked_by and VU.locked_by[VU.player]
			for _, k in ipairs({ copy.base, unpack(copy.keys) }) do st[#st + 1] = k .. "=" .. tostring(locked and locked[k]) end
			vu_log("  locks", table.concat(st, " "), "prelocked", VU.prelocked)
		end
	end
end

-- OK / Cancel: in a tree they apply / discard, then return to the list if that's where we came from.
local function vu_close(commit)
	if VU.mode == "tree" and commit then vu_commit() end
	vu_log("panel", VU.mode == "tree" and (commit and "OK" or "cancel") or "list closed")
	if VU.mode == "tree" and VU.from_list then vu_show_list() return end
	if VU.panel then VU.panel:SetVisible(false) end
	VU.mode, VU.open_family, VU.pending = nil, nil, nil
end

-- Which unit type (list mode) a clicked component belongs to.
local function vu_fam_for(addr)
	local cur = addr
	for _ = 1, 6 do
		if cur == nil then return nil end
		local fam = VU.node_fam and VU.node_fam[addr_key(cur)]
		if fam then return fam end
		local ok, p = pcall(function() return UIComponent(cur):Parent() end)
		if not ok then return nil end
		cur = p
	end
	return nil
end

-- Find which upgrade node (if any) a clicked component belongs to.
local function vu_node_for(addr)
	local cur = addr
	for _ = 1, 6 do
		if cur == nil then return nil end
		local line = VU.node_line[addr_key(cur)]
		if line then return line end
		local ok, p = pcall(function() return UIComponent(cur):Parent() end)
		if not ok then return nil end
		cur = p
	end
	return nil
end

-------------------------------------------------------------------------------
-- HUD button: a clone of the popup's own (inert) "?" button, placed beside the unit cards.
-------------------------------------------------------------------------------
local VU_BUTTON_ICON = "data/ui/frontend ui/skills/skill_melee_attack.tga"

local function vu_card_family(card_addr)
	local name = string.match(tostring(UIComponent(card_addr):GetTooltipText()), "^[^\n]*") or ""
	return VU_BY_NAME[name], name
end

-- The army panel's currently selected unit card, if any.
local function vu_selected_card()
	local group = VU.root:Find("s2_LandUnitCardGroup")
	if not group then return nil end
	local g = UIComponent(group)
	for i = 0, g:ChildCount() - 1 do
		local card = g:Find(i)
		if tostring(UIComponent(card):CurrentState()) == "selected" then return card end
	end
	return nil
end

local function vu_place_hud_button()
	if not VU.button then return end
	local b = UIComponent(VU.button)
	local x, y = 20, 220
	local adv
	for _, id in ipairs({ "button_show_advice", "button_show_advice_male", "button_show_advice_female", "show_advice" }) do
		local ok, a = pcall(function() return VU.root:Find(id) end)
		if ok and a then
			local vis = false
			pcall(function() vis = UIComponent(a):Visible() end)
			if vis then adv = a vu_log("hud anchor:", id) break end
			adv = adv or a
		end
	end
	if adv then
		pcall(function()
			local a = UIComponent(adv)
			local ax, ay = a:Position()
			x, y = ax + (a:Width() - b:Width()) / 2, ay + a:Height() + 8
		end)
	end
	pcall(function() b:MoveTo(math.floor(x), math.floor(y)) end)
	vu_log("hud button at", math.floor(x), math.floor(y), adv and "(below the show-advice button)" or "(fallback position)")
end

local function vu_create_hud_button()
	if VU.button then return end
	if not vu_create_panel() then return end
	local template = VU.nodes[#VU.nodes]
	if not template then vu_log("hud button: no template node") return end
	local addr = Component.CreateFromComponent(template.addr, "vu_button", VU.root_addr, 0, 0, {}, {})
	if not addr then vu_log("hud button: CreateFromComponent returned nil") return end
	VU.button = addr
	local b = UIComponent(addr)
	-- Hide everything in the cloned node except its icon and label; arrows and level pips go.
	local icon, name
	for i = 0, b:ChildCount() - 1 do
		local child = b:Find(i)
		local cid = tostring(UIComponent(child):Id())
		if cid == "skill_icon" then icon = child
		elseif cid == "skill_name" then name = child
		else pcall(function() UIComponent(child):SetVisible(false) end) end
	end
	local tip = "Veteran Upgrades\nSpend your clan's points (1 per battle fought) on upgrades for any unit type."
	for _, a in ipairs({ addr, icon, name }) do
		if a then pcall(function() UIComponent(a):SetTooltipText(tip, true) end) end
	end
	if icon then
		pcall(function() UIImage(VU_BUTTON_ICON):SetComponentTexture(icon, 0) end)
		pcall(function() UIComponent(icon):ShaderTechniqueSet("normal_t0", true) end)
	end
	vu_set_text(name, "Veterans")
	-- Let the node itself receive the mouse, so it highlights on hover and presses on click.
	for _, a in ipairs({ icon, name }) do
		if a then pcall(function() UIComponent(a):SetInteractive(false) end) end
	end
	pcall(function() b:SetInteractive(true) end)
	pcall(function() b:SetState("active") end)
	pcall(function() b:SetVisible(true) end)
	vu_place_hud_button()
end

-- Is this component our HUD button or one of its children?
local function vu_is_button(addr)
	if not VU.button then return false end
	local cur = addr
	for _ = 1, 3 do
		if cur == nil then return false end
		if addr_key(cur) == addr_key(VU.button) then return true end
		local ok, p = pcall(function() return UIComponent(cur):Parent() end)
		if not ok then return false end
		cur = p
	end
	return false
end

local function vu_open_for_card(card)
	if not card then vu_log("open: no unit card selected") return end
	local fam, name = vu_card_family(card)
	vu_log("open request:", tostring(UIComponent(card):Id()), "name", name, "family", fam and fam.id or "none")
	if fam then vu_open(fam) end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
local function VU_OnUICreated(context)
	vu_guard("UICreated", function()
		if context.string ~= "Campaign UI" then return end
		VU.root_addr = context.component
		VU.root = UIComponent(context.component)
		-- The campaign UI is rebuilt after every battle: drop every reference to old components.
		VU.panel, VU.panel_addr, VU.nodes, VU.nodes_by_id, VU.arrows = nil, nil, {}, {}, {}
		VU.tree_addr, VU.title_box, VU.title_label = nil, nil, nil
		VU.list_nodes, VU.cat_headers, VU.assign, VU.layout_for = nil, nil, nil, nil
		VU.node_line, VU.node_fam, VU.bounds_logged = {}, {}, nil
		VU.mode, VU.open_family, VU.pending, VU.from_list = nil, nil, nil, false
		pcall(function() VU.player = CampaignUI.PlayerFactionId() end)
		vu_guard("mp legacy", vu_mp_settle_legacy, nil)
		VU.button, VU.layout_for = nil, nil
		VU.retrain_node, VU.retrain_armed, VU.title_node, VU.page_node, VU.list_page = nil, false, nil, nil, 1
		vu_log("==== Veteran Upgrades " .. VU_VERSION .. " loaded; player", tostring(VU.player), vu_is_mp() and "(multiplayer)" or "", "====")
		vu_guard("create hud button", vu_create_hud_button)
		if VU.panel then VU.panel:SetVisible(false) end
	end)
end

local VU_LOCK_ALL, VU_PRELOCK   -- set by the recruitment code below

local function VU_OnNewCampaignStarted(context)
	vu_guard("NewCampaignStarted", function()
		VU.pool = VU_START_POINTS
		vu_log("new campaign: clan starts with", VU_START_POINTS, "points")
		-- Lock every copy for every clan now, like vanilla's own restrictions here: locks set at the
		-- first turn start only take effect at the next turn change (copies were recruitable on turn 1),
		-- and the local player isn't known yet (FactionKeyIsLocal is false for all). This also keeps
		-- the AI off the copies. The player's earned copies are unlocked at turn start.
		if VU_PRELOCK then VU_PRELOCK() end
	end)
end

local vu_ai_spend, vu_ai_clan   -- defined with the points code below

-- Multiplayer: every human clan's applied state (VU_MP marks the format; single-player saves keep the
-- old keys, so they still load in older versions). Unsent purchases aren't saved.
local function vu_save_humans(gi, context)
	gi:save_named_value("VU_MP", 1, context)
	local n = 0
	for _, faction in ipairs(VU_FACTIONS) do
		local h = VU.hum and VU.hum[faction]
		if h then
			n = n + 1
			gi:save_named_value("VU_H_" .. faction, 1, context)
			gi:save_named_value("VU_HPOOL_" .. faction, h.pool, context)
			gi:save_named_value("VU_HSEQ_" .. faction, h.seq, context)
			for _, fam in ipairs(VU_FAMILIES) do
				local lv = h.levels[fam.id] or {}
				for _, line in ipairs(fam.lines) do
					if (lv[line.key] or 0) > 0 then gi:save_named_value("VU_HL_" .. faction .. "__" .. fam.id .. "__" .. line.key, lv[line.key], context) end
				end
			end
		end
	end
	return n
end

local function vu_load_humans(gi, context)
	VU.hum = {}
	local n = 0
	for _, faction in ipairs(VU_FACTIONS) do
		if gi:load_named_value("VU_H_" .. faction, 0, context) == 1 then
			n = n + 1
			local h = vu_hum(faction)
			h.pool = gi:load_named_value("VU_HPOOL_" .. faction, VU_START_POINTS, context)
			h.seq = gi:load_named_value("VU_HSEQ_" .. faction, 0, context)
			for _, fam in ipairs(VU_FAMILIES) do
				local lv = {}
				for _, line in ipairs(fam.lines) do
					local l = gi:load_named_value("VU_HL_" .. faction .. "__" .. fam.id .. "__" .. line.key, 0, context)
					if l > 0 then lv[line.key] = l end
				end
				if next(lv) then h.levels[fam.id] = lv end
			end
		end
	end
	return n
end

local function VU_OnSavingGame(context)
	vu_guard("SavingGame", function()
		local gi = EpisodicScripting.game_interface
		if vu_is_mp() and not VU.legacy_mp then   -- an older save not yet refunded keeps its format
			vu_log("saved", vu_save_humans(gi, context), "human clans (multiplayer)")
		else
			gi:save_named_value("VU_POOL", VU.pool or 0, context)
			for _, fam in ipairs(VU_FAMILIES) do
				for _, line in ipairs(fam.lines) do
					gi:save_named_value("VU_L_" .. fam.id .. "__" .. line.key, vu_level(fam.id, line.key), context)
				end
			end
		end
		-- AI clans: a flag per clan, its pool, and per unit type it has fought with the levels packed
		-- base 16 (levels go up to 10).
		local n = 0
		for faction, clan in pairs(VU.ai or {}) do
			gi:save_named_value("VU_AF_" .. faction, 1, context)
			gi:save_named_value("VU_APOOL_" .. faction, clan.pool, context)
			for _, fam in ipairs(VU_FAMILIES) do
				if clan.used[fam.id] then
					local lv, packed = clan.levels[fam.id] or {}, 0
					for i = #fam.lines, 1, -1 do packed = packed * 16 + (lv[fam.lines[i].key] or 0) end
					gi:save_named_value("VU_AU_" .. faction .. "__" .. fam.id, 1, context)
					gi:save_named_value("VU_AL_" .. faction .. "__" .. fam.id, packed, context)
				end
			end
			n = n + 1
		end
		vu_log("saved state; pool", VU.pool or 0, "|", n, "AI clans")
	end)
end

local function VU_OnLoadingGame(context)
	vu_guard("LoadingGame", function()
		local gi = EpisodicScripting.game_interface
		VU.legacy, VU.legacy_mp = nil, nil
		if gi:load_named_value("VU_MP", 0, context) == 1 then
			vu_log("loaded", vu_load_humans(gi, context), "human clans (multiplayer)")
		else
			VU.pool = gi:load_named_value("VU_POOL", VU.pool or VU_START_POINTS, context)
			for _, fam in ipairs(VU_FAMILIES) do
				VU.levels[fam.id] = {}
				for _, line in ipairs(fam.lines) do
					VU.levels[fam.id][line.key] = gi:load_named_value("VU_L_" .. fam.id .. "__" .. line.key, 0, context)
				end
			end
			-- Single-player format: if this turns out to be a multiplayer campaign, vu_mp_settle_legacy
			-- refunds it (CampaignUI.IsMultiplayer isn't available yet).
			VU.legacy = { pool = VU.pool, levels = VU.levels }
		end
		VU.ai = {}
		local n = 0
		for _, faction in ipairs(VU_FACTIONS) do
			if gi:load_named_value("VU_AF_" .. faction, 0, context) == 1 then
				n = n + 1
				local clan = vu_ai_clan(faction)
				clan.pool = gi:load_named_value("VU_APOOL_" .. faction, 0, context)
				for _, fam in ipairs(VU_FAMILIES) do
					if gi:load_named_value("VU_AU_" .. faction .. "__" .. fam.id, 0, context) == 1 then
						clan.used[fam.id] = true
						local packed, lv = gi:load_named_value("VU_AL_" .. faction .. "__" .. fam.id, 0, context), {}
						for i = 1, #fam.lines do
							local l = packed % 16
							if l > 0 then lv[fam.lines[i].key] = l end
							packed = (packed - l) / 16
						end
						clan.levels[fam.id] = lv
					end
				end
			end
		end
		vu_log("loaded state: pool", VU.pool, "|", n, "AI clans")
		-- No prelock here: LoadingGame fires mid model-load, and the lock call crashed inside the
		-- engine's restriction list (v0.16). Saves keep their locks; vanilla restricts in NewCampaignStarted.
	end)
end

-------------------------------------------------------------------------------
-- Recruitment: ability unlocks are unit copies (<key>_VU<mask>, bit i = fam.abilities[i]).
-- add_event_restricted_unit_record_for_faction(unit, faction) locks a unit for one clan only
-- (confirmed v0.10g); add_restricted_unit_record is global and would lock the AI out too.
-------------------------------------------------------------------------------
local function vu_mask(fam, levels)
	local mask = 0
	for i, line_key in ipairs(fam.abilities) do
		if (levels[line_key] or 0) > 0 then mask = mask + 2 ^ (i - 1) end
	end
	return mask
end

local function vu_committed_levels(fam)
	local lv = {}
	for _, line in ipairs(fam.lines) do lv[line.key] = vu_level(fam.id, line.key) end
	return lv
end

-- The unit key the clan should field for this base unit, given an ability mask.
local function vu_target(copy, mask)
	if mask == 0 then return copy.base end
	return copy.keys[mask]
end

-- Per-clan locks are queued and take effect at the next turn change. (Toggling the global restriction
-- applies them at once, but left the game crashing on the next character selection, v0.12l.)
-- Lock every version of the family's units except the current target, for one clan (default: the
-- local player, with its committed levels; multiplayer passes the clan and its applied levels).
local function vu_apply_recruitment(fam, refresh, faction, levels)
	faction = faction or VU.player
	if not faction or #fam.copies == 0 then return end
	local gi = vu_gi()
	local mask = vu_mask(fam, levels or vu_committed_levels(fam))
	VU.locked_by = VU.locked_by or {}
	VU.locked_by[faction] = VU.locked_by[faction] or {}
	local locked = VU.locked_by[faction]
	local changed = false
	for _, copy in ipairs(fam.copies) do
		local target = vu_target(copy, mask)
		local all = { copy.base }
		for _, k in ipairs(copy.keys) do all[#all + 1] = k end
		for _, key in ipairs(all) do
			local lock = key ~= target
			-- First pass in a session (was == nil): only lock. A key that should stay recruitable is
			-- either never locked (new campaign) or still unlocked in the save, so it needs no call.
			local was = locked[key]
			if was == nil and VU.prelocked and key ~= copy.base then was = true end   -- locked for every clan
			if was == nil and not lock then locked[key] = false was = false end
			if was ~= lock then
				if lock then gi:add_event_restricted_unit_record_for_faction(key, faction)
				else gi:remove_event_restricted_unit_record_for_faction(key, faction) end
				locked[key] = lock
				changed = true
			end
		end
	end
	vu_log("recruitment:", fam.id, faction, "ability mask", mask)
	-- No immediate refresh: toggling the global restriction (vu_refresh_recruitment) left the game
	-- crashing on the next character selection (v0.12l). Changes apply at the next turn change.
end

-------------------------------------------------------------------------------
-- Retraining: units of the selected army whose ability set is out of date are replaced by
-- the right copy. The engine can't add a unit to an existing army, so the copies spawn as one
-- stack beside the army (create_force, no general) and the originals are disbanded.
--   * unit pointer: card:InterfaceFunction('ItemAddress') (as CA's unit card does)
--   * army position: RetrieveFactionMilitaryForceLists entry whose Address is the card's CharacterPtr
-- The copies start without experience (the engine can't set one unit's experience).
-------------------------------------------------------------------------------
local VU_KEY_INFO = {}   -- unit key -> { fam, copy }
for _, fam in ipairs(VU_FAMILIES) do
	fam.all_keys = {}
	for _, u in ipairs(fam.units) do fam.all_keys[#fam.all_keys + 1] = u end
	for _, copy in ipairs(fam.copies) do
		VU_KEY_INFO[copy.base] = { fam = fam, copy = copy }
		for _, k in ipairs(copy.keys) do
			VU_KEY_INFO[k] = { fam = fam, copy = copy }
			fam.all_keys[#fam.all_keys + 1] = k
		end
	end
end
local VU_RETRAIN_OFFSET = 1.0   -- map distance between the army and the spawned stack

-- Is this unit (pointer) of the family and on an out-of-date ability set? -> candidate row.
local function vu_candidate(fam, mask, unit)
	local d = unit and CampaignUI.InitialiseUnitDetails(unit)
	local key = d and d.UnitRecord and d.UnitRecord.Key
	local info = key and VU_KEY_INFO[key]
	if info and info.fam == fam then
		local to = vu_target(info.copy, mask)
		if to ~= key then return { unit = unit, from = key, to = to, xp = d.Experience or 0 }, d, key end
	end
	return nil, d, key
end

-- Units in the selected army's cards, or nil when no army is selected.
local function vu_selected_army_units()
	local group = VU.root:Find("s2_LandUnitCardGroup")
	if not group then return nil end
	local g = UIComponent(group)
	local visible = true
	pcall(function() visible = g:Visible() end)
	if g:ChildCount() == 0 or not visible then return nil end
	local units = {}
	for i = 0, g:ChildCount() - 1 do
		units[#units + 1] = UIComponent(g:Find(i)):InterfaceFunction("ItemAddress")
	end
	return units
end

-- Units of one army by its general: the exchange panel's own call. Its second argument must be a
-- character or a garrison (null crashes, DLL RVA 0x1147850); the army's own general is valid.
local function vu_army_units(char)
	local ents = CampaignUI.RetrieveContainedEntitiesFromCharacter(char, char)
	if not VU.ents_logged then
		VU.ents_logged = true
		local keys = {}
		for k, v in pairs(ents or {}) do keys[#keys + 1] = tostring(k) .. "=" .. type(v) end
		vu_log("retrain: contained entities fields:", table.concat(keys, " "))
		local first = ents and ents.Units and ents.Units[1]
		if type(first) == "table" then
			local f = {}
			for k, v in pairs(first) do f[#f + 1] = tostring(k) .. "=" .. tostring(v) end
			vu_log("retrain: first unit entry:", table.concat(f, " "))
		end
	end
	local units = {}
	for _, v in ipairs((ents and ents.Units) or {}) do
		units[#units + 1] = type(v) == "table" and v.Address or v
	end
	return units
end

-- Units of this family needing retraining, grouped by army: { { char, rows }, ... }.
-- With an army selected: that army only. Otherwise: every army with a general.
local function vu_retrain_candidates(fam, levels)
	local armies = {}
	VU.retrain_why, VU.retrain_all = nil, false
	if not VU.root or #fam.copies == 0 then VU.retrain_why = "(no copies)" return armies end
	local mask = vu_mask(fam, levels or vu_committed_levels(fam))
	local selected = vu_selected_army_units()
	if selected then
		local rows, seen, char = {}, {}, nil
		for _, unit in ipairs(selected) do
			local row, d, key = vu_candidate(fam, mask, unit)
			seen[#seen + 1] = tostring(key)
			char = char or (d and d.CharacterPtr)   -- only the general's card carries it
			if row then rows[#rows + 1] = row end
		end
		VU.retrain_why = "(selected army cards: " .. table.concat(seen, ", ") .. ")"
		-- The new stack is placed by the general's map position, so an army without one can't retrain.
		if not char then VU.retrain_why = "(no general in the selected army) " .. VU.retrain_why return armies end
		if #rows > 0 then armies[1] = { char = char, rows = rows } end
		return armies
	end
	VU.retrain_all = true
	local n = 0
	for _, f in ipairs(CampaignUI.RetrieveFactionMilitaryForceLists(VU.player, true) or {}) do
		if f.Address then
			n = n + 1
			local rows = {}
			for _, unit in ipairs(vu_army_units(f.Address)) do
				local row = vu_candidate(fam, mask, unit)
				if row then rows[#rows + 1] = row end
			end
			if #rows > 0 then armies[#armies + 1] = { char = f.Address, rows = rows, x = f.PosX, y = f.PosY, name = f.Name } end
		end
	end
	VU.retrain_why = "(all armies: " .. n .. " with a general)"
	return armies
end

vu_count_rows = function(armies)
	local n, xp = 0, 0
	for _, a in ipairs(armies) do
		for _, r in ipairs(a.rows) do n = n + 1 if r.xp > 0 then xp = xp + 1 end end
	end
	return n, xp
end

local function vu_army_position(char)
	if not char then return nil end
	for _, f in ipairs(CampaignUI.RetrieveFactionMilitaryForceLists(VU.player, true) or {}) do
		if tostring(f.Address) == tostring(char) then return f.PosX, f.PosY, f.Name end
	end
	return nil
end

local function vu_retrain(fam)
	local armies = vu_retrain_candidates(fam)
	if #armies == 0 then vu_log("retrain:", fam.id, "nothing to retrain", VU.retrain_why or "") return end
	local gi = vu_gi()
	for _, army in ipairs(armies) do
		local x, y, name = army.x, army.y, army.name
		if not x then x, y, name = vu_army_position(army.char) end
		if not x then
			vu_log("retrain: army position not found, skipped")
		else
			local keys = {}
			for _, r in ipairs(army.rows) do keys[#keys + 1] = r.to end
			VU.retrain_n = (VU.retrain_n or 0) + 1
			local id = "vu_retrain_" .. VU.retrain_n
			vu_log("retrain:", fam.id, #army.rows, "units of", name, "-> create_force", table.concat(keys, ","), "at", x + VU_RETRAIN_OFFSET, y)
			gi:create_force(VU.player, table.concat(keys, ","), x + VU_RETRAIN_OFFSET, y, id, true)
			for _, r in ipairs(army.rows) do
				vu_log("retrain: disband", r.from, "(experience", r.xp .. ")")
				CampaignUI.DisbandUnit(r.unit)
				VU.doomed = VU.doomed or {}
				VU.doomed[addr_key(r.unit)] = true   -- multiplayer: no message on a unit that's going
			end
		end
	end
	vu_log("retrain: done")
	if vu_is_mp() then vu_mp_send() end
end

VU_RETRAIN_CANDIDATES, VU_RETRAIN = vu_retrain_candidates, vu_retrain

VU_PRELOCK = function()
	if VU.prelocked then return end   -- LoadingGame and NewCampaignStarted both fire on a new campaign
	local gi, n = EpisodicScripting.game_interface, 0   -- untraced: thousands of calls at campaign start
	for _, fam in ipairs(VU_FAMILIES) do
		for _, copy in ipairs(fam.copies) do
			for _, key in ipairs(copy.keys) do
				for _, faction in ipairs(VU_FACTIONS) do
					gi:add_event_restricted_unit_record_for_faction(key, faction)
					n = n + 1
				end
			end
		end
	end
	VU.prelocked = true
	vu_log("prelocked copies for all clans:", n, "locks")
end

VU_LOCK_ALL = function()
	for _, fam in ipairs(VU_FAMILIES) do vu_guard("recruitment " .. fam.id, vu_apply_recruitment, fam) end
end

VU_AFTER_COMMIT = function(fam) vu_guard("recruitment " .. fam.id, vu_apply_recruitment, fam, true) end

-------------------------------------------------------------------------------
-- Multiplayer campaigns. The game keeps every player's campaign in lockstep: game events (turn
-- start/end, battles) run these scripts on every machine at the same point, but a click in our panel
-- runs on one machine only. Up to 1.1.0 a purchase applied its bundles from the click, so only the
-- buyer's game changed; the end-of-turn check found the games out of sync and the game resynced
-- everyone from the host (the guest's upgrades vanished, the host's were kept).
-- Now a confirmed purchase is only sent, and every machine applies it at the same point:
--   * send (buyer's machine): the purchases of this turn (VU.outbox) are written into the names of
--     some of the buyer's units with CampaignUI.SetMyUnitName - renaming a unit is a game command,
--     which the game delivers to every machine in order. Name = "VU" .. seq .. part .. parts .. data.
--   * receive (every machine, at the buyer's FactionTurnEnd): read that clan's unit names
--     (RegimentName), apply the newest complete message (bundles, copy locks, points) to the clan.
--   * the buyer's machine puts the units' names back at its next turn start.
-- Each human clan's points and upgrades (VU.hum) are therefore the same on every machine; points come
-- from battles (grouped by game events, not the clock - see VU_OnUnitCompletedBattle). Only the local
-- player's unsent purchases (VU.outbox) differ, and the panel shows them as owned.
-------------------------------------------------------------------------------
local VU_MP_CHUNK = 24   -- data characters per unit name (plus the 5-character "VU" header)
local VU_B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function vu_b36(n) n = math.max(0, math.min(35, math.floor(n))) return string.sub(VU_B36, n + 1, n + 1) end
local function vu_unb36(c) local i = c and c ~= "" and string.find(VU_B36, c, 1, true) return i and i - 1 end

-- A human clan's applied state, identical on every machine.
vu_hum = function(faction)
	VU.hum = VU.hum or {}
	local h = VU.hum[faction]
	if not h then h = { pool = VU_START_POINTS, levels = {}, seq = 0 } VU.hum[faction] = h end
	return h
end

vu_mp_view_level = function(fam_id, line_key)
	local o = VU.outbox and VU.outbox[fam_id]
	if o then return o.levels[line_key] or 0 end
	local lv = VU.player and vu_hum(VU.player).levels[fam_id]
	return (lv and lv[line_key]) or 0
end

vu_mp_view_points = function()
	if not VU.player then return 0 end
	local h = vu_hum(VU.player)
	local pts = h.pool
	for _, fam in ipairs(VU_FAMILIES) do
		local o = VU.outbox and VU.outbox[fam.id]
		if o then pts = pts - (vu_spent(fam, o.levels) - vu_spent(fam, h.levels[fam.id] or {})) - o.fee end
	end
	return pts
end

local function vu_mp_my_turn()
	if VU.my_turn ~= nil then return VU.my_turn end
	local ok, r = pcall(function() return CampaignUI.IsPlayersTurn() end)   -- loaded mid-turn
	return ok and r == true
end

local function vu_mp_name_parts(name)
	return string.match(tostring(name or ""), "^VU(%w)(%w)(%w)(%w*)$")
end

-- The clan's units in its armies (those with a general), in army order: { { addr, name } }.
local function vu_mp_units(faction)
	local out = {}
	for _, f in ipairs(CampaignUI.RetrieveFactionMilitaryForceLists(faction, true) or {}) do
		if f.Address then
			for _, unit in ipairs(vu_army_units(f.Address)) do
				local name = ""
				pcall(function() name = tostring(CampaignUI.RegimentName(unit) or "") end)
				out[#out + 1] = { addr = unit, name = name }
			end
		end
	end
	return out
end

-- Units have no custom name unless renamed (RegimentName is "" in a 1.1.0 multiplayer log), so a name
-- not recorded this session (renamed before a reload) goes back to "".
local function vu_mp_original_name(u)
	return VU.orig_names and VU.orig_names[addr_key(u.addr)] or ""
end

local function vu_mp_rename(u, name)
	VU.orig_names = VU.orig_names or {}
	local k = addr_key(u.addr)
	if not vu_mp_name_parts(u.name) and VU.orig_names[k] == nil then VU.orig_names[k] = u.name end
	CampaignUI.SetMyUnitName(u.addr, name)
	u.name = name
end

-- This turn's purchases, per family: index (2), fee (1), changed lines (1), then line index + level
-- pairs - absolute levels, so a message can be applied twice without harm.
local function vu_mp_payload(h)
	local parts = {}
	for i, fam in ipairs(VU_FAMILIES) do
		local o = VU.outbox and VU.outbox[fam.id]
		if o then
			local applied, changed = h.levels[fam.id] or {}, {}
			for li, line in ipairs(fam.lines) do
				local lv = o.levels[line.key] or 0
				if lv ~= (applied[line.key] or 0) then changed[#changed + 1] = vu_b36(li - 1) .. vu_b36(lv) end
			end
			if #changed > 0 or o.fee > 0 then
				parts[#parts + 1] = vu_b36((i - 1) / 36) .. vu_b36((i - 1) % 36) .. vu_b36(o.fee) .. vu_b36(#changed) .. table.concat(changed)
			end
		end
	end
	return table.concat(parts)
end

-- Write this turn's purchases into unit names (or clear old ones). Local player, own turn only.
vu_mp_send = function()
	if not VU.player then return end
	if not vu_mp_my_turn() then vu_log("mp: not your turn - purchases are sent at your next turn start") return end
	local h = vu_hum(VU.player)
	local data = vu_mp_payload(h)
	local chunks = {}
	for i = 1, #data, VU_MP_CHUNK do chunks[#chunks + 1] = string.sub(data, i, i + VU_MP_CHUNK - 1) end
	local units = {}
	for _, u in ipairs(vu_mp_units(VU.player)) do
		if not (VU.doomed and VU.doomed[addr_key(u.addr)]) then units[#units + 1] = u end
	end
	if #chunks > 35 or #chunks > #units then
		VU.mp_problem = string.format("Can't send your upgrades: they need %d units in armies with a general (you have %d).", #chunks, #units)
		vu_log("mp:", VU.mp_problem)
		return
	end
	VU.mp_problem = nil
	-- A new number for every send (counting on across turns, so a leftover older message can't look
	-- newer), never the one last applied (receivers skip that one).
	VU.send_seq = ((VU.send_seq or h.seq) + 1) % 36
	if VU.send_seq == h.seq then VU.send_seq = (VU.send_seq + 1) % 36 end
	local seq, restored = vu_b36(VU.send_seq), 0
	for i, u in ipairs(units) do
		if i <= #chunks then
			vu_mp_rename(u, "VU" .. seq .. vu_b36(i - 1) .. vu_b36(#chunks) .. chunks[i])
		elseif vu_mp_name_parts(u.name) then
			vu_mp_rename(u, vu_mp_original_name(u))   -- part of an earlier message
			restored = restored + 1
		end
	end
	VU.sent_seq = #chunks > 0 and VU.send_seq or nil
	if #chunks > 0 or restored > 0 then
		vu_log("mp: sent", #data, "characters in", #chunks, "unit names, seq", seq, data, "| names put back:", restored)
	end
end

vu_mp_commit = function(p)
	local fam = p.fam
	local h = vu_hum(VU.player)
	local view = {}
	for _, l in ipairs(fam.lines) do view[l.key] = vu_level(fam.id, l.key) end
	local fee = (vu_points() - p.points) - (vu_spent(fam, p.levels) - vu_spent(fam, view))   -- respec fee
	VU.outbox = VU.outbox or {}
	local o = VU.outbox[fam.id] or { levels = {}, fee = 0 }
	for _, l in ipairs(fam.lines) do o.levels[l.key] = p.levels[l.key] or 0 end
	o.fee = o.fee + math.max(0, fee)
	local applied, same = h.levels[fam.id] or {}, o.fee == 0
	for _, l in ipairs(fam.lines) do if o.levels[l.key] ~= (applied[l.key] or 0) then same = false end end
	VU.outbox[fam.id] = (not same) and o or nil
	vu_log("mp: purchase for", fam.id, "queued, fee", fee, "| points now", vu_points())
	vu_mp_send()
end

-- Apply one family's new levels (only the lines given) and respec fee to a human clan.
local function vu_mp_apply(faction, fam, new, fee)
	local h = vu_hum(faction)
	local gi = vu_gi()
	local cur = h.levels[fam.id] or {}
	local nxt = {}
	for _, line in ipairs(fam.lines) do
		local old, lv = cur[line.key] or 0, new[line.key] or cur[line.key] or 0
		if old ~= lv then
			if old > 0 and line.levels[old].bundle ~= "" then gi:remove_effect_bundle(line.levels[old].bundle, faction) end
			if lv > 0 and line.levels[lv].bundle ~= "" then gi:apply_effect_bundle(line.levels[lv].bundle, faction, 0) end
			vu_log("mp: COMMIT", faction, fam.id, line.key, old, "->", lv)
		end
		if lv > 0 then nxt[line.key] = lv end
	end
	h.pool = h.pool - (vu_spent(fam, nxt) - vu_spent(fam, cur)) - fee
	h.levels[fam.id] = nxt
	vu_apply_recruitment(fam, false, faction, nxt)
end

local function vu_mp_apply_message(faction, data)
	local pos = 1
	local function take() local c = string.sub(data, pos, pos) pos = pos + 1 return vu_unb36(c) end
	while pos + 3 <= #data do
		local idx = (take() or 0) * 36 + (take() or 0)
		local fee, n = take() or 0, take() or 0
		local fam, new = VU_FAMILIES[idx + 1], {}
		for _ = 1, n do
			local li, lv = take(), take()
			local line = fam and li and fam.lines[li + 1]
			if line and lv then new[line.key] = math.min(lv, #line.levels) end
		end
		if fam then vu_mp_apply(faction, fam, new, fee)
		else vu_log("mp: !! message names an unknown unit type", idx, "- are both players on the same version?") end
	end
end

-- Every machine, at a human clan's FactionTurnEnd: read and apply its newest message.
-- Returns the applied message's number, or nil.
local function vu_mp_receive(faction)
	local h = vu_hum(faction)
	local sets, found = {}, 0
	for _, u in ipairs(vu_mp_units(faction)) do
		local s, i, n, data = vu_mp_name_parts(u.name)
		if s then
			found = found + 1
			local key = s .. n
			sets[key] = sets[key] or { seq = vu_unb36(s), n = vu_unb36(n), parts = {} }
			local idx = vu_unb36(i)
			if idx then sets[key].parts[idx + 1] = data end
		end
	end
	local best
	for _, set in pairs(sets) do   -- the pick depends only on the sets, not on pairs() order
		local complete = set.seq and set.n and set.n > 0
		for c = 1, set.n or 0 do if not set.parts[c] then complete = false end end
		if complete then
			set.age = (set.seq - h.seq) % 36
			if set.age > 0 and (not best or set.age > best.age or (set.age == best.age and set.n > best.n)) then best = set end
		end
	end
	if not best then
		if found > 0 then vu_log("mp:", faction, "has", found, "upgrade unit names but no new complete message") end
		return nil
	end
	local data = table.concat(best.parts, "", 1, best.n)
	vu_log("mp: applying", faction, "message seq", best.seq, data)
	vu_mp_apply_message(faction, data)
	h.seq = best.seq
	return best.seq
end

-- Older saves of a multiplayer campaign hold one clan's upgrades with no owner (up to 1.1.0 they were
-- the host's, in a pool fed by every player's battles), and no machine can tell whose. Refund them to
-- every human clan as points: same result on every machine. Runs at the first game event with a
-- context (FactionIsHuman needs one).
vu_mp_settle_legacy = function(context)
	if VU.legacy and vu_is_mp() then
		local L = VU.legacy
		local refund, any = L.pool or 0, false
		for _, fam in ipairs(VU_FAMILIES) do
			local s = vu_spent(fam, L.levels[fam.id] or {})
			refund, any = refund + s, any or s > 0
		end
		VU.legacy_mp = (any or refund ~= VU_START_POINTS) and { refund = refund, levels = L.levels } or nil
	end
	if VU.mp ~= nil then VU.legacy = nil end
	local L = VU.legacy_mp
	if not L or not context then return end
	VU.legacy_mp = nil
	local gi = vu_gi()
	for _, faction in ipairs(VU_FACTIONS) do
		local ok, human = pcall(conditions.FactionIsHuman, faction, context)
		if ok and human then
			for _, fam in ipairs(VU_FAMILIES) do
				local lv = L.levels[fam.id] or {}
				for _, line in ipairs(fam.lines) do
					local l = lv[line.key] or 0
					if l > 0 and line.levels[l].bundle ~= "" then gi:remove_effect_bundle(line.levels[l].bundle, faction) end
				end
				if vu_mask(fam, lv) > 0 then   -- the plain units were locked for the owner
					for _, copy in ipairs(fam.copies) do gi:remove_event_restricted_unit_record_for_faction(copy.base, faction) end
				end
			end
			local h = vu_hum(faction)
			h.pool, h.levels = L.refund, {}
			vu_log("mp: upgrades from an older save refunded to", faction, "as", L.refund, "points")
		end
	end
end

-- A human clan's turn starts (every machine). Its copy locks get their first pass; the local player's
-- machine then puts back unit names and sends anything still unsent (time trigger: after the event).
local function vu_mp_turn_start(faction)
	local h = vu_hum(faction)
	VU.recruit_applied_by = VU.recruit_applied_by or {}
	if not VU.recruit_applied_by[faction] then
		VU.recruit_applied_by[faction] = true
		for _, fam in ipairs(VU_FAMILIES) do
			vu_guard("recruitment " .. fam.id, vu_apply_recruitment, fam, false, faction, h.levels[fam.id] or {})
		end
	end
	VU.debug_granted_by = VU.debug_granted_by or {}
	if VU_DEBUG and not VU_UNDER_TEST and not VU.debug_granted_by[faction] then   -- same on every machine
		VU.debug_granted_by[faction] = true
		h.pool = h.pool + 100
		vu_log("DEBUG: granted 100 points to", faction, "pool", h.pool)
	end
	if faction ~= VU.player then return end
	VU.my_turn, VU.doomed = true, {}
	if not VU.button then vu_guard("create hud button", vu_create_hud_button)
	else vu_guard("place hud button", vu_place_hud_button) end
	EpisodicScripting.game_interface:add_time_trigger("vu_mp_turn", 0.5)
end

-- A human clan's turn ends (every machine).
local function vu_mp_turn_end(faction)
	local seq = vu_mp_receive(faction)
	if faction ~= VU.player then return end
	VU.my_turn = false
	if seq and seq == VU.sent_seq then
		VU.outbox = nil
	elseif VU.outbox then
		-- Not received (a named unit was lost, or it was sent out of turn): send again next turn,
		-- minus whatever an older message already applied.
		local h = vu_hum(VU.player)
		for _, fam in ipairs(VU_FAMILIES) do
			local o = VU.outbox[fam.id]
			if o then
				if seq then o.fee = 0 end
				local applied, same = h.levels[fam.id] or {}, o.fee == 0
				for _, l in ipairs(fam.lines) do if (o.levels[l.key] or 0) ~= (applied[l.key] or 0) then same = false end end
				if same then VU.outbox[fam.id] = nil end
			end
		end
		if next(VU.outbox) then vu_log("mp: purchases not received this turn; sending again next turn") end
	end
	VU.sent_seq = nil
end

local function VU_OnFactionTurnStart(context)
	vu_guard("FactionTurnStart", function()
		local mp = vu_is_mp()
		if mp then
			vu_guard("mp legacy", vu_mp_settle_legacy, context)
			VU.battle_earned = {}   -- multiplayer battle grouping, see VU_OnUnitCompletedBattle
		end
		if not conditions.FactionIsHuman(context.string, context) then
			vu_guard("AI spend " .. tostring(context.string), vu_ai_spend, context.string)
			return
		end
		if mp then vu_guard("mp turn start", vu_mp_turn_start, context.string) return end
		if conditions.FactionIsHuman(context.string, context) then
			VU.player = context.string
			if VU_DEBUG and not VU.debug_granted and not VU_UNDER_TEST then   -- debug builds: points to reproduce bugs without battles
				VU.debug_granted = true
				VU.pool = (VU.pool or 0) + 100
				vu_log("DEBUG: granted 100 points, pool", VU.pool)
			end
			if not VU.recruit_applied then
				VU.recruit_applied = true
				VU_LOCK_ALL()   -- no-op for keys already locked at campaign start
				-- No immediate refresh here: the global restrict toggle at session start makes the next
				-- character selection crash (v0.12l). Locks set now take effect at the next turn change.
			end
			if not VU.button then vu_guard("create hud button", vu_create_hud_button)
			else vu_guard("place hud button", vu_place_hud_button) end
		end
	end)
end

local function VU_OnFactionTurnEnd(context)
	if not vu_is_mp() then return end
	vu_guard("FactionTurnEnd", function()
		vu_guard("mp legacy", vu_mp_settle_legacy, context)
		local human = conditions.FactionIsHuman(context.string, context)
		if human or VU_DEBUG then vu_log("mp: turn end", tostring(context.string), human and "(human)" or "") end
		if human then vu_mp_turn_end(context.string) end
	end)
end

-------------------------------------------------------------------------------
-- Points. Each clan earns VU_POINTS_PER_BATTLE per battle in which any of its units actually fought,
-- into one pool it can spend on any unit type. AI clans earn the same way and spend at their turn
-- start on stat/passive upgrades for unit types they have fought with (abilities need unit copies
-- and retraining, which the AI can't use).
-------------------------------------------------------------------------------
local VU_POINTS_PER_BATTLE = 1
local VU_BATTLE_GAP = 3   -- seconds without UnitCompletedBattle events = a new battle

local function vu_unit_family(context, human)
	for _, fam in ipairs(VU_FAMILIES) do
		for _, key in ipairs(human and fam.all_keys or fam.units) do
			if conditions.UnitType(key, context) then return fam end
		end
	end
	return nil
end

local function vu_unit_faction(context, human)
	if human then return VU.player end
	for _, key in ipairs(VU_FACTIONS) do
		if conditions.FactionName(key, context) then return key end
	end
	return nil
end

vu_ai_clan = function(faction)
	VU.ai = VU.ai or {}
	local clan = VU.ai[faction]
	if not clan then clan = { pool = 0, used = {}, levels = {} } VU.ai[faction] = clan end
	return clan
end

local function VU_OnUnitCompletedBattle(context)
	vu_guard("UnitCompletedBattle", function()
		if not conditions.UnitFoughtInBattle(context) then return end   -- must have been used
		local mp = vu_is_mp()
		if mp then
			-- The clock differs between machines, so multiplayer groups a battle's units by game events
			-- instead: a new battle starts after any general's CharacterCompletedBattle or a turn start.
			vu_guard("mp legacy", vu_mp_settle_legacy, context)
			VU.battle_earned = VU.battle_earned or {}
		else
			local now = os.time()
			if now - (VU.last_battle_t or 0) > VU_BATTLE_GAP then VU.battle_earned = {} end
			VU.last_battle_t = now
		end
		local human = conditions.FactionIsHuman(context)
		local faction = vu_unit_faction(context, human and not mp)
		if not faction then return end
		if human then
			if VU.battle_earned[faction] then return end
			VU.battle_earned[faction] = true
			if mp then
				local h = vu_hum(faction)
				h.pool = h.pool + VU_POINTS_PER_BATTLE
				vu_log("battle: +" .. VU_POINTS_PER_BATTLE, "clan points for", faction, "now", h.pool)
				return
			end
			VU.pool = (VU.pool or 0) + VU_POINTS_PER_BATTLE
			vu_log("battle: +" .. VU_POINTS_PER_BATTLE, "clan points, now", VU.pool)
			return
		end
		local clan = vu_ai_clan(faction)
		local fam = vu_unit_family(context, false)
		if fam then clan.used[fam.id] = true end   -- the AI invests in unit types it fields
		if VU.battle_earned[faction] then return end
		VU.battle_earned[faction] = true
		clan.pool = clan.pool + VU_POINTS_PER_BATTLE
		if (VU.ai_logged or 0) < 60 then
			VU.ai_logged = (VU.ai_logged or 0) + 1
			vu_log("battle (AI " .. faction .. "): +" .. VU_POINTS_PER_BATTLE, "now", clan.pool)
		end
	end)
end

local function VU_OnCharacterCompletedBattle(context)
	if vu_is_mp() then VU.battle_earned = {} end
end

-- AI spending: repeatedly buy the cheapest affordable stat/passive upgrade among the unit types the
-- clan has fought with; ties go to the unit type with the fewest upgrades so far.
vu_ai_spend = function(faction)
	local clan = VU.ai and VU.ai[faction]
	if not clan or clan.pool <= 0 then return end
	local gi = vu_gi()
	while true do
		local best, best_fam, best_cost, best_owned
		for _, fam in ipairs(VU_FAMILIES) do
			if clan.used[fam.id] then
				local lv = clan.levels[fam.id] or {}
				local owned = 0
				for _, l in pairs(lv) do owned = owned + l end
				for _, line in ipairs(fam.lines) do
					local nxt = line.kind ~= "ability" and line.levels[(lv[line.key] or 0) + 1]
					if nxt and nxt.cost <= clan.pool and (not best_cost or nxt.cost < best_cost
						or (nxt.cost == best_cost and owned < best_owned)) then
						best, best_fam, best_cost, best_owned = line, fam, nxt.cost, owned
					end
				end
			end
		end
		if not best then break end
		local lv = clan.levels[best_fam.id] or {}
		clan.levels[best_fam.id] = lv
		local old = lv[best.key] or 0
		if old > 0 then gi:remove_effect_bundle(best.levels[old].bundle, faction) end
		gi:apply_effect_bundle(best.levels[old + 1].bundle, faction, 0)
		lv[best.key] = old + 1
		clan.pool = clan.pool - best_cost
		vu_log("AI " .. faction .. " bought", best_fam.id, best.key, old + 1, "pool left", clan.pool)
	end
end

-- What a click on our button or panel does. Runs from a time trigger just after the click,
-- never inside ComponentLClickUp: changing the UI (hiding the panel the clicked button is in)
-- during the click left the game's own handlers for that click with a dead component (crash, v0.12).
local function vu_handle_click(addr, id)
	-- The HUD button toggles the list even while the panel is open.
	if id == "vu_button" then
		if VU.panel and VU.panel:Visible() then
			VU.from_list = false
			vu_close(false)
		else
			vu_show_list()
		end
		return
	end

	-- Clicks inside the list.
	if VU.mode == "list" and VU.panel and VU.panel:Visible() then
		if id == "button_ok" or id == "button_cancel" then vu_close(false) return end
		if VU.page_node and vu_is_node(addr, VU.page_node) then
			VU.list_page = (VU.list_page or 1) % (VU.list_pages or 1) + 1
			vu_refresh_list()
			return
		end
		local fam = vu_fam_for(addr)
		if fam then vu_open(fam, true) return end
		vu_log("list click (unhandled):", id)
		return
	end

	-- Clicks inside an open upgrade tree.
	if VU.mode == "tree" and VU.panel and VU.panel:Visible() then
		if id == "button_ok" then vu_close(true) return end
		if id == "button_cancel" then vu_close(false) return end
		if id == "button_reset" then vu_pending_reset() vu_refresh_panel() return end
		if vu_is_retrain(addr) then
			if VU.retrain_armed then
				VU.retrain_armed = false
				local fam = VU.pending.fam
				vu_commit()            -- Retrain applies the pending purchases, like OK
				vu_begin_edit(fam)
				vu_guard("retrain", VU_RETRAIN, fam)
			else
				VU.retrain_armed = true
			end
			vu_refresh_panel()
			return
		end
		local line = vu_node_for(addr)
		if line then
			vu_pending_buy(line)
			vu_refresh_panel()
			return
		end
		vu_log("panel click (unhandled):", id)
		return
	end

end

local function VU_OnComponentLClickUp(context)
	vu_guard("ComponentLClickUp", function()
		local addr = context.component
		local id = tostring(UIComponent(addr):Id())
		-- Touch nothing else for clicks that aren't ours: anything more here (walking parents,
		-- logging, changing the UI) made the game's later handlers for the same click crash (v0.12).
		local panel_open = VU.panel and VU.panel:Visible()
		if id ~= "vu_button" and not panel_open then return end
		VU.click = { addr = addr, id = id }
		EpisodicScripting.game_interface:add_time_trigger("vu_click", 0.01)
	end)
end

local function VU_OnTimeTrigger(context)
	if context.string == "vu_mp_turn" then vu_guard("mp send", vu_mp_send) return end
	if context.string ~= "vu_click" then return end
	vu_guard("click", function()
		local c = VU.click
		VU.click = nil
		if not c then return end
		if VU_DEBUG then
			vu_log("click:", c.id, "mode", VU.mode, "family", VU.pending and VU.pending.fam.id,
				"points", VU.pending and VU.pending.points, "retrain armed", VU.retrain_armed)
		end
		vu_handle_click(c.addr, c.id)
		if VU_DEBUG then vu_log("click handled:", c.id) end
	end)
end

for _, reg in ipairs({
	{ "UICreated", VU_OnUICreated },
	{ "NewCampaignStarted", VU_OnNewCampaignStarted },
	{ "SavingGame", VU_OnSavingGame },
	{ "LoadingGame", VU_OnLoadingGame },
	{ "FactionTurnStart", VU_OnFactionTurnStart },
	{ "FactionTurnEnd", VU_OnFactionTurnEnd },
	{ "UnitCompletedBattle", VU_OnUnitCompletedBattle },
	{ "CharacterCompletedBattle", VU_OnCharacterCompletedBattle },
	{ "ComponentLClickUp", VU_OnComponentLClickUp },
	{ "TimeTrigger", VU_OnTimeTrigger },
}) do
	local ok, err = pcall(EpisodicScripting.AddEventCallBack, reg[1], reg[2])
	if not ok then vu_log("AddEventCallBack failed for", reg[1], tostring(err)) end
end
vu_log("vu.lua parsed")
-- Test harness hook (tests/run_tests.py sets VU_UNDER_TEST; the game never does).
if VU_UNDER_TEST then VU_UNDER_TEST.families, VU_UNDER_TEST.factions, VU_UNDER_TEST.state = VU_FAMILIES, VU_FACTIONS, VU end

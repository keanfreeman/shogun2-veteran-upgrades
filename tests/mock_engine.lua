-- Minimal stand-in for the Shogun 2 campaign scripting API, enough to run vu.lua outside the game.
-- Only behaviour vu.lua relies on is modelled; signatures follow what was confirmed in game.

MOCK = { log = {}, locks = {}, bundles = {}, created = {}, disbanded = {}, saved = {}, triggers = {},
	player = MOCK_PLAYER or "shimazu" }
VU_UNDER_TEST = {}
local handlers = {}

out = { ting = function() end }

-- game_interface ------------------------------------------------------------
local gi = {}
function gi:apply_effect_bundle(b, f, turns) MOCK.bundles[f .. "/" .. b] = true end
function gi:remove_effect_bundle(b, f) MOCK.bundles[f .. "/" .. b] = nil end
function gi:save_named_value(k, v, ctx) MOCK.saved[k] = v end
function gi:load_named_value(k, d, ctx) if MOCK.saved[k] ~= nil then return MOCK.saved[k] end return d end
function gi:add_event_restricted_unit_record_for_faction(unit, faction) MOCK.locks[faction .. "/" .. unit] = true end
function gi:remove_event_restricted_unit_record_for_faction(unit, faction) MOCK.locks[faction .. "/" .. unit] = nil end
function gi:add_restricted_unit_record(u) MOCK.global_lock = u end
function gi:remove_restricted_unit_record(u) MOCK.global_unlock = u end
function gi:create_force(faction, units, x, y, id, queue)
	MOCK.created[#MOCK.created + 1] = { faction = faction, units = units, x = x, y = y, id = id }
end
function gi:add_time_trigger(name, t) MOCK.triggers[#MOCK.triggers + 1] = name end
EpisodicScripting = {
	game_interface = gi,
	AddEventCallBack = function(ev, fn) handlers[ev] = handlers[ev] or {} table.insert(handlers[ev], fn) end,
}

-- Fake UI tree ---------------------------------------------------------------
MOCK.C = {}
local function node(id, parent, extra)
	local n = { id = id, parent = parent, kids = {}, visible = true, text = "", state = "", x = 0, y = 0, w = 60, h = 60 }
	for k, v in pairs(extra or {}) do n[k] = v end
	MOCK.C[#MOCK.C + 1] = n
	if parent then table.insert(parent.kids, n) end
	return n
end
MOCK.node = node
MOCK.root = node("root")

local function make_panel()
	local p = node("vu_panel_layout", MOCK.root)
	local dock = node("dock_area", p)
	node("button_encyclopaedia", dock)
	local dy = node("dy_points_to_spend", dock)
	node("points_txt", dy, { text = "Points to spend:" })
	node("button_ok", dock, { x = 500, y = 900 }) node("button_cancel", dock, { x = 600, y = 900 })
	node("button_reset", dock, { x = 20, y = 900 })
	node("boshin_subpanel", dock)
	local tb = node("stats_list_bg", dock, { x = 100, y = 900 })
	node("clan_token_icon", tb) node("label", tb, { text = "Clan Tokens" })
	local sub = node("shogun_subpanel", dock)
	for i, h in ipairs({ "leadership", "ranged", "physical", "melee" }) do
		local c = node(h, sub, { x = 100 + 250 * (i - 1), w = 120 })
		node("label_" .. h, c)
	end
	local ids = { "avatar_skill_fatigue_resistance_aura", "avatar_skill_melee_attack", "avatar_skill_melee_defence",
		"avatar_skill_marksmanship", "avatar_skill_morale", "avatar_skill_armour", "avatar_skill_speed",
		"avatar_skill_charge", "avatar_skill_rally", "avatar_skill_stamina" }
	for i, id in ipairs(ids) do
		local s = node(id, sub, { x = (i % 4) * 150, y = 300 + math.floor(i / 4) * 100 })
		node("skill_icon", s) node("skill_name", s) node("arrow_straight", s)
	end
	return p
end

-- Army panel: a general, two plain Yari Ashigaru, one Yari copy; recruitment group for card checks.
local window = node("s2_CardGroupWindow", MOCK.root)
MOCK.cards = node("s2_LandUnitCardGroup", window)
MOCK.unit_details = {}
function MOCK.add_card(key, xp, general)
	local n = node("LandUnit " .. #MOCK.cards.kids, MOCK.cards)
	local ptr = "UNIT:" .. n.id
	MOCK.unit_details[ptr] = { UnitRecord = { Key = key }, Experience = xp or 0, Men = 160,
		CharacterPtr = general and "CHAR:army1" or nil }
	n.unit_ptr = ptr
	return n
end
local menu = node("menu_bar", MOCK.root)
node("button_show_advice", menu, { x = 30, y = 150 })

UIComponent = function(n)
	return setmetatable({ n = n }, { __index = {
		Id = function(s) return s.n.id end,
		ChildCount = function(s) return #s.n.kids end,
		Find = function(s, k)
			if type(k) == "number" then
				local r = s.n.kids[k + 1]
				if not r then error("CRASH: Find index out of range") end   -- the real game crashes here
				return r
			end
			local function f(x) for _, c in ipairs(x.kids) do if c.id == k then return c end local r = f(c) if r then return r end end end
			return f(s.n)
		end,
		Parent = function(s) return s.n.parent end,
		Position = function(s) return s.n.x, s.n.y end,
		Width = function(s) return s.n.w end, Height = function(s) return s.n.h end,
		Dimensions = function(s) return s.n.w, s.n.h end,
		MoveTo = function(s, x, y) s.n.x, s.n.y = x, y end,
		SetVisible = function(s, v) s.n.visible = v end, Visible = function(s) return s.n.visible end,
		SetStateText = function(s, t) s.n.text = t end, GetStateText = function(s) return s.n.text end,
		SetState = function(s, st) s.n.state = st end, CurrentState = function(s) return s.n.state end,
		SetTooltipText = function(s, t, all) s.n.tip = t end, GetTooltipText = function(s) return s.n.tip or "" end,
		SetInteractive = function(s, b) s.n.interactive = b end, IsInteractive = function(s) return s.n.interactive == true end,
		ShaderTechniqueSet = function(s, t) s.n.shader = t end,
		InterfaceFunction = function(s, f) if f == "ItemAddress" then return s.n.unit_ptr end end,
	} })
end
UIImage = function(path) return { SetComponentTexture = function(self, n, i) n.image = path end } end
Component = {
	CreateFromLayout = function(path, name, parent, x, y) return make_panel() end,
	CreateFromComponent = function(tpl, name, parent, x, y)
		local function copy(src, p, id)
			local n = node(id or src.id, p, { w = src.w, h = src.h, text = src.text })
			for _, k in ipairs(src.kids) do copy(k, n) end
			return n
		end
		return copy(tpl, parent, name)
	end,
}

CampaignUI = {
	PlayerFactionId = function() return MOCK.player end,
	InitialiseUnitDetails = function(u) return MOCK.unit_details[u] end,
	DisbandUnit = function(u) MOCK.disbanded[#MOCK.disbanded + 1] = u end,
	RetrieveFactionMilitaryForceLists = function(f, armies)
		return { { Address = "CHAR:army1", Name = "Tanegashima", PosX = -246, PosY = -161 },
			{ Address = "CHAR:army2", Name = "Second", PosX = 10, PosY = 20 } }
	end,
	RetrieveContainedEntitiesFromCharacter = function(c, t)
		local out = { Units = {} }
		if c == "CHAR:army1" then
			for _, n in ipairs(MOCK.cards.kids) do out.Units[#out.Units + 1] = { Address = n.unit_ptr } end
		else
			MOCK.unit_details["UNIT:far"] = { UnitRecord = { Key = "Inf_Spear_Yari_Ashigaru" }, Experience = 1 }
			out.Units[1] = { Address = "UNIT:far" }
		end
		return out
	end,
}

conditions = {
	FactionKeyIsLocal = function(k, c) return false end,   -- as in game at NewCampaignStarted
	FactionIsHuman = function(a, b) if b == nil then return a.human end return a == MOCK.player end,
	FactionName = function(k, c) return k == c.faction end,
	UnitType = function(k, c) return k == c.unit end,
	UnitWonBattle = function(c) return c.won end,
	UnitFoughtInBattle = function(c) return c.fought ~= false end,
}

-- Events: like the game, a time trigger fires after the event that queued it.
MOCK.now = 1000
os.time = function() return MOCK.now end
function MOCK.fire(ev, ctx)
	for _, fn in ipairs(handlers[ev] or {}) do fn(ctx or {}) end
	while #MOCK.triggers > 0 do
		local name = table.remove(MOCK.triggers, 1)
		for _, fn in ipairs(handlers.TimeTrigger or {}) do fn({ string = name }) end
	end
end
function MOCK.find(id) for i = #MOCK.C, 1, -1 do if MOCK.C[i].id == id then return MOCK.C[i] end end end
function MOCK.click(n) assert(n, "click on nil component") MOCK.fire("ComponentLClickUp", { component = n }) end
function MOCK.label_of(n) for _, k in ipairs(n.kids) do if k.id == "skill_name" then return k.text end end end
function MOCK.node_labelled(prefix)
	for i = #MOCK.C, 1, -1 do
		local n = MOCK.C[i]
		local l = n.visible and MOCK.label_of(n)
		if l and string.find(l, prefix, 1, true) == 1 then return n end
	end
end
function MOCK.battle(units, faction)   -- one battle: every unit fights; human units unless a faction is given
	MOCK.now = MOCK.now + 10
	for _, u in ipairs(units) do
		MOCK.fire("UnitCompletedBattle", { human = faction == nil, faction = faction, unit = u, won = true })
	end
end

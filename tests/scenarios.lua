-- End-to-end scenarios against tests/mock_engine.lua. Each check() failure is collected and reported.
local failures, passed = {}, 0
local function check(cond, what)
	if cond then passed = passed + 1 else failures[#failures + 1] = what end
end
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function pool_text() return MOCK.find("dy_points_to_spend").text end
local F = MOCK.fire

-- Campaign start ----------------------------------------------------------------
F("LoadingGame", {})
F("NewCampaignStarted", {})
check(count(MOCK.locks) > 9000, "copies prelocked for every clan at NewCampaignStarted (" .. count(MOCK.locks) .. ")")
check(MOCK.locks["oda/Inf_Spear_Yari_Ashigaru_VU1"], "AI clans can't recruit copies")
check(not MOCK.locks["shimazu/Inf_Spear_Yari_Ashigaru"], "plain units are not locked at start")
F("UICreated", { string = "Campaign UI", component = MOCK.root })
F("FactionTurnStart", { string = "shimazu" })
check(MOCK.find("vu_button") ~= nil, "Veterans HUD button created")

-- Army for retraining: general + 2 plain Yari Ashigaru + 1 Yari copy
MOCK.add_card("Gen_Taisho", 0, true)
MOCK.add_card("Inf_Spear_Yari_Ashigaru", 2)
MOCK.add_card("Inf_Spear_Yari_Ashigaru", 0)

-- Points: 1 per battle the clan fights in, however many units/types --------------
MOCK.battle({ "Inf_Spear_Yari_Ashigaru", "Inf_Spear_Yari_Ashigaru", "Inf_Missile_Bow_Ashigaru" })
MOCK.click(MOCK.find("vu_button"))
check(pool_text() == "1", "one battle = 1 clan point (shows " .. tostring(pool_text()) .. ")")
MOCK.click(MOCK.find("button_cancel"))
MOCK.now = MOCK.now + 10
MOCK.fire("UnitCompletedBattle", { human = true, unit = "Inf_Missile_Bow_Ashigaru", fought = false })
for i = 1, 11 do MOCK.battle({ "Inf_Spear_Yari_Ashigaru" }) end   -- 12 points total

-- List: only unit types the player's clan can recruit -------------------------------
MOCK.click(MOCK.find("vu_button"))
check(pool_text() == "12", "pool after 12 battles (shows " .. tostring(pool_text()) .. ")")
check(MOCK.node_labelled("Yari Ashigaru") ~= nil, "Yari Ashigaru listed")
check(MOCK.node_labelled("Ikko Ikki") == nil, "Ikko Ikki units hidden for Shimazu")
check(MOCK.node_labelled("Portuguese Tercos") == nil, "Otomo-only units hidden for Shimazu")
check(MOCK.find("button_reset").visible == false, "Reset hidden in the list")

-- Tree: buy an ability, retrain the selected army ----------------------------------
MOCK.click(MOCK.node_labelled("Yari Ashigaru"))
check(MOCK.find("vu_title").visible, "tree title shown")
local inspire = MOCK.node_labelled("Inspire Unit")
check(inspire ~= nil, "Inspire Unit node present")
MOCK.click(inspire)
check(pool_text() == tostring(12 - 5), "Inspire Unit costs 5 (pool " .. tostring(pool_text()) .. ")")
local retrain = MOCK.find("vu_retrain")
check(retrain and retrain.visible and string.find(MOCK.label_of(retrain), "Retrain (2)", 1, true),
	"Retrain (2) offered for the 2 plain Yari Ashigaru (" .. tostring(retrain and MOCK.label_of(retrain)) .. ")")
MOCK.click(retrain)
check(string.find(MOCK.label_of(retrain), "Confirm", 1, true), "first Retrain click asks to confirm")
check(string.find(retrain.tip, "LOSE", 1, true), "confirmation warns about lost experience")
MOCK.click(retrain)
local made = MOCK.created[#MOCK.created]
check(made and string.find(made.units, "Inf_Spear_Yari_Ashigaru_VU", 1, true), "copies spawned beside the army")
check(made and made.x == -246 + 1.0 and made.y == -161, "spawned at the army's position")
check(#MOCK.disbanded == 2, "both originals disbanded (" .. #MOCK.disbanded .. ")")
check(MOCK.locks["shimazu/Inf_Spear_Yari_Ashigaru"], "plain Yari Ashigaru locked for the player after the purchase")
local unlocked = 0
for _, key in ipairs({ "Inf_Spear_Yari_Ashigaru_VU1", "Inf_Spear_Yari_Ashigaru_VU2" }) do
	if not MOCK.locks["shimazu/" .. key] then unlocked = unlocked + 1 end
end
check(unlocked == 1, "exactly one Yari copy unlocked for the player (" .. unlocked .. ")")
check(MOCK.locks["oda/Inf_Spear_Yari_Ashigaru_VU1"] and MOCK.locks["oda/Inf_Spear_Yari_Ashigaru_VU2"], "AI still locked out of copies")

-- Escalating stat costs ---------------------------------------------------------------
local before = tonumber(pool_text())
local ma = MOCK.node_labelled("Melee Attack")
MOCK.click(ma) MOCK.click(ma)
local spent = before - tonumber(pool_text())
check(spent >= 2 and MOCK.label_of(ma) == "Melee Attack 2/10", "two Melee Attack picks (spent " .. spent .. ", " .. tostring(MOCK.label_of(ma)) .. ")")
MOCK.click(MOCK.find("button_ok"))
check(MOCK.bundles["shimazu/vu_inf_spear_yari_ashigaru__stat_melee_attack_mod_2"], "level-2 melee attack bundle applied")

-- Respec: refund minus a 2-point fee, charged on OK --------------------------------------
MOCK.click(MOCK.find("button_ok"))   -- close the list
MOCK.click(MOCK.find("vu_button"))
local p0 = tonumber(pool_text())
MOCK.click(MOCK.node_labelled("Yari Ashigaru"))
MOCK.click(MOCK.find("button_reset"))
local p1 = tonumber(pool_text())
check(p1 == p0 + 5 + spent - 2, "respec refunds everything minus 2 (" .. p0 .. " -> " .. p1 .. ")")
MOCK.click(MOCK.find("button_reset"))
check(tonumber(pool_text()) == p1, "a second Reset charges nothing more")
MOCK.click(MOCK.find("button_ok"))
check(not MOCK.bundles["shimazu/vu_inf_spear_yari_ashigaru__stat_melee_attack_mod_2"], "respec removed the stat bundle")
MOCK.click(MOCK.find("button_ok"))

-- Retrain all armies when no army is selected ---------------------------------------------
MOCK.cards.visible = false
MOCK.click(MOCK.find("vu_button"))
MOCK.click(MOCK.node_labelled("Yari Ashigaru"))
MOCK.click(MOCK.node_labelled("Inspire Unit"))
retrain = MOCK.find("vu_retrain")
check(retrain.visible and string.find(MOCK.label_of(retrain), "Retrain all", 1, true), "Retrain all offered with no army selected")
local n_created = #MOCK.created
MOCK.click(retrain) MOCK.click(retrain)
check(#MOCK.created == n_created + 2, "one new stack per army (" .. (#MOCK.created - n_created) .. ")")
MOCK.click(MOCK.find("button_ok"))
MOCK.cards.visible = true

-- AI: earns per battle, spends on unit types it fought with -------------------------------
MOCK.battle({ "Inf_Spear_Yari_Ashigaru" }, "oda")
MOCK.battle({ "Inf_Spear_Yari_Ashigaru" }, "oda")
F("FactionTurnStart", { string = "oda" })
local oda_bundles = 0
for k in pairs(MOCK.bundles) do if string.sub(k, 1, 4) == "oda/" then oda_bundles = oda_bundles + 1 end end
check(oda_bundles >= 1, "AI clan bought stat upgrades (" .. oda_bundles .. " bundles)")

-- Save / load round trip ------------------------------------------------------------------
F("SavingGame", {})
check(MOCK.saved.VU_POOL ~= nil and MOCK.saved.VU_AF_oda == 1, "pool and AI state saved")
local saved_pool = MOCK.saved.VU_POOL
F("LoadingGame", {})
F("UICreated", { string = "Campaign UI", component = MOCK.root })
MOCK.click(MOCK.find("vu_button"))
check(tonumber(pool_text()) == saved_pool, "pool restored after load")

-- Report ---------------------------------------------------------------------------------
RESULT = { passed = passed, failures = failures }

"""Run the Veteran Upgrades Lua against the mock engine.

Build first (veteran_upgrades/build.py writes veteran_upgrades.pack), then:
    .venv/bin/python tests/run_tests.py
Runs tests/scenarios.lua (full flows) on Sengoku, tests/smoke.lua on every campaign, and a
two-machine multiplayer campaign (run_mp).
Needs lupa (pip install lupa). Exit code 1 if any check fails.
"""
import os, sys, tempfile
import lupa.lua51 as lua51

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAMPAIGN_KEYS = {"sengoku": "jap_shogun", "gempei": "jap_gempei", "boshin": "jap_boshin"}
RUNS = [  # (campaign, scenario, player clan)
    ("sengoku", "scenarios.lua", "shimazu"),
    ("sengoku", "smoke.lua", "shimazu"),
    ("gempei", "smoke.lua", "gem_minamoto_kamakura"),
    ("boshin", "smoke.lua", "bos_satsuma"),
]


sys.path.insert(0, ROOT)
from tools_packread import extract
ADVICE_SRC = extract(os.path.join(ROOT, "veteran_upgrades", "veteran_upgrades.pack"), "export_advice.lua").decode("utf-8")


def machine(campaign, player, setup=""):
    """A Lua runtime with the mock engine and the mod loaded, as the game does it."""
    lua = lua51.LuaRuntime()
    lua.execute(f'MOCK_PLAYER = "{player}"')
    lua.execute(setup)
    # As in the game: the campaign script requires export_advice (CA's module with our hook appended,
    # taken from the built pack) and then calls SetCampaign.
    lua.execute(open(os.path.join(ROOT, "tests", "mock_engine.lua"), encoding="utf-8").read())
    lua.globals().package.preload["export_advice"] = lua.execute(
        "local src = ... return function(name) local f = assert(loadstring(src, '@export_advice.lua')) return f(name) end",
        ADVICE_SRC)
    lua.execute('require "export_advice"')
    lua.execute(f'EpisodicScripting.SetCampaign("{CAMPAIGN_KEYS[campaign]}")')
    return lua


def report(name, passed, failures, log):
    errors = [l for l in log.splitlines() if "!!" in l]
    print(f"{name:48} {passed:3} passed, {len(failures)} failed, "
          f"{len(errors)} Lua errors   (log: {os.path.abspath('vu_log.txt')})")
    for f in failures:
        print("    FAIL:", f)
    for e in errors:
        print("    ERROR:", e)
    return not failures and not errors


def run(campaign, scenario, player):
    os.chdir(tempfile.mkdtemp(prefix="vu_tests_"))   # vu.lua writes vu_log.txt to the working directory
    lua = machine(campaign, player)
    lua.execute(open(os.path.join(ROOT, "tests", scenario), encoding="utf-8").read())
    result = lua.globals().RESULT
    log = open("vu_log.txt").read() if os.path.exists("vu_log.txt") else ""
    return report(f"{campaign:8} {scenario:14} {player}", result.passed, list(result.failures.values()), log)


MP_SETUP = 'MOCK_MP = true MOCK_HUMANS = { shimazu = true, oda = true }'


def run_mp():
    """Two machines in lockstep (host Shimazu, guest Oda): every game event fires on both, a unit
    rename reaches both. Purchases must change both games identically, at the buyer's turn end."""
    os.chdir(tempfile.mkdtemp(prefix="vu_tests_mp_"))   # both machines append to one vu_log.txt
    failures, passed = [], 0

    def check(cond, what):
        nonlocal passed
        if cond:
            passed += 1
        else:
            failures.append(what)

    def new_pair(saved=None):
        ms = []
        for player in ("shimazu", "oda"):
            m = machine("sengoku", player, MP_SETUP)
            m.execute(open(os.path.join(ROOT, "tests", "mp_setup.lua"), encoding="utf-8").read())
            if saved:
                for k, v in saved.items():
                    m.globals().MOCK.saved[k] = v
            ms.append(m)
        return ms

    def deliver(ms):   # the game's command queue: every rename reaches every machine
        for m in ms:
            for e in list(m.globals().MOCK.sent.values()):
                for mm in ms:
                    mm.globals().MOCK.names[e.u] = e.name
            m.execute("MOCK.sent = {}")

    def fire(ms, event, ctx="{}"):
        for m in ms:
            m.execute(f"MOCK.fire('{event}', {ctx})")
        deliver(ms)

    def same(ms, what):
        a, b = (m.eval("MOCK.model()") for m in ms)
        check(a == b, f"{what}: games differ\n      host: {a!r}\n      guest: {b!r}")
        a, b = (m.eval("MOCK.humans_state()") for m in ms)
        check(a == b, f"{what}: clan state differs\n      host: {a!r}\n      guest: {b!r}")

    def battle(ms, faction, human=True, n=1):
        for _ in range(n):
            ctx = f"{{ human = {'true' if human else 'false'}, faction = '{faction}', unit = MOCK.yari_key, won = true }}"
            fire(ms, "UnitCompletedBattle", ctx)
            fire(ms, "UnitCompletedBattle", ctx)   # two units, one battle
            fire(ms, "CharacterCompletedBattle")

    def names(m, faction):
        return [m.globals().MOCK.names[f"UNIT:{faction}{i}"] for i in range(1, 5)]

    host, guest = ms = new_pair()
    fire(ms, "LoadingGame")
    fire(ms, "NewCampaignStarted")
    fire(ms, "UICreated", "{ string = 'Campaign UI', component = MOCK.root }")
    fire(ms, "FactionTurnStart", "{ string = 'shimazu' }")
    check(host.eval("MOCK.find('vu_button') ~= nil") and guest.eval("MOCK.find('vu_button') ~= nil"), "Veterans button on both machines")
    battle(ms, "shimazu", n=12)   # enough for an ability in either edition
    battle(ms, "oda", n=6)
    battle(ms, "chosokabe", human=False, n=2)
    same(ms, "after battles")
    check("oda pool 6 " in host.eval("MOCK.humans_state()"), "6 battles = 6 points for the guest, on the host too")

    # The guest buys during the host's turn: kept, sent at its own turn start.
    guest.execute("MOCK.buy('Yari Ashigaru', 'Melee Attack', 2)")
    deliver(ms)
    check(not any(n.startswith("VU") for n in names(host, "oda")), "nothing sent outside the guest's turn")
    check(guest.eval("MOCK.pool_shown()") is not None, "guest panel works")
    fire(ms, "FactionTurnEnd", "{ string = 'shimazu' }")
    same(ms, "host turn end")
    fire(ms, "FactionTurnStart", "{ string = 'oda' }")
    check(any(n.startswith("VU") for n in names(host, "oda")), "guest's purchase sent at its turn start (" + repr(names(host, "oda")) + ")")
    check(not any(k.startswith("oda/") for k in host.globals().MOCK.bundles.keys()) and
          not any(k.startswith("oda/") for k in guest.globals().MOCK.bundles.keys()), "not applied before the turn ends")

    # More purchases in the same turn: the last message carries them all.
    guest.execute("MOCK.buy('Yari Ashigaru', 'Melee Defence', 1)")
    deliver(ms)
    guest.execute("MOCK.click(MOCK.find('vu_button'))")
    shown = guest.eval("MOCK.pool_shown()")
    guest.execute("MOCK.click(MOCK.find('button_ok'))")
    fire(ms, "FactionTurnEnd", "{ string = 'oda' }")
    same(ms, "guest turn end")
    bundles = [k for k in host.globals().MOCK.bundles.keys() if k.startswith("oda/")]
    check(any("melee_attack_mod_2" in k for k in bundles) and any("melee_defence_mod_1" in k for k in bundles),
          f"guest's purchases applied on both machines ({bundles})")
    state = host.eval("MOCK.humans_state()")
    check(f"oda pool {shown} " in state, f"guest's points after purchases match its panel ({shown}): {state}")

    # The guest's next turn start puts the unit names back.
    fire(ms, "FactionTurnStart", "{ string = 'chosokabe' }")
    same(ms, "AI turn")
    fire(ms, "FactionTurnStart", "{ string = 'oda' }")
    check(names(host, "oda") == [""] * 4, f"unit names restored ({names(host, 'oda')})")
    fire(ms, "FactionTurnEnd", "{ string = 'oda' }")
    same(ms, "quiet turn")

    # The host buys an ability (unit copies): locks change on both machines at its turn end.
    fire(ms, "FactionTurnStart", "{ string = 'shimazu' }")
    host.execute("MOCK.buy('Yari Ashigaru', MOCK.yari_ability, 1)")
    deliver(ms)
    plain = "shimazu/" + host.eval("MOCK.yari_key")
    check(not host.globals().MOCK.locks[plain], "copy locks wait for the turn end")
    fire(ms, "FactionTurnEnd", "{ string = 'shimazu' }")
    same(ms, "host ability")
    check(host.globals().MOCK.locks[plain] and guest.globals().MOCK.locks[plain], "plain Yari Ashigaru locked for the host on both machines")

    # A unit carrying the message is lost before the turn ends: nothing applied, sent again next turn.
    fire(ms, "FactionTurnStart", "{ string = 'oda' }")
    guest.execute("MOCK.buy('Yari Ashigaru', 'Armour', 1)")
    deliver(ms)
    for m in ms:
        m.execute("table.remove(MOCK.force_units['CHAR:oda1'], 1)")
    fire(ms, "FactionTurnEnd", "{ string = 'oda' }")
    same(ms, "lost message")
    check(not any("armour_mod_1" in k for k in host.globals().MOCK.bundles.keys() if k.startswith("oda/")), "lost message not applied")
    fire(ms, "FactionTurnStart", "{ string = 'oda' }")
    fire(ms, "FactionTurnEnd", "{ string = 'oda' }")
    same(ms, "resent message")
    check(any("armour_mod_1" in k for k in host.globals().MOCK.bundles.keys() if k.startswith("oda/")), "resent next turn and applied")

    # AI spending stays identical (it runs on both machines at the AI's turn start).
    battle(ms, "chosokabe", human=False, n=3)
    fire(ms, "FactionTurnStart", "{ string = 'chosokabe' }")
    same(ms, "AI spending")
    check(any(k.startswith("chosokabe/") for k in host.globals().MOCK.bundles.keys()), "AI clan bought upgrades")

    # Save on the host, load into a fresh pair: same clan state.
    before = host.eval("MOCK.humans_state()")
    fire([host], "SavingGame")
    saved = dict(host.globals().MOCK.saved.items())
    check(saved.get("VU_MP") == 1 and "VU_POOL" not in saved, "multiplayer save format")
    ms2 = new_pair(saved)
    fire(ms2, "LoadingGame")
    fire(ms2, "UICreated", "{ string = 'Campaign UI', component = MOCK.root }")
    check(ms2[0].eval("MOCK.humans_state()") == before and ms2[1].eval("MOCK.humans_state()") == before,
          "clan state survives save/load")

    # An older multiplayer save (one clan's upgrades, no owner): refunded to both clans.
    legacy = {"VU_POOL": 4, f"VU_L_{host.eval('MOCK.yari.id')}__stat_melee_attack_mod": 2}
    ms3 = new_pair(legacy)
    fire(ms3, "LoadingGame")
    fire(ms3, "UICreated", "{ string = 'Campaign UI', component = MOCK.root }")
    fire(ms3, "FactionTurnStart", "{ string = 'shimazu' }")
    same(ms3, "older save")
    st = ms3[0].eval("MOCK.humans_state()")
    check("oda pool " in st and "shimazu pool " in st and st.count("pool 4 ") == 0 and len(set(
        l.split(" seq")[0].split("pool ")[1] for l in st.splitlines())) == 1, f"older save refunded to both clans equally: {st!r}")

    log = open("vu_log.txt").read() if os.path.exists("vu_log.txt") else ""
    return report("sengoku  multiplayer    shimazu + oda", passed, failures, log)


def main():
    ok = [run(*r) for r in RUNS] + [run_mp()]
    return 0 if all(ok) else 1


if __name__ == "__main__":
    sys.exit(main())

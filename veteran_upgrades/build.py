"""Build veteran_upgrades.pack.

Covers the three campaigns (CAMPAIGNS): Sengoku Jidai, Rise of the Samurai and Fall of the Samurai.

Clan-wide upgrades per unit family, modelled on the multiplayer veteran skill trees:
  * upgrade lines + per-level values come from the MP avatar_skill tables
  * stat lines: only bonuses proven to work at unit_record scope in campaign; each
    (family, line, level) is an effect bundle that the Lua side applies/removes
  * ability lines (incl. Increased Range for missile units): one unit-record COPY per unit key
    and ability combination; the Lua side switches the clan's recruitment to the right copy
    and retrains existing units (spawn copy beside the army, disband the original)
Outputs veteran_upgrades.pack (mod type) next to this file.
"""
import collections, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
from tools_packread import extract
from tools_packwrite import write_pack
from tools_db import load, load_file, encode, GAME_DATA
from tools_loc import read_loc, write_loc

DATA = os.path.join(GAME_DATA, "data.pack")
LOCAL = os.path.join(GAME_DATA, "local_en.pack")

# Families are generated from the multiplayer units of each campaign's era: each <Unit>_MP has its
# own skill list, and its campaign equivalent is <Unit> plus clan variants (<Unit>_Oda, ...).
# Recruitable land units without an MP tree borrow the tree of an MP unit of the same class.
SKIP = re.compile(r"(^|_)(Gen_|Heavy_Ship|Medium_Ship|Light_Ship|Cannon_Ship|Corvette|Frigate|Ironclad|Gun_Boat|Torpedo_Boat)")
EXCLUDE = re.compile(r"(_MP|_Tutorial|_Tutorial_No_Cap)$")
# Per campaign: script, MP products, which unit keys and clans belong to it, and the list columns
# (category id, label, heading emblem to clone, tooltip) in display order.
CAMPAIGNS = [
    {"id": "sengoku", "script": "campaigns\\jap_shogun\\scripting.lua", "pack": "data.pack",
     "products": {"shogun2"}, "unit_prefixes": None, "clan_prefix": None,
     "categories": [("spear", "Spear", "melee", "Spear and polearm infantry"), ("sword", "Sword", "melee", "Sword infantry"),
                    ("bow", "Bow", "ranged", "Bow infantry"), ("gun", "Firearms", "ranged", "Matchlock and other firearm infantry"),
                    ("cavalry", "Cavalry", "physical", "Cavalry"),
                    ("siege_stealth", "Siege & Special", "leadership", "Artillery, siege weapons and special units")]},
    {"id": "gempei", "script": "campaigns\\jap_gempei\\scripting.lua", "pack": "data.pack",
     "products": {"gempei"}, "unit_prefixes": ("Genpei_",), "clan_prefix": "gem_",
     "categories": [("spear", "Spear", "melee", "Spear and polearm infantry"), ("sword", "Sword", "melee", "Sword and club infantry"),
                    ("bow", "Bow", "ranged", "Bow infantry"), ("cavalry", "Cavalry", "physical", "Cavalry"),
                    ("siege_stealth", "Special", "leadership", "Special units")]},
    {"id": "boshin", "script": "campaigns\\jap_boshin\\scripting.lua", "pack": "data_fots.pack",
     "products": {"boshin"}, "unit_prefixes": ("Boshin_",), "clan_prefix": "bos_",
     "categories": [("line_inf_boshin", "Line Infantry", "ranged", "Line infantry"),
                    ("elite_inf_boshin", "Elite Infantry", "ranged", "Elite and marine infantry"),
                    ("missile_inf_boshin", "Light & Missile", "ranged", "Light infantry, riflemen and traditional missile infantry"),
                    ("melee_inf_boshin", "Melee", "melee", "Traditional melee infantry"),
                    ("cavalry_boshin", "Cavalry", "physical", "Cavalry"),
                    ("artillery_boshin", "Artillery", "leadership", "Artillery and special units")]},
]
SENGOKU_FOREIGN = ("Genpei_", "Boshin_")   # other campaigns' unit prefixes

# MP avatar effect -> (campaign bonus_value_id, label). Only bonuses verified at unit_record scope.
BONUS = {
    "mod_marksmanship":  ("accuracy_mod",      "Accuracy"),   # MP calls it marksmanship
    "mod_melee_attack":  ("melee_attack_mod",  "Melee Attack"),
    "mod_melee_defence": ("melee_defence_mod", "Melee Defence"),
    "mod_armour":        ("armour_mod",        "Armour"),
    "mod_unit_morale":   ("morale",            "Morale"),
    # (No reload: "reload" per unit record is ignored - the card stayed at the base value after +60%,
    #  v0.19; the game only honours it at unit_class scope.)
}
# MP "enable ability" effects -> campaign unit ability to clone (gated) for the family.
ABILITY_MAP = {
    "enable_ability_banzai": "banzai", "enable_ability_inspire": "inspire_unit", "enable_ability_rally": "rally",
    "enable_ability_fire_arrows": "flaming_arrows_ability", "enable_ability_stand_and_fight": "we_stand_and_fight",
    "enable_ability_whistling_arrows": "whistling_arrows_ability", "enable_ability_second_wind": "second_wind",
    "enable_ability_blind_grenades": "blinding_grenade", "enable_ability_heroic_assault": "heroic_assault",
    "enable_ability_ganbatte": "ganbatte", "enable_ability_cantabrian_circle": "cantabrian_circle",
    "enable_ability_rapid_volley": "rapid_volley", "enable_ability_warcry": "warcry",
    "enable_ability_kneel_fire": "kneel_fire_ability", "enable_ability_suppressive_fire": "suppression_fire",
    "ability_stand_firm": "stand_firm", "mod_ability_stand_firm": "stand_firm",
}
# MP effects that are passive unit_record bonuses in campaign.
PASSIVE_MAP = {"enable_ability_scare_enemies": ("scares_men", "Scare Enemies", 1.0)}
# Panel column (popup heading container) per bonus / ability.
COLUMN = {"morale": "leadership", "accuracy_mod": "ranged", "reload": "ranged", "armour_mod": "physical",
          "melee_attack_mod": "melee", "melee_defence_mod": "melee", "scares_men": "leadership"}
ABILITY_COLUMN = {"rally": "leadership", "inspire_unit": "leadership", "warcry": "leadership", "stand_firm": "leadership",
                  "we_stand_and_fight": "leadership", "flaming_arrows_ability": "ranged", "whistling_arrows_ability": "ranged",
                  "rapid_volley": "ranged", "kneel_fire_ability": "ranged", "suppression_fire": "ranged",
                  "cantabrian_circle": "ranged", "blinding_grenade": "physical", "second_wind": "physical",
                  "banzai": "melee", "heroic_assault": "melee", "ganbatte": "melee", "range_effect": "ranged"}
# Costs (clan points; the clan earns a flat amount per battle, vu.lua VU_POINTS_PER_BATTLE).
ABILITY_COST = 5   # unit abilities, unless listed in ABILITY_COSTS
ABILITY_COSTS = {"range_effect": 6, "banzai": 6, "rapid_volley": 6, "inspire_unit": 5, "blinding_grenade": 5,
                 "whistling_arrows_ability": 4, "rally": 4, "stand_firm": 4, "warcry": 4}
# Stat picks are priced by value: a pick's size as a share of that stat's spread (max - min) across
# all unit types the mod covers; pick n costs max(1, round(PRICE_K * share * n)).
PRICE_K = 16
STAT_FIELD = {"melee_attack_mod": "melee_attack", "melee_defence_mod": "melee_defence", "morale": "morale",
              "accuracy_mod": "core_marksmanship", "armour_mod": "armour"}
PERCENT_SPREAD = {"reload": 100.0}   # percent bonuses: share of 100%
PASSIVE_COST = 4   # passive unlocks such as Scare Enemies
STAT_MAX_LEVEL = 10   # each stat line can be bought this many times...
STAT_MAX_FACTOR = 2   # ...and buying it that often gives about twice the multiplayer maximum
# ...and pick n costs n points (1+2+...+10 = 55 to max one stat), so stacking one stat gets expensive.
ROMAN = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"]
# Fallback icon per bonus when the MP skill's own icon file doesn't exist.
STAT_ICON = {"reload": "skill_reload", "accuracy_mod": "skill_accuracy", "melee_attack_mod": "skill_melee_attack", "melee_defence_mod": "skill_melee_defence",
             "armour_mod": "skill_armour", "morale": "skill_morale"}
ICON = "data/ui/campaign ui/pips/effect_admiral.tga"
START_POINTS = 0  # points come from battles (vu.lua: VU_OnUnitCompletedBattle)
VERSION = "1.0.0"
DEBUG = os.environ.get("VU_DEBUG") == "1"   # debug build: logs the panel's UI tree + tooltips (tools/vu_ui_audit.py)

# Ability unlocks are unit-record COPIES: abilities attached through unit_to_unit_abilities apply
# per unit record, and cloned ability keys are ignored by the battle engine (v0.7b test C).
# One copy per (unit key, non-empty ability combination): <key>_VU<mask>, where bit i of mask
# is fam["abilities"][i].
RANGE_ABILITY = "range_effect"          # "Increased Range": +25 range for 50 s; range_mod has no effect
RANGE_EFFECTS = {"mod_missile_range"}   # MP skill effects that become the range unlock
# Names: a copy lists its abilities ("Yari Ashigaru (Inspire Unit, Hold Firm)"); the plain unit of a
# family with copies becomes "Yari Ashigaru (no abilities)".
NO_ABILITIES_SUFFIX = " (no abilities)"
COPY_REF_FIELD = {  # tables copied row-for-row from the base unit -> field holding the unit key
    "unit_stats_land_tables": "key", "units_to_exclusive_faction_permissions_tables": "key",
    "units_to_groupings_military_permissions_tables": "unit", "cdir_unit_qualities_tables": "unit_key",
    "unit_experience_threshold_modifiers_tables": "key", "effect_bonus_value_unit_record_junctions_tables": "unit_record_key",
    "unit_to_unit_abilities_junctions_tables": "unit_name",
}


def copy_key(unit, mask):
    return f"{unit}_VU{mask}"


def add_copies(catalog):
    """fam["copies"] = [{"base": unit, "keys": [copy for mask 1..2^n-1]}] for every family unit."""
    for fam in catalog:
        n = len(fam["abilities"])
        fam["copies"] = [{"base": u, "keys": [copy_key(u, m) for m in range(1, 2 ** n)]} for u in fam["units"]] if n else []
        fam["copy_keys"] = [k for c in fam["copies"] for k in c["keys"]]


def copy_tables(catalog):
    """Rows for every copy, keyed by table name, plus units.loc names and encyclopedia pages."""
    out = collections.defaultdict(list)
    units = load("units_tables")
    by_key = {r["key"]: r for r in units}
    # Reuse free indices inside the vanilla range (1031 free below the vanilla maximum, 1463).
    used = {r["unique_index"] for r in units}
    free_indices = iter(i for i in range(max(used) - 1, 0, -1) if i not in used)
    bua = load("building_units_allowed_tables")
    # The recruitment list seems to follow these keys: give each copy row the first free key after
    # its base unit's row, so the copy sits next to its plain unit (4000+ keys are unused).
    bua_used = {r["key"] for r in bua}

    def bua_key_after(k):
        k += 1
        while k in bua_used:
            k += 1
        bua_used.add(k)
        return k
    loaded = {t: collections.defaultdict(list) for t in COPY_REF_FIELD}
    for t, field in COPY_REF_FIELD.items():
        for r in load(t):
            loaded[t][r[field]].append(r)
    uniforms = collections.defaultdict(list)
    for r in load("uniforms_tables"):
        uniforms[r["Unit"]].append(r)
    bua_of = collections.defaultdict(list)
    for r in bua:
        bua_of[r["unit"]].append(r)
    ency_root = os.path.join(GAME_DATA, "encyclopedia", "units")
    _, unit_loc = read_loc(extract(LOCAL, "text\\db\\units.loc"))
    base_names = {k[len("units_on_screen_name_"):]: v for k, v, _ in unit_loc if k.startswith("units_on_screen_name_")}
    loc, pages = [], []
    for fam in catalog:
        for c in fam["copies"]:
            loc.append(("units_on_screen_name_" + c["base"], base_names.get(c["base"], by_key[c["base"]]["on_screen_name"]) + NO_ABILITIES_SUFFIX))
    for fam in catalog:
        for c in fam["copies"]:
            base = c["base"]
            html_path = os.path.join(ency_root, base.lower() + ".html")
            html = open(html_path, "rb").read() if os.path.exists(html_path) else None
            for mask, key in enumerate(c["keys"], 1):
                labels = [ABILITIES[ab]["bullet_text"] for i, ab in enumerate(fam["abilities"]) if mask & (1 << i)]
                name = f"{base_names.get(base, by_key[base]['on_screen_name'])} ({', '.join(labels)})"
                row = dict(by_key[base])
                row.update(key=key, on_screen_name=name, unique_index=next(free_indices))
                out["units_tables"].append(row)
                loc.append(("units_on_screen_name_" + key, name))
                for t, field in COPY_REF_FIELD.items():
                    for r in loaded[t][base]:
                        cr = dict(r); cr[field] = key; out[t].append(cr)
                for r in uniforms[base]:
                    cr = dict(r); cr["Unit"] = key; cr["Uniform_Name"] = f"VU{mask}_" + r["Uniform_Name"]
                    out["uniforms_tables"].append(cr)
                for r in bua_of[base]:
                    cr = dict(r); cr["unit"] = key; cr["key"] = bua_key_after(r["key"])
                    out["building_units_allowed_tables"].append(cr)
                for i, ab in enumerate(fam["abilities"]):
                    if mask & (1 << i):
                        out["unit_to_unit_abilities_junctions_tables"].append({"unit_name": key, "ability": ab})
                if html:
                    pages.append((f"encyclopedia\\units\\{key.lower()}.html", html))
    return out, loc, pages


def icon_files():
    from tools_packread import read_index
    names = set()
    for p in ("data.pack", "data_fots.pack"):
        for n, _, _ in read_index(os.path.join(GAME_DATA, p)):
            if n.lower().startswith("ui\\frontend ui\\skills\\"):
                names.add(n.lower().split("\\")[-1][:-4])
    return names


def icon_path(mp_icon, bonus, available):
    """MP icon '/UI/Frontend UI/Skills/skill_x.tga' -> 'data/ui/frontend ui/skills/skill_x.tga' if it exists."""
    name = mp_icon.lower().split("/")[-1][:-4]
    if name not in available:
        name = STAT_ICON[bonus]
    return f"data/ui/frontend ui/skills/{name}.tga"


def portraits():
    from tools_packread import read_index
    out = []
    for p in ("data.pack", "data_fots.pack"):
        for n, _, _ in read_index(os.path.join(GAME_DATA, p)):
            nl = n.lower()
            if nl.startswith("ui\\units\\icons_square\\") and nl.endswith(".tga"):
                out.append(nl.split("\\")[-1][:-4])
    return out


def portrait_for(fam_id, names):
    """Square unit portrait for a family, e.g. yari_ashigaru -> ashigaru_inf_yari_ashigaru."""
    hits = sorted((n for n in names if n.endswith("_" + fam_id)), key=len)
    return f"data/ui/units/icons_square/{hits[0]}.tga" if hits else None


def family_portrait(base_key, square):
    """Square portrait: try the unit key's trailing tokens, longest first (Inf_Spear_Yari_Ashigaru -> *_yari_ashigaru)."""
    tokens = base_key.lower().split("_")
    for k in range(len(tokens) - 1, 0, -1):
        suffix = "_" + "_".join(tokens[-k:])
        hits = sorted((n for n in square if n.endswith(suffix)), key=len)
        if hits:
            return f"data/ui/units/icons_square/{hits[0]}.tga"
    return None


ABIL_JUNC, ABILITIES, ICON_FILES = [], {}, set()


def ability_icon(ab):
    name = f"{ab}_icon.tga"
    return f"data/ui/battle ui/button icons/{name}" if name in ICON_FILES else STAT_ICON_PATH


def campaign_unit(camp, key):
    if camp["unit_prefixes"]:
        return key.startswith(camp["unit_prefixes"])
    return not key.startswith(SENGOKU_FOREIGN)


def build_catalog(camp):
    global ABIL_JUNC, ABILITIES, ICON_FILES
    from tools_packread import read_index
    ABIL_JUNC = load("unit_to_unit_abilities_junctions_tables")
    ABILITIES = {r["key"]: r for r in load("unit_abilities_tables")}
    ICON_FILES = {n.lower().split("\\")[-1] for n, _, _ in read_index(DATA) if n.lower().startswith("ui\\battle ui\\button icons\\")}
    available = icon_files()
    square = portraits()
    units = {r["key"]: r for r in load("units_tables")}
    skills = {r["key"]: r for r in load("avatar_skills_tables")}
    effects = collections.defaultdict(list)
    for e in load("avatar_skill_effects_juncs_tables"):
        effects[e["skill"]].append(e)
    unit_skills = collections.defaultdict(list)
    for r in load("avatar_skills_to_units_juncs_tables"):
        unit_skills[r["unit"]].append(r["skill"])

    avatars = sorted(load("avatar_units_tables"), key=lambda r: r["unit_ui_category_order"])
    sources = []   # (base unit, its keys, MP unit whose skills it uses, MP avatar row)
    for av in avatars:
        mp = av["key"]
        if av["product"] not in camp["products"] or not mp.endswith("_MP") or SKIP.search(mp):
            continue
        base = mp[:-3]
        if base not in units or not campaign_unit(camp, base):
            continue
        keys = sorted(k for k in units if (k == base or k.startswith(base + "_")) and not EXCLUDE.search(k))
        sources.append((base, keys, mp, av))
    # Recruitable land units of this campaign without an MP tree: borrow one from an MP unit of the
    # same class (preferring this campaign's era).
    covered = {k for _, keys, _, _ in sources for k in keys}
    land = {r["key"] for r in load("unit_stats_land_tables")}
    buildable = {r["unit"] for r in load("building_units_allowed_tables")}
    by_class = collections.defaultdict(list)
    for av in avatars:
        b = av["key"][:-3]
        if av["key"].endswith("_MP") and b in units and not SKIP.search(av["key"]) and unit_skills[av["key"]]:
            by_class[units[b]["class"]].append((av["product"] not in camp["products"], av))
    for k in sorted(units):
        if (k in covered or k not in land or k not in buildable or not campaign_unit(camp, k)
                or EXCLUDE.search(k) or SKIP.search(k) or "Citizenry" in k):
            continue
        cands = sorted(by_class.get(units[k]["class"], []), key=lambda x: (x[0], x[1]["unique_index"]))
        if cands:
            sources.append((k, [k], cands[0][1]["key"], cands[0][1]))
            print(f"  {camp['id']}: {k} borrows the MP tree of {cands[0][1]['key']}")
        else:
            print(f"  {camp['id']}: {k} has no MP tree of its class - not covered")

    catalog = []
    for base, keys, mp, av in sources:
        lines = collections.OrderedDict()
        for sk in sorted((skills[s] for s in unit_skills[mp] if s in skills),
                         key=lambda s: (s["advanced_skill"], s["skill_sub_chain"], s["level"])):
            for e in effects.get(sk["key"], []):
                if e["effect"] not in BONUS or e["effect_value"] <= 0:
                    continue
                bonus, label = BONUS[e["effect"]]
                line = lines.setdefault(sk["skill_sub_chain"], {
                    "key": sk["skill_sub_chain"], "label": label + (" (Advanced)" if sk["advanced_skill"] else ""),
                    "bonus": bonus, "advanced": bool(sk["advanced_skill"]),
                    "icon": icon_path(sk["icon"], bonus, available), "levels": []})
                line["levels"].append(e["effect_value"])
        # Ability unlocks from the same MP skill list (one single-level line each), as vanilla
        # ability keys attached to the family's unit copies. Abilities the unit already has are skipped.
        native = {r["ability"] for r in ABIL_JUNC if r["unit_name"] == base}
        abilities = []
        for sk in sorted((skills[s] for s in unit_skills[mp] if s in skills), key=lambda s: s["key"]):
            for e in effects.get(sk["key"], []):
                if e["effect"] in PASSIVE_MAP:
                    bonus, label, value = PASSIVE_MAP[e["effect"]]
                    lines.setdefault("passive_" + bonus, {"key": "passive_" + bonus, "label": label, "bonus": bonus,
                        "advanced": True, "icon": STAT_ICON_PATH, "levels": [value], "kind": "passive"})
                ab = RANGE_ABILITY if e["effect"] in RANGE_EFFECTS else ABILITY_MAP.get(e["effect"])
                if ab and ab in ABILITIES and ab not in native and ab not in abilities:
                    abilities.append(ab)
        for ab in abilities:
            lines["ab_" + ab] = {"key": "ab_" + ab, "label": ABILITIES[ab]["bullet_text"], "bonus": "ability",
                "ability": ab, "advanced": True, "icon": ability_icon(ab), "levels": [1.0], "kind": "ability",
                "desc": ABILITIES[ab]["info_card_tooltip_text"],
                "gated": bool(ABILITIES[ab]["requires_effect_enabling"])}
        if not lines:
            continue
        lines = merge_stat_lines(lines)
        for line in lines.values():
            kind = line.get("kind", "stat")
            line.setdefault("kind", kind)
            line["column"] = ABILITY_COLUMN.get(line.get("ability"), "melee") if kind == "ability" else COLUMN.get(line["bonus"], "melee")
            line["row"] = 2 if kind in ("ability", "passive") else 0
        catalog.append({"id": base.lower(), "display": units[base]["on_screen_name"],
                        "portrait": family_portrait(base, square), "category": av["unit_ui_category"],
                        "units": keys, "names": sorted({units[k]["on_screen_name"] for k in keys}),
                        "lines": list(lines.values()), "abilities": abilities})
    cat_ids = [c[0] for c in camp["categories"]]
    for f in catalog:   # categories outside the campaign's columns go to the last column
        if f["category"] not in cat_ids:
            f["category"] = cat_ids[-1]
    order = {c: i for i, c in enumerate(cat_ids)}
    cost = {f["id"]: units[f["units"][0] if f["units"] else ""]["create_cost"] if f["units"] else 0 for f in catalog}
    for f in catalog:
        base = next((u for u in f["units"] if u.lower() == f["id"]), None)
        cost[f["id"]] = units[base]["create_cost"] if base else 0
    catalog.sort(key=lambda f: (order.get(f["category"], 99), cost[f["id"]], f["display"]))
    price_stats(catalog)
    return catalog


def stat_spreads(catalog):
    """{bonus: (min, mean, max)} of each stat across the base units of every family."""
    stats = {r["key"]: r for r in load("unit_stats_land_tables")}
    keys = [u for f in catalog for u in f["units"] if u in stats]
    out = {}
    for bonus, field in STAT_FIELD.items():
        vals = [stats[k][field] for k in keys if not (field == "core_marksmanship" and stats[k][field] == 0)]
        out[bonus] = (min(vals), sum(vals) / len(vals), max(vals))
    return out


def price_stats(catalog):
    """line["costs"][n-1] = price of pick n, from the pick's size relative to the stat's spread."""
    spreads = stat_spreads(catalog)
    for fam in catalog:
        for line in fam["lines"]:
            if line["kind"] != "stat":
                continue
            step = line["levels"][0]
            spread = PERCENT_SPREAD.get(line["bonus"]) or (spreads[line["bonus"]][2] - spreads[line["bonus"]][0])
            share = step / spread
            line["costs"] = [max(1, round(PRICE_K * share * n)) for n in range(1, len(line["levels"]) + 1)]


def merge_stat_lines(lines):
    """One repeatable line per stat: the MP basic + advanced chains of a bonus become a single line of
    STAT_MAX_LEVEL equal steps. STAT_MAX_LEVEL picks give about STAT_MAX_FACTOR x the MP maximum."""
    out, by_bonus = collections.OrderedDict(), collections.OrderedDict()
    for key, line in lines.items():
        if line.get("kind", "stat") != "stat":
            continue
        by_bonus.setdefault(line["bonus"], []).append(line)
    for bonus, group in by_bonus.items():
        basic = [l for l in group if not l["advanced"]] or group
        mp_max = max(max(l["levels"]) for l in group)
        step = max(1, round(mp_max * STAT_MAX_FACTOR / STAT_MAX_LEVEL))
        out["stat_" + bonus] = {"key": "stat_" + bonus, "label": BONUS[next(k for k, v in BONUS.items() if v[0] == bonus)][1]
                                if bonus in {v[0] for v in BONUS.values()} else basic[0]["label"],
                                "bonus": bonus, "advanced": False, "icon": basic[0]["icon"], "kind": "stat",
                                "levels": [float(step * i) for i in range(1, STAT_MAX_LEVEL + 1)]}
    for key, line in lines.items():
        if line.get("kind", "stat") != "stat":
            out[key] = line
    return out


def bundle_key(fam, line, level):
    return f"vu_{fam}__{line['key']}_{level}"


def effect_key(bonus, unit):
    return f"vu_{bonus}__{unit}"


def build(catalog):
    """Effects and bundles for the stat and passive lines. Each effect targets one unit record, so
    the family's copies get their own effects and every bundle covers originals and copies alike."""
    eff_rows, junc_rows, bundle_rows, bjunc_rows = [], [], [], []
    eff_loc, bundle_loc = [], []
    seen_effects = set()
    for fam in catalog:
        disp = fam["display"]
        for line in fam["lines"]:
            if line["kind"] == "ability":
                continue
            effect_keys = []
            for u in fam["units"] + fam["copy_keys"]:
                ek = effect_key(line["bonus"], u)
                effect_keys.append(ek)
                if ek not in seen_effects:
                    seen_effects.add(ek)
                    eff_rows.append({"effect": ek, "icon": ICON, "priority": 900})
                    junc_rows.append({"bonus_value_id": line["bonus"], "effect": ek, "unit_record_key": u})
                    eff_loc.append(("effects_description_" + ek, f"%+n {BONUS_LABEL.get(line['bonus'], line['label'])} for {disp} (veteran upgrades)"))
            for lvl, value in enumerate(line["levels"], 1):
                bk = bundle_key(fam["id"], line, lvl)
                title = f"Veterans: {disp} {line['label']}" + (f" {ROMAN[lvl]}" if len(line["levels"]) > 1 else "")
                bundle_rows.append({"key": bk, "localised_description": title, "localised_title": title,
                                    "ui_icon": "bos_effect_faction_aizu.tga"})
                bundle_loc += [("effect_bundles_localised_title_" + bk, title),
                               ("effect_bundles_localised_description_" + bk, title)]
                for ek in effect_keys:
                    bjunc_rows.append({"effect_bundle_key": bk, "effect_key": ek, "value": float(value)})
    return {"effects": eff_rows, "junc": junc_rows, "bundles": bundle_rows, "bjunc": bjunc_rows,
            "eff_loc": eff_loc, "bundle_loc": bundle_loc}


BONUS_LABEL = {v[0]: v[1] for v in BONUS.values()}
BONUS_LABEL["scares_men"] = "Scare Enemies"
STAT_ICON_PATH = "data/ui/frontend ui/skills/skill_melee_attack.tga"


def table_file_full(table, extra_rows):
    """Full copy of the vanilla table file plus our rows, under the vanilla file name (replaces it)."""
    path = f"db\\{table}\\{table[:-len('_tables')]}"
    ver, header, rows = load_file(DATA, path)
    return path, encode(table, ver, rows + extra_rows, header)


def new_table(table, name, rows):
    """A separately named table file holding only our rows (merging is confirmed to work)."""
    ver, header, _ = load_file(DATA, f"db\\{table}\\{table[:-len('_tables')]}")
    return f"db\\{table}\\{name}", encode(table, ver, rows, header)


def loc_file(path, extra):
    """Vanilla loc file plus our rows; a row whose key already exists replaces the vanilla text."""
    ver, rows = read_loc(extract(LOCAL, path))
    new = dict(extra)
    rows = [(k, new.pop(k), t) if k in new else (k, v, t) for k, v, t in rows]
    return path, write_loc(rows + [(k, v, 1) for k, v in extra if k in new], ver)


def lua_value(v):
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, (int, float)): return repr(v)
    if isinstance(v, str): return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, list): return "{ " + ", ".join(lua_value(x) for x in v) + " }"
    if isinstance(v, dict): return "{ " + ", ".join(f"{k} = {lua_value(x)}" for k, x in v.items()) + " }"
    raise TypeError(v)


def check_lua(script):
    """Compile the full scripting.lua (vanilla + ours) with Lua 5.1, if lupa is available."""
    try:
        import lupa.lua51 as lua51
    except ImportError:
        print("WARNING: lupa not installed - full scripting.lua NOT compile-checked")
        return
    err = lua51.LuaRuntime().eval("function(s) local f, e = loadstring(s) return e end")(script.decode("utf-8"))
    if err:
        raise SystemExit("scripting.lua does not compile: " + err)
    print("scripting.lua compiles (Lua 5.1)")


def family_factions(catalog, camp):
    """fam["factions"] = campaign clans that can recruit at least one of the family's units: the clan's
    military_group must be one of the unit's groupings (if it has any), and exclusive permissions must not bar it
    (allowed=False excludes a clan; any allowed=True row restricts the unit to the listed clans)."""
    groups = {r["key"]: r["military_group"] for r in load("factions_tables")}
    unit_groups = collections.defaultdict(set)
    for r in load("units_to_groupings_military_permissions_tables"):
        unit_groups[r["unit"]].add(r["military_group"])
    allow, deny = collections.defaultdict(set), collections.defaultdict(set)
    for r in load("units_to_exclusive_faction_permissions_tables"):
        (allow if r["allowed"] else deny)[r["key"]].add(r["faction"])
    buildable = {r["unit"] for r in load("building_units_allowed_tables")}   # no building: script/reward only
    clans = campaign_factions(camp)
    for fam in catalog:
        ok = set()
        for u in fam["units"]:
            if u not in buildable:
                continue
            for f in clans:
                in_group = not unit_groups[u] or groups.get(f) in unit_groups[u]   # no rows: no group limit
                if in_group and f not in deny[u] and (not allow[u] or f in allow[u]):
                    ok.add(f)
        fam["factions"] = sorted(ok)


def campaign_factions(camp):
    """Campaign clan keys (rebels, custom-battle and tutorial factions excluded)."""
    keys = [r["key"] for r in load("factions_tables") if not r["is_rebel"]]
    if camp["clan_prefix"]:
        return [k for k in keys if k.startswith(camp["clan_prefix"]) and not k.startswith("bos_cb_")]
    return [k for k in keys if not k.startswith(("bos_", "gem_", "mp_", "tut", "movie"))]


def lua_data(catalog, camp):
    fams = []
    for fam in catalog:
        lines = []
        for line in fam["lines"]:
            ability = line["kind"] == "ability"
            lines.append({"key": line["key"], "label": line["label"], "advanced": line["advanced"], "icon": line["icon"],
                          "bonus": line["bonus"], "stat": BONUS_LABEL.get(line["bonus"], line["label"]),
                          "kind": line["kind"], "column": line["column"], "row": line["row"],
                          "desc": line.get("desc", ""), "gated": line.get("gated", False),
                          "levels": [{"bundle": "" if ability else bundle_key(fam["id"], line, i), "value": v,
                                      "cost": ABILITY_COSTS.get(line.get("ability"), ABILITY_COST) if ability
                                      else (PASSIVE_COST if line["kind"] == "passive" else line["costs"][i - 1])}
                                     for i, v in enumerate(line["levels"], 1)]})
        fams.append({"id": fam["id"], "name": fam["display"], "portrait": fam["portrait"] or STAT_ICON_PATH,
                     "category": fam["category"], "names": fam["names"], "units": fam["units"], "lines": lines,
                     "abilities": ["ab_" + ab for ab in fam["abilities"]], "copies": fam["copies"],
                     "factions": fam["factions"]})
    return ("-- generated by veteran_upgrades/build.py\n"
            f"local VU_START_POINTS = {START_POINTS}\n"
            + f"local VU_VERSION = {lua_value(VERSION)}\n"
            + ("local VU_DEBUG = true\n" if DEBUG else "local VU_DEBUG = false\n")
            + f"local VU_CAMPAIGN = {lua_value(camp['id'])}\n"
            + "local VU_FACTIONS = " + lua_value(campaign_factions(camp)) + "\n"
            + "local VU_CATEGORY_LIST = " + lua_value([{"id": c[0], "label": c[1], "tpl": c[2], "tip": c[3]}
                                                       for c in camp["categories"]]) + "\n"
            + "local VU_FAMILIES = {\n" + "".join(f"\t{lua_value(f)},\n" for f in fams) + "}\n")


if __name__ == "__main__":
    catalogs, scripts = {}, []
    for camp in CAMPAIGNS:
        print(f"== {camp['id']}")
        catalog = build_catalog(camp)
        add_copies(catalog)
        family_factions(catalog, camp)
        for fam in catalog:
            print(f"   {fam['display']:<34} {fam['category']:<18} {len(fam['units'])} keys, {len(fam['lines'])} lines, "
                  f"{len(fam['copy_keys'])} copies, {len(fam['factions'])} clans, portrait={'yes' if fam['portrait'] else 'NO'}")
        catalogs[camp["id"]] = catalog
    every = [f for c in CAMPAIGNS for f in catalogs[c["id"]]]
    ids = [f["id"] for f in every]
    assert len(ids) == len(set(ids)), "family ids must be unique across campaigns"
    b = build(every)
    ct, copy_loc, pages = copy_tables(every)
    files = [
        new_table("effects_tables", "veteran_upgrades", b["effects"]),
        new_table("effect_bonus_value_unit_record_junctions_tables", "veteran_upgrades", b["junc"]),
        new_table("effect_bundles_tables", "veteran_upgrades", b["bundles"]),
        new_table("effect_bundles_to_effects_junctions_tables", "veteran_upgrades", b["bjunc"]),
        loc_file("text\\db\\effects.loc", b["eff_loc"]),
        loc_file("text\\db\\effect_bundles.loc", b["bundle_loc"]),
        loc_file("text\\db\\units.loc", copy_loc),
    ]
    files += [new_table(t, "vu_copies", rows) for t, rows in ct.items()]
    files += pages
    vu_lua = open(os.path.join(HERE, "vu.lua")).read()
    for camp in CAMPAIGNS:
        catalog = catalogs[camp["id"]]
        n_ab = sum(1 for f in catalog for l in f["lines"] if l["kind"] == "ability")
        print(f"{camp['id']}: {len(catalog)} families, {n_ab} ability unlocks, "
              f"{sum(len(f['copy_keys']) for f in catalog)} unit copies")
        our_script = lua_data(catalog, camp) + vu_lua
        # Unwrapped copy for tests/run_tests.py (it loads the mod's part on its own).
        open(os.path.join(HERE, f"vu_{camp['id']}.lua"), "w").write(our_script)
        # Our code runs in its own function: appended straight to vanilla's main chunk it pushed that
        # chunk past Lua 5.1's 200-local limit, and the whole campaign script failed to load.
        wrapped = "do\nlocal function veteran_upgrades_main()\n" + our_script + "\nend\nveteran_upgrades_main()\nend\n"
        vanilla = extract(os.path.join(GAME_DATA, camp["pack"]), camp["script"]).rstrip()
        script = vanilla + b"\r\n\r\n" + wrapped.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8")
        check_lua(script)
        files.append((camp["script"], script))
    out = os.path.join(HERE, "veteran_upgrades.pack")
    write_pack(out, files, pack_type="mod")
    print(f"{len(b['effects'])} effects, {len(b['bundles'])} bundles, {len(ct['units_tables'])} copies, {len(files)} files -> {out}")

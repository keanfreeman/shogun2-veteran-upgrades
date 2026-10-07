"""Run the Veteran Upgrades Lua against the mock engine.

Build first (veteran_upgrades/build.py writes vu_<campaign>.lua), then:
    .venv/bin/python tests/run_tests.py
Runs tests/scenarios.lua (full flows) on Sengoku and tests/smoke.lua on every campaign.
Needs lupa (pip install lupa). Exit code 1 if any check fails.
"""
import os, sys, tempfile
import lupa.lua51 as lua51

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNS = [  # (campaign script, scenario, player clan)
    ("sengoku", "scenarios.lua", "shimazu"),
    ("sengoku", "smoke.lua", "shimazu"),
    ("gempei", "smoke.lua", "gem_minamoto_kamakura"),
    ("boshin", "smoke.lua", "bos_satsuma"),
]


def run(campaign, scenario, player):
    os.chdir(tempfile.mkdtemp(prefix="vu_tests_"))   # vu.lua writes vu_log.txt to the working directory
    lua = lua51.LuaRuntime()
    lua.execute(f'MOCK_PLAYER = "{player}"')
    for path in (os.path.join(ROOT, "tests", "mock_engine.lua"),
                 os.path.join(ROOT, "veteran_upgrades", f"vu_{campaign}.lua"),
                 os.path.join(ROOT, "tests", scenario)):
        lua.execute(open(path, encoding="utf-8").read())
    result = lua.globals().RESULT
    failures = list(result.failures.values())
    log = open("vu_log.txt").read() if os.path.exists("vu_log.txt") else ""
    errors = [l for l in log.splitlines() if "!!" in l]
    print(f"{campaign:8} {scenario:14} {player:24} {result.passed:3} passed, {len(failures)} failed, "
          f"{len(errors)} Lua errors   (log: {os.path.abspath('vu_log.txt')})")
    for f in failures:
        print("    FAIL:", f)
    for e in errors:
        print("    ERROR:", e)
    return not failures and not errors


def main():
    ok = [run(*r) for r in RUNS]
    return 0 if all(ok) else 1


if __name__ == "__main__":
    sys.exit(main())

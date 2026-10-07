"""Make a Veteran Upgrades release: build, test, and assemble dist/ for the Steam Workshop.

    .venv/bin/python tools/release.py            # build + test + dist/
    .venv/bin/python tools/release.py --install  # ...and copy pack + thumbnail into the game's data folder

dist/ gets:
  veteran_upgrades.pack            the mod (release build, no debug logging)
  veteran_upgrades.jpg             Workshop thumbnail (made from the game's own unit art)
  workshop_description.bbcode      text for the Workshop page (docs/workshop_description.bbcode)
The Assembly Kit's Mod Manager uploads a pack from the game's data folder and needs a .jpg with the
same name next to it - that's what --install sets up.
"""
import io, os, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from tools_db import GAME_DATA            # noqa: E402
from tools_packread import extract        # noqa: E402

DIST = os.path.join(ROOT, "dist")
PACK = os.path.join(ROOT, "veteran_upgrades", "veteran_upgrades.pack")
ART = ["ashigaru_inf_yari_ashigaru", "samurai_inf_katana_samurai", "ashigaru_inf_bow_ashigaru",
       "ashigaru_inf_matchlock_ashigaru", "samurai_cav_yari_cavalry", "samurai_inf_nodachi_samurai"]
FONTS = ["/usr/share/fonts/dejavu/DejaVuSerif-Bold.ttf", "C:\\Windows\\Fonts\\georgiab.ttf",
         "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf"]


def run(*cmd):
    print("$", " ".join(cmd))
    subprocess.run(cmd, cwd=ROOT, check=True, env={k: v for k, v in os.environ.items() if k != "VU_DEBUG"})


def thumbnail(path, size=512):
    """Six unit portraits on a dark red field, with the title below."""
    from PIL import Image, ImageDraw, ImageFont
    img = Image.new("RGB", (size, size), (34, 10, 10))
    draw = ImageDraw.Draw(img)
    for y in range(size):   # vertical gradient
        c = int(34 + 40 * y / size)
        draw.line([(0, y), (size, y)], fill=(c, 12, 12))
    data = os.path.join(GAME_DATA, "data.pack")
    w, h, gap = 76, 140, 6
    x0 = (size - (len(ART) * w + (len(ART) - 1) * gap)) // 2
    for i, name in enumerate(ART):
        pic = Image.open(io.BytesIO(extract(data, f"ui\\units\\info\\{name}.tga"))).convert("RGBA")
        pic = pic.resize((w, h), Image.LANCZOS)
        img.paste(pic, (x0 + i * (w + gap), 70), pic)
    font = next((f for f in FONTS if os.path.exists(f)), None)
    big = ImageFont.truetype(font, 54) if font else ImageFont.load_default()
    small = ImageFont.truetype(font, 22) if font else ImageFont.load_default()
    for text, f, y, colour in (("VETERAN", big, 260, (232, 196, 120)), ("UPGRADES", big, 322, (232, 196, 120)),
                               ("Multiplayer-style unit upgrades", small, 410, (220, 210, 200)),
                               ("for all three Shogun 2 campaigns", small, 440, (220, 210, 200))):
        tw = draw.textlength(text, font=f)
        draw.text(((size - tw) / 2, y), text, font=f, fill=colour)
    draw.rectangle([6, 6, size - 7, size - 7], outline=(150, 110, 60), width=3)
    img.save(path, "JPEG", quality=90)


def main():
    install = "--install" in sys.argv
    run(sys.executable, "veteran_upgrades/build.py")
    run(sys.executable, "tests/run_tests.py")
    os.makedirs(DIST, exist_ok=True)
    shutil.copy(PACK, os.path.join(DIST, "veteran_upgrades.pack"))
    thumbnail(os.path.join(DIST, "veteran_upgrades.jpg"))
    shutil.copy(os.path.join(ROOT, "docs", "workshop_description.bbcode"), DIST)
    print("dist/:", ", ".join(sorted(os.listdir(DIST))))
    if install:
        for name in ("veteran_upgrades.pack", "veteran_upgrades.jpg"):
            shutil.copy(os.path.join(DIST, name), os.path.join(GAME_DATA, name))
        print(f"installed pack + thumbnail into {GAME_DATA}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

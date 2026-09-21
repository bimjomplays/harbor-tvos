#!/usr/bin/env python3
"""Builds the tvOS "App Icon & Top Shelf Image" brand assets from upstream's icon."""
import json, os, shutil
from PIL import Image, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "reference/harbor/src-tauri/icons/ios/AppIcon-512@2x.png")
OUT = os.path.join(ROOT, "App/Assets.xcassets/App Icon & Top Shelf Image.brandassets")
INFO = {"author": "xcode", "version": 1}
TOP, BOTTOM = (22, 27, 38), (8, 9, 10)

def dump(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)

def glyph():
    """White sail mark with alpha taken from the icon's brightness."""
    src = Image.open(SRC).convert("RGBA")
    inset = src.width // 6  # the iOS icon has opaque white corners; keep only the middle
    src = src.crop((inset, inset, src.width - inset, src.height - inset))
    lum = src.convert("L").point(lambda v: 0 if v < 90 else min(255, int((v - 90) * 255 / 140)))
    alpha = ImageChops.multiply(lum, src.getchannel("A"))
    g = Image.new("RGBA", src.size, (244, 245, 248, 0))
    g.putalpha(alpha)
    return g.crop(g.getbbox())

def background(w, h):
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        row = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = row
    return img

def front(w, h, mark, scale):
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    gh = int(h * scale)
    gw = int(mark.width * gh / mark.height)
    m = mark.resize((gw, gh), Image.LANCZOS)
    layer.paste(m, ((w - gw) // 2, (h - gh) // 2), m)
    return layer

def imageset(path, files):
    images = []
    for name, scale, img in files:
        os.makedirs(path, exist_ok=True)
        img.save(os.path.join(path, name))
        images.append({"filename": name, "idiom": "tv", "scale": scale})
    dump(os.path.join(path, "Contents.json"), {"images": images, "info": INFO})

def imagestack(path, scales, w, h, mark):
    dump(os.path.join(path, "Contents.json"),
         {"info": INFO, "layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}]})
    for layer in ("Front", "Back"):
        lp = os.path.join(path, f"{layer}.imagestacklayer")
        dump(os.path.join(lp, "Contents.json"), {"info": INFO})
        files = []
        for s in scales:
            img = front(w * s, h * s, mark, 0.5) if layer == "Front" else background(w * s, h * s)
            files.append((f"{layer.lower()}@{s}x.png", f"{s}x", img))
        imageset(os.path.join(lp, "Content.imageset"), files)

def shelf(path, w, h, mark):
    files = []
    for s in (1, 2):
        img = background(w * s, h * s).convert("RGBA")
        img.alpha_composite(front(w * s, h * s, mark, 0.42))
        files.append((f"shelf@{s}x.png", f"{s}x", img.convert("RGB")))
    imageset(path, files)

def main():
    shutil.rmtree(OUT, ignore_errors=True)
    mark = glyph()
    dump(os.path.join(OUT, "Contents.json"), {"info": INFO, "assets": [
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
    ]})
    imagestack(os.path.join(OUT, "App Icon.imagestack"), (1, 2), 400, 240, mark)
    imagestack(os.path.join(OUT, "App Icon - App Store.imagestack"), (1,), 1280, 768, mark)
    shelf(os.path.join(OUT, "Top Shelf Image.imageset"), 1920, 720, mark)
    shelf(os.path.join(OUT, "Top Shelf Image Wide.imageset"), 2320, 720, mark)
    dump(os.path.join(ROOT, "App/Assets.xcassets/Contents.json"), {"info": INFO})

if __name__ == "__main__":
    main()

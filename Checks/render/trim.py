import sys, glob, os
from PIL import Image, ImageChops
raw, out = sys.argv[1], sys.argv[2]
for p in sorted(glob.glob(raw + "/*.png")):
    im = Image.open(p).convert("RGB")
    bg = Image.new("RGB", im.size, im.getpixel((2, im.size[1] - 3)))
    bbox = ImageChops.difference(im, bg).getbbox()
    h = (bbox[3] + 16) if bbox else im.size[1]
    im.crop((0, 0, im.size[0], min(h, im.size[1]))).save(os.path.join(out, os.path.basename(p)))
    print(os.path.basename(p), im.size, "->", h)

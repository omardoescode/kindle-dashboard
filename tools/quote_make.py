import sys
from PIL import Image, ImageDraw, ImageFont
W, H = 1272, 1696
MARGIN = 120
F = sys.argv[1]
quote = ("Our actions may be impeded . . . but there can be no impeding our intentions or dispositions. "
 "Because we can accommodate and adapt. The mind adapts and converts to its own purposes the obstacle to our acting. "
 "And then he concluded with powerful words destined for maxim.")
maxim = ["The impediment to action advances action.", "What stands in the way becomes the way."]
source = "Marcus Aurelius, as told in The Obstacle Is the Way"
img = Image.new("L", (W, H), 255)
d = ImageDraw.Draw(img)
mark = ImageFont.truetype(F + "/IBMPlexSans-SemiBold.ttf", 200)
body = ImageFont.truetype(F + "/IBMPlexSans-Regular.ttf", 46)
bold = ImageFont.truetype(F + "/IBMPlexSans-SemiBold.ttf", 58)
small = ImageFont.truetype(F + "/IBMPlexSans-Regular.ttf", 34)

def wrap(text, font):
    lines, cur = [], ""
    for w in text.split():
        t = (cur + " " + w).strip()
        if d.textlength(t, font=font) <= W - 2 * MARGIN:
            cur = t
        else:
            lines.append(cur)
            cur = w
    return lines + [cur]

body_lines = wrap(quote, body)
maxim_lines = [l for m in maxim for l in wrap(m, bold)]
total = 150 + 66 * len(body_lines) + 50 + 78 * len(maxim_lines) + 50 + 30 + 40
y = (H - total) // 2 + 150
d.text((MARGIN, y - 150), chr(0x201C), font=mark, fill=0)
for l in body_lines:
    d.text((MARGIN, y), l, font=body, fill=0); y += 66
y += 50
for l in maxim_lines:
    d.text((MARGIN, y), l, font=bold, fill=0); y += 78
y += 50
d.line((MARGIN, y, MARGIN + 160, y), fill=0, width=4); y += 30
d.text((MARGIN, y), source, font=small, fill=80)
img.save(sys.argv[2])

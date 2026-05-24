from PIL import Image, ImageDraw
import os

sizes = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}

base_dir = r'C:\Users\HB\.openclaw\workspace\fund_app_flutter\android\app\src\main\res'

for dirname, px in sizes.items():
    img = Image.new('RGBA', (px, px), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    r = px * 0.18
    bg_color = (229, 57, 53, 255)
    draw.rounded_rectangle([(2,2),(px-3,px-3)], radius=r, fill=bg_color)

    cx = px / 2
    cy = px / 2

    stroke_w = max(2, px // 20)
    line_color = (255, 255, 255, 255)

    margin = px * 0.22
    chart_points = [
        (margin, px - margin),
        (cx * 0.85, px * 0.65),
        (cx * 1.25, px * 0.75),
        (px - margin, px * 0.28),
    ]
    draw.line(chart_points, fill=line_color, width=stroke_w, joint='round')

    last = chart_points[3]
    dot_r = max(2, px // 24)
    draw.ellipse([last[0]-dot_r, last[1]-dot_r, last[0]+dot_r, last[1]+dot_r], fill=line_color)

    filepath = os.path.join(base_dir, dirname, 'ic_launcher.png')
    img.save(filepath, 'PNG')

    rfilepath = os.path.join(base_dir, dirname, 'ic_launcher_round.png')
    mask = Image.new('L', (px, px), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.ellipse([0, 0, px-1, px-1], fill=255)
    round_img = Image.new('RGBA', (px, px), (0, 0, 0, 0))
    round_img.paste(img, (0, 0), mask)
    round_img.save(rfilepath, 'PNG')
    print(f'{dirname} done')

# Update adaptive icon background
with open(os.path.join(base_dir, 'drawable', 'ic_background.xml'), 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n')
    f.write('<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">\n')
    f.write('  <solid android:color="#E53935"/>\n')
    f.write('</shape>\n')
print('ic_background.xml updated to red')

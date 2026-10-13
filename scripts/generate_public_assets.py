"""Create original geometric backgrounds/icons; no input images or personal data.

Requires Pillow. Generated assets are GPL-3.0-only, like this script.
"""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent


def camera(size):
    image = Image.new('RGB', (512, 512), '#ebece0')
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((68, 158, 444, 386), radius=45, fill='#285a52')
    draw.rounded_rectangle((158, 118, 300, 180), radius=16, fill='#285a52')
    draw.ellipse((175, 188, 337, 350), fill='#faf5e8')
    draw.ellipse((200, 213, 312, 325), fill='#d49562')
    draw.ellipse((367, 185, 391, 209), fill='#faf5e8')
    return image.resize((size, size), Image.Resampling.LANCZOS)


def main():
    scenes = ROOT / 'app/assets/report_scenes'
    scenes.mkdir(parents=True, exist_ok=True)
    palettes = [('#e8eadc', '#adbeb0', '#617f76', '#dca16a'),
                ('#eae6db', '#bacbd0', '#5d7c90', '#d49a79'),
                ('#f0e5d9', '#d6bca5', '#957c70', '#c89c55'),
                ('#e5e8e4', '#acbdbb', '#4b7273', '#e0b277')]
    for i in range(20):
        paper, far, near, sun = palettes[i % len(palettes)]
        image = Image.new('RGB', (1122, 357), paper)
        draw = ImageDraw.Draw(image)
        x = 95 + (i * 43) % 900
        draw.ellipse((x, 35, x + 96, 131), fill=sun)
        draw.polygon([(0, 220), (160, 100 + i % 5 * 12), (410, 230),
                      (720, 90 + i % 4 * 16), (1122, 250), (1122, 357), (0, 357)], fill=far)
        draw.polygon([(0, 290), (265, 180 + i % 3 * 20), (575, 310),
                      (960, 220), (1122, 280), (1122, 357), (0, 357)], fill=near)
        image.save(scenes / f'scene-{i + 1:02d}.jpg', quality=90)
    # Replace template logos with project-owned geometric camera icons.
    for path in (ROOT / 'app/android/app/src/main/res').glob('mipmap-*/ic_launcher.png'):
        with Image.open(path) as old:
            size = old.width
        camera(size).save(path)
    for path in (ROOT / 'app/ios/Runner/Assets.xcassets/AppIcon.appiconset').glob('*.png'):
        with Image.open(path) as old:
            size = old.width
        camera(size).save(path)
    for name, size in [('icon-192.png', 192), ('icon-512.png', 512)]:
        camera(size).save(ROOT / 'server/static/icons' / name)
    camera(480).save(ROOT / 'server/static/icons/ph.png')
    print('Generated 20 generic backgrounds and project icons without EXIF or personal input')


if __name__ == '__main__':
    main()

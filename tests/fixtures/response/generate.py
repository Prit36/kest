"""Reproduce the deterministic response decoder fixtures; no external data."""
from pathlib import Path
import struct
import zlib
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parent
image = Image.new("RGB", (3000, 1600), (27, 66, 103))
draw = ImageDraw.Draw(image)
for y in range(0, 1600, 200):
    for x in range(0, 3000, 200):
        if (x // 200 + y // 200) % 2 == 0:
            draw.rectangle((x, y, x + 199, y + 199), fill=(45, 126, 183))
draw.rectangle((600, 450, 2400, 1150), fill=(224, 241, 255))
image.save(root / "preview-large.png", optimize=True)
Image.new("RGB", (96, 48), (220, 94, 32)).save(root / "preview.jpg", quality=90)


def chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))


encoder = zlib.compressobj(9)
parts = [encoder.compress(bytes(65536)) for _ in range(4096)]
parts.append(encoder.flush())
(root / "expansion-invalid.png").write_bytes(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
    + chunk(b"IDAT", b"".join(parts))
    + chunk(b"IEND", b""))

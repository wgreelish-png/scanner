"""Build the label wordmark as outlined PDF paths, without embedded bitmaps.

Development-only tool; requires fontTools and reportlab plus DejaVu fonts.
The app draws the bundled PDF directly at its printer dot size. No fonts,
Python packages, SVG interpreter or generator run on the phone.
"""

from pathlib import Path
import json

from fontTools.pens.reportLabPen import ReportLabPen
from fontTools.ttLib import TTFont
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parents[1]
FONT_DIRECTORY = Path("/usr/share/fonts/truetype/dejavu")
ASSET_DIRECTORY = ROOT / "CardShowScanner/Assets.xcassets/PokeDenWordmark.dataset"


class PDFOutlinePen(ReportLabPen):
    """Adapt the fontTools pen to a PDF canvas path rather than a Drawing."""

    def _closePath(self):
        self.path.close()


def draw_outlines(document, filename, text, size, baseline, maximum_width):
    font = TTFont(FONT_DIRECTORY / filename)
    glyphs = font.getGlyphSet()
    cmap = font.getBestCmap()
    names = [cmap[ord(character)] for character in text]
    kerning = {}
    if "kern" in font:
        for table in font["kern"].kernTables:
            kerning.update(getattr(table, "kernTable", {}))
    advances = [glyphs[name].width for name in names]
    for index in range(len(names) - 1):
        advances[index] += kerning.get((names[index], names[index + 1]), 0)
    scale = min(size / font["head"].unitsPerEm, maximum_width / sum(advances))
    document.saveState()
    document.translate((200 - sum(advances) * scale) / 2, baseline)
    document.scale(scale, scale)
    for name, advance in zip(names, advances):
        pen = PDFOutlinePen(glyphs, path=document.beginPath())
        glyphs[name].draw(pen)
        document.drawPath(pen.path, stroke=0, fill=1)
        document.translate(advance, 0)
    document.restoreState()
    font.close()


def main():
    ASSET_DIRECTORY.mkdir(parents=True, exist_ok=True)
    document = canvas.Canvas(str(ASSET_DIRECTORY / "PokeDenWordmark.pdf"),
                             pagesize=(200, 68), pageCompression=1, invariant=1)
    document.setTitle("PokéDen Collectibles label wordmark")
    document.setAuthor("PokéDen Collectibles")
    document.setFillColorRGB(0, 0, 0)
    draw_outlines(document, "DejaVuSerif-Bold.ttf", "PokéDen", 40, 26, 194)
    draw_outlines(document, "DejaVuSans-Bold.ttf", "COLLECTIBLES", 14, 5, 165)
    document.showPage()
    document.save()
    (ASSET_DIRECTORY / "Contents.json").write_text(json.dumps({
        "data": [{"filename": "PokeDenWordmark.pdf", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Builds the two small files the theme puts in front of Inter, in desktop/assets/fonts:

- Inter-Numbers.ttf: the ten digits in their tabular forms, for numbers in columns;
- Inter-Blank.ttf: no characters at all, only Inter's metrics and an empty .notdef.

    python3 desktop/tools/make-inter.py <path to InterVariable.ttf from the Inter 4.1 release>

Needs fonttools (pip install fonttools). The source is InterVariable.ttf from
https://github.com/rsms/inter/releases/tag/v4.1 (Inter-4.1.zip, sha256
9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e), which the theme also uses,
unmodified, for all text. egui applies no OpenType features, so Inter's tabular figures (`tnum`)
can't be switched on; this file carries them as the plain digits instead. What changes, all
allowed by the SIL Open Font License (Inter declares no Reserved Font Name):

- instanced to the weights the theme uses, wght 300-700, at the text optical size, opsz 14;
- the digits 0-9 mapped to their tabular forms (Inter-Numbers only);
- every other character removed, hinting too, and the .notdef glyph left empty.

egui takes a family's line metrics and its missing-character glyph from the family's first font,
and each character from the first font that has it. So the theme puts Inter-Blank first in the
text families (every character then comes from InterVariable.ttf itself, and a character no
font has, not even a system font, is blank instead of a box) and Inter-Numbers first in the
number families (digits tabular, everything else from InterVariable.ttf). Both keep Inter's
vertical metrics, so numbers and text share one line box.

The licence goes beside it as OFL.txt, the release's LICENSE.txt unchanged.
"""
import io
import sys

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

DIGITS = [ord(c) for c in "0123456789"]


def build(src: str, out: str, digits: list[int]) -> None:
    font = instancer.instantiateVariableFont(TTFont(src), {"opsz": 14, "wght": (300, 700)})

    gsub = font["GSUB"].table
    lookups = {i for record in gsub.FeatureList.FeatureRecord if record.FeatureTag == "tnum"
               for i in record.Feature.LookupListIndex}
    tabular = {}
    for i in lookups:
        for table in gsub.LookupList.Lookup[i].SubTable:
            table = getattr(table, "ExtSubTable", table)
            tabular.update(getattr(table, "mapping", {}) or {})
    for cmap in font["cmap"].tables:
        for code in digits:
            glyph = cmap.cmap.get(code)
            if glyph in tabular:
                cmap.cmap[code] = tabular[glyph]

    # The instancer leaves some tables lazily loaded; the subsetter needs them read in full.
    buffer = io.BytesIO()
    font.save(buffer)
    buffer.seek(0)
    font = TTFont(buffer)

    options = subset.Options()
    options.layout_features = []
    options.hinting = False
    options.name_IDs = ["*"]
    options.name_languages = ["*"]
    options.notdef_outline = False
    options.drop_tables += ["STAT"]
    subsetter = subset.Subsetter(options)
    subsetter.populate(unicodes=digits)
    subsetter.subset(font)
    font.save(out)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    folder = sys.argv[2] if len(sys.argv) == 3 else "desktop/assets/fonts"
    build(sys.argv[1], f"{folder}/Inter-Numbers.ttf", DIGITS)
    build(sys.argv[1], f"{folder}/Inter-Blank.ttf", [])

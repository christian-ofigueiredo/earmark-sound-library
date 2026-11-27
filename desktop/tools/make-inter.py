#!/usr/bin/env python3
"""Builds desktop/assets/fonts/Inter.ttf, the theme's text font, from Inter's official release.

    python3 desktop/tools/make-inter.py <path to InterVariable.ttf from the Inter 4.1 release>

Needs fonttools (pip install fonttools). The source is InterVariable.ttf from
https://github.com/rsms/inter/releases/tag/v4.1 (Inter-4.1.zip, sha256
9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e). What changes, all allowed by the
SIL Open Font License (Inter declares no Reserved Font Name):

- instanced to the weights the theme uses, wght 300-700, at the text optical size, opsz 14;
- digits 0-9 mapped to their tabular forms (the font's own `tnum` glyphs), because egui applies
  no OpenType features and numbers in columns should line up; spaces and punctuation are left;
- glyphs no character reaches (alternates) and hinting dropped; kerning kept.

The licence goes beside the font as OFL.txt, the release's LICENSE.txt unchanged.
"""
import io
import sys

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer


def main(src: str, out: str) -> None:
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
        for code, glyph in list(cmap.cmap.items()):
            if code < 0x80 and chr(code).isdigit() and glyph in tabular:
                cmap.cmap[code] = tabular[glyph]

    # The instancer leaves some tables lazily loaded; the subsetter needs them read in full.
    buffer = io.BytesIO()
    font.save(buffer)
    buffer.seek(0)
    font = TTFont(buffer)

    options = subset.Options()
    options.layout_features = ["kern"]
    options.hinting = False
    options.name_IDs = ["*"]
    options.name_languages = ["*"]
    options.notdef_outline = True
    options.drop_tables += ["STAT"]
    subsetter = subset.Subsetter(options)
    subsetter.populate(unicodes=font.getBestCmap().keys())
    subsetter.subset(font)
    font.save(out)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else "desktop/assets/fonts/Inter.ttf")

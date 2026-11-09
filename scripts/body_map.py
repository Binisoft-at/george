#!/usr/bin/env python3
"""Single source of truth for George's body map (front + back muscle regions).

Usage:
  python3 scripts/body_map.py swift   > Packages/GeorgeCore/Sources/GeorgeCore/BodyMapData.swift
  python3 scripts/body_map.py preview out.svg [values.json]   # SVG preview with example heat values

Coordinates: each view is 200 × 440, figure centred on x = 100. Regions marked "mirror" are drawn
for the left side (x < 100) and mirrored for the right side.
"""
import json
import sys

# Base silhouette (drawn in a neutral colour under the muscles). Same for front and back.
BASE = [
    ("head", "M 100 12 C 111 12 119 22 119 36 C 119 50 111 60 100 60 C 89 60 81 50 81 36 C 81 22 89 12 100 12 Z", False),
    ("neck", "M 89 54 L 111 54 L 113 80 L 87 80 Z", False),
    ("torso", "M 100 74 L 66 76 C 54 78 46 86 44 98 L 46 128 C 52 150 58 180 60 204 C 62 214 68 222 76 226 L 100 232 Z", True),
    ("upperArm", "M 44 92 C 36 100 34 116 34 130 C 33 146 36 160 40 168 L 54 166 C 56 150 57 132 55 112 Z", True),
    ("forearm", "M 40 166 C 34 178 28 198 27 216 C 26 228 28 236 30 240 L 44 240 C 48 222 52 196 54 168 Z", True),
    ("hand", "M 30 238 L 44 238 C 46 250 44 262 37 268 C 30 266 26 256 27 246 Z", True),
    ("thigh", "M 62 208 C 58 240 60 290 66 322 L 97 324 C 100 290 101 250 100 228 Z", True),
    ("knee", "M 66 320 L 96 320 C 97 330 96 338 94 342 L 68 342 C 66 336 65 328 66 320 Z", True),
    ("shin", "M 67 338 C 64 362 66 390 72 410 L 89 410 C 94 390 97 362 95 338 Z", True),
    ("foot", "M 71 406 L 90 406 L 93 424 C 87 430 74 430 65 425 Z", True),
]

FRONT = [
    ("neck", "M 91 58 L 99 61 L 99 79 L 92 77 Z", True),
    ("traps", "M 89 68 C 84 73 76 76 66 78 C 76 80 86 80 92 80 Z", True),
    ("shoulders", "M 66 78 C 54 78 45 86 43 100 C 42 110 44 118 47 124 C 50 112 56 100 66 92 C 68 86 68 80 66 78 Z", True),
    ("chest", "M 69 86 C 80 80 94 82 99 86 L 99 122 C 90 130 76 130 66 122 C 61 112 62 96 69 86 Z", True),
    ("biceps", "M 46 128 C 50 122 55 122 56 130 C 57 144 55 158 50 166 C 45 162 41 150 41 138 C 41 132 43 129 46 128 Z", True),
    ("forearms", "M 41 172 C 46 168 52 170 52 176 C 51 196 47 216 42 234 C 37 233 33 229 32 224 C 31 206 35 186 41 172 Z", True),
    ("obliques", "M 64 128 C 70 132 77 136 81 138 L 81 198 C 75 196 70 200 66 206 C 63 186 62 160 64 128 Z", True),
    ("abs", "M 84 134 C 92 130 108 130 116 134 L 117 196 C 113 212 87 212 83 196 Z", False),
    ("hipFlexors", "M 74 210 C 80 212 88 218 94 230 L 90 238 C 85 228 79 220 70 216 Z", True),
    ("abductors", "M 62 206 C 66 204 70 208 70 216 C 66 230 63 244 62 256 C 59 240 58 222 62 206 Z", True),
    ("quads", "M 70 220 C 76 218 84 224 89 236 C 95 254 96 290 93 318 C 88 326 76 326 70 318 C 64 290 63 250 70 220 Z", True),
    ("adductors", "M 91 238 C 96 244 99 252 99 262 C 99 276 97 288 95 298 C 94 278 93 258 91 238 Z", True),
    ("calves", "M 70 342 C 76 338 88 340 91 348 C 93 370 89 392 85 404 C 81 406 77 404 75 400 C 69 380 68 360 70 342 Z", True),
]

# Thin detail strokes drawn on top (abs segmentation, spine).
FRONT_DETAILS = [
    "M 100 133 L 100 206",
    "M 85 150 C 92 148 108 148 115 150",
    "M 85 166 C 92 164 108 164 115 166",
    "M 85 182 C 92 180 108 180 115 182",
]
BACK_DETAILS = [
    "M 100 132 L 100 206",
]

BACK = [
    ("neck", "M 91 56 L 109 56 L 110 64 L 100 61 L 90 64 Z", False),
    ("traps", "M 100 60 L 111 65 C 119 72 131 76 140 80 C 128 86 118 96 112 110 L 100 132 L 88 110 C 82 96 72 86 60 80 C 69 76 81 72 89 65 Z", False),
    ("shoulders", "M 60 80 C 50 82 44 90 43 102 C 43 112 45 118 48 124 C 52 110 58 100 66 94 C 66 88 64 83 60 80 Z", True),
    ("upperBack", "M 87 112 L 99 136 L 99 158 C 92 152 84 144 76 130 C 79 122 83 116 87 112 Z", True),
    ("lats", "M 67 96 C 71 110 76 124 85 140 C 92 150 97 160 98 172 C 89 180 79 186 70 192 C 66 170 62 142 62 114 C 62 106 64 100 67 96 Z", True),
    ("lowerBack", "M 91 174 C 96 170 104 170 109 174 L 111 204 C 105 210 95 210 89 204 Z", False),
    ("triceps", "M 45 128 C 49 122 55 122 56 130 C 57 144 55 158 50 166 C 45 162 41 150 41 138 C 41 133 43 130 45 128 Z", True),
    ("forearms", "M 41 172 C 46 168 52 170 52 176 C 51 196 47 216 42 234 C 37 233 33 229 32 224 C 31 206 35 186 41 172 Z", True),
    ("abductors", "M 62 194 C 68 190 78 192 85 198 C 77 201 70 203 65 209 C 62 205 61 199 62 194 Z", True),
    ("glutes", "M 66 208 C 74 202 90 204 98 212 C 100 224 99 236 96 244 C 86 249 74 247 66 241 C 62 231 62 217 66 208 Z", True),
    ("hamstrings", "M 66 250 C 74 248 86 250 92 254 C 95 276 94 300 90 318 C 84 324 74 324 70 318 C 65 296 64 272 66 250 Z", True),
    ("adductors", "M 93 254 C 97 262 99 272 99 282 C 98 292 96 300 94 306 C 95 286 95 270 93 254 Z", True),
    ("calves", "M 69 342 C 76 336 88 338 92 348 C 95 364 92 380 86 390 C 82 394 76 394 72 390 C 66 376 65 356 69 342 Z", True),
]


def swift():
    def regions(name, items):
        lines = [f"    public static let {name}: [BodyRegion] = ["]
        for group, path, mirror in items:
            lines.append(f'        BodyRegion(group: .{group}, path: "{path}", mirrored: {"true" if mirror else "false"}),')
        lines.append("    ]")
        return "\n".join(lines)

    base = ["    public static let silhouette: [BodyShape] = ["]
    for name, path, mirror in BASE:
        base.append(f'        BodyShape(name: "{name}", path: "{path}", mirrored: {"true" if mirror else "false"}),')
    base.append("    ]")
    details = [
        "    public static let frontDetails: [String] = [" + ", ".join(f'"{d}"' for d in FRONT_DETAILS) + "]",
        "    public static let backDetails: [String] = [" + ", ".join(f'"{d}"' for d in BACK_DETAILS) + "]",
    ]
    print("// Generated by scripts/body_map.py — edit the script, not this file.")
    print("import Foundation\n")
    print("extension BodyMap {")
    print("\n".join(base))
    print()
    print("\n".join(details))
    print()
    print(regions("front", FRONT))
    print()
    print(regions("back", BACK))
    print("}")


def preview(out, values):
    def color(v):
        if v is None or v <= 0:
            return "#4a5060"
        # single warm ramp: light amber -> red-orange
        lo, hi = (247, 201, 107), (232, 70, 30)
        t = max(0.0, min(1.0, v))
        c = [round(lo[i] + (hi[i] - lo[i]) * t) for i in range(3)]
        return "#%02x%02x%02x" % tuple(c)

    def view(items, dx, details):
        parts = [f'<g transform="translate({dx},0)">']
        for _, path, mirror in BASE:
            parts.append(f'<path d="{path}" fill="#2c313c"/>')
            if mirror:
                parts.append(f'<path d="{path}" fill="#2c313c" transform="translate(200,0) scale(-1,1)"/>')
        for group, path, mirror in items:
            c = color(values.get(group))
            parts.append(f'<path d="{path}" fill="{c}" stroke="#1b1e25" stroke-width="0.8"/>')
            if mirror:
                parts.append(f'<path d="{path}" fill="{c}" stroke="#1b1e25" stroke-width="0.8" transform="translate(200,0) scale(-1,1)"/>')
        for d in details:
            parts.append(f'<path d="{d}" fill="none" stroke="#1b1e25" stroke-width="1.2" stroke-linecap="round" opacity="0.7"/>')
        parts.append("</g>")
        return "\n".join(parts)

    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="840" height="880" viewBox="0 0 420 440">
<rect width="420" height="440" fill="#20232b"/>
{view(FRONT, 0, FRONT_DETAILS)}
{view(BACK, 220, BACK_DETAILS)}
</svg>'''
    open(out, "w").write(svg)


if __name__ == "__main__":
    if sys.argv[1] == "swift":
        swift()
    else:
        values = json.load(open(sys.argv[3])) if len(sys.argv) > 3 else {}
        preview(sys.argv[2], values)

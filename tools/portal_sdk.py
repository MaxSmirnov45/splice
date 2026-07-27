"""Swap the portal SDK script tag in web/index.html.

Called by tools/build_web.sh. Strips every known portal script first, then adds
back exactly the one requested — so a build can never end up carrying two
portals' SDKs, or a stale one from a previous target.

    python3 tools/portal_sdk.py web/index.html {none|poki|crazygames}
"""

import re
import sys

TAGS = {
    "poki": (
        "  <!-- Poki SDK. Loaded ahead of the engine so PokiSDK exists before\n"
        "       the game initialises. The game detects it at runtime and runs\n"
        "       normally without it, so other hosts still work. -->\n"
        '  <script src="https://game-cdn.poki.com/scripts/v2/poki-sdk.js"></script>\n'
    ),
    "crazygames": (
        "  <!-- CrazyGames SDK. Same contract as above: detected at runtime,\n"
        "       absent elsewhere without breaking the game. -->\n"
        '  <script src="https://sdk.crazygames.com/crazygames-sdk-v3.js"></script>\n'
    ),
}

STRIP = re.compile(
    r"\n?[ \t]*<!--[^>]*?(?:Poki|CrazyGames) SDK.*?-->\s*"
    r"|\n?[ \t]*<script src=\"https://(?:game-cdn\.poki\.com|sdk\.crazygames\.com)[^\"]*\"></script>",
    re.S,
)


def main() -> None:
    path, which = sys.argv[1], sys.argv[2]
    html = open(path).read()

    html = STRIP.sub("", html)
    tag = TAGS.get(which, "")
    if tag:
        html = html.replace("</head>", tag + "</head>")

    open(path, "w").write(html)
    print(f"  index.html: portal sdk = {which}")


if __name__ == "__main__":
    main()

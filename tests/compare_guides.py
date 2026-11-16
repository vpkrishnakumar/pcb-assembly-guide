"""Checks exported web guides.

    python3 tests/compare_guides.py a.html b.html     the two pages must describe the same guide
    python3 tests/compare_guides.py --require-3d a.html   the page must contain a 3D board

The Mac app and the command-line tool implement the same logic twice; this keeps them in step.
"""
import json
import re
import sys


def read(path):
    page = open(path, encoding="utf-8").read()
    data = re.search(r'<script type="application/json" id="data">(.*?)</script>', page, re.S).group(1)
    model = re.search(r'<script type="application/octet-stream" id="glb">(.*?)</script>', page, re.S).group(1)
    return json.loads(data), len(model.strip())


def differences(a, b, path=""):
    if isinstance(a, dict) and isinstance(b, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a or key not in b:
                yield path + "/" + key, a.get(key, "<missing>"), b.get(key, "<missing>")
            else:
                yield from differences(a[key], b[key], path + "/" + key)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            yield path + " (length)", len(a), len(b)
        for index, (x, y) in enumerate(zip(a, b)):
            yield from differences(x, y, "%s[%d]" % (path, index))
    elif isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool):
        if abs(a - b) > 1e-6:
            yield path, a, b
    elif a != b:
        yield path, a, b


def main(arguments):
    if arguments and arguments[0] == "--require-3d":
        data, model = read(arguments[1])
        print("%d parts, 3D model of %d base64 characters, %s" % (len(data["parts"]), model, data["summary"]))
        return 0 if model > 1000 else 1
    (a, model_a), (b, model_b) = read(arguments[0]), read(arguments[1])
    # The summary line counts borrowed library models, which depends on the KiCad install.
    a.pop("summary", None)
    b.pop("summary", None)
    found = list(differences(a, b))
    print("%d and %d parts, %d differences" % (len(a["parts"]), len(b["parts"]), len(found)))
    for entry in found[:20]:
        print("  ", str(entry)[:200])
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

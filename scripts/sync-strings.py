#!/usr/bin/env python3
"""把编译器抽取的本地化 key（*.stringsdata）同步进 App/Localizable.xcstrings。

用法（先构建一次 App，生成 stringsdata）：
    python3 -I scripts/sync-strings.py [--translations en.json] [--check]

- 新 key 以 zh-Hans 为源语言加入；--translations 提供 {key: 英文} 时写入 en 译文。
- 不再被代码引用的 key 标记为 stale（保留译文，不删除）。
- --check：只检查，有缺失 en 译文或新 key 时退出码 1。
"""
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "App", "Localizable.xcstrings")
PATTERN = os.path.join(ROOT, "build", "DerivedData", "Build", "Intermediates.noindex", "IPADepot.build",
                       "*", "IPADepot.build", "Objects-normal", "*", "*.stringsdata")


def extracted_keys():
    keys = {}
    for path in glob.glob(PATTERN):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        for table, entries in data.get("tables", {}).items():
            if table != "Localizable":
                continue
            for entry in entries:
                keys[entry["key"]] = entry.get("comment", "")
    return keys


def main():
    args = sys.argv[1:]
    check = "--check" in args
    translations = {}
    if "--translations" in args:
        with open(args[args.index("--translations") + 1], encoding="utf-8") as f:
            translations = json.load(f)

    with open(CATALOG, encoding="utf-8") as f:
        catalog = json.load(f)
    strings = catalog.setdefault("strings", {})
    keys = extracted_keys()
    if not keys:
        print("没有找到 stringsdata，请先构建 App。", file=sys.stderr)
        return 2

    added, missing = [], []
    for key in sorted(keys):
        entry = strings.get(key)
        if entry is None:
            entry = {}
            strings[key] = entry
            added.append(key)
        entry.pop("extractionState", None)
        if key in translations:
            entry.setdefault("localizations", {})["en"] = {
                "stringUnit": {"state": "translated", "value": translations[key]}
            }
        if "en" not in entry.get("localizations", {}):
            missing.append(key)
    for key, entry in strings.items():
        if key not in keys:
            entry["extractionState"] = "stale"

    if check:
        for k in added:
            print("新 key：", k)
        for k in missing:
            print("缺英文：", k)
        return 1 if (added or missing) else 0

    catalog["sourceLanguage"] = "zh-Hans"
    catalog["version"] = "1.0"
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print(f"共 {len(keys)} 个 key，新增 {len(added)}，缺英文 {len(missing)}")
    for k in missing:
        print("缺英文：", k)
    return 0


if __name__ == "__main__":
    sys.exit(main())

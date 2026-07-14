#!/usr/bin/env python3
"""Generate compact Unicode 17 case-mapping tables for the Zig renderer."""

import argparse
import hashlib
import pathlib
import subprocess
import tempfile
import urllib.request


VERSION = "17.0.0"
BASE_URL = "https://www.unicode.org/Public/{}/ucd/".format(VERSION)
FILES = {
    "UnicodeData.txt": "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c",
    "SpecialCasing.txt": "efc25faf19de21b92c1194c111c932e03d2a5eaf18194e33f1156e96de4c9588",
    "DerivedCoreProperties.txt": "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08",
    "PropList.txt": "130dcddcaadaf071008bdfce1e7743e04fdfbc910886f017d9f9ac931d8c64dd",
}


def read_verified(directory, name):
    path = directory / name
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != FILES[name]:
        raise RuntimeError("{} SHA-256 mismatch: {}".format(name, digest))
    return data.decode("utf-8")


def download_ucd(directory):
    directory.mkdir(parents=True, exist_ok=True)
    for name in FILES:
        target = directory / name
        if not target.exists():
            with urllib.request.urlopen(BASE_URL + name) as response:
                target.write_bytes(response.read())
        read_verified(directory, name)


def parse_codepoints(value):
    value = value.strip()
    if not value:
        return ()
    return tuple(int(item, 16) for item in value.split())


def parse_range(value):
    pieces = value.strip().split("..")
    start = int(pieces[0], 16)
    return start, int(pieces[-1], 16)


def parse_unicode_data(text):
    mappings = {"lower": {}, "title": {}, "upper": {}}
    combining = {}
    for raw_line in text.splitlines():
        if not raw_line or raw_line.startswith("#"):
            continue
        fields = raw_line.split(";")
        codepoint = int(fields[0], 16)
        combining_class = int(fields[3])
        if combining_class:
            combining[codepoint] = combining_class
        for name, index in (("upper", 12), ("lower", 13), ("title", 14)):
            if fields[index]:
                mappings[name][codepoint] = (int(fields[index], 16),)
    return mappings, combining


def apply_unconditional_special_casing(mappings, text):
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        if fields[4]:
            continue
        codepoint = int(fields[0], 16)
        mappings["lower"][codepoint] = parse_codepoints(fields[1])
        mappings["title"][codepoint] = parse_codepoints(fields[2])
        mappings["upper"][codepoint] = parse_codepoints(fields[3])


def parse_property_ranges(text, wanted):
    result = {name: [] for name in wanted}
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        value, property_name = [part.strip() for part in line.split(";", 1)]
        if property_name in result:
            result[property_name].append(parse_range(value))
    return result


def write_mapping(lines, name, mappings):
    data = []
    entries = []
    for codepoint, mapped in sorted(mappings.items()):
        if mapped == (codepoint,):
            continue
        offset = len(data)
        data.extend(mapped)
        entries.append((codepoint, offset, len(mapped)))
    lines.append("pub const {}_data = [_]u21{{".format(name))
    for index in range(0, len(data), 12):
        values = ", ".join("0x{:X}".format(value) for value in data[index : index + 12])
        lines.append("    " + values + ",")
    lines.append("};")
    lines.append("pub const {}_mappings = [_]Mapping{{".format(name))
    for codepoint, offset, length in entries:
        lines.append("    .{{ .codepoint = 0x{:X}, .offset = {}, .length = {} }},".format(codepoint, offset, length))
    lines.append("};")
    lines.append("")


def write_ranges(lines, name, ranges):
    lines.append("pub const {} = [_]Range{{".format(name))
    for start, end in ranges:
        lines.append("    .{{ .start = 0x{:X}, .end = 0x{:X} }},".format(start, end))
    lines.append("};")
    lines.append("")


def generate(ucd_dir, output):
    unicode_data = read_verified(ucd_dir, "UnicodeData.txt")
    special_casing = read_verified(ucd_dir, "SpecialCasing.txt")
    derived = read_verified(ucd_dir, "DerivedCoreProperties.txt")
    prop_list = read_verified(ucd_dir, "PropList.txt")

    mappings, combining = parse_unicode_data(unicode_data)
    apply_unconditional_special_casing(mappings, special_casing)
    derived_ranges = parse_property_ranges(derived, {"Cased", "Case_Ignorable"})
    prop_ranges = parse_property_ranges(prop_list, {"Soft_Dotted"})

    lines = [
        "//! Generated Unicode {} default case data. Do not edit manually.".format(VERSION),
        "//! Source hashes are pinned in scripts/generate_unicode_case.py.",
        "",
        "pub const version = \"{}\";".format(VERSION),
        "pub const Mapping = struct { codepoint: u21, offset: u32, length: u8 };",
        "pub const Range = struct { start: u21, end: u21 };",
        "pub const Combining = struct { codepoint: u21, class: u8 };",
        "",
    ]
    for name in ("lower", "title", "upper"):
        write_mapping(lines, name, mappings[name])
    write_ranges(lines, "cased_ranges", derived_ranges["Cased"])
    write_ranges(lines, "case_ignorable_ranges", derived_ranges["Case_Ignorable"])
    write_ranges(lines, "soft_dotted_ranges", prop_ranges["Soft_Dotted"])
    lines.append("pub const combining_classes = [_]Combining{")
    for codepoint, combining_class in sorted(combining.items()):
        lines.append("    .{{ .codepoint = 0x{:X}, .class = {} }},".format(codepoint, combining_class))
    lines.append("};")
    lines.append("")
    output.write_text("\n".join(lines), encoding="utf-8")
    subprocess.run(["zig", "fmt", str(output)], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ucd-dir", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("src/unicode_case_data.zig"))
    args = parser.parse_args()

    if args.ucd_dir:
        generate(args.ucd_dir, args.output)
        return
    with tempfile.TemporaryDirectory(prefix="html2realpdf-ucd-") as temp:
        directory = pathlib.Path(temp)
        download_ucd(directory)
        generate(directory, args.output)


if __name__ == "__main__":
    main()

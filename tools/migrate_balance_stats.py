"""One-shot migration for the data-driven balance refactor.

Phase 1 (default run): bake resolved tier values into the new direct
numeric fields on every WeaponResource and UnitStatResource. Add the
weapons array to building .tres files based on turret_component PROFILES.
Old tier fields are left intact so the game still works during code
migration.

Phase 2 (re-run with --strip after Task 13): remove the now-unused
tier fields.

Usage from project root:
    python tools/migrate_balance_stats.py [--dry-run] [--strip]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any


# -----------------------------------------------------------------------------
# Mirrors of the GDScript constants. KEEP IN SYNC if combat_tables.gd or
# unit_stat_resource.gd ship a balance change before this script runs.
# -----------------------------------------------------------------------------

DAMAGE_MAP = {"very_low": 5, "low": 12, "moderate": 25, "high": 50,
              "very_high": 85, "extreme": 150}
RANGE_MAP = {"melee": 2.0, "short": 8.0, "medium": 15.0, "long": 25.0,
             "very_long": 40.0, "extreme": 60.0}
ROF_MAP = {"single": 4.0, "slow": 2.0, "moderate": 1.0, "fast": 0.5,
           "rapid": 0.25, "volley": 0.3, "continuous": 0.15}
ARMOR_MAP = {"unarmored": 0.0, "light": 0.15, "medium": 0.30,
             "heavy": 0.45, "structure": 0.45,
             "light_air": 0.10, "heavy_air": 0.35}
SPEED_MAP = {"static": 0.0, "very_slow": 3.0, "slow": 5.0,
             "moderate": 8.0, "fast": 12.0, "very_fast": 16.0}
SIGHT_MAP = {"short": 12.0, "medium": 18.0, "long": 26.0,
             "very_long": 36.0, "extreme": 50.0}
ROLE_VS_ARMOR: dict[str, dict[str, float]] = {
    "AP": {"unarmored": 1.0, "light": 1.0, "medium": 0.4, "heavy": 0.3,
           "structure": 0.4, "light_air": 1.0, "heavy_air": 0.5},
    "AA": {"unarmored": 0.8, "light": 0.5, "medium": 0.8, "heavy": 1.2,
           "structure": 0.6, "light_air": 0.3, "heavy_air": 0.4},
    "AAir": {"unarmored": 0.0, "light": 0.0, "medium": 0.0, "heavy": 0.0,
             "structure": 0.0, "light_air": 1.2, "heavy_air": 1.0},
    "Universal": {"unarmored": 0.8, "light": 0.8, "medium": 1.0,
                  "heavy": 0.8, "structure": 0.8, "light_air": 0.4,
                  "heavy_air": 0.3},
    "AAir_Light": {"unarmored": 0.40, "light": 0.35, "medium": 0.28,
                   "heavy": 0.10, "structure": 0.15, "light_air": 1.0,
                   "heavy_air": 0.2},
    "AB": {"unarmored": 0.10, "light": 0.10, "medium": 0.20, "heavy": 0.30,
           "structure": 2.00, "light_air": 0.00, "heavy_air": 0.00},
    "AS": {"unarmored": 0.6, "light": 0.6, "medium": 0.6, "heavy": 0.7,
           "structure": 2.5, "light_air": 0.2, "heavy_air": 0.2},
}
ARMOR_CLASSES = ["unarmored", "light", "medium", "heavy", "structure",
                 "light_air", "heavy_air"]


# -----------------------------------------------------------------------------
# Mirror of turret_component.gd's PROFILES dict. The "name" field becomes
# WeaponResource.weapon_name. The HQ-defense entry has a custom per-armor
# table baked into mults_override that folds the 0.45 air-damage scalar
# into the air mults so the produced WeaponResource is fully self-contained.
# -----------------------------------------------------------------------------

TURRET_PROFILES: dict[str, dict[str, Any]] = {
    "balanced":   {"damage": 45,  "rof": 0.9,  "range": 20.0, "role": "Universal",
                   "name": "Balanced",   "engages_air": False},
    "anti_light": {"damage": 24,  "rof": 0.3,  "range": 18.0, "role": "AP",
                   "name": "Anti-Light", "engages_air": False},
    "anti_heavy": {"damage": 135, "rof": 2.2,  "range": 22.0, "role": "AP",
                   "name": "Anti-Heavy", "engages_air": False},
    "anti_air":   {"damage": 36,  "rof": 0.25, "range": 24.0, "role": "AAir",
                   "name": "Anti-Air",   "engages_air": True},
    "hq_defense": {"damage": 19,  "rof": 1.1,  "range": 28.0, "role": "Universal",
                   "name": "HQ Defense", "engages_air": True,
                   "salvo_count": 5, "salvo_stagger_sec": 0.08,
                   # Folds turret_component's 0.45 base air-damage scalar
                   # into the per-class mults so this WeaponResource is
                   # the single source of truth for HQ MG damage.
                   "mults_override": {"unarmored": 1.0, "light": 1.0, "medium": 0.7,
                                      "heavy": 0.4, "structure": 0.3,
                                      "light_air": 0.45, "heavy_air": 0.18}},
}

# Per-building plan: which profiles map to which .tres file, with optional
# Anvil +15% damage bonus baked in.
BUILDING_WEAPONS: dict[str, list[tuple[str, float]]] = {
    "gun_emplacement.tres":       [("balanced",   1.15), ("anti_light", 1.15), ("anti_heavy", 1.15)],
    "gun_emplacement_basic.tres": [("balanced",   1.0)],
    "sam_site.tres":              [("anti_air",   1.0)],
    "headquarters.tres":          [("hq_defense", 1.0)],
}


# -----------------------------------------------------------------------------
# .tres parsing — section-based. Each [header] block becomes a Section;
# everything between headers is preserved verbatim except for property
# additions / replacements we explicitly apply.
# -----------------------------------------------------------------------------

SECTION_RE = re.compile(r'^\[(?P<header>[^\]]+)\]\s*$')
KV_RE = re.compile(r'^(?P<key>[a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(?P<val>.*)$')


class Section:
    """A [header] block plus its key/value lines and any blank lines."""
    def __init__(self, header: str):
        self.header = header
        self.lines: list[str] = []

    def get(self, key: str) -> str | None:
        for line in self.lines:
            m = KV_RE.match(line.strip())
            if m and m.group("key") == key:
                return m.group("val").strip()
        return None

    def set_or_append(self, key: str, val: str) -> None:
        new_line = f"{key} = {val}"
        for i, line in enumerate(self.lines):
            m = KV_RE.match(line.strip())
            if m and m.group("key") == key:
                self.lines[i] = new_line
                return
        self.lines.append(new_line)

    def remove(self, key: str) -> None:
        kept: list[str] = []
        for line in self.lines:
            m = KV_RE.match(line.strip())
            if m and m.group("key") == key:
                continue
            kept.append(line)
        self.lines = kept


def parse_tres(path: Path) -> tuple[str, list[Section]]:
    """Returns (preamble_lines_before_first_section, sections)."""
    sections: list[Section] = []
    preamble: list[str] = []
    current: Section | None = None
    text = path.read_text(encoding="utf-8")
    for line in text.split("\n"):
        m = SECTION_RE.match(line)
        if m:
            current = Section(m.group("header"))
            sections.append(current)
        elif current is not None:
            current.lines.append(line)
        else:
            preamble.append(line)
    return "\n".join(preamble), sections


def write_tres(path: Path, preamble: str, sections: list[Section]) -> None:
    parts: list[str] = []
    if preamble:
        parts.append(preamble)
    for s in sections:
        parts.append(f"[{s.header}]")
        for line in s.lines:
            parts.append(line)
    text = "\n".join(parts)
    if not text.endswith("\n"):
        text += "\n"
    path.write_text(text, encoding="utf-8")


# -----------------------------------------------------------------------------
# Helpers for parsing primitive values out of the raw kv strings.
# -----------------------------------------------------------------------------

def parse_str_lit(v: str | None) -> str | None:
    """Parse '&"foo"' or '"foo"' → 'foo'. Returns None for missing."""
    if v is None:
        return None
    v = v.strip()
    if v.startswith("&"):
        v = v[1:]
    if v.startswith('"') and v.endswith('"'):
        return v[1:-1]
    return v


def parse_num(v: str | None, default: float) -> float:
    if v is None:
        return default
    try:
        return float(v.strip())
    except ValueError:
        return default


def parse_bool(v: str | None) -> bool:
    return v is not None and v.strip() == "true"


# -----------------------------------------------------------------------------
# Section-type detection.
# -----------------------------------------------------------------------------

def is_weapon_subresource(s: Section) -> bool:
    if not s.header.startswith("sub_resource"):
        return False
    # WeaponResource sub-resources expose damage_tier OR damage; both unique
    # to weapons among the sub_resource shapes used in this project.
    return s.get("damage_tier") is not None or s.get("role_tag") is not None


def is_unit_resource(s: Section) -> bool:
    return s.header == "resource" and s.get("hp_total") is not None


def is_building_resource(s: Section) -> bool:
    return s.header == "resource" and s.get("building_id") is not None


# -----------------------------------------------------------------------------
# WeaponResource migration — applies in-place to a Section.
# -----------------------------------------------------------------------------

LEGACY_MULT_KEYS = {
    "unarmored": None,
    "light": "mult_vs_light",
    "medium": "mult_vs_medium",
    "heavy": "mult_vs_heavy",
    "structure": "structure_damage_mult",
    "light_air": "mult_vs_light_air",
    "heavy_air": "mult_vs_heavy_air",
}

LEGACY_WEAPON_FIELDS = [
    "damage_tier", "range_tier", "rof_tier",
    "damage_value", "range_value", "rof_seconds_value",
    "can_hit_air",
    "mult_vs_light", "mult_vs_medium", "mult_vs_heavy",
    "mult_vs_light_air", "mult_vs_heavy_air", "structure_damage_mult",
]


def migrate_weapon(s: Section, anvil_bonus: float = 1.0, strip: bool = False) -> None:
    role_tag = parse_str_lit(s.get("role_tag")) or "Universal"
    damage_tier = parse_str_lit(s.get("damage_tier")) or "moderate"
    range_tier = parse_str_lit(s.get("range_tier")) or "medium"
    rof_tier = parse_str_lit(s.get("rof_tier")) or "moderate"

    damage_v = int(parse_num(s.get("damage_value"), -1))
    range_v = parse_num(s.get("range_value"), -1.0)
    rof_v = parse_num(s.get("rof_seconds_value"), -1.0)

    can_hit_air = parse_bool(s.get("can_hit_air"))

    # Resolve scalar values, preferring per-weapon overrides.
    if damage_v >= 0:
        damage = damage_v
    else:
        damage = DAMAGE_MAP.get(damage_tier, 25)
    damage = int(round(damage * anvil_bonus))

    if range_v >= 0.0:
        rng = range_v
    else:
        rng = RANGE_MAP.get(range_tier, 15.0)

    if rof_v >= 0.0:
        rof = rof_v
    else:
        rof = ROF_MAP.get(rof_tier, 1.0)

    engages_air = role_tag in ("AAir", "AAir_Light") or can_hit_air

    s.set_or_append("damage", str(damage))
    s.set_or_append("range", _fmt_float(rng))
    s.set_or_append("rof_seconds", _fmt_float(rof))
    s.set_or_append("use_explicit_air", "true")
    s.set_or_append("engages_air_explicit", "true" if engages_air else "false")

    # Per-armor-class multipliers — bake into _v2 fields.
    role_table = ROLE_VS_ARMOR.get(role_tag, ROLE_VS_ARMOR["Universal"])
    for armor in ARMOR_CLASSES:
        legacy_key = LEGACY_MULT_KEYS[armor]
        legacy_v = parse_num(s.get(legacy_key), -1.0) if legacy_key else -1.0
        if legacy_v > 0.0:
            mult = legacy_v
        else:
            mult = role_table.get(armor, 0.8)
        s.set_or_append(f"mult_vs_{armor}_v2", _fmt_float(mult))

    if strip:
        for k in LEGACY_WEAPON_FIELDS:
            s.remove(k)


# -----------------------------------------------------------------------------
# UnitStatResource migration.
# -----------------------------------------------------------------------------

LEGACY_UNIT_FIELDS = [
    "speed_tier", "sight_tier",
    "speed_value", "sight_radius_value", "armor_reduction_value",
]


def migrate_unit(s: Section, strip: bool = False) -> None:
    speed_tier = parse_str_lit(s.get("speed_tier")) or "moderate"
    sight_tier = parse_str_lit(s.get("sight_tier")) or "medium"
    armor_class = parse_str_lit(s.get("armor_class")) or "light"

    speed_v = parse_num(s.get("speed_value"), -1.0)
    sight_v = parse_num(s.get("sight_radius_value"), -1.0)
    armor_v = parse_num(s.get("armor_reduction_value"), -1.0)

    if speed_v >= 0.0:
        speed = speed_v
    else:
        speed = SPEED_MAP.get(speed_tier, 8.0)
    if sight_v >= 0.0:
        sight = sight_v
    else:
        sight = SIGHT_MAP.get(sight_tier, 18.0)
    if armor_v >= 0.0:
        armor_red = armor_v
    else:
        armor_red = ARMOR_MAP.get(armor_class, 0.0)

    s.set_or_append("speed", _fmt_float(speed))
    s.set_or_append("sight_radius", _fmt_float(sight))
    s.set_or_append("armor_reduction", _fmt_float(armor_red))

    if strip:
        for k in LEGACY_UNIT_FIELDS:
            s.remove(k)


# -----------------------------------------------------------------------------
# Building turret weapons — synthesizes new sub_resource sections + a
# weapons array reference on the [resource] section.
# -----------------------------------------------------------------------------

EXT_HEADER_RE = re.compile(r'^ext_resource\s+.*?\bid="(?P<id>[^"]+)"')


def _next_ext_id(sections: list[Section]) -> int:
    nx = 1
    for s in sections:
        m = EXT_HEADER_RE.match(s.header)
        if m:
            try:
                nx = max(nx, int(m.group("id")) + 1)
            except ValueError:
                pass
    return nx


def _find_weapon_ext_id(sections: list[Section]) -> str | None:
    for s in sections:
        if s.header.startswith("ext_resource") and 'path="res://scripts/weapon_resource.gd"' in s.header:
            m = EXT_HEADER_RE.match(s.header)
            if m:
                return m.group("id")
    return None


def _bump_load_steps(preamble: str, delta: int) -> str:
    """Increase the load_steps count in the gd_resource header by delta."""
    m = re.search(r'load_steps=(\d+)', preamble)
    if not m:
        return preamble
    new_count = int(m.group(1)) + delta
    return preamble[: m.start()] + f"load_steps={new_count}" + preamble[m.end():]


def _fmt_float(v: float) -> str:
    """Format a float to match Godot's .tres output style — no trailing
    zeros for round numbers, but keep a trailing .0 for integers so the
    value remains a float in the inspector."""
    if v == int(v):
        return f"{int(v)}.0"
    return f"{v}"


def migrate_building(path: Path, strip: bool = False) -> bool:
    """Returns True if the file was changed."""
    plan = BUILDING_WEAPONS.get(path.name)
    if plan is None:
        return False  # Building has no turret — skip.

    preamble, sections = parse_tres(path)

    # Only migrate once: skip if a weapons array is already present.
    res_section = next((s for s in sections if is_building_resource(s)), None)
    if res_section is None:
        return False
    if res_section.get("weapons") is not None and not strip:
        return False
    if strip and res_section.get("weapons") is None:
        # No-op for buildings that were never migrated.
        return False
    if strip:
        # Strip pass currently has nothing to remove on buildings
        # (PROFILES dict lives in .gd, not .tres). Leave file alone.
        return False

    # Ensure ext_resource for weapon_resource.gd exists.
    weapon_ext_id = _find_weapon_ext_id(sections)
    added_ext = 0
    if weapon_ext_id is None:
        weapon_ext_id = str(_next_ext_id(sections))
        new_ext = Section(f'ext_resource type="Script" path="res://scripts/weapon_resource.gd" id="{weapon_ext_id}"')
        # Insert after the last ext_resource (or at index 0 if none).
        insert_at = 0
        for i, s in enumerate(sections):
            if s.header.startswith("ext_resource"):
                insert_at = i + 1
        sections.insert(insert_at, new_ext)
        added_ext = 1

    # Build sub_resource sections for each weapon and an ID list for the array.
    sub_ids: list[str] = []
    new_subs: list[Section] = []
    for idx, (profile_key, anvil_bonus) in enumerate(plan):
        prof = TURRET_PROFILES[profile_key]
        sub_id = f"turret_{path.stem}_{idx}_{profile_key}"
        sub_ids.append(sub_id)
        sub = Section(f'sub_resource type="Resource" id="{sub_id}"')
        sub.lines.append(f'script = ExtResource("{weapon_ext_id}")')
        sub.lines.append(f'weapon_name = "{prof["name"]}"')
        sub.lines.append(f'role_tag = &"{prof["role"]}"')
        damage = int(round(prof["damage"] * anvil_bonus))
        sub.lines.append(f"damage = {damage}")
        sub.lines.append(f"range = {_fmt_float(prof['range'])}")
        sub.lines.append(f"rof_seconds = {_fmt_float(prof['rof'])}")
        sub.lines.append("use_explicit_air = true")
        sub.lines.append(f"engages_air_explicit = {'true' if prof['engages_air'] else 'false'}")
        if "salvo_count" in prof:
            sub.lines.append(f"salvo_count = {prof['salvo_count']}")
        if "salvo_stagger_sec" in prof:
            sub.lines.append(f"salvo_stagger_sec = {_fmt_float(prof['salvo_stagger_sec'])}")
        mults_src = prof.get("mults_override")
        role_table = ROLE_VS_ARMOR.get(prof["role"], ROLE_VS_ARMOR["Universal"])
        for armor in ARMOR_CLASSES:
            if mults_src and armor in mults_src:
                mult = mults_src[armor]
            else:
                mult = role_table.get(armor, 0.8)
            sub.lines.append(f"mult_vs_{armor}_v2 = {_fmt_float(mult)}")
        new_subs.append(sub)

    # Insert sub_resources right before the [resource] section.
    res_idx = next(i for i, s in enumerate(sections) if s.header == "resource")
    for sub in new_subs:
        sections.insert(res_idx, sub)
        res_idx += 1

    # Set weapons array on the resource. Use plain bracket syntax (matches
    # how Godot writes typed-resource arrays — see basic_foundry.tres).
    arr_str = "[" + ", ".join(f'SubResource("{sid}")' for sid in sub_ids) + "]"
    res_section.set_or_append("weapons", arr_str)
    res_section.set_or_append("default_weapon_index", "0")

    # Bump load_steps to count the new ext + new subs.
    preamble = _bump_load_steps(preamble, added_ext + len(new_subs))

    write_tres(path, preamble, sections)
    return True


# -----------------------------------------------------------------------------
# Per-file passes.
# -----------------------------------------------------------------------------

def migrate_unit_file(path: Path, strip: bool) -> bool:
    preamble, sections = parse_tres(path)
    changed = False
    for s in sections:
        if is_weapon_subresource(s):
            migrate_weapon(s, strip=strip)
            changed = True
        elif is_unit_resource(s):
            migrate_unit(s, strip=strip)
            changed = True
    if changed:
        write_tres(path, preamble, sections)
    return changed


# -----------------------------------------------------------------------------
# Main.
# -----------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true",
                        help="Print intended targets, change no files.")
    parser.add_argument("--strip", action="store_true",
                        help="Remove legacy tier/override fields. Run only "
                             "after Task 13 of the refactor plan.")
    parser.add_argument("--root", default=".",
                        help="Project root (must contain resources/).")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    units_dir = root / "resources" / "units"
    bldgs_dir = root / "resources" / "buildings"

    if not units_dir.is_dir():
        print(f"error: {units_dir} not found", file=sys.stderr)
        return 1
    if not bldgs_dir.is_dir():
        print(f"error: {bldgs_dir} not found", file=sys.stderr)
        return 1

    if args.dry_run:
        print(f"[dry-run] would migrate units in {units_dir}")
        print(f"[dry-run] would migrate buildings in {bldgs_dir}")
        u = sum(1 for _ in units_dir.glob("*.tres"))
        b = sum(1 for p in bldgs_dir.glob("*.tres") if p.name in BUILDING_WEAPONS)
        print(f"[dry-run] {u} unit .tres files, {b} building .tres files in scope")
        return 0

    unit_changed = 0
    for path in sorted(units_dir.glob("*.tres")):
        if migrate_unit_file(path, strip=args.strip):
            unit_changed += 1
    print(f"migrated {unit_changed} unit .tres files")

    bldg_changed = 0
    for path in sorted(bldgs_dir.glob("*.tres")):
        if migrate_building(path, strip=args.strip):
            bldg_changed += 1
    print(f"migrated {bldg_changed} building .tres files")

    return 0


if __name__ == "__main__":
    sys.exit(main())

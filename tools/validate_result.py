#!/usr/bin/env python3
"""Validate a scanner result.json against a JSON Schema (run-matrix --schema).

Uses the `jsonschema` package when it's importable (Fedora: python3-jsonschema).
Otherwise falls back to a small built-in validator covering the subset the
bundled schemas use: type (incl. type lists), required, properties, items,
enum, pattern, minimum, additionalProperties (boolean). The fallback says so
on stderr, so a report never silently claims full Draft 2020-12 validation.

Usage: validate_result.py SCHEMA RESULT_JSON
Exit: 0 valid, 1 invalid (one error per line on stdout), 2 usage/IO error.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

_TYPES = {
    "object": dict, "array": list, "string": str, "boolean": bool,
    "null": type(None), "number": (int, float), "integer": int,
}


def _is_type(value: Any, name: str) -> bool:
    if name in ("integer", "number") and isinstance(value, bool):
        return False
    return isinstance(value, _TYPES[name])


def subset_validate(schema: dict, value: Any, path: str = "$") -> list[str]:
    errors: list[str] = []
    t = schema.get("type")
    if t is not None:
        names = t if isinstance(t, list) else [t]
        if not any(_is_type(value, n) for n in names):
            return [f"{path}: expected {'|'.join(names)}, got {type(value).__name__}"]
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} not in {schema['enum']}")
    if isinstance(value, str) and "pattern" in schema and not re.search(schema["pattern"], value):
        errors.append(f"{path}: {value!r} doesn't match {schema['pattern']}")
    if _is_type(value, "number") and "minimum" in schema and value < schema["minimum"]:
        errors.append(f"{path}: {value} < minimum {schema['minimum']}")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required key {key!r}")
        props = schema.get("properties", {})
        for key, sub in props.items():
            if key in value:
                errors.extend(subset_validate(sub, value[key], f"{path}.{key}"))
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    errors.append(f"{path}: unexpected key {key!r}")
    if isinstance(value, list) and isinstance(schema.get("items"), dict):
        for i, item in enumerate(value):
            errors.extend(subset_validate(schema["items"], item, f"{path}[{i}]"))
    return errors


def validate(schema: dict, doc: Any) -> list[str]:
    try:
        import jsonschema  # type: ignore[import-untyped]
    except ImportError:
        print("validate_result: jsonschema not installed; using the built-in subset validator",
              file=sys.stderr)
        return subset_validate(schema, doc)
    validator = jsonschema.validators.validator_for(schema)(schema)
    return [
        f"$.{'.'.join(str(p) for p in e.absolute_path)}: {e.message}" if e.absolute_path
        else f"$: {e.message}"
        for e in sorted(validator.iter_errors(doc), key=lambda e: list(map(str, e.absolute_path)))
    ]


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-3], file=sys.stderr)
        return 2
    try:
        schema = json.loads(Path(argv[1]).read_text())
        doc = json.loads(Path(argv[2]).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"validate_result: {exc}", file=sys.stderr)
        return 2
    errors = validate(schema, doc)
    for e in errors:
        print(e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

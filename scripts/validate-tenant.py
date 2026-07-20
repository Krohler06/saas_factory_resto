#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path
from typing import Any

import yaml
from jsonschema import Draft202012Validator, FormatChecker

DAYS = [
    "monday", "tuesday", "wednesday", "thursday",
    "friday", "saturday", "sunday",
]


class TenantValidationError(Exception):
    pass


def load_yaml(path: Path) -> dict[str, Any]:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise TenantValidationError(f"lecture impossible de {path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise TenantValidationError(f"YAML invalide dans {path}: {exc}") from exc

    if not isinstance(data, dict):
        raise TenantValidationError("la racine du YAML doit être un objet")
    return data


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise TenantValidationError(f"lecture impossible de {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise TenantValidationError(f"JSON Schema invalide: {exc}") from exc

    if not isinstance(data, dict):
        raise TenantValidationError("le JSON Schema doit être un objet")
    return data


def error_path(error: Any) -> str:
    return ".".join(str(part) for part in error.absolute_path) or "<racine>"


def parse_time(value: str, field: str) -> dt.time:
    try:
        return dt.time.fromisoformat(value)
    except ValueError as exc:
        raise TenantValidationError(f"{field}: heure invalide {value!r}") from exc


def parse_datetime(value: str, field: str) -> dt.datetime:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = dt.datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise TenantValidationError(f"{field}: date ISO invalide {value!r}") from exc
    if parsed.tzinfo is None:
        raise TenantValidationError(f"{field}: le fuseau horaire est obligatoire")
    return parsed


def duplicates(values: list[str]) -> list[str]:
    seen: set[str] = set()
    dup: set[str] = set()
    for value in values:
        if value in seen:
            dup.add(value)
        seen.add(value)
    return sorted(dup)


def custom_validation(config: dict[str, Any]) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []

    services = config.get("service_definitions", [])
    service_slugs = [str(item.get("slug", "")) for item in services]
    for value in duplicates(service_slugs):
        errors.append(f"service_definitions: slug dupliqué {value!r}")
    known_services = set(service_slugs)

    open_service_count = 0
    schedule = config.get("weekly_schedule", {})
    for day in DAYS:
        day_cfg = schedule.get(day, {})
        day_enabled = bool(day_cfg.get("enabled", False))
        day_services = day_cfg.get("services", {}) or {}
        if not isinstance(day_services, dict):
            continue

        for service_slug, hours in day_services.items():
            if service_slug not in known_services:
                errors.append(f"weekly_schedule.{day}: service inconnu {service_slug!r}")
                continue
            if not isinstance(hours, dict) or not bool(hours.get("enabled", False)):
                continue
            if not day_enabled:
                errors.append(
                    f"weekly_schedule.{day}.{service_slug}: service actif sur un jour désactivé"
                )
                continue

            open_service_count += 1
            try:
                opens = parse_time(hours["opens_at"], f"{day}.{service_slug}.opens_at")
                first = parse_time(hours["first_booking_at"], f"{day}.{service_slug}.first_booking_at")
                last = parse_time(hours["last_booking_at"], f"{day}.{service_slug}.last_booking_at")
                closes = parse_time(hours["closes_at"], f"{day}.{service_slug}.closes_at")
            except (KeyError, TenantValidationError) as exc:
                errors.append(str(exc))
                continue

            if not (opens <= first <= last):
                errors.append(
                    f"{day}.{service_slug}: ordre invalide opens_at <= first_booking_at <= last_booking_at"
                )
            closes_next_day = closes <= opens
            if not closes_next_day and last > closes:
                errors.append(
                    f"{day}.{service_slug}: last_booking_at est après closes_at"
                )

    if open_service_count == 0:
        errors.append("weekly_schedule: aucun service ouvert")

    areas = config.get("areas", [])
    area_slugs = [str(item.get("slug", "")) for item in areas]
    for value in duplicates(area_slugs):
        errors.append(f"areas: slug dupliqué {value!r}")
    known_areas = set(area_slugs)

    alias_owner: dict[str, str] = {}
    total_active_capacity = 0
    max_active_area_capacity = 0
    area_capacity: dict[str, int] = {}
    for area in areas:
        slug = str(area.get("slug", ""))
        capacity = int(area.get("capacity", 0) or 0)
        area_capacity[slug] = capacity
        if bool(area.get("enabled", False)):
            total_active_capacity += capacity
            max_active_area_capacity = max(max_active_area_capacity, capacity)
            if capacity <= 0:
                errors.append(f"areas.{slug}: une zone active doit avoir une capacité positive")
        for alias in area.get("aliases", []) or []:
            normalized = str(alias).strip().casefold()
            if not normalized:
                errors.append(f"areas.{slug}: alias vide")
                continue
            previous = alias_owner.get(normalized)
            if previous and previous != slug:
                errors.append(
                    f"areas: alias {alias!r} utilisé par {previous!r} et {slug!r}"
                )
            alias_owner[normalized] = slug

    engine = config.get("booking_engine", {})
    allocation_mode = engine.get("allocation_mode")
    if allocation_mode in {"area_capacity", "table_assignment"} and not areas:
        errors.append(f"booking_engine.{allocation_mode}: au moins une zone est requise")
    if allocation_mode in {"area_capacity", "table_assignment"} and total_active_capacity <= 0:
        errors.append("areas: la capacité active totale doit être positive")

    max_party_size = int(engine.get("max_party_size", 0) or 0)
    if allocation_mode == "area_capacity" and max_party_size > max_active_area_capacity:
        warnings.append(
            "max_party_size dépasse la capacité de la plus grande zone; une réservation unique pourrait être impossible"
        )

    tables = config.get("tables", [])
    table_codes = [str(item.get("code", "")) for item in tables]
    for value in duplicates(table_codes):
        errors.append(f"tables: code dupliqué {value!r}")

    for table in tables:
        code = str(table.get("code", ""))
        area = str(table.get("area", ""))
        if area not in known_areas:
            errors.append(f"tables.{code}: zone inconnue {area!r}")
        minimum = int(table.get("min_capacity", 0) or 0)
        maximum = int(table.get("max_capacity", 0) or 0)
        if maximum < minimum:
            errors.append(f"tables.{code}: max_capacity doit être >= min_capacity")
        if area in area_capacity and maximum > area_capacity[area]:
            errors.append(
                f"tables.{code}: max_capacity dépasse la capacité de la zone {area!r}"
            )
        if bool(table.get("is_combinable", False)) and not str(
            table.get("combination_group") or ""
        ).strip():
            errors.append(
                f"tables.{code}: combination_group requis pour une table combinable"
            )

    if allocation_mode == "table_assignment" and not tables:
        errors.append("booking_engine.table_assignment: au moins une table est requise")

    allow_combined = bool(engine.get("allow_table_combinations", False))
    if allow_combined and not any(bool(t.get("is_combinable", False)) for t in tables):
        warnings.append(
            "allow_table_combinations est activé mais aucune table n'est combinable"
        )

    closure_slugs: list[str] = []
    for index, closure in enumerate(config.get("recurring_closures", [])):
        slug = str(closure.get("slug", ""))
        closure_slugs.append(slug)
        try:
            dt.date(2028, int(closure["month"]), int(closure["day"]))
        except (KeyError, TypeError, ValueError):
            errors.append(f"recurring_closures[{index}]: date annuelle invalide")
        services_ref = closure.get("services", []) or []
        areas_ref = closure.get("areas", []) or []
        for service in services_ref:
            if service not in known_services:
                errors.append(
                    f"recurring_closures.{slug}: service inconnu {service!r}"
                )
        for area in areas_ref:
            if area not in known_areas:
                errors.append(f"recurring_closures.{slug}: zone inconnue {area!r}")
        if not bool(closure.get("all_day", False)) and not services_ref and not areas_ref:
            errors.append(
                f"recurring_closures.{slug}: une fermeture partielle doit cibler au moins un service ou une zone"
            )

    for index, closure in enumerate(config.get("exceptional_closures", [])):
        slug = str(closure.get("slug", ""))
        closure_slugs.append(slug)
        try:
            starts = parse_datetime(
                str(closure.get("starts_at", "")),
                f"exceptional_closures[{index}].starts_at",
            )
            ends = parse_datetime(
                str(closure.get("ends_at", "")),
                f"exceptional_closures[{index}].ends_at",
            )
            if ends <= starts:
                errors.append(f"exceptional_closures.{slug}: ends_at doit être après starts_at")
        except TenantValidationError as exc:
            errors.append(str(exc))
        for service in closure.get("services", []) or []:
            if service not in known_services:
                errors.append(f"exceptional_closures.{slug}: service inconnu {service!r}")
        for area in closure.get("areas", []) or []:
            if area not in known_areas:
                errors.append(f"exceptional_closures.{slug}: zone inconnue {area!r}")

    for value in duplicates(closure_slugs):
        errors.append(f"closures: slug dupliqué {value!r}")

    return errors, warnings


def main() -> int:
    parser = argparse.ArgumentParser(description="Valide un tenant.yml")
    parser.add_argument("tenant_file", type=Path)
    parser.add_argument(
        "--schema",
        type=Path,
        default=Path("/root/saas_factory/schemas/tenant.schema.json"),
    )
    parser.add_argument("--json", action="store_true", dest="json_output")
    args = parser.parse_args()

    try:
        config = load_yaml(args.tenant_file)
        schema = load_json(args.schema)
    except TenantValidationError as exc:
        print(f"[ERREUR] {exc}", file=sys.stderr)
        return 1

    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    schema_errors = sorted(validator.iter_errors(config), key=lambda e: list(e.absolute_path))
    errors = [f"{error_path(error)}: {error.message}" for error in schema_errors]
    custom_errors, warnings = custom_validation(config)
    errors.extend(custom_errors)

    if args.json_output:
        print(json.dumps({"valid": not errors, "errors": errors, "warnings": warnings}, ensure_ascii=False, indent=2))
    else:
        for warning in warnings:
            print(f"[AVERTISSEMENT] {warning}")
        if errors:
            for error in errors:
                print(f"[ERREUR] {error}", file=sys.stderr)
        else:
            print(f"[OK] Configuration valide : {args.tenant_file}")
            print(f"[OK] Services ouverts : {sum(1 for day in DAYS for h in (config['weekly_schedule'][day].get('services') or {}).values() if config['weekly_schedule'][day].get('enabled') and h.get('enabled'))}")
            print(f"[OK] Zones : {len(config.get('areas', []))}")
            print(f"[OK] Tables : {len(config.get('tables', []))}")

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())


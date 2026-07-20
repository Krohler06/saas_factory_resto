#!/usr/bin/env python3

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from pathlib import Path
from typing import Any

import yaml


WEEKDAYS = {
    "monday": 1,
    "tuesday": 2,
    "wednesday": 3,
    "thursday": 4,
    "friday": 5,
    "saturday": 6,
    "sunday": 7,
}

ALLOCATION_MODES = {
    "global_capacity",
    "area_capacity",
    "table_assignment",
}

SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]*$")


class ValidationError(Exception):
    pass


def sql_text(value: Any) -> str:
    if value is None:
        return "NULL"

    escaped = str(value).replace("'", "''")
    return f"'{escaped}'"


def sql_bool(value: Any) -> str:
    return "TRUE" if bool(value) else "FALSE"


def sql_int(value: Any, field: str) -> str:
    try:
        return str(int(value))
    except (TypeError, ValueError) as exc:
        raise ValidationError(
            f"{field} doit être un entier : {value!r}"
        ) from exc


def require_mapping(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValidationError(f"{field} doit être un objet YAML.")

    return value


def require_list(value: Any, field: str) -> list[Any]:
    if not isinstance(value, list):
        raise ValidationError(f"{field} doit être une liste YAML.")

    return value


def require_slug(value: Any, field: str) -> str:
    slug = str(value or "").strip()

    if not slug or slug == "CHANGE_ME":
        raise ValidationError(
            f"{field} doit contenir le slug réel du restaurant."
        )

    if not SLUG_PATTERN.fullmatch(slug):
        raise ValidationError(
            f"{field} invalide : {slug!r}. "
            "Utiliser uniquement a-z, 0-9, _ ou -."
        )

    return slug


def require_time(value: Any, field: str) -> dt.time:
    text = str(value or "").strip()

    try:
        return dt.time.fromisoformat(text)
    except ValueError as exc:
        raise ValidationError(
            f"{field} doit être au format HH:MM : {text!r}"
        ) from exc


def validate_config(config: dict[str, Any]) -> dict[str, Any]:
    if config.get("version") != 1:
        raise ValidationError("version doit être égale à 1.")

    tenant = require_mapping(config.get("tenant"), "tenant")
    restaurant_slug = require_slug(
        tenant.get("restaurant_slug"),
        "tenant.restaurant_slug",
    )

    restaurant = require_mapping(
        config.get("restaurant"),
        "restaurant",
    )

    timezone = str(restaurant.get("timezone") or "").strip()

    if not timezone:
        raise ValidationError("restaurant.timezone est obligatoire.")

    engine = require_mapping(
        config.get("booking_engine"),
        "booking_engine",
    )

    allocation_mode = str(
        engine.get("allocation_mode") or ""
    ).strip()

    if allocation_mode not in ALLOCATION_MODES:
        raise ValidationError(
            "booking_engine.allocation_mode doit être l'un de : "
            + ", ".join(sorted(ALLOCATION_MODES))
        )

    max_party_size = int(engine.get("max_party_size", 12))

    if max_party_size < 1:
        raise ValidationError(
            "booking_engine.max_party_size doit être supérieur à zéro."
        )

    services = require_list(
        config.get("service_definitions"),
        "service_definitions",
    )

    if not services:
        raise ValidationError(
            "Au moins un service doit être défini."
        )

    service_slugs: set[str] = set()

    for index, service in enumerate(services):
        service = require_mapping(
            service,
            f"service_definitions[{index}]",
        )

        slug = require_slug(
            service.get("slug"),
            f"service_definitions[{index}].slug",
        )

        if slug in service_slugs:
            raise ValidationError(
                f"Service dupliqué : {slug}"
            )

        service_slugs.add(slug)

        duration = int(
            service.get("default_duration_minutes", 120)
        )

        interval = int(
            service.get("slot_interval_minutes", 15)
        )

        if duration <= 0:
            raise ValidationError(
                f"Durée invalide pour le service {slug}."
            )

        if interval < 5 or interval > 240:
            raise ValidationError(
                f"Intervalle invalide pour le service {slug}."
            )

    schedule = require_mapping(
        config.get("weekly_schedule"),
        "weekly_schedule",
    )

    unknown_days = set(schedule) - set(WEEKDAYS)

    if unknown_days:
        raise ValidationError(
            "Jours hebdomadaires inconnus : "
            + ", ".join(sorted(unknown_days))
        )

    open_service_count = 0

    for day_name, weekday in WEEKDAYS.items():
        day = require_mapping(
            schedule.get(
                day_name,
                {"enabled": False, "services": {}},
            ),
            f"weekly_schedule.{day_name}",
        )

        day_enabled = bool(day.get("enabled", False))

        day_services = require_mapping(
            day.get("services", {}),
            f"weekly_schedule.{day_name}.services",
        )

        for service_slug, hours in day_services.items():
            if service_slug not in service_slugs:
                raise ValidationError(
                    f"Service inconnu {service_slug!r} pour {day_name}."
                )

            hours = require_mapping(
                hours,
                (
                    f"weekly_schedule.{day_name}"
                    f".services.{service_slug}"
                ),
            )

            enabled = day_enabled and bool(
                hours.get("enabled", False)
            )

            if not enabled:
                continue

            open_service_count += 1

            opens_at = require_time(
                hours.get("opens_at"),
                f"{day_name}.{service_slug}.opens_at",
            )

            first_booking = require_time(
                hours.get("first_booking_at"),
                f"{day_name}.{service_slug}.first_booking_at",
            )

            last_booking = require_time(
                hours.get("last_booking_at"),
                f"{day_name}.{service_slug}.last_booking_at",
            )

            closes_at = require_time(
                hours.get("closes_at"),
                f"{day_name}.{service_slug}.closes_at",
            )

            if not (
                opens_at <= first_booking <= last_booking
            ):
                raise ValidationError(
                    f"Ordre horaire invalide pour "
                    f"{day_name}/{service_slug}."
                )

            closes_next_day = closes_at <= opens_at

            if not closes_next_day and last_booking > closes_at:
                raise ValidationError(
                    f"Dernière réservation après fermeture pour "
                    f"{day_name}/{service_slug}."
                )

    if open_service_count == 0:
        raise ValidationError(
            "Aucun service ouvert n'est configuré."
        )

    areas = require_list(config.get("areas", []), "areas")

    if allocation_mode in {
        "area_capacity",
        "table_assignment",
    } and not areas:
        raise ValidationError(
            "Le mode choisi exige au moins une zone."
        )

    area_slugs: set[str] = set()
    alias_values: set[str] = set()

    for index, area in enumerate(areas):
        area = require_mapping(area, f"areas[{index}]")

        slug = require_slug(
            area.get("slug"),
            f"areas[{index}].slug",
        )

        if slug in area_slugs:
            raise ValidationError(f"Zone dupliquée : {slug}")

        area_slugs.add(slug)

        capacity = int(area.get("capacity", 0))

        if capacity < 0:
            raise ValidationError(
                f"Capacité négative pour la zone {slug}."
            )

        aliases = require_list(
            area.get("aliases", []),
            f"areas[{index}].aliases",
        )

        for alias in aliases:
            normalized = str(alias).strip().casefold()

            if not normalized:
                raise ValidationError(
                    f"Alias vide dans la zone {slug}."
                )

            if normalized in alias_values:
                raise ValidationError(
                    f"Alias utilisé plusieurs fois : {alias!r}"
                )

            alias_values.add(normalized)

    tables = require_list(config.get("tables", []), "tables")
    table_codes: set[str] = set()

    for index, table in enumerate(tables):
        table = require_mapping(table, f"tables[{index}]")

        code = str(table.get("code") or "").strip()
        area_slug = str(table.get("area") or "").strip()

        if not code:
            raise ValidationError(
                f"tables[{index}].code est obligatoire."
            )

        if code in table_codes:
            raise ValidationError(
                f"Code de table dupliqué : {code}"
            )

        table_codes.add(code)

        if area_slug not in area_slugs:
            raise ValidationError(
                f"Zone inconnue pour la table {code}: {area_slug}"
            )

        minimum = int(table.get("min_capacity", 1))
        maximum = int(table.get("max_capacity", 0))

        if minimum < 1 or maximum < minimum:
            raise ValidationError(
                f"Capacité invalide pour la table {code}."
            )

        combinable = bool(table.get("is_combinable", False))
        group = str(table.get("combination_group") or "").strip()

        if combinable and not group:
            raise ValidationError(
                f"La table {code} est combinable mais n'a "
                "pas de combination_group."
            )

    if allocation_mode == "table_assignment" and not tables:
        raise ValidationError(
            "Le mode table_assignment exige des tables."
        )

    return {
        "restaurant_slug": restaurant_slug,
        "timezone": timezone,
        "allocation_mode": allocation_mode,
        "service_slugs": service_slugs,
        "area_slugs": area_slugs,
    }


def service_id_sql(restaurant_slug: str, service_slug: str) -> str:
    return (
        "(SELECT sd.id "
        "FROM restaurant_service_definitions sd "
        "JOIN restaurants r ON r.id = sd.restaurant_id "
        f"WHERE r.slug = {sql_text(restaurant_slug)} "
        f"AND sd.slug = {sql_text(service_slug)} "
        "LIMIT 1)"
    )


def area_id_sql(restaurant_slug: str, area_slug: str) -> str:
    return (
        "(SELECT a.id "
        "FROM restaurant_areas a "
        "JOIN restaurants r ON r.id = a.restaurant_id "
        f"WHERE r.slug = {sql_text(restaurant_slug)} "
        f"AND a.slug = {sql_text(area_slug)} "
        "LIMIT 1)"
    )


def generate_sql(config: dict[str, Any]) -> str:
    validated = validate_config(config)

    tenant = config["tenant"]
    restaurant = config["restaurant"]
    engine = config["booking_engine"]

    restaurant_slug = validated["restaurant_slug"]
    timezone = validated["timezone"]
    allocation_mode = validated["allocation_mode"]

    lines: list[str] = []

    lines.extend([
        "-- Généré automatiquement depuis tenant.yml",
        "-- Ne pas modifier ce fichier à la main.",
        "",
        "BEGIN;",
        "",
        "DO $seed$",
        "BEGIN",
        "    IF NOT EXISTS (",
        "        SELECT 1",
        "        FROM restaurants",
        f"        WHERE slug = {sql_text(restaurant_slug)}",
        "    ) THEN",
        "        RAISE EXCEPTION "
        f"'Restaurant introuvable : {restaurant_slug}';",
        "    END IF;",
        "END",
        "$seed$;",
        "",
        "UPDATE restaurants",
        f"SET timezone = {sql_text(timezone)},",
        f"    is_active = {sql_bool(restaurant.get('active', True))},",
        "    updated_at = NOW()",
        f"WHERE slug = {sql_text(restaurant_slug)};",
        "",
    ])

    max_party = int(engine.get("max_party_size", 12))
    cleaning = int(
        engine.get("default_cleaning_buffer_minutes", 15)
    )
    allow_combinations = bool(
        engine.get("allow_table_combinations", False)
    )
    minimum_advance = int(
        engine.get("minimum_advance_minutes", 60)
    )
    maximum_days = int(
        engine.get("maximum_advance_days", 90)
    )
    slot_interval = int(
        engine.get("default_slot_interval_minutes", 15)
    )
    maximum_combined = int(
        engine.get("maximum_combined_tables", 1)
    )

    lines.extend([
        "UPDATE restaurant_settings s",
        f"SET max_party_size = {max_party},",
        f"    cleaning_buffer_minutes = {cleaning},",
        f"    allow_combined_tables = {sql_bool(allow_combinations)},",
        "    booking_policy = "
        "COALESCE(s.booking_policy, '{}'::jsonb) || "
        "jsonb_build_object(",
        f"        'allocation_mode', {sql_text(allocation_mode)},",
        f"        'minimum_advance_minutes', {minimum_advance},",
        f"        'maximum_advance_days', {maximum_days},",
        f"        'slot_interval_minutes', {slot_interval},",
        f"        'maximum_combined_tables', {maximum_combined}",
        "    ),",
        "    updated_at = NOW()",
        "FROM restaurants r",
        "WHERE r.id = s.restaurant_id",
        f"  AND r.slug = {sql_text(restaurant_slug)};",
        "",
    ])

    service_slugs = [
        str(service["slug"])
        for service in config["service_definitions"]
    ]

    for service in config["service_definitions"]:
        slug = str(service["slug"])
        name = str(service.get("name") or slug)
        duration = int(
            service.get("default_duration_minutes", 120)
        )
        interval = int(
            service.get("slot_interval_minutes", 15)
        )
        priority = int(service.get("priority", 100))
        active = bool(service.get("enabled", True))

        lines.extend([
            "INSERT INTO restaurant_service_definitions (",
            "    restaurant_id,",
            "    slug,",
            "    name,",
            "    default_duration_minutes,",
            "    slot_interval_minutes,",
            "    priority,",
            "    is_active,",
            "    created_at,",
            "    updated_at",
            ")",
            "SELECT",
            "    r.id,",
            f"    {sql_text(slug)},",
            f"    {sql_text(name)},",
            f"    {duration},",
            f"    {interval},",
            f"    {priority},",
            f"    {sql_bool(active)},",
            "    NOW(),",
            "    NOW()",
            "FROM restaurants r",
            f"WHERE r.slug = {sql_text(restaurant_slug)}",
            "ON CONFLICT (restaurant_id, slug)",
            "DO UPDATE SET",
            "    name = EXCLUDED.name,",
            "    default_duration_minutes = "
            "EXCLUDED.default_duration_minutes,",
            "    slot_interval_minutes = "
            "EXCLUDED.slot_interval_minutes,",
            "    priority = EXCLUDED.priority,",
            "    is_active = EXCLUDED.is_active,",
            "    updated_at = NOW();",
            "",
        ])

    active_service_list = ", ".join(
        sql_text(slug) for slug in service_slugs
    )

    lines.extend([
        "UPDATE restaurant_service_definitions sd",
        "SET is_active = FALSE,",
        "    updated_at = NOW()",
        "FROM restaurants r",
        "WHERE r.id = sd.restaurant_id",
        f"  AND r.slug = {sql_text(restaurant_slug)}",
        f"  AND sd.slug NOT IN ({active_service_list});",
        "",
        "DELETE FROM restaurant_service_hours sh",
        "USING restaurants r",
        "WHERE r.id = sh.restaurant_id",
        f"  AND r.slug = {sql_text(restaurant_slug)};",
        "",
    ])

    schedule = config["weekly_schedule"]

    for day_name, weekday in WEEKDAYS.items():
        day = schedule.get(
            day_name,
            {"enabled": False, "services": {}},
        )

        if not day.get("enabled", False):
            continue

        for service_slug, hours in day.get(
            "services",
            {},
        ).items():
            if not hours.get("enabled", False):
                continue

            opens = str(hours["opens_at"])
            first = str(hours["first_booking_at"])
            last = str(hours["last_booking_at"])
            closes = str(hours["closes_at"])

            opens_time = dt.time.fromisoformat(opens)
            closes_time = dt.time.fromisoformat(closes)
            closes_next_day = closes_time <= opens_time

            capacity_override = hours.get("capacity_override")
            capacity_sql = (
                "NULL"
                if capacity_override is None
                else str(int(capacity_override))
            )

            lines.extend([
                "INSERT INTO restaurant_service_hours (",
                "    restaurant_id,",
                "    service_id,",
                "    weekday,",
                "    opens_at,",
                "    first_booking_at,",
                "    last_booking_at,",
                "    closes_at,",
                "    closes_next_day,",
                "    is_open,",
                "    capacity_override,",
                "    created_at,",
                "    updated_at",
                ")",
                "SELECT",
                "    r.id,",
                "    sd.id,",
                f"    {weekday},",
                f"    {sql_text(opens)}::time,",
                f"    {sql_text(first)}::time,",
                f"    {sql_text(last)}::time,",
                f"    {sql_text(closes)}::time,",
                f"    {sql_bool(closes_next_day)},",
                "    TRUE,",
                f"    {capacity_sql},",
                "    NOW(),",
                "    NOW()",
                "FROM restaurants r",
                "JOIN restaurant_service_definitions sd",
                "  ON sd.restaurant_id = r.id",
                f" AND sd.slug = {sql_text(service_slug)}",
                f"WHERE r.slug = {sql_text(restaurant_slug)};",
                "",
            ])

    area_slugs = [
        str(area["slug"])
        for area in config.get("areas", [])
    ]

    for area in config.get("areas", []):
        slug = str(area["slug"])
        name = str(area.get("name") or slug)
        capacity = int(area.get("capacity", 0))
        priority = int(area.get("priority", 100))
        enabled = bool(area.get("enabled", True))
        selectable = bool(
            area.get("customer_selectable", True)
        )
        accessible = bool(area.get("accessible", False))
        floor_label = area.get("floor_label")

        lines.extend([
            "INSERT INTO restaurant_areas (",
            "    restaurant_id,",
            "    slug,",
            "    name,",
            "    capacity,",
            "    priority,",
            "    is_active,",
            "    customer_selectable,",
            "    accessible,",
            "    floor_label,",
            "    created_at,",
            "    updated_at",
            ")",
            "SELECT",
            "    r.id,",
            f"    {sql_text(slug)},",
            f"    {sql_text(name)},",
            f"    {capacity},",
            f"    {priority},",
            f"    {sql_bool(enabled)},",
            f"    {sql_bool(selectable)},",
            f"    {sql_bool(accessible)},",
            f"    {sql_text(floor_label)},",
            "    NOW(),",
            "    NOW()",
            "FROM restaurants r",
            f"WHERE r.slug = {sql_text(restaurant_slug)}",
            "ON CONFLICT (restaurant_id, slug)",
            "DO UPDATE SET",
            "    name = EXCLUDED.name,",
            "    capacity = EXCLUDED.capacity,",
            "    priority = EXCLUDED.priority,",
            "    is_active = EXCLUDED.is_active,",
            "    customer_selectable = "
            "EXCLUDED.customer_selectable,",
            "    accessible = EXCLUDED.accessible,",
            "    floor_label = EXCLUDED.floor_label,",
            "    updated_at = NOW();",
            "",
        ])

    if area_slugs:
        area_list = ", ".join(
            sql_text(slug) for slug in area_slugs
        )

        lines.extend([
            "UPDATE restaurant_areas a",
            "SET is_active = FALSE,",
            "    updated_at = NOW()",
            "FROM restaurants r",
            "WHERE r.id = a.restaurant_id",
            f"  AND r.slug = {sql_text(restaurant_slug)}",
            f"  AND a.slug NOT IN ({area_list});",
            "",
        ])

    lines.extend([
        "DELETE FROM restaurant_area_aliases aa",
        "USING restaurants r",
        "WHERE r.id = aa.restaurant_id",
        f"  AND r.slug = {sql_text(restaurant_slug)};",
        "",
    ])

    for area in config.get("areas", []):
        area_slug = str(area["slug"])

        for alias in area.get("aliases", []):
            lines.extend([
                "INSERT INTO restaurant_area_aliases (",
                "    restaurant_id,",
                "    area_id,",
                "    alias,",
                "    created_at",
                ")",
                "SELECT",
                "    r.id,",
                "    a.id,",
                f"    {sql_text(alias)},",
                "    NOW()",
                "FROM restaurants r",
                "JOIN restaurant_areas a",
                "  ON a.restaurant_id = r.id",
                f" AND a.slug = {sql_text(area_slug)}",
                f"WHERE r.slug = {sql_text(restaurant_slug)};",
                "",
            ])

    tables = config.get("tables", [])

    if tables or allocation_mode == "table_assignment":
        table_codes: list[str] = []

        for table in tables:
            code = str(table["code"])
            table_codes.append(code)

            area_slug = str(table["area"])
            name = table.get("name")
            minimum = int(table.get("min_capacity", 1))
            maximum = int(table["max_capacity"])
            priority = int(table.get("priority", 100))
            active = bool(table.get("enabled", True))
            combinable = bool(
                table.get("is_combinable", False)
            )
            group = table.get("combination_group")

            lines.extend([
                "INSERT INTO restaurant_tables (",
                "    restaurant_id,",
                "    area_id,",
                "    code,",
                "    name,",
                "    min_capacity,",
                "    max_capacity,",
                "    priority,",
                "    is_active,",
                "    is_combinable,",
                "    combination_group,",
                "    created_at,",
                "    updated_at",
                ")",
                "SELECT",
                "    r.id,",
                "    a.id,",
                f"    {sql_text(code)},",
                f"    {sql_text(name)},",
                f"    {minimum},",
                f"    {maximum},",
                f"    {priority},",
                f"    {sql_bool(active)},",
                f"    {sql_bool(combinable)},",
                f"    {sql_text(group)},",
                "    NOW(),",
                "    NOW()",
                "FROM restaurants r",
                "JOIN restaurant_areas a",
                "  ON a.restaurant_id = r.id",
                f" AND a.slug = {sql_text(area_slug)}",
                f"WHERE r.slug = {sql_text(restaurant_slug)}",
                "ON CONFLICT (restaurant_id, code)",
                "DO UPDATE SET",
                "    area_id = EXCLUDED.area_id,",
                "    name = EXCLUDED.name,",
                "    min_capacity = EXCLUDED.min_capacity,",
                "    max_capacity = EXCLUDED.max_capacity,",
                "    priority = EXCLUDED.priority,",
                "    is_active = EXCLUDED.is_active,",
                "    is_combinable = EXCLUDED.is_combinable,",
                "    combination_group = "
                "EXCLUDED.combination_group,",
                "    updated_at = NOW();",
                "",
            ])

        if table_codes:
            table_list = ", ".join(
                sql_text(code) for code in table_codes
            )

            lines.extend([
                "UPDATE restaurant_tables t",
                "SET is_active = FALSE,",
                "    updated_at = NOW()",
                "FROM restaurants r",
                "WHERE r.id = t.restaurant_id",
                f"  AND r.slug = {sql_text(restaurant_slug)}",
                f"  AND t.code NOT IN ({table_list});",
                "",
            ])

    lines.extend([
        "DELETE FROM restaurant_closures c",
        "USING restaurants r",
        "WHERE r.id = c.restaurant_id",
        f"  AND r.slug = {sql_text(restaurant_slug)}",
        "  AND c.source_key LIKE 'tenant-yaml:%';",
        "",
    ])

    current_year = dt.date.today().year
    closure_years = int(
        engine.get("recurring_closure_years", 5)
    )

    for closure in config.get("recurring_closures", []):
        closure_slug = require_slug(
            closure.get("slug"),
            "recurring_closures.slug",
        )
        name = str(closure.get("name") or closure_slug)
        recurrence_type = str(
            closure.get("recurrence_type") or ""
        )

        if recurrence_type != "annual_date":
            raise ValidationError(
                f"Type de récurrence non pris en charge : "
                f"{recurrence_type}"
            )

        month = int(closure["month"])
        day = int(closure["day"])
        services = closure.get("services", [])
        all_day = bool(closure.get("all_day", True))

        for year in range(
            current_year,
            current_year + closure_years,
        ):
            try:
                closure_date = dt.date(year, month, day)
            except ValueError as exc:
                raise ValidationError(
                    f"Date annuelle invalide : "
                    f"{day:02d}/{month:02d}"
                ) from exc

            source_prefix = (
                f"tenant-yaml:{closure_slug}:{year}"
            )

            if services:
                for service_slug in services:
                    if service_slug not in validated["service_slugs"]:
                        raise ValidationError(
                            f"Service de fermeture inconnu : "
                            f"{service_slug}"
                        )

                    source_key = (
                        f"{source_prefix}:{service_slug}"
                    )

                    lines.extend([
                        "INSERT INTO restaurant_closures (",
                        "    restaurant_id,",
                        "    starts_at,",
                        "    ends_at,",
                        "    reason,",
                        "    is_active,",
                        "    closure_type,",
                        "    recurrence_rule,",
                        "    service_id,",
                        "    all_day,",
                        "    source_key,",
                        "    metadata,",
                        "    created_at,",
                        "    updated_at",
                        ")",
                        "SELECT",
                        "    r.id,",
                        "    CASE",
                        "      WHEN sh.id IS NOT NULL THEN",
                        f"        (DATE {sql_text(str(closure_date))}",
                        "         + sh.opens_at)",
                        "         AT TIME ZONE r.timezone",
                        "      ELSE",
                        f"        DATE {sql_text(str(closure_date))}",
                        "         AT TIME ZONE r.timezone",
                        "    END,",
                        "    CASE",
                        "      WHEN sh.id IS NOT NULL THEN",
                        "        (",
                        f"          DATE {sql_text(str(closure_date))}",
                        "          + CASE",
                        "              WHEN sh.closes_next_day",
                        "              THEN INTERVAL '1 day'",
                        "              ELSE INTERVAL '0 day'",
                        "            END",
                        "          + sh.closes_at",
                        "        ) AT TIME ZONE r.timezone",
                        "      ELSE",
                        f"        (DATE {sql_text(str(closure_date))}",
                        "         + INTERVAL '1 day')",
                        "         AT TIME ZONE r.timezone",
                        "    END,",
                        f"    {sql_text(name)},",
                        "    TRUE,",
                        "    'annual_recurring',",
                        f"    {sql_text(f'annual_date:{month:02d}-{day:02d}')},",
                        "    sd.id,",
                        f"    {sql_bool(all_day)},",
                        f"    {sql_text(source_key)},",
                        "    '{}'::jsonb,",
                        "    NOW(),",
                        "    NOW()",
                        "FROM restaurants r",
                        "JOIN restaurant_service_definitions sd",
                        "  ON sd.restaurant_id = r.id",
                        f" AND sd.slug = {sql_text(service_slug)}",
                        "JOIN restaurant_service_hours sh",
                        "  ON sh.restaurant_id = r.id",
                        " AND sh.service_id = sd.id",
                        f" AND sh.weekday = {closure_date.isoweekday()}",
                        " AND sh.is_open = TRUE",
                        f"WHERE r.slug = {sql_text(restaurant_slug)}",
                        "ON CONFLICT DO NOTHING;",
                        "",
                    ])
            else:
                source_key = source_prefix

                lines.extend([
                    "INSERT INTO restaurant_closures (",
                    "    restaurant_id,",
                    "    starts_at,",
                    "    ends_at,",
                    "    reason,",
                    "    is_active,",
                    "    closure_type,",
                    "    recurrence_rule,",
                    "    all_day,",
                    "    source_key,",
                    "    metadata,",
                    "    created_at,",
                    "    updated_at",
                    ")",
                    "SELECT",
                    "    r.id,",
                    f"    ({sql_text(str(closure_date))}::date::timestamp",
                    "      AT TIME ZONE r.timezone),",
                    f"    (({sql_text(str(closure_date))}::date + 1)::timestamp",
                    "      AT TIME ZONE r.timezone),",
                    f"    {sql_text(name)},",
                    "    TRUE,",
                    "    'annual_recurring',",
                    f"    {sql_text(f'annual_date:{month:02d}-{day:02d}')},",
                    f"    {sql_bool(all_day)},",
                    f"    {sql_text(source_key)},",
                    "    '{}'::jsonb,",
                    "    NOW(),",
                    "    NOW()",
                    "FROM restaurants r",
                    f"WHERE r.slug = {sql_text(restaurant_slug)}",
                    "ON CONFLICT DO NOTHING;",
                    "",
                ])

    for closure in config.get("exceptional_closures", []):
        closure_slug = require_slug(
            closure.get("slug"),
            "exceptional_closures.slug",
        )
        name = str(closure.get("name") or closure_slug)
        starts_at = str(closure.get("starts_at") or "")
        ends_at = str(closure.get("ends_at") or "")

        if not starts_at or not ends_at:
            raise ValidationError(
                f"La fermeture exceptionnelle {closure_slug} "
                "doit avoir starts_at et ends_at."
            )

        source_key = f"tenant-yaml:exceptional:{closure_slug}"

        lines.extend([
            "INSERT INTO restaurant_closures (",
            "    restaurant_id,",
            "    starts_at,",
            "    ends_at,",
            "    reason,",
            "    is_active,",
            "    closure_type,",
            "    all_day,",
            "    source_key,",
            "    metadata,",
            "    created_at,",
            "    updated_at",
            ")",
            "SELECT",
            "    r.id,",
            f"    {sql_text(starts_at)}::timestamptz,",
            f"    {sql_text(ends_at)}::timestamptz,",
            f"    {sql_text(name)},",
            "    TRUE,",
            "    'exceptional',",
            f"    {sql_bool(closure.get('all_day', False))},",
            f"    {sql_text(source_key)},",
            "    '{}'::jsonb,",
            "    NOW(),",
            "    NOW()",
            "FROM restaurants r",
            f"WHERE r.slug = {sql_text(restaurant_slug)}",
            "ON CONFLICT DO NOTHING;",
            "",
        ])

    lines.extend([
        "COMMIT;",
        "",
    ])

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Valide un tenant.yml et génère le seed SQL "
            "Booking Engine V2."
        )
    )

    parser.add_argument(
        "tenant_file",
        type=Path,
        help="Chemin du fichier tenant YAML.",
    )

    parser.add_argument(
        "output_file",
        type=Path,
        help="Chemin du fichier SQL généré.",
    )


    args = parser.parse_args()

    if not args.tenant_file.is_file():
        print(
            f"ERREUR: fichier absent : {args.tenant_file}",
            file=sys.stderr,
        )
        return 1

    try:
        with args.tenant_file.open(
            "r",
            encoding="utf-8",
        ) as stream:
            config = yaml.safe_load(stream)

        if not isinstance(config, dict):
            raise ValidationError(
                "La racine du YAML doit être un objet."
            )

        sql = generate_sql(config)

        args.output_file.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        args.output_file.write_text(
            sql,
            encoding="utf-8",
        )

    except (
        OSError,
        yaml.YAMLError,
        ValidationError,
    ) as exc:
        print(f"ERREUR: {exc}", file=sys.stderr)
        return 1

    print("Configuration YAML valide.")
    print(f"Seed SQL généré : {args.output_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

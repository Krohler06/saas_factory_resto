#!/usr/bin/env python3

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

import yaml


class ConfigurationError(Exception):
    pass


def sql_text(value: Any) -> str:
    if value is None:
        return "NULL"

    escaped = str(value).replace("'", "''")
    return f"'{escaped}'"


def sql_bool(value: Any) -> str:
    return "TRUE" if bool(value) else "FALSE"


def require_mapping(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ConfigurationError(
            f"{name} doit être un objet YAML."
        )

    return value


def require_text(value: Any, name: str) -> str:
    text = str(value or "").strip()

    if not text:
        raise ConfigurationError(
            f"{name} est obligatoire."
        )

    return text


def generate(config: dict[str, Any]) -> str:
    tenant = require_mapping(
        config.get("tenant"),
        "tenant",
    )

    restaurant = require_mapping(
        config.get("restaurant"),
        "restaurant",
    )

    booking_engine = require_mapping(
        config.get("booking_engine"),
        "booking_engine",
    )

    client_id = require_text(
        tenant.get("client_id"),
        "tenant.client_id",
    )

    slug = require_text(
        tenant.get("restaurant_slug"),
        "tenant.restaurant_slug",
    )

    name = str(
        tenant.get("restaurant_name")
        or restaurant.get("name")
        or slug.replace("_", " ").replace("-", " ").title()
    ).strip()

    timezone = require_text(
        restaurant.get("timezone"),
        "restaurant.timezone",
    )

    active = bool(restaurant.get("active", True))

    default_duration = int(
        booking_engine.get(
            "default_meal_duration_minutes",
            120,
        )
    )

    cleaning_buffer = int(
        booking_engine.get(
            "default_cleaning_buffer_minutes",
            15,
        )
    )

    grace_delay = int(
        booking_engine.get(
            "grace_delay_minutes",
            15,
        )
    )

    max_party_size = int(
        booking_engine.get(
            "max_party_size",
            12,
        )
    )

    allow_combined_tables = bool(
        booking_engine.get(
            "allow_table_combinations",
            False,
        )
    )

    minimum_advance = int(
        booking_engine.get(
            "minimum_advance_minutes",
            60,
        )
    )

    maximum_advance = int(
        booking_engine.get(
            "maximum_advance_days",
            90,
        )
    )

    allocation_mode = require_text(
        booking_engine.get("allocation_mode"),
        "booking_engine.allocation_mode",
    )

    slot_interval = int(
        booking_engine.get(
            "default_slot_interval_minutes",
            15,
        )
    )

    maximum_combined = int(
        booking_engine.get(
            "maximum_combined_tables",
            1,
        )
    )

    return f"""\
-- Generated tenant bootstrap
-- Client: {client_id}

BEGIN;

INSERT INTO restaurants (
    name,
    slug,
    timezone,
    is_active,
    created_at,
    updated_at
)
SELECT
    {sql_text(name)},
    {sql_text(slug)},
    {sql_text(timezone)},
    {sql_bool(active)},
    NOW(),
    NOW()
WHERE NOT EXISTS (
    SELECT 1
    FROM restaurants
    WHERE slug = {sql_text(slug)}
);

UPDATE restaurants
SET name = {sql_text(name)},
    timezone = {sql_text(timezone)},
    is_active = {sql_bool(active)},
    updated_at = NOW()
WHERE slug = {sql_text(slug)};

INSERT INTO restaurant_settings (
    restaurant_id,
    default_meal_duration_minutes,
    cleaning_buffer_minutes,
    grace_delay_minutes,
    max_party_size,
    reminder_days_before,
    reminder_hour,
    reminder_channel,
    allow_combined_tables,
    booking_policy,
    event_notification_policy,
    created_at,
    updated_at
)
SELECT
    r.id,
    {default_duration},
    {cleaning_buffer},
    {grace_delay},
    {max_party_size},
    1,
    10,
    'email',
    {sql_bool(allow_combined_tables)},
    jsonb_build_object(
        'allocation_mode', {sql_text(allocation_mode)},
        'minimum_advance_minutes', {minimum_advance},
        'maximum_advance_days', {maximum_advance},
        'slot_interval_minutes', {slot_interval},
        'maximum_combined_tables', {maximum_combined}
    ),
    '{{}}'::jsonb,
    NOW(),
    NOW()
FROM restaurants r
WHERE r.slug = {sql_text(slug)}
  AND NOT EXISTS (
      SELECT 1
      FROM restaurant_settings s
      WHERE s.restaurant_id = r.id
  );

UPDATE restaurant_settings s
SET default_meal_duration_minutes = {default_duration},
    cleaning_buffer_minutes = {cleaning_buffer},
    grace_delay_minutes = {grace_delay},
    max_party_size = {max_party_size},
    allow_combined_tables = {sql_bool(allow_combined_tables)},
    booking_policy =
        COALESCE(s.booking_policy, '{{}}'::jsonb)
        || jsonb_build_object(
            'allocation_mode', {sql_text(allocation_mode)},
            'minimum_advance_minutes', {minimum_advance},
            'maximum_advance_days', {maximum_advance},
            'slot_interval_minutes', {slot_interval},
            'maximum_combined_tables', {maximum_combined}
        ),
    updated_at = NOW()
FROM restaurants r
WHERE r.id = s.restaurant_id
  AND r.slug = {sql_text(slug)};

COMMIT;
"""


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Génère le bootstrap SQL initial d'un tenant."
        )
    )

    parser.add_argument(
        "tenant_file",
        type=Path,
    )

    parser.add_argument(
        "output_file",
        type=Path,
    )

    args = parser.parse_args()

    try:
        with args.tenant_file.open(
            "r",
            encoding="utf-8",
        ) as stream:
            config = yaml.safe_load(stream)

        if not isinstance(config, dict):
            raise ConfigurationError(
                "La racine du YAML doit être un objet."
            )

        sql = generate(config)

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
        ConfigurationError,
        TypeError,
        ValueError,
    ) as exc:
        print(f"[ERREUR] {exc}", file=sys.stderr)
        return 1

    print(
        f"[OK] Bootstrap SQL généré : "
        f"{args.output_file}"
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

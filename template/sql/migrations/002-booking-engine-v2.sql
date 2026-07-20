BEGIN;

-------------------------------------------------------------------------------
-- 1. Définitions des services
-------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS restaurant_service_definitions (
    id BIGSERIAL PRIMARY KEY,

    restaurant_id BIGINT NOT NULL
        REFERENCES restaurants(id)
        ON DELETE CASCADE,

    slug TEXT NOT NULL,
    name TEXT NOT NULL,

    default_duration_minutes INTEGER NOT NULL DEFAULT 120,
    slot_interval_minutes INTEGER NOT NULL DEFAULT 15,

    priority INTEGER NOT NULL DEFAULT 100,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_service_definitions_restaurant_slug
        UNIQUE (restaurant_id, slug),

    CONSTRAINT uq_service_definitions_id_restaurant
        UNIQUE (id, restaurant_id),

    CONSTRAINT ck_service_definitions_slug
        CHECK (slug ~ '^[a-z0-9][a-z0-9_-]*$'),

    CONSTRAINT ck_service_definitions_duration
        CHECK (default_duration_minutes > 0),

    CONSTRAINT ck_service_definitions_interval
        CHECK (slot_interval_minutes BETWEEN 5 AND 240)
);

-------------------------------------------------------------------------------
-- 2. Horaires hebdomadaires
--
-- weekday suit ISO-8601 :
--   1 = lundi
--   2 = mardi
--   ...
--   7 = dimanche
-------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS restaurant_service_hours (
    id BIGSERIAL PRIMARY KEY,

    restaurant_id BIGINT NOT NULL,
    service_id BIGINT NOT NULL,

    weekday SMALLINT NOT NULL,

    opens_at TIME WITHOUT TIME ZONE,
    first_booking_at TIME WITHOUT TIME ZONE,
    last_booking_at TIME WITHOUT TIME ZONE,
    closes_at TIME WITHOUT TIME ZONE,

    closes_next_day BOOLEAN NOT NULL DEFAULT FALSE,
    is_open BOOLEAN NOT NULL DEFAULT TRUE,

    capacity_override INTEGER,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_service_hours_service
        FOREIGN KEY (service_id, restaurant_id)
        REFERENCES restaurant_service_definitions(id, restaurant_id)
        ON DELETE CASCADE,

    CONSTRAINT uq_service_hours_restaurant_service_day
        UNIQUE (restaurant_id, service_id, weekday),

    CONSTRAINT ck_service_hours_weekday
        CHECK (weekday BETWEEN 1 AND 7),

    CONSTRAINT ck_service_hours_capacity
        CHECK (
            capacity_override IS NULL
            OR capacity_override >= 0
        ),

    CONSTRAINT ck_service_hours_required_times
        CHECK (
            is_open = FALSE
            OR (
                opens_at IS NOT NULL
                AND first_booking_at IS NOT NULL
                AND last_booking_at IS NOT NULL
                AND closes_at IS NOT NULL
            )
        ),

    CONSTRAINT ck_service_hours_time_order
        CHECK (
            is_open = FALSE
            OR (
                closes_next_day = FALSE
                AND opens_at <= first_booking_at
                AND first_booking_at <= last_booking_at
                AND last_booking_at <= closes_at
            )
            OR (
                closes_next_day = TRUE
                AND opens_at <= first_booking_at
                AND first_booking_at <= last_booking_at
            )
        )
);

-------------------------------------------------------------------------------
-- 3. Zones du restaurant
-------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS restaurant_areas (
    id BIGSERIAL PRIMARY KEY,

    restaurant_id BIGINT NOT NULL
        REFERENCES restaurants(id)
        ON DELETE CASCADE,

    slug TEXT NOT NULL,
    name TEXT NOT NULL,

    capacity INTEGER NOT NULL DEFAULT 0,
    priority INTEGER NOT NULL DEFAULT 100,

    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    customer_selectable BOOLEAN NOT NULL DEFAULT TRUE,
    accessible BOOLEAN NOT NULL DEFAULT FALSE,

    floor_label TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_restaurant_areas_restaurant_slug
        UNIQUE (restaurant_id, slug),

    CONSTRAINT uq_restaurant_areas_id_restaurant
        UNIQUE (id, restaurant_id),

    CONSTRAINT ck_restaurant_areas_slug
        CHECK (slug ~ '^[a-z0-9][a-z0-9_-]*$'),

    CONSTRAINT ck_restaurant_areas_capacity
        CHECK (capacity >= 0)
);

-------------------------------------------------------------------------------
-- 4. Alias conversationnels des zones
-------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS restaurant_area_aliases (
    id BIGSERIAL PRIMARY KEY,

    restaurant_id BIGINT NOT NULL,
    area_id BIGINT NOT NULL,

    alias TEXT NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_area_aliases_area
        FOREIGN KEY (area_id, restaurant_id)
        REFERENCES restaurant_areas(id, restaurant_id)
        ON DELETE CASCADE,

    CONSTRAINT ck_area_aliases_not_empty
        CHECK (BTRIM(alias) <> '')
);

-------------------------------------------------------------------------------
-- 5. Tables physiques
-------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS restaurant_tables (
    id BIGSERIAL PRIMARY KEY,

    restaurant_id BIGINT NOT NULL,
    area_id BIGINT NOT NULL,

    code TEXT NOT NULL,
    name TEXT,

    min_capacity INTEGER NOT NULL DEFAULT 1,
    max_capacity INTEGER NOT NULL,

    priority INTEGER NOT NULL DEFAULT 100,

    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    is_combinable BOOLEAN NOT NULL DEFAULT FALSE,
    combination_group TEXT,

    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_restaurant_tables_area
        FOREIGN KEY (area_id, restaurant_id)
        REFERENCES restaurant_areas(id, restaurant_id)
        ON DELETE CASCADE,

    CONSTRAINT uq_restaurant_tables_restaurant_code
        UNIQUE (restaurant_id, code),

    CONSTRAINT ck_restaurant_tables_capacity
        CHECK (
            min_capacity > 0
            AND max_capacity >= min_capacity
        ),

    CONSTRAINT ck_restaurant_tables_combination
        CHECK (
            is_combinable = FALSE
            OR NULLIF(BTRIM(combination_group), '') IS NOT NULL
        )
);

-------------------------------------------------------------------------------
-- 6. Association réservation <-> tables
-------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS reservation_tables (
    reservation_id BIGINT NOT NULL
        REFERENCES reservations(id)
        ON DELETE CASCADE,

    table_id BIGINT NOT NULL
        REFERENCES restaurant_tables(id)
        ON DELETE RESTRICT,

    seats_allocated INTEGER,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (reservation_id, table_id),

    CONSTRAINT ck_reservation_tables_seats
        CHECK (
            seats_allocated IS NULL
            OR seats_allocated > 0
        )
);

-------------------------------------------------------------------------------
-- 7. Enrichissement des réservations
-------------------------------------------------------------------------------

ALTER TABLE reservations
    ADD COLUMN IF NOT EXISTS service_id BIGINT;

ALTER TABLE reservations
    ADD COLUMN IF NOT EXISTS requested_area_id BIGINT;

DO $migration$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'fk_reservations_service'
          AND conrelid = 'reservations'::regclass
    ) THEN
        ALTER TABLE reservations
            ADD CONSTRAINT fk_reservations_service
            FOREIGN KEY (service_id)
            REFERENCES restaurant_service_definitions(id)
            ON DELETE SET NULL;
    END IF;
END
$migration$;

DO $migration$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'fk_reservations_requested_area'
          AND conrelid = 'reservations'::regclass
    ) THEN
        ALTER TABLE reservations
            ADD CONSTRAINT fk_reservations_requested_area
            FOREIGN KEY (requested_area_id)
            REFERENCES restaurant_areas(id)
            ON DELETE SET NULL;
    END IF;
END
$migration$;

-------------------------------------------------------------------------------
-- 8. Relations existantes area_id et table_id
--
-- Les contraintes ne sont ajoutées que si les données existantes sont valides.
-------------------------------------------------------------------------------

DO $migration$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'fk_reservations_area'
          AND conrelid = 'reservations'::regclass
    ) THEN
        IF NOT EXISTS (
            SELECT 1
            FROM reservations r
            LEFT JOIN restaurant_areas a
                ON a.id = r.area_id
            WHERE r.area_id IS NOT NULL
              AND a.id IS NULL
        ) THEN
            ALTER TABLE reservations
                ADD CONSTRAINT fk_reservations_area
                FOREIGN KEY (area_id)
                REFERENCES restaurant_areas(id)
                ON DELETE SET NULL;
        ELSE
            RAISE NOTICE
                'fk_reservations_area ignorée : des area_id orphelins existent';
        END IF;
    END IF;
END
$migration$;

DO $migration$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'fk_reservations_table'
          AND conrelid = 'reservations'::regclass
    ) THEN
        IF NOT EXISTS (
            SELECT 1
            FROM reservations r
            LEFT JOIN restaurant_tables t
                ON t.id = r.table_id
            WHERE r.table_id IS NOT NULL
              AND t.id IS NULL
        ) THEN
            ALTER TABLE reservations
                ADD CONSTRAINT fk_reservations_table
                FOREIGN KEY (table_id)
                REFERENCES restaurant_tables(id)
                ON DELETE SET NULL;
        ELSE
            RAISE NOTICE
                'fk_reservations_table ignorée : des table_id orphelins existent';
        END IF;
    END IF;
END
$migration$;

-------------------------------------------------------------------------------
-- 9. Fermetures partielles par service ou zone
-------------------------------------------------------------------------------

ALTER TABLE restaurant_closures
    ADD COLUMN IF NOT EXISTS service_id BIGINT;

ALTER TABLE restaurant_closures
    ADD COLUMN IF NOT EXISTS area_id BIGINT;

ALTER TABLE restaurant_closures
    ADD COLUMN IF NOT EXISTS all_day BOOLEAN NOT NULL DEFAULT TRUE;

ALTER TABLE restaurant_closures
    ADD COLUMN IF NOT EXISTS source_key TEXT;

ALTER TABLE restaurant_closures
    ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::jsonb;

DO $migration$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'fk_restaurant_closures_service'
          AND conrelid = 'restaurant_closures'::regclass
    ) THEN
        ALTER TABLE restaurant_closures
            ADD CONSTRAINT fk_restaurant_closures_service
            FOREIGN KEY (service_id)
            REFERENCES restaurant_service_definitions(id)
            ON DELETE SET NULL;
    END IF;
END
$migration$;

DO $migration$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'fk_restaurant_closures_area'
          AND conrelid = 'restaurant_closures'::regclass
    ) THEN
        ALTER TABLE restaurant_closures
            ADD CONSTRAINT fk_restaurant_closures_area
            FOREIGN KEY (area_id)
            REFERENCES restaurant_areas(id)
            ON DELETE SET NULL;
    END IF;
END
$migration$;

-------------------------------------------------------------------------------
-- 10. Index
-------------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_service_definitions_restaurant_active
    ON restaurant_service_definitions (
        restaurant_id,
        is_active,
        priority
    );

CREATE INDEX IF NOT EXISTS idx_service_hours_restaurant_weekday
    ON restaurant_service_hours (
        restaurant_id,
        weekday,
        is_open
    );

CREATE INDEX IF NOT EXISTS idx_service_hours_service
    ON restaurant_service_hours (
        service_id,
        weekday
    );

CREATE INDEX IF NOT EXISTS idx_restaurant_areas_active
    ON restaurant_areas (
        restaurant_id,
        is_active,
        priority
    );

CREATE UNIQUE INDEX IF NOT EXISTS uq_restaurant_area_aliases_normalized
    ON restaurant_area_aliases (
        restaurant_id,
        LOWER(BTRIM(alias))
    );

CREATE INDEX IF NOT EXISTS idx_restaurant_tables_area_active
    ON restaurant_tables (
        restaurant_id,
        area_id,
        is_active,
        priority
    );

CREATE INDEX IF NOT EXISTS idx_restaurant_tables_combination_group
    ON restaurant_tables (
        restaurant_id,
        combination_group
    )
    WHERE is_combinable = TRUE;

CREATE UNIQUE INDEX IF NOT EXISTS uq_reservation_tables_primary
    ON reservation_tables (reservation_id)
    WHERE is_primary = TRUE;

CREATE INDEX IF NOT EXISTS idx_reservation_tables_table
    ON reservation_tables (table_id, reservation_id);

CREATE INDEX IF NOT EXISTS idx_reservations_availability
    ON reservations (
        restaurant_id,
        start_time,
        end_time
    )
    WHERE status NOT IN (
        'cancelled',
        'declined',
        'no_show'
    );

CREATE INDEX IF NOT EXISTS idx_reservations_area_availability
    ON reservations (
        restaurant_id,
        area_id,
        start_time,
        end_time
    )
    WHERE area_id IS NOT NULL
      AND status NOT IN (
          'cancelled',
          'declined',
          'no_show'
      );

CREATE INDEX IF NOT EXISTS idx_restaurant_closures_period
    ON restaurant_closures (
        restaurant_id,
        starts_at,
        ends_at
    )
    WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_restaurant_closures_service
    ON restaurant_closures (
        restaurant_id,
        service_id,
        starts_at,
        ends_at
    )
    WHERE service_id IS NOT NULL
      AND is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_restaurant_closures_area
    ON restaurant_closures (
        restaurant_id,
        area_id,
        starts_at,
        ends_at
    )
    WHERE area_id IS NOT NULL
      AND is_active = TRUE;

CREATE UNIQUE INDEX IF NOT EXISTS uq_restaurant_closures_source_instance
    ON restaurant_closures (
        restaurant_id,
        source_key,
        starts_at
    )
    WHERE source_key IS NOT NULL;

COMMIT;

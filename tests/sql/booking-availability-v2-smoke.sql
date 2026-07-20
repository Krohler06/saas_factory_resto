\set ON_ERROR_STOP on
\pset pager off

-------------------------------------------------------------------------------
-- Recherche automatique du prochain créneau ouvert.
-------------------------------------------------------------------------------

DROP TABLE IF EXISTS booking_test_candidate;

CREATE TEMP TABLE booking_test_candidate AS
WITH restaurant_configuration AS (
    SELECT
        r.id AS restaurant_id,
        r.slug AS restaurant_slug,
        r.timezone,
        s.max_party_size,

        COALESCE(
            NULLIF(
                s.booking_policy ->> 'minimum_advance_minutes',
                ''
            )::INTEGER,
            60
        ) AS minimum_advance_minutes
    FROM restaurants r
    JOIN restaurant_settings s
        ON s.restaurant_id = r.id
    WHERE r.is_active = TRUE
    ORDER BY r.id
    LIMIT 1
),
candidate_slots AS (
    SELECT
        rc.restaurant_slug,
        rc.timezone,
        rc.max_party_size,

        sd.slug AS service_slug,

        (
            candidate_date.booking_date
            + sh.first_booking_at
        ) AT TIME ZONE rc.timezone AS requested_start_time

    FROM restaurant_configuration rc

    JOIN restaurant_service_definitions sd
        ON sd.restaurant_id = rc.restaurant_id
       AND sd.is_active = TRUE

    JOIN restaurant_service_hours sh
        ON sh.restaurant_id = rc.restaurant_id
       AND sh.service_id = sd.id
       AND sh.is_open = TRUE

    CROSS JOIN LATERAL (
        SELECT generated_day::DATE AS booking_date
        FROM GENERATE_SERIES(
            (
                NOW()
                AT TIME ZONE rc.timezone
            )::DATE,

            (
                NOW()
                AT TIME ZONE rc.timezone
            )::DATE + 30,

            INTERVAL '1 day'
        ) generated_day
    ) candidate_date

    WHERE sh.weekday =
        EXTRACT(
            ISODOW
            FROM candidate_date.booking_date
        )::INTEGER

      AND (
          candidate_date.booking_date
          + sh.first_booking_at
      ) AT TIME ZONE rc.timezone
          >
      NOW()
      + MAKE_INTERVAL(
            mins => rc.minimum_advance_minutes
        )
)
SELECT *
FROM candidate_slots
ORDER BY requested_start_time, service_slug
LIMIT 1;

-------------------------------------------------------------------------------
-- Affichage du créneau choisi.
-------------------------------------------------------------------------------

SELECT
    restaurant_slug,
    service_slug,
    requested_start_time,
    timezone,
    max_party_size
FROM booking_test_candidate;

-------------------------------------------------------------------------------
-- Test 1 : réservation normale de deux personnes.
-------------------------------------------------------------------------------

SELECT
    'NORMAL_BOOKING' AS test_name,
    result.*
FROM booking_test_candidate candidate
CROSS JOIN LATERAL public.booking_check_availability_v2(
    candidate.restaurant_slug,
    candidate.service_slug,
    candidate.requested_start_time,
    2,
    NULL
) result;

-------------------------------------------------------------------------------
-- Test 2 : groupe volontairement trop grand.
-------------------------------------------------------------------------------

SELECT
    'PARTY_TOO_LARGE' AS test_name,
    result.*
FROM booking_test_candidate candidate
CROSS JOIN LATERAL public.booking_check_availability_v2(
    candidate.restaurant_slug,
    candidate.service_slug,
    candidate.requested_start_time,
    candidate.max_party_size + 1,
    NULL
) result;

-------------------------------------------------------------------------------
-- Test 3 : service inexistant.
-------------------------------------------------------------------------------

SELECT
    'UNKNOWN_SERVICE' AS test_name,
    result.*
FROM booking_test_candidate candidate
CROSS JOIN LATERAL public.booking_check_availability_v2(
    candidate.restaurant_slug,
    'service_inexistant',
    candidate.requested_start_time,
    2,
    NULL
) result;

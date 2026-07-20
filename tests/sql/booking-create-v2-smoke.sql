\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DROP TABLE IF EXISTS booking_create_test_candidate;

CREATE TEMP TABLE booking_create_test_candidate AS
WITH restaurant_configuration AS (
    SELECT
        r.id AS restaurant_id,
        r.slug AS restaurant_slug,
        r.timezone,

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
),
available_slots AS (
    SELECT
        slots.*,
        availability.available,
        availability.reason_code
    FROM candidate_slots slots
    CROSS JOIN LATERAL public.booking_check_availability_v2(
        slots.restaurant_slug,
        slots.service_slug,
        slots.requested_start_time,
        2,
        NULL
    ) availability
)
SELECT
    restaurant_slug,
    service_slug,
    requested_start_time,
    'factory-test-v2-'
        || TXID_CURRENT()::TEXT AS conversation_id
FROM available_slots
WHERE available = TRUE
ORDER BY requested_start_time, service_slug
LIMIT 1;

DO $test$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM booking_create_test_candidate
    ) THEN
        RAISE EXCEPTION
            'Aucun créneau disponible trouvé pour le test.';
    END IF;
END
$test$;

SELECT
    'TEST_CANDIDATE' AS test_name,
    *
FROM booking_create_test_candidate;

-------------------------------------------------------------------------------
-- Test 1 : première création
-------------------------------------------------------------------------------

CREATE TEMP TABLE booking_create_first_result AS
SELECT result.*
FROM booking_create_test_candidate candidate
CROSS JOIN LATERAL public.booking_create_reservation_v2(
    candidate.restaurant_slug,
    candidate.service_slug,
    candidate.requested_start_time,
    2,
    'Client Test Factory',
    '+33600000001',
    'factory-test@example.invalid',
    'Test automatique Booking Engine V2',
    NULL,
    'factory_test',
    candidate.conversation_id,
    TRUE
) result;

SELECT
    'FIRST_CREATE' AS test_name,
    *
FROM booking_create_first_result;

DO $test$
DECLARE
    v_result RECORD;
BEGIN
    SELECT *
    INTO v_result
    FROM booking_create_first_result;

    IF v_result.created IS NOT TRUE THEN
        RAISE EXCEPTION
            'Création initiale échouée : % - %',
            v_result.reason_code,
            v_result.reason_detail;
    END IF;

    IF v_result.reason_code <> 'RESERVATION_CREATED' THEN
        RAISE EXCEPTION
            'Code inattendu : %',
            v_result.reason_code;
    END IF;
END
$test$;

-------------------------------------------------------------------------------
-- Test 2 : même appel, donc idempotence
-------------------------------------------------------------------------------

CREATE TEMP TABLE booking_create_second_result AS
SELECT result.*
FROM booking_create_test_candidate candidate
CROSS JOIN LATERAL public.booking_create_reservation_v2(
    candidate.restaurant_slug,
    candidate.service_slug,
    candidate.requested_start_time,
    2,
    'Client Test Factory',
    '+33600000001',
    'factory-test@example.invalid',
    'Test automatique Booking Engine V2',
    NULL,
    'factory_test',
    candidate.conversation_id,
    TRUE
) result;

SELECT
    'SECOND_CREATE_IDEMPOTENT' AS test_name,
    *
FROM booking_create_second_result;

DO $test$
DECLARE
    v_result RECORD;
BEGIN
    SELECT *
    INTO v_result
    FROM booking_create_second_result;

    IF v_result.idempotent IS NOT TRUE THEN
        RAISE EXCEPTION
            'Le second appel n''est pas idempotent.';
    END IF;

    IF v_result.reason_code <>
       'RESERVATION_ALREADY_EXISTS'
    THEN
        RAISE EXCEPTION
            'Code idempotent inattendu : %',
            v_result.reason_code;
    END IF;
END
$test$;

-------------------------------------------------------------------------------
-- Test 3 : réservation non confirmée
-------------------------------------------------------------------------------

CREATE TEMP TABLE booking_create_unconfirmed_result AS
SELECT result.*
FROM booking_create_test_candidate candidate
CROSS JOIN LATERAL public.booking_create_reservation_v2(
    candidate.restaurant_slug,
    candidate.service_slug,
    candidate.requested_start_time + INTERVAL '7 days',
    2,
    'Client Non Confirmé',
    '+33600000002',
    NULL,
    NULL,
    NULL,
    'factory_test',
    candidate.conversation_id || '-unconfirmed',
    FALSE
) result;

SELECT
    'UNCONFIRMED' AS test_name,
    *
FROM booking_create_unconfirmed_result;

DO $test$
DECLARE
    v_result RECORD;
BEGIN
    SELECT *
    INTO v_result
    FROM booking_create_unconfirmed_result;

    IF v_result.created IS TRUE THEN
        RAISE EXCEPTION
            'Une réservation non confirmée a été créée.';
    END IF;

    IF v_result.reason_code <>
       'CUSTOMER_NOT_CONFIRMED'
    THEN
        RAISE EXCEPTION
            'Code non confirmé inattendu : %',
            v_result.reason_code;
    END IF;
END
$test$;

-------------------------------------------------------------------------------
-- Une seule réservation doit avoir été créée
-------------------------------------------------------------------------------

DO $test$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_count
    FROM reservations r
    JOIN booking_create_test_candidate candidate
      ON r.conversation_id = candidate.conversation_id
     AND r.start_time = candidate.requested_start_time;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'Nombre de réservations inattendu : %',
            v_count;
    END IF;
END
$test$;

ROLLBACK;

SELECT
    'BOOKING_CREATE_V2_TESTS_OK' AS final_status;

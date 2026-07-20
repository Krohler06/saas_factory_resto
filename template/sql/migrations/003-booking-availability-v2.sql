-------------------------------------------------------------------------------
-- Booking Engine V2
-- Résolution des services, horaires, fermetures et capacités.
--
-- Cette migration ne crée pas encore de réservation.
-- Elle fournit uniquement une fonction de contrôle de disponibilité.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.booking_check_availability_v2(
    p_restaurant_slug TEXT,
    p_service_slug TEXT,
    p_start_time TIMESTAMPTZ,
    p_party_size INTEGER,
    p_requested_area_slug TEXT DEFAULT NULL
)
RETURNS TABLE (
    available BOOLEAN,
    reason_code TEXT,
    reason_detail TEXT,

    restaurant_id BIGINT,
    service_id BIGINT,
    service_slug TEXT,
    allocation_mode TEXT,

    area_id BIGINT,
    area_slug TEXT,

    start_time TIMESTAMPTZ,
    end_time TIMESTAMPTZ,

    duration_minutes INTEGER,
    cleaning_buffer_minutes INTEGER,

    capacity_total INTEGER,
    capacity_used INTEGER,
    capacity_remaining INTEGER
)
LANGUAGE plpgsql
AS $booking_function$
DECLARE
    v_restaurant_id BIGINT;
    v_timezone TEXT;

    v_max_party_size INTEGER;
    v_cleaning_buffer INTEGER;

    v_minimum_advance_minutes INTEGER;
    v_maximum_advance_days INTEGER;
    v_default_slot_interval INTEGER;
    v_allocation_mode TEXT;

    v_service_id BIGINT;
    v_service_slug TEXT;
    v_duration_minutes INTEGER;
    v_slot_interval INTEGER;

    v_start_local TIMESTAMP WITHOUT TIME ZONE;
    v_end_local TIMESTAMP WITHOUT TIME ZONE;
    v_service_date DATE;

    v_first_booking_at TIME WITHOUT TIME ZONE;
    v_last_booking_at TIME WITHOUT TIME ZONE;
    v_closes_at TIME WITHOUT TIME ZONE;
    v_closes_next_day BOOLEAN;
    v_capacity_override INTEGER;

    v_end_time TIMESTAMPTZ;
    v_occupied_end_time TIMESTAMPTZ;

    v_minutes_since_first INTEGER;

    v_requested_area_id BIGINT;
    v_requested_area_slug TEXT;
    v_area_capacity INTEGER;
    v_area_used INTEGER;

    v_global_capacity INTEGER;
    v_global_used INTEGER;

    v_closure_reason TEXT;
BEGIN
    available := FALSE;
    reason_code := NULL;
    reason_detail := NULL;

    restaurant_id := NULL;
    service_id := NULL;
    service_slug := NULL;
    allocation_mode := NULL;

    area_id := NULL;
    area_slug := NULL;

    start_time := p_start_time;
    end_time := NULL;

    duration_minutes := NULL;
    cleaning_buffer_minutes := NULL;

    capacity_total := NULL;
    capacity_used := NULL;
    capacity_remaining := NULL;

    ---------------------------------------------------------------------------
    -- Validation minimale des entrées
    ---------------------------------------------------------------------------

    IF NULLIF(BTRIM(p_restaurant_slug), '') IS NULL THEN
        reason_code := 'RESTAURANT_SLUG_REQUIRED';
        reason_detail := 'Le slug du restaurant est obligatoire.';
        RETURN NEXT;
        RETURN;
    END IF;

    IF NULLIF(BTRIM(p_service_slug), '') IS NULL THEN
        reason_code := 'SERVICE_SLUG_REQUIRED';
        reason_detail := 'Le service demandé est obligatoire.';
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_start_time IS NULL THEN
        reason_code := 'START_TIME_REQUIRED';
        reason_detail := 'La date et l''heure sont obligatoires.';
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_party_size IS NULL OR p_party_size < 1 THEN
        reason_code := 'INVALID_PARTY_SIZE';
        reason_detail := 'Le nombre de personnes doit être supérieur à zéro.';
        RETURN NEXT;
        RETURN;
    END IF;

    ---------------------------------------------------------------------------
    -- Restaurant et règles générales
    ---------------------------------------------------------------------------

    SELECT
        r.id,
        r.timezone,
        s.max_party_size,
        s.cleaning_buffer_minutes,

        COALESCE(
            NULLIF(
                s.booking_policy ->> 'minimum_advance_minutes',
                ''
            )::INTEGER,
            60
        ),

        COALESCE(
            NULLIF(
                s.booking_policy ->> 'maximum_advance_days',
                ''
            )::INTEGER,
            90
        ),

        COALESCE(
            NULLIF(
                s.booking_policy ->> 'slot_interval_minutes',
                ''
            )::INTEGER,
            15
        ),

        COALESCE(
            NULLIF(
                s.booking_policy ->> 'allocation_mode',
                ''
            ),
            'global_capacity'
        )
    INTO
        v_restaurant_id,
        v_timezone,
        v_max_party_size,
        v_cleaning_buffer,
        v_minimum_advance_minutes,
        v_maximum_advance_days,
        v_default_slot_interval,
        v_allocation_mode
    FROM restaurants r
    JOIN restaurant_settings s
        ON s.restaurant_id = r.id
    WHERE r.slug = p_restaurant_slug
      AND r.is_active = TRUE
    LIMIT 1;

    IF NOT FOUND THEN
        reason_code := 'RESTAURANT_NOT_FOUND';
        reason_detail := 'Restaurant actif introuvable.';
        RETURN NEXT;
        RETURN;
    END IF;

    restaurant_id := v_restaurant_id;
    allocation_mode := v_allocation_mode;

    IF p_party_size > v_max_party_size THEN
        reason_code := 'PARTY_TOO_LARGE';
        reason_detail :=
            'Le nombre de personnes dépasse la limite du restaurant.';
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_start_time <
       NOW() + MAKE_INTERVAL(mins => v_minimum_advance_minutes)
    THEN
        reason_code := 'MINIMUM_ADVANCE_NOT_MET';
        reason_detail :=
            'La réservation est trop proche de l''heure actuelle.';
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_start_time >
       NOW() + MAKE_INTERVAL(days => v_maximum_advance_days)
    THEN
        reason_code := 'MAXIMUM_ADVANCE_EXCEEDED';
        reason_detail :=
            'La date dépasse la période maximale de réservation.';
        RETURN NEXT;
        RETURN;
    END IF;

    ---------------------------------------------------------------------------
    -- Service demandé
    ---------------------------------------------------------------------------

    SELECT
        sd.id,
        sd.slug,
        sd.default_duration_minutes,
        COALESCE(
            sd.slot_interval_minutes,
            v_default_slot_interval
        )
    INTO
        v_service_id,
        v_service_slug,
        v_duration_minutes,
        v_slot_interval
    FROM restaurant_service_definitions sd
    WHERE sd.restaurant_id = v_restaurant_id
      AND sd.slug = p_service_slug
      AND sd.is_active = TRUE
    LIMIT 1;

    IF NOT FOUND THEN
        reason_code := 'SERVICE_NOT_FOUND';
        reason_detail := 'Service actif introuvable.';
        RETURN NEXT;
        RETURN;
    END IF;

    service_id := v_service_id;
    service_slug := v_service_slug;
    duration_minutes := v_duration_minutes;
    cleaning_buffer_minutes := v_cleaning_buffer;

    v_end_time :=
        p_start_time
        + MAKE_INTERVAL(mins => v_duration_minutes);

    v_occupied_end_time :=
        v_end_time
        + MAKE_INTERVAL(mins => v_cleaning_buffer);

    end_time := v_end_time;

    v_start_local :=
        p_start_time AT TIME ZONE v_timezone;

    v_end_local :=
        v_end_time AT TIME ZONE v_timezone;

    ---------------------------------------------------------------------------
    -- Horaires du service
    --
    -- Deux dates sont testées :
    --   - la date locale de la réservation ;
    --   - la veille, pour les services fermant après minuit.
    ---------------------------------------------------------------------------

    SELECT
        schedule.service_date,
        sh.first_booking_at,
        sh.last_booking_at,
        sh.closes_at,
        sh.closes_next_day,
        sh.capacity_override
    INTO
        v_service_date,
        v_first_booking_at,
        v_last_booking_at,
        v_closes_at,
        v_closes_next_day,
        v_capacity_override
    FROM restaurant_service_hours sh
    CROSS JOIN LATERAL (
        SELECT v_start_local::DATE AS service_date

        UNION ALL

        SELECT (v_start_local::DATE - 1) AS service_date
    ) schedule
    WHERE sh.restaurant_id = v_restaurant_id
      AND sh.service_id = v_service_id
      AND sh.is_open = TRUE

      AND sh.weekday =
          EXTRACT(
              ISODOW
              FROM schedule.service_date
          )::INTEGER

      AND v_start_local >=
          schedule.service_date
          + sh.first_booking_at

      AND v_start_local <=
          schedule.service_date
          + sh.last_booking_at

      AND v_end_local <=
          schedule.service_date
          + sh.closes_at
          + CASE
                WHEN sh.closes_next_day
                    THEN INTERVAL '1 day'
                ELSE INTERVAL '0 day'
            END

    ORDER BY schedule.service_date DESC
    LIMIT 1;

    IF NOT FOUND THEN
        reason_code := 'SERVICE_CLOSED';
        reason_detail :=
            'Le service n''est pas ouvert à la date ou à l''heure demandée.';
        RETURN NEXT;
        RETURN;
    END IF;

    ---------------------------------------------------------------------------
    -- Alignement sur l'intervalle des créneaux
    ---------------------------------------------------------------------------

    v_minutes_since_first :=
        FLOOR(
            EXTRACT(
                EPOCH
                FROM (
                    v_start_local
                    - (
                        v_service_date
                        + v_first_booking_at
                    )
                )
            ) / 60
        )::INTEGER;

    IF MOD(v_minutes_since_first, v_slot_interval) <> 0 THEN
        reason_code := 'SLOT_INTERVAL_MISMATCH';
        reason_detail :=
            'L''heure demandée ne correspond pas à un créneau autorisé.';
        RETURN NEXT;
        RETURN;
    END IF;

    ---------------------------------------------------------------------------
    -- Mode table_assignment
    --
    -- Refus volontaire tant que l'allocation atomique des tables
    -- n'est pas ajoutée dans la prochaine migration.
    ---------------------------------------------------------------------------

    IF v_allocation_mode = 'table_assignment' THEN
        reason_code := 'TABLE_ASSIGNMENT_PENDING';
        reason_detail :=
            'Le moteur d''allocation des tables n''est pas encore activé.';
        RETURN NEXT;
        RETURN;
    END IF;

    ---------------------------------------------------------------------------
    -- Capacité globale
    ---------------------------------------------------------------------------

    IF v_allocation_mode = 'global_capacity' THEN
        SELECT COALESCE(
            v_capacity_override,
            NULLIF(SUM(a.capacity), 0),
            v_max_party_size
        )::INTEGER
        INTO v_global_capacity
        FROM restaurant_areas a
        WHERE a.restaurant_id = v_restaurant_id
          AND a.is_active = TRUE;

        SELECT COALESCE(SUM(r.party_size), 0)::INTEGER
        INTO v_global_used
        FROM reservations r
        WHERE r.restaurant_id = v_restaurant_id

          AND r.status NOT IN (
              'cancelled',
              'declined',
              'no_show'
          )

          AND r.start_time < v_occupied_end_time

          AND (
              r.end_time
              + MAKE_INTERVAL(
                    mins => COALESCE(
                        r.cleaning_buffer_minutes,
                        0
                    )
                )
          ) > p_start_time;

        capacity_total := v_global_capacity;
        capacity_used := v_global_used;
        capacity_remaining :=
            GREATEST(
                v_global_capacity - v_global_used,
                0
            );

        SELECT c.reason
        INTO v_closure_reason
        FROM restaurant_closures c
        WHERE c.restaurant_id = v_restaurant_id
          AND c.is_active = TRUE

          AND c.starts_at < v_occupied_end_time
          AND c.ends_at > p_start_time

          AND (
              c.service_id IS NULL
              OR c.service_id = v_service_id
          )

          AND c.area_id IS NULL

        ORDER BY c.starts_at DESC
        LIMIT 1;

        IF FOUND THEN
            reason_code := 'RESTAURANT_CLOSED';
            reason_detail :=
                COALESCE(
                    v_closure_reason,
                    'Le restaurant est fermé sur ce créneau.'
                );
            RETURN NEXT;
            RETURN;
        END IF;

        IF v_global_used + p_party_size > v_global_capacity THEN
            reason_code := 'GLOBAL_CAPACITY_EXCEEDED';
            reason_detail :=
                'La capacité globale disponible est insuffisante.';
            RETURN NEXT;
            RETURN;
        END IF;

        available := TRUE;
        reason_code := 'AVAILABLE';
        reason_detail := 'Créneau disponible.';
        RETURN NEXT;
        RETURN;
    END IF;

    ---------------------------------------------------------------------------
    -- Capacité par zone
    ---------------------------------------------------------------------------

    IF v_allocation_mode = 'area_capacity' THEN

        -----------------------------------------------------------------------
        -- Zone explicitement demandée
        -----------------------------------------------------------------------

        IF NULLIF(BTRIM(p_requested_area_slug), '') IS NOT NULL THEN
            SELECT
                a.id,
                a.slug,
                a.capacity
            INTO
                v_requested_area_id,
                v_requested_area_slug,
                v_area_capacity
            FROM restaurant_areas a
            WHERE a.restaurant_id = v_restaurant_id
              AND a.slug = p_requested_area_slug
              AND a.is_active = TRUE
            LIMIT 1;

            IF NOT FOUND THEN
                reason_code := 'AREA_NOT_FOUND';
                reason_detail :=
                    'La zone demandée est introuvable ou inactive.';
                RETURN NEXT;
                RETURN;
            END IF;

            SELECT c.reason
            INTO v_closure_reason
            FROM restaurant_closures c
            WHERE c.restaurant_id = v_restaurant_id
              AND c.is_active = TRUE

              AND c.starts_at < v_occupied_end_time
              AND c.ends_at > p_start_time

              AND (
                  c.service_id IS NULL
                  OR c.service_id = v_service_id
              )

              AND (
                  c.area_id IS NULL
                  OR c.area_id = v_requested_area_id
              )

            ORDER BY
                CASE
                    WHEN c.area_id = v_requested_area_id
                        THEN 0
                    ELSE 1
                END,
                c.starts_at DESC
            LIMIT 1;

            IF FOUND THEN
                reason_code := 'AREA_CLOSED';
                reason_detail :=
                    COALESCE(
                        v_closure_reason,
                        'La zone demandée est fermée.'
                    );
                RETURN NEXT;
                RETURN;
            END IF;

            SELECT COALESCE(SUM(r.party_size), 0)::INTEGER
            INTO v_area_used
            FROM reservations r
            WHERE r.restaurant_id = v_restaurant_id

              AND COALESCE(
                  r.area_id,
                  r.requested_area_id
              ) = v_requested_area_id

              AND r.status NOT IN (
                  'cancelled',
                  'declined',
                  'no_show'
              )

              AND r.start_time < v_occupied_end_time

              AND (
                  r.end_time
                  + MAKE_INTERVAL(
                        mins => COALESCE(
                            r.cleaning_buffer_minutes,
                            0
                        )
                    )
              ) > p_start_time;

            capacity_total := v_area_capacity;
            capacity_used := v_area_used;
            capacity_remaining :=
                GREATEST(
                    v_area_capacity - v_area_used,
                    0
                );

            IF v_area_used + p_party_size > v_area_capacity THEN
                reason_code := 'AREA_CAPACITY_EXCEEDED';
                reason_detail :=
                    'La capacité de la zone demandée est insuffisante.';
                RETURN NEXT;
                RETURN;
            END IF;

            area_id := v_requested_area_id;
            area_slug := v_requested_area_slug;

            available := TRUE;
            reason_code := 'AVAILABLE';
            reason_detail := 'Créneau disponible dans la zone demandée.';
            RETURN NEXT;
            RETURN;
        END IF;

        -----------------------------------------------------------------------
        -- Sélection automatique de la meilleure zone disponible
        -----------------------------------------------------------------------

        SELECT
            candidate.id,
            candidate.slug,
            candidate.capacity,
            candidate.used_capacity
        INTO
            v_requested_area_id,
            v_requested_area_slug,
            v_area_capacity,
            v_area_used
        FROM (
            SELECT
                a.id,
                a.slug,
                a.capacity,

                COALESCE(
                    SUM(r.party_size)
                        FILTER (
                            WHERE r.id IS NOT NULL
                        ),
                    0
                )::INTEGER AS used_capacity,

                a.priority
            FROM restaurant_areas a

            LEFT JOIN reservations r
                ON r.restaurant_id = v_restaurant_id

               AND COALESCE(
                   r.area_id,
                   r.requested_area_id
               ) = a.id

               AND r.status NOT IN (
                   'cancelled',
                   'declined',
                   'no_show'
               )

               AND r.start_time < v_occupied_end_time

               AND (
                   r.end_time
                   + MAKE_INTERVAL(
                        mins => COALESCE(
                            r.cleaning_buffer_minutes,
                            0
                        )
                     )
               ) > p_start_time

            WHERE a.restaurant_id = v_restaurant_id
              AND a.is_active = TRUE

              AND NOT EXISTS (
                  SELECT 1
                  FROM restaurant_closures c
                  WHERE c.restaurant_id = v_restaurant_id
                    AND c.is_active = TRUE

                    AND c.starts_at < v_occupied_end_time
                    AND c.ends_at > p_start_time

                    AND (
                        c.service_id IS NULL
                        OR c.service_id = v_service_id
                    )

                    AND (
                        c.area_id IS NULL
                        OR c.area_id = a.id
                    )
              )

            GROUP BY
                a.id,
                a.slug,
                a.capacity,
                a.priority
        ) candidate
        WHERE
            candidate.capacity
            - candidate.used_capacity
            >= p_party_size

        ORDER BY
            (
                candidate.capacity
                - candidate.used_capacity
                - p_party_size
            ) ASC,
            candidate.priority ASC,
            candidate.id ASC

        LIMIT 1;

        IF NOT FOUND THEN
            reason_code := 'NO_AREA_AVAILABLE';
            reason_detail :=
                'Aucune zone ne dispose de suffisamment de capacité.';
            RETURN NEXT;
            RETURN;
        END IF;

        area_id := v_requested_area_id;
        area_slug := v_requested_area_slug;

        capacity_total := v_area_capacity;
        capacity_used := v_area_used;
        capacity_remaining :=
            GREATEST(
                v_area_capacity - v_area_used,
                0
            );

        available := TRUE;
        reason_code := 'AVAILABLE';
        reason_detail :=
            'Créneau disponible avec sélection automatique de la zone.';
        RETURN NEXT;
        RETURN;
    END IF;

    ---------------------------------------------------------------------------
    -- Mode inconnu
    ---------------------------------------------------------------------------

    reason_code := 'UNSUPPORTED_ALLOCATION_MODE';
    reason_detail :=
        'Le mode d''allocation du restaurant n''est pas supporté.';

    RETURN NEXT;
    RETURN;
END;
$booking_function$;

COMMENT ON FUNCTION public.booking_check_availability_v2(
    TEXT,
    TEXT,
    TIMESTAMPTZ,
    INTEGER,
    TEXT
)
IS
'Contrôle Booking Engine V2 : service, horaires, fermetures, chevauchements et capacités.';

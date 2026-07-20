-------------------------------------------------------------------------------
-- Booking Engine V2
-- Création atomique et idempotente d'une réservation.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.booking_create_reservation_v2(
    p_restaurant_slug TEXT,
    p_service_slug TEXT,
    p_start_time TIMESTAMPTZ,
    p_party_size INTEGER,
    p_full_name TEXT,
    p_phone TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL,
    p_special_request TEXT DEFAULT NULL,
    p_requested_area_slug TEXT DEFAULT NULL,
    p_source_channel TEXT DEFAULT 'webhook',
    p_conversation_id TEXT DEFAULT NULL,
    p_customer_confirmed BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    created BOOLEAN,
    idempotent BOOLEAN,
    reason_code TEXT,
    reason_detail TEXT,

    reservation_id BIGINT,
    client_id BIGINT,
    restaurant_id BIGINT,
    service_id BIGINT,

    area_id BIGINT,
    area_slug TEXT,

    start_time TIMESTAMPTZ,
    end_time TIMESTAMPTZ,

    party_size INTEGER,
    reservation_status TEXT
)
LANGUAGE plpgsql
AS $booking_create$
DECLARE
    v_restaurant_id BIGINT;
    v_timezone TEXT;
    v_grace_delay_minutes INTEGER;

    v_client_id BIGINT;
    v_reservation_id BIGINT;
    v_existing_status TEXT;

    v_phone TEXT;
    v_email TEXT;
    v_full_name TEXT;
    v_conversation_id TEXT;
    v_source_channel TEXT;

    v_availability RECORD;

    v_booking_lock_key TEXT;
    v_client_lock_key TEXT;
BEGIN
    created := FALSE;
    idempotent := FALSE;

    reason_code := NULL;
    reason_detail := NULL;

    reservation_id := NULL;
    client_id := NULL;
    restaurant_id := NULL;
    service_id := NULL;

    area_id := NULL;
    area_slug := NULL;

    start_time := p_start_time;
    end_time := NULL;

    party_size := p_party_size;
    reservation_status := NULL;

    v_phone := NULLIF(BTRIM(p_phone), '');
    v_email := NULLIF(LOWER(BTRIM(p_email)), '');
    v_full_name := NULLIF(BTRIM(p_full_name), '');
    v_conversation_id := NULLIF(BTRIM(p_conversation_id), '');
    v_source_channel :=
        COALESCE(
            NULLIF(BTRIM(p_source_channel), ''),
            'webhook'
        );

    ---------------------------------------------------------------------------
    -- Validation métier préalable
    ---------------------------------------------------------------------------

    IF p_customer_confirmed IS NOT TRUE THEN
        reason_code := 'CUSTOMER_NOT_CONFIRMED';
        reason_detail :=
            'La réservation doit être confirmée par le client.';
        RETURN NEXT;
        RETURN;
    END IF;

    IF v_full_name IS NULL THEN
        reason_code := 'FULL_NAME_REQUIRED';
        reason_detail :=
            'Le nom du client est obligatoire.';
        RETURN NEXT;
        RETURN;
    END IF;

    ---------------------------------------------------------------------------
    -- Restaurant
    ---------------------------------------------------------------------------

    SELECT
        r.id,
        r.timezone,
        s.grace_delay_minutes
    INTO
        v_restaurant_id,
        v_timezone,
        v_grace_delay_minutes
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

    ---------------------------------------------------------------------------
    -- Verrou transactionnel
    --
    -- Toutes les créations d'un restaurant pour une même journée locale sont
    -- sérialisées. C'est volontairement plus strict, mais fiable et simple.
    ---------------------------------------------------------------------------

    v_booking_lock_key :=
        'booking-create-v2:'
        || v_restaurant_id::TEXT
        || ':'
        || (
            p_start_time
            AT TIME ZONE v_timezone
        )::DATE::TEXT;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_booking_lock_key, 0)
    );

    ---------------------------------------------------------------------------
    -- Idempotence avant toute création
    ---------------------------------------------------------------------------

    IF v_conversation_id IS NOT NULL THEN
        SELECT
            r.id,
            r.client_id,
            r.service_id,
            r.area_id,
            a.slug,
            r.start_time,
            r.end_time,
            r.party_size,
            r.status
        INTO
            v_reservation_id,
            v_client_id,
            service_id,
            area_id,
            area_slug,
            start_time,
            end_time,
            party_size,
            v_existing_status
        FROM reservations r
        LEFT JOIN restaurant_areas a
            ON a.id = r.area_id
        WHERE r.restaurant_id = v_restaurant_id
          AND r.conversation_id = v_conversation_id
          AND r.start_time = p_start_time
        ORDER BY r.created_at DESC
        LIMIT 1;

        IF FOUND THEN
            created := FALSE;
            idempotent := TRUE;

            reservation_id := v_reservation_id;
            client_id := v_client_id;
            reservation_status := v_existing_status;

            reason_code := 'RESERVATION_ALREADY_EXISTS';
            reason_detail :=
                'Cette réservation a déjà été enregistrée.';

            RETURN NEXT;
            RETURN;
        END IF;
    END IF;

    ---------------------------------------------------------------------------
    -- Nouvelle vérification de disponibilité sous verrou
    ---------------------------------------------------------------------------

    SELECT availability.*
    INTO v_availability
    FROM public.booking_check_availability_v2(
        p_restaurant_slug,
        p_service_slug,
        p_start_time,
        p_party_size,
        p_requested_area_slug
    ) availability
    LIMIT 1;

    IF v_availability.available IS NOT TRUE THEN
        reason_code :=
            COALESCE(
                v_availability.reason_code,
                'NOT_AVAILABLE'
            );

        reason_detail :=
            COALESCE(
                v_availability.reason_detail,
                'Le créneau demandé n''est pas disponible.'
            );

        service_id := v_availability.service_id;
        area_id := v_availability.area_id;
        area_slug := v_availability.area_slug;
        end_time := v_availability.end_time;

        RETURN NEXT;
        RETURN;
    END IF;

    service_id := v_availability.service_id;
    area_id := v_availability.area_id;
    area_slug := v_availability.area_slug;
    end_time := v_availability.end_time;

    ---------------------------------------------------------------------------
    -- Verrou d'identité client
    ---------------------------------------------------------------------------

    v_client_lock_key :=
        'booking-client-v2:'
        || v_restaurant_id::TEXT
        || ':'
        || COALESCE(
            v_phone,
            v_email,
            v_conversation_id,
            LOWER(v_full_name)
        );

    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_client_lock_key, 0)
    );

    ---------------------------------------------------------------------------
    -- Recherche du client existant
    ---------------------------------------------------------------------------

    SELECT c.id
    INTO v_client_id
    FROM clients c
    WHERE c.restaurant_id = v_restaurant_id
      AND (
          (
              v_phone IS NOT NULL
              AND c.phone = v_phone
          )
          OR
          (
              v_email IS NOT NULL
              AND LOWER(c.email) = v_email
          )
      )
    ORDER BY
        CASE
            WHEN v_phone IS NOT NULL
             AND c.phone = v_phone
                THEN 0
            ELSE 1
        END,
        c.updated_at DESC NULLS LAST,
        c.created_at DESC
    LIMIT 1;

    ---------------------------------------------------------------------------
    -- Création du client
    ---------------------------------------------------------------------------

    IF v_client_id IS NULL THEN
        INSERT INTO clients (
            restaurant_id,
            full_name,
            phone,
            email,
            channel_type,
            channel_value,
            is_new_customer,
            consent_notifications,
            consent_marketing,
            created_at,
            updated_at
        )
        VALUES (
            v_restaurant_id,
            v_full_name,
            v_phone,
            v_email,
            v_source_channel,
            COALESCE(
                v_phone,
                v_email,
                v_conversation_id
            ),
            TRUE,
            TRUE,
            FALSE,
            NOW(),
            NOW()
        )
        RETURNING id
        INTO v_client_id;
    ELSE
        UPDATE clients
        SET full_name =
                COALESCE(v_full_name, clients.full_name),
            phone =
                COALESCE(v_phone, clients.phone),
            email =
                COALESCE(v_email, clients.email),
            updated_at = NOW()
        WHERE id = v_client_id;
    END IF;

    client_id := v_client_id;

    ---------------------------------------------------------------------------
    -- Création de la réservation
    ---------------------------------------------------------------------------

    INSERT INTO reservations (
        restaurant_id,
        client_id,

        service_id,
        requested_area_id,
        area_id,

        start_time,
        end_time,
        party_size,

        status,
        source_channel,
        booking_source,
        created_by,
        source,

        meal_duration_minutes,
        cleaning_buffer_minutes,
        grace_delay_minutes,

        special_request,
        conversation_id,

        created_at,
        updated_at
    )
    VALUES (
        v_restaurant_id,
        v_client_id,

        v_availability.service_id,
        v_availability.area_id,
        v_availability.area_id,

        p_start_time,
        v_availability.end_time,
        p_party_size,

        'confirmed',
        v_source_channel,
        v_source_channel,
        v_source_channel,
        v_source_channel,

        v_availability.duration_minutes,
        v_availability.cleaning_buffer_minutes,
        COALESCE(v_grace_delay_minutes, 10),

        NULLIF(BTRIM(p_special_request), ''),
        v_conversation_id,

        NOW(),
        NOW()
    )
    ON CONFLICT (
        restaurant_id,
        conversation_id,
        start_time
    )
    WHERE conversation_id IS NOT NULL
    DO NOTHING
    RETURNING
        id,
        status
    INTO
        v_reservation_id,
        v_existing_status;

    ---------------------------------------------------------------------------
    -- Protection supplémentaire en cas de conflit d'idempotence
    ---------------------------------------------------------------------------

    IF v_reservation_id IS NULL
       AND v_conversation_id IS NOT NULL
    THEN
        SELECT
            r.id,
            r.client_id,
            r.status
        INTO
            v_reservation_id,
            v_client_id,
            v_existing_status
        FROM reservations r
        WHERE r.restaurant_id = v_restaurant_id
          AND r.conversation_id = v_conversation_id
          AND r.start_time = p_start_time
        ORDER BY r.created_at DESC
        LIMIT 1;

        created := FALSE;
        idempotent := TRUE;

        reservation_id := v_reservation_id;
        client_id := v_client_id;
        reservation_status := v_existing_status;

        reason_code := 'RESERVATION_ALREADY_EXISTS';
        reason_detail :=
            'Cette réservation a déjà été enregistrée.';

        RETURN NEXT;
        RETURN;
    END IF;

    created := TRUE;
    idempotent := FALSE;

    reservation_id := v_reservation_id;
    reservation_status := v_existing_status;

    reason_code := 'RESERVATION_CREATED';
    reason_detail :=
        'La réservation a été enregistrée avec succès.';

    RETURN NEXT;
    RETURN;
END;
$booking_create$;

COMMENT ON FUNCTION public.booking_create_reservation_v2(
    TEXT,
    TEXT,
    TIMESTAMPTZ,
    INTEGER,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    BOOLEAN
)
IS
'Crée une réservation V2 de manière atomique et idempotente.';

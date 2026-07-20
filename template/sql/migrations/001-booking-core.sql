--
-- PostgreSQL database dump
--

\restrict xYu2m284vHYj38y91F9VWY5dERWCJCE2HZgIVkqerhZFu3VB7TV1hGPCHjFdYx0

-- Dumped from database version 16.14 (Debian 16.14-1.pgdg13+1)
-- Dumped by pg_dump version 16.14 (Debian 16.14-1.pgdg13+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: channel_conversation_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_conversation_logs (
    id bigint NOT NULL,
    restaurant_id bigint,
    conversation_id text NOT NULL,
    external_event_id text NOT NULL,
    call_id text,
    sms_id text,
    email_message_id text,
    instagram_message_id text,
    source text NOT NULL,
    channel text NOT NULL,
    provider text,
    phone text,
    email text,
    summary text,
    transcript text,
    user_message text,
    raw_payload jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: channel_conversation_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_conversation_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_conversation_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_conversation_logs_id_seq OWNED BY public.channel_conversation_logs.id;


--
-- Name: client_notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.client_notifications (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    reservation_id bigint,
    client_id bigint,
    channel text DEFAULT 'whatsapp'::text NOT NULL,
    scheduled_at timestamp with time zone NOT NULL,
    sent_at timestamp with time zone,
    status text DEFAULT 'pending'::text NOT NULL,
    payload jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: client_notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.client_notifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: client_notifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.client_notifications_id_seq OWNED BY public.client_notifications.id;


--
-- Name: clients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clients (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    full_name text,
    phone text,
    email text,
    channel_type text,
    channel_value text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    is_new_customer boolean DEFAULT true NOT NULL,
    notes text,
    preferences jsonb,
    consent_notifications boolean DEFAULT true NOT NULL,
    consent_marketing boolean DEFAULT false NOT NULL
);


--
-- Name: clients_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.clients_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: clients_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.clients_id_seq OWNED BY public.clients.id;


--
-- Name: outbound_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outbound_messages (
    id bigint NOT NULL,
    restaurant_id bigint,
    conversation_id text NOT NULL,
    source text NOT NULL,
    channel text NOT NULL,
    provider text,
    recipient text,
    sender text,
    subject text,
    content text NOT NULL,
    payload jsonb,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: outbound_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.outbound_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: outbound_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.outbound_messages_id_seq OWNED BY public.outbound_messages.id;


--
-- Name: reservations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reservations (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    client_id bigint,
    start_time timestamp with time zone NOT NULL,
    end_time timestamp with time zone NOT NULL,
    party_size integer NOT NULL,
    status text DEFAULT 'confirmed'::text NOT NULL,
    source_channel text DEFAULT 'webhook'::text NOT NULL,
    meal_duration_minutes integer DEFAULT 120 NOT NULL,
    cleaning_buffer_minutes integer DEFAULT 15 NOT NULL,
    grace_delay_minutes integer DEFAULT 10 NOT NULL,
    special_request text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    table_id bigint,
    area_id bigint,
    booking_source text,
    created_by text,
    source text,
    conversation_id text
);


--
-- Name: reservations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reservations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reservations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reservations_id_seq OWNED BY public.reservations.id;


--
-- Name: restaurant_channels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_channels (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    channel_type text NOT NULL,
    channel_value text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: restaurant_channels_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.restaurant_channels_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: restaurant_channels_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.restaurant_channels_id_seq OWNED BY public.restaurant_channels.id;


--
-- Name: restaurant_closures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_closures (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    closure_type text,
    recurrence_rule text
);


--
-- Name: restaurant_closures_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.restaurant_closures_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: restaurant_closures_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.restaurant_closures_id_seq OWNED BY public.restaurant_closures.id;


--
-- Name: restaurant_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurant_settings (
    id bigint NOT NULL,
    restaurant_id bigint NOT NULL,
    default_meal_duration_minutes integer DEFAULT 120 NOT NULL,
    cleaning_buffer_minutes integer DEFAULT 15 NOT NULL,
    grace_delay_minutes integer DEFAULT 10 NOT NULL,
    max_party_size integer DEFAULT 12 NOT NULL,
    reminder_days_before integer DEFAULT 1 NOT NULL,
    reminder_hour integer DEFAULT 9 NOT NULL,
    reminder_channel text DEFAULT 'whatsapp'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    allow_combined_tables boolean DEFAULT false NOT NULL,
    booking_policy jsonb,
    event_notification_policy jsonb
);


--
-- Name: restaurant_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.restaurant_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: restaurant_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.restaurant_settings_id_seq OWNED BY public.restaurant_settings.id;


--
-- Name: restaurants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.restaurants (
    id bigint NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    timezone text DEFAULT 'Europe/Paris'::text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: restaurants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.restaurants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: restaurants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.restaurants_id_seq OWNED BY public.restaurants.id;


--
-- Name: channel_conversation_logs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_conversation_logs ALTER COLUMN id SET DEFAULT nextval('public.channel_conversation_logs_id_seq'::regclass);


--
-- Name: client_notifications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_notifications ALTER COLUMN id SET DEFAULT nextval('public.client_notifications_id_seq'::regclass);


--
-- Name: clients id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients ALTER COLUMN id SET DEFAULT nextval('public.clients_id_seq'::regclass);


--
-- Name: outbound_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_messages ALTER COLUMN id SET DEFAULT nextval('public.outbound_messages_id_seq'::regclass);


--
-- Name: reservations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reservations ALTER COLUMN id SET DEFAULT nextval('public.reservations_id_seq'::regclass);


--
-- Name: restaurant_channels id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_channels ALTER COLUMN id SET DEFAULT nextval('public.restaurant_channels_id_seq'::regclass);


--
-- Name: restaurant_closures id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_closures ALTER COLUMN id SET DEFAULT nextval('public.restaurant_closures_id_seq'::regclass);


--
-- Name: restaurant_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_settings ALTER COLUMN id SET DEFAULT nextval('public.restaurant_settings_id_seq'::regclass);


--
-- Name: restaurants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurants ALTER COLUMN id SET DEFAULT nextval('public.restaurants_id_seq'::regclass);


--
-- Name: channel_conversation_logs channel_conversation_logs_conversation_id_external_event_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_conversation_logs
    ADD CONSTRAINT channel_conversation_logs_conversation_id_external_event_id_key UNIQUE (conversation_id, external_event_id);


--
-- Name: channel_conversation_logs channel_conversation_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_conversation_logs
    ADD CONSTRAINT channel_conversation_logs_pkey PRIMARY KEY (id);


--
-- Name: client_notifications client_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_notifications
    ADD CONSTRAINT client_notifications_pkey PRIMARY KEY (id);


--
-- Name: clients clients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_pkey PRIMARY KEY (id);


--
-- Name: clients clients_unique_channel; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_unique_channel UNIQUE (restaurant_id, channel_type, channel_value);


--
-- Name: outbound_messages outbound_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbound_messages
    ADD CONSTRAINT outbound_messages_pkey PRIMARY KEY (id);


--
-- Name: reservations reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reservations
    ADD CONSTRAINT reservations_pkey PRIMARY KEY (id);


--
-- Name: restaurant_channels restaurant_channels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_channels
    ADD CONSTRAINT restaurant_channels_pkey PRIMARY KEY (id);


--
-- Name: restaurant_channels restaurant_channels_unique_channel; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_channels
    ADD CONSTRAINT restaurant_channels_unique_channel UNIQUE (restaurant_id, channel_type, channel_value);


--
-- Name: restaurant_closures restaurant_closures_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_closures
    ADD CONSTRAINT restaurant_closures_pkey PRIMARY KEY (id);


--
-- Name: restaurant_settings restaurant_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_settings
    ADD CONSTRAINT restaurant_settings_pkey PRIMARY KEY (id);


--
-- Name: restaurant_settings restaurant_settings_unique_restaurant; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_settings
    ADD CONSTRAINT restaurant_settings_unique_restaurant UNIQUE (restaurant_id);


--
-- Name: restaurants restaurants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurants
    ADD CONSTRAINT restaurants_pkey PRIMARY KEY (id);


--
-- Name: restaurants restaurants_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurants
    ADD CONSTRAINT restaurants_slug_key UNIQUE (slug);


--
-- Name: idx_clients_restaurant_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clients_restaurant_email ON public.clients USING btree (restaurant_id, email);


--
-- Name: idx_clients_restaurant_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clients_restaurant_phone ON public.clients USING btree (restaurant_id, phone);


--
-- Name: idx_reservations_lookup_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reservations_lookup_slot ON public.reservations USING btree (restaurant_id, start_time, status);


--
-- Name: idx_reservations_restaurant_start_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reservations_restaurant_start_time ON public.reservations USING btree (restaurant_id, start_time);


--
-- Name: idx_reservations_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reservations_status ON public.reservations USING btree (status);


--
-- Name: idx_restaurant_closures_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_restaurant_closures_lookup ON public.restaurant_closures USING btree (restaurant_id, starts_at, ends_at, is_active);


--
-- Name: ux_reservations_conversation_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_reservations_conversation_slot ON public.reservations USING btree (restaurant_id, conversation_id, start_time) WHERE (conversation_id IS NOT NULL);


--
-- Name: client_notifications client_notifications_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_notifications
    ADD CONSTRAINT client_notifications_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE SET NULL;


--
-- Name: client_notifications client_notifications_reservation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_notifications
    ADD CONSTRAINT client_notifications_reservation_id_fkey FOREIGN KEY (reservation_id) REFERENCES public.reservations(id) ON DELETE CASCADE;


--
-- Name: client_notifications client_notifications_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_notifications
    ADD CONSTRAINT client_notifications_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: clients clients_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: reservations reservations_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reservations
    ADD CONSTRAINT reservations_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE SET NULL;


--
-- Name: reservations reservations_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reservations
    ADD CONSTRAINT reservations_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_channels restaurant_channels_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_channels
    ADD CONSTRAINT restaurant_channels_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_closures restaurant_closures_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_closures
    ADD CONSTRAINT restaurant_closures_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- Name: restaurant_settings restaurant_settings_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.restaurant_settings
    ADD CONSTRAINT restaurant_settings_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurants(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict xYu2m284vHYj38y91F9VWY5dERWCJCE2HZgIVkqerhZFu3VB7TV1hGPCHjFdYx0


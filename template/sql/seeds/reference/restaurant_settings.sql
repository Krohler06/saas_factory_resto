--
-- PostgreSQL database dump
--

\restrict jszqrFgOmjgMskCzj4ztNLRVQp751WrtfvVvFBYFObItrwSq7LJbVFb7aO27OQX

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

--
-- Data for Name: restaurant_settings; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.restaurant_settings (id, restaurant_id, default_meal_duration_minutes, cleaning_buffer_minutes, grace_delay_minutes, max_party_size, reminder_days_before, reminder_hour, reminder_channel, created_at, updated_at, allow_combined_tables, booking_policy, event_notification_policy) VALUES (1, 1, 120, 15, 10, 12, 1, 9, 'whatsapp', '2026-06-26 09:15:45.310307+02', '2026-06-26 09:15:45.310307+02', false, NULL, NULL);
INSERT INTO public.restaurant_settings (id, restaurant_id, default_meal_duration_minutes, cleaning_buffer_minutes, grace_delay_minutes, max_party_size, reminder_days_before, reminder_hour, reminder_channel, created_at, updated_at, allow_combined_tables, booking_policy, event_notification_policy) VALUES (2, 2, 120, 15, 10, 12, 1, 9, 'sms', '2026-07-18 20:48:13.046809+02', '2026-07-18 20:48:13.046809+02', false, NULL, NULL);


--
-- Name: restaurant_settings_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.restaurant_settings_id_seq', 2, true);


--
-- PostgreSQL database dump complete
--

\unrestrict jszqrFgOmjgMskCzj4ztNLRVQp751WrtfvVvFBYFObItrwSq7LJbVFb7aO27OQX


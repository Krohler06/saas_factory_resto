--
-- PostgreSQL database dump
--

\restrict Ji6AtOPyk4Q8GJcRyGrZQg1YfjhVrAgk5xstclJwVEnntE6Vgc3sof9iWcGU8Lo

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
-- Data for Name: restaurants; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.restaurants (id, name, slug, timezone, is_active, created_at, updated_at) VALUES (1, 'Little Africa', 'little_africa_nice', 'Europe/Paris', true, '2026-06-26 09:15:45.309133+02', '2026-06-26 09:15:45.309133+02');
INSERT INTO public.restaurants (id, name, slug, timezone, is_active, created_at, updated_at) VALUES (2, 'Restaurant Little Africa Nice', 'little-africa-nice', 'Europe/Paris', true, '2026-07-18 20:48:13.046809+02', '2026-07-18 20:48:13.046809+02');


--
-- Name: restaurants_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.restaurants_id_seq', 2, true);


--
-- PostgreSQL database dump complete
--

\unrestrict Ji6AtOPyk4Q8GJcRyGrZQg1YfjhVrAgk5xstclJwVEnntE6Vgc3sof9iWcGU8Lo


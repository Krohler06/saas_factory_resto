# Migrations Booking Engine

Ordre prévu :

- `001-base-schema.sql`
- `002-booking-engine-v2.sql`
- `003-booking-engine-v2-indexes.sql`
- `004-booking-engine-v2-constraints.sql`

Les données spécifiques à un restaurant ne doivent pas être intégrées aux migrations de schéma. Elles seront générées séparément depuis `tenant.yml`.


docker compose stop n8n

docker compose exec -T postgres \
  dropdb ...

docker compose exec -T postgres \
  createdb ...

docker compose exec -T postgres \
  pg_restore ...

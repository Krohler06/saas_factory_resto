
Template tenant SaaS

Ce dossier contient le modèle utilisé pour créer un nouveau client.

Contenu
template/
├── caddy/
├── docker/
├── env/
├── n8n/
├── retell/
├── sql/
└── tests/
À générer par client

Les valeurs suivantes doivent être remplacées :

__CLIENT_ID__
__RESTAURANT_SLUG__
__RESTAURANT_NAME__
__BASE_DOMAIN__
__TLS_EMAIL__
__POSTGRES_DB__
__POSTGRES_USER__
__POSTGRES_PASSWORD__
__N8N_ENCRYPTION_KEY__
Commande type
bash /root/saas_factory/scripts/create-tenant.sh \
  --client-id demo_restaurant_01 \
  --restaurant-slug demo-restaurant \
  --restaurant-name "Restaurant Démo" \
  --base-domain cyber-saas-private.ddnsfree.com \
  --tls-email admin@example.com


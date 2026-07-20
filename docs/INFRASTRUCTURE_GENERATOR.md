# Générateur d'infrastructure SaaS Factory

## Objectif

Ce lot transforme un `tenant.yml` validé en un déploiement reproductible :

```text
tenant.yml + config/factory.yml
        ↓
validation
        ↓
.env avec secrets stables
docker-compose.yml
route Caddy
migrations et seed SQL
workflows n8n rendus
manifest et SHA256SUMS
        ↓
déploiement sous /opt/clients/<client_id>
```

## Séparation des configurations

### `config/factory.yml`

Configuration globale du serveur :

- domaine ;
- réseau Docker de Caddy ;
- images Docker ;
- emplacement des tenants ;
- emplacement des routes Caddy.

Ce fichier reste privé.

### `tenants/private/<client_id>.yml`

Configuration métier d'un restaurant :

- services ;
- horaires ;
- zones ;
- capacités ;
- fermetures ;
- tables.

Ce fichier reste également privé.

## Dépendances

```bash
apt-get update
apt-get install -y \
  python3 \
  python3-yaml \
  python3-jsonschema \
  rsync \
  curl
```

## Configuration globale

```bash
mkdir -p /root/saas_factory/config

cp \
  /root/saas_factory/config/factory.example.yml \
  /root/saas_factory/config/factory.yml

chmod 600 /root/saas_factory/config/factory.yml
```

Inspecter le reverse proxy :

```bash
/root/saas_factory/scripts/inspect-factory-host.sh edge-caddy
```

Renseigner ensuite `config/factory.yml`.

## Prérequis Caddy

Le Caddyfile du domaine partagé doit importer les snippets depuis son bloc de site :

```caddy
example.com {
    import /etc/caddy/tenants/*.caddy

    # Autres routes éventuelles...
}
```

Le répertoire hôte indiqué par `factory.caddy.routes_host_dir` doit être monté
dans le conteneur au chemin utilisé par l'import.

Les snippets générés utilisent `handle`, et non `handle_path`, afin de conserver
le préfixe `/<client_id>/` attendu par `N8N_PATH`.

## Génération seule

```bash
/root/saas_factory/scripts/generate-tenant-infrastructure.sh \
  --tenant /root/saas_factory/tenants/private/restaurant_test.yml \
  --factory /root/saas_factory/config/factory.yml
```

Résultat :

```text
generated/restaurant_test/
├── .env
├── SHA256SUMS
├── caddy/
├── docker-compose.yml
├── meta/
├── n8n/
├── retell/
├── sql/
└── tenant.snapshot.yml
```

## Validation du rendu

```bash
/root/saas_factory/scripts/validate-generated-tenant.sh \
  /root/saas_factory/generated/restaurant_test
```

## Dry-run de déploiement

```bash
/root/saas_factory/scripts/deploy-tenant.sh \
  --tenant /root/saas_factory/tenants/private/restaurant_test.yml \
  --factory /root/saas_factory/config/factory.yml \
  --dry-run
```

## Premier déploiement

Utiliser d'abord un tenant de test et ignorer Caddy tant que son import global
n'est pas confirmé :

```bash
/root/saas_factory/scripts/deploy-tenant.sh \
  --tenant /root/saas_factory/tenants/private/restaurant_test.yml \
  --factory /root/saas_factory/config/factory.yml \
  --skip-caddy
```

Puis activer la route après validation du montage Caddy.

## Mise à jour

```bash
/root/saas_factory/scripts/deploy-tenant.sh \
  --tenant /root/saas_factory/tenants/private/restaurant_test.yml \
  --factory /root/saas_factory/config/factory.yml \
  --update
```

Les secrets existants sont conservés automatiquement.

Ne pas utiliser `--rotate-secrets` sur une instance n8n contenant déjà des
credentials, sauf procédure de rotation maîtrisée.

## Git

À versionner :

```text
config/factory.example.yml
docs/INFRASTRUCTURE_GENERATOR.md
scripts/deploy-tenant.sh
scripts/generate-tenant-infrastructure.sh
scripts/inspect-factory-host.sh
scripts/render-tenant-infrastructure.py
scripts/validate-generated-tenant.sh
template/docker/docker-compose.yml.template
template/caddy/client-route.caddy.template
template/env/.env.template
```

À ignorer :

```text
config/factory.yml
generated/
tenants/private/
backups/
```


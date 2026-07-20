# SaaS Factory - Agents IA Restaurant

Ce dépôt sert à industrialiser le déploiement de tenants restaurant avec :

- Docker Compose
- PostgreSQL
- n8n
- Retell AI
- Caddy reverse proxy
- workflows de réservation
- scripts de smoke test
- structure SQL reproductible

## Objectif

Transformer un tenant validé manuellement, par exemple :

`/opt/clients/resto_demo` en modèle réutilisable pour générer automatiquement `/opt/clients/<client_id>` avec :

- base PostgreSQL dédiée
- instance n8n dédiée
- workflows importés
- restaurant seedé
- route Caddy générée
- webhook Retell prêt à configurer
- tests curl de validation

## Structure

```sh
/root/saas_factory/
├── README.md
├── .gitignore
├── docs/
├── exports/
├── scripts/
└── template/
```
## Dossiers
### exports

Contient les exports bruts de tenants existants.

Ce dossier n’est pas versionné Git, car il peut contenir :

- des secrets
- des credentials n8n ;
- des fichiers .env privés ;
- des backups complets.
- template/

Contient le modèle propre, sans secrets, utilisé pour créer de nouveaux clients.

### scripts

Contient les scripts d’industrialisation :

- promotion d’un export vers le template ;
- création d’un tenant ;
- import workflows ;
- tests webhook ;
- contrôle anti-secret avant Git.

## Workflow recommandé

1. Exporter un client existant
```bash /root/saas_export_tenant_bundle.sh /opt/clients/little_africa_nice```
2. Promouvoir le dernier export en template
```sh
cd /root/saas_factory
bash scripts/promote-latest-export.sh
```
3. Vérifier le template
```tree -a /root/saas_factory/template```
4. Initialiser Git sans secrets
```sh
cd /root/saas_factory
bash scripts/git-init-safe.sh
```
5. Créer un nouveau tenant
```sh
```
## Règle importante

Ne jamais commiter :

- .env réel ;
- credentials n8n ;
- exports bruts ;
- fichiers contenant mots de passe, tokens, clés API ou secrets.


# SaaS Factory — Infrastructure Generator V1

Ce package ne contient pas d'installateur. Copiez les fichiers dans les mêmes
répertoires sous `/root/saas_factory`.

```bash
mkdir -p \
  /root/saas_factory/config \
  /root/saas_factory/docs \
  /root/saas_factory/scripts \
  /root/saas_factory/template/docker \
  /root/saas_factory/template/caddy \
  /root/saas_factory/template/env

cp -a config/factory.example.yml /root/saas_factory/config/
cp -a docs/INFRASTRUCTURE_GENERATOR.md /root/saas_factory/docs/
cp -a scripts/* /root/saas_factory/scripts/
cp -a template/docker/docker-compose.yml.template /root/saas_factory/template/docker/
cp -a template/caddy/client-route.caddy.template /root/saas_factory/template/caddy/
cp -a template/env/.env.template /root/saas_factory/template/env/

chmod +x /root/saas_factory/scripts/*.sh
chmod +x /root/saas_factory/scripts/render-tenant-infrastructure.py
```

Lire ensuite :

```text
/root/saas_factory/docs/INFRASTRUCTURE_GENERATOR.md
```


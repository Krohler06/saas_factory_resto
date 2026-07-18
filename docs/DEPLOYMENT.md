
Déploiement automatisé d’un tenant
Principe

Chaque client restaurant est isolé dans :

/opt/clients/<client_id>

Avec ses propres conteneurs :

<client_id>_postgres
<client_id>_n8n
Étapes de création

Le script create-tenant.sh doit :

créer le dossier client ;
générer le .env ;
copier le docker-compose.yml ;
copier les workflows ;
copier le SQL ;
démarrer PostgreSQL ;
appliquer le schéma ;
seeder restaurant + settings ;
démarrer n8n ;
importer les workflows ;
afficher l’URL webhook Retell ;
lancer les tests smoke.
URL webhook Retell

Format attendu :

https://<base_domain>/<client_id>/webhook/retell-voice-function

Exemple :

https://mydomaine.com/resto_demo/webhook/retell-voice-function
Route Caddy attendue

Le préfixe client doit être conservé jusqu’à n8n, sauf le préfixe public du tenant :

handle /__CLIENT_ID__/webhook/* {
        uri strip_prefix /__CLIENT_ID__
        reverse_proxy __CLIENT_ID___n8n:5678
}

Ne pas utiliser :

handle_path /__CLIENT_ID__/webhook/*

car cela peut transformer l’URL reçue par n8n en /retell-voice-function et provoquer :

Cannot POST /retell-voice-function
Credentials n8n

Les credentials n8n ne doivent pas être versionnés en clair.

Options possibles :

recréation manuelle dans n8n après déploiement ;
import credentials chiffrés avec même N8N_ENCRYPTION_KEY ;
automatisation ultérieure via API n8n ;
génération contrôlée via script dédié.

Pour l’instant, la factory privilégie une base saine sans secrets.

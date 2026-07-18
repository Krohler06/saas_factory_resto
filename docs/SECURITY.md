
Sécurité
Secrets interdits dans Git
mots de passe PostgreSQL ;
N8N_ENCRYPTION_KEY ;
tokens Retell ;
credentials n8n ;
clés API SMS/email ;
fichiers .env réels ;
exports complets de tenants.
Webhooks Retell

En production, les webhooks Retell doivent être vérifiés avec une signature ou une clé partagée.

Les tests curl affichent normalement :

RETELL_SIGNATURE_MISSING

C’est acceptable en test manuel, mais pas en production finale.

Recommandation

Chaque tenant doit avoir :

son propre mot de passe PostgreSQL ;
sa propre clé n8n ;
ses propres credentials ;
ses propres routes ;
ses propres workflows activés.

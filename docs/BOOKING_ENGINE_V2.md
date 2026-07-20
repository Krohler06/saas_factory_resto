# Booking Engine V2

## Statut

- Version documentaire : 0.1
- Source de vérité cible : `tenant.yml`
- Orchestration : n8n
- Base de données : PostgreSQL
- Canaux prévus : voix, SMS, e-mail, web et réseaux sociaux

## Objectif

Le moteur valide et enregistre les réservations. L’IA comprend la demande du client, mais la décision d’accepter ou refuser appartient au moteur métier.

## Principes

```text
tenant.yml
    ↓
validation
    ↓
génération
    ↓
PostgreSQL
    ↓
n8n
    ↓
Retell
```

Le wizard génère le YAML sans contenir de logique métier. Le générateur produit les fichiers et données. Le moteur applique les règles. L’agent conversationnel collecte les informations et reformule la décision.

## État actuel confirmé

Les identifiants sont en `BIGINT`.

Tables existantes :

- `restaurants`
- `restaurant_settings`
- `restaurant_closures`
- `reservations`

Tables V2 attendues :

- `restaurant_service_definitions`
- `restaurant_service_hours`
- `restaurant_areas`
- `restaurant_area_aliases`
- `restaurant_tables`
- `reservation_tables`

## Ordre de validation

1. Restaurant existant et actif.
2. Date résolue dans son fuseau horaire.
3. Délai minimum et fenêtre maximale.
4. Service ouvert et horaire réservable.
5. Fin de réservation compatible avec la fermeture.
6. Fermetures exceptionnelles et annuelles.
7. Taille du groupe.
8. Zone demandée.
9. Chevauchements et capacité.
10. Zone alternative.
11. Affectation de table si activée.
12. Décision JSON structurée.

## Chevauchement

```sql
existing.start_time < requested_end_time
AND existing.end_time > requested_start_time
```

## Modes d’allocation

```yaml
booking_engine:
  allocation_mode: area_capacity
```

Modes prévus : `global_capacity`, `area_capacity`, `table_assignment`.

## Règles de développement

- aucune donnée restaurant en dur dans les workflows ;
- aucun horaire en dur dans Retell ;
- aucune capacité en dur dans les nœuds Code ;
- migrations versionnées ;
- tests sans pollution de production ;
- exports sans secrets ;
- séparation stricte du schéma et des données tenant.

## Ordre d’implémentation

1. analyser la baseline SQL ;
2. analyser les workflows ;
3. figer les tables manquantes ;
4. écrire la migration SQL ;
5. écrire les seeds Little Africa ;
6. adapter le workflow ;
7. écrire les tests `curl` ;
8. valider ;
9. exporter ;
10. promouvoir dans le template ;
11. générer depuis le YAML ;
12. créer le wizard.


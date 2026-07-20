#!/usr/bin/env python3

import copy
import json
import re
import sys
import uuid
from pathlib import Path


POSTGRES_CREDENTIAL_ID = "SaasPgBusinessV2"
POSTGRES_CREDENTIAL_NAME = "Postgres @@CLIENT_ID@@"
GENERIC_WORKFLOW_ID = "SaasMultiChanV2a"

WEBHOOK_NAMESPACE = uuid.UUID(
    "2a94f0f8-4a76-4cb8-a35a-8c35877a90b2"
)

EXPECTED_NODES = {
    "Normalize Channel Input",
    "Lookup Restaurant Context",
    "Ensure Channel Logs Table",
    "Ensure Outbound Messages Table",
    "Save Channel Log",
    "Queue Outbound Message When Needed",
}

DDL_NODES_TO_REMOVE = {
    "Ensure Channel Logs Table",
    "Ensure Outbound Messages Table",
}

LOOKUP_RESTAURANT_QUERY = r"""
WITH input AS (
    SELECT
        {{ $('Verify Channel Source').item.json.restaurant_slug_sql }}::text
            AS requested_slug
)
SELECT
    r.id AS restaurant_id,
    r.slug,
    r.name,
    r.timezone,
    s.default_meal_duration_minutes,
    s.cleaning_buffer_minutes,
    s.grace_delay_minutes,
    s.max_party_size,
    s.allow_combined_tables,
    s.reminder_days_before,
    s.reminder_hour,
    s.reminder_channel,
    s.booking_policy,
    s.event_notification_policy
FROM restaurants r
JOIN restaurant_settings s
    ON s.restaurant_id = r.id
CROSS JOIN input i
WHERE r.is_active = TRUE
  AND (
      i.requested_slug IS NULL
      OR r.slug = i.requested_slug
  )
ORDER BY
    CASE
        WHEN i.requested_slug IS NOT NULL
         AND r.slug = i.requested_slug
        THEN 0
        ELSE 1
    END,
    r.id
LIMIT 1;
""".strip()


def fatal(message: str) -> None:
    print(f"[ERREUR] {message}", file=sys.stderr)
    raise SystemExit(1)


def load_workflow(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fatal(f"Workflow source absent : {path}")
    except json.JSONDecodeError as exc:
        fatal(f"JSON source invalide : {exc}")

    if isinstance(data, list):
        if len(data) != 1:
            fatal(
                "L'export contient "
                f"{len(data)} workflows au lieu d'un seul."
            )
        data = data[0]

    if not isinstance(data, dict):
        fatal("Le workflow doit être un objet JSON.")

    if not isinstance(data.get("nodes"), list):
        fatal("La propriété nodes est absente ou invalide.")

    if not isinstance(data.get("connections"), dict):
        fatal("La propriété connections est absente ou invalide.")

    return data


def node_map(workflow: dict) -> dict:
    return {
        node.get("name"): node
        for node in workflow["nodes"]
        if node.get("name")
    }


def get_single_successor(workflow: dict, node_name: str) -> dict:
    node_connections = (
        workflow["connections"]
        .get(node_name, {})
        .get("main", [])
    )

    successors = []

    for branch in node_connections:
        for edge in branch:
            successors.append(edge)

    if len(successors) != 1:
        fatal(
            f"Le nœud {node_name!r} doit avoir exactement "
            f"un successeur, trouvé : {len(successors)}"
        )

    return copy.deepcopy(successors[0])


def bypass_node(workflow: dict, node_name: str) -> None:
    successor = get_single_successor(workflow, node_name)

    for connection_data in workflow["connections"].values():
        for output_type, branches in connection_data.items():
            if not isinstance(branches, list):
                continue

            for branch in branches:
                if not isinstance(branch, list):
                    continue

                for index, edge in enumerate(branch):
                    if edge.get("node") == node_name:
                        branch[index] = copy.deepcopy(successor)

    workflow["connections"].pop(node_name, None)

    workflow["nodes"] = [
        node
        for node in workflow["nodes"]
        if node.get("name") != node_name
    ]


def normalize_workflow(workflow: dict) -> dict:
    workflow = copy.deepcopy(workflow)

    names = set(node_map(workflow))
    missing = sorted(EXPECTED_NODES - names)

    if missing:
        fatal(
            "Nœuds attendus absents : "
            + ", ".join(missing)
        )

    workflow["id"] = GENERIC_WORKFLOW_ID
    workflow["name"] = (
        "reservation_multichannel_router_"
        "@@CLIENT_ID@@_v2"
    )
    workflow["active"] = False

    # Champs générés par l'instance n8n source.
    for key in (
        "versionId",
        "activeVersionId",
        "createdAt",
        "updatedAt",
        "triggerCount",
        "shared",
    ):
        workflow.pop(key, None)

    # Les tables sont gérées par les migrations SQL,
    # jamais par le workflow en cours d'exécution.
    for node_name in DDL_NODES_TO_REMOVE:
        bypass_node(workflow, node_name)

    nodes = node_map(workflow)

    lookup_node = nodes.get("Lookup Restaurant Context")

    if lookup_node is None:
        fatal("Nœud Lookup Restaurant Context absent.")

    if "parameters" not in lookup_node:
        fatal(
            "Paramètres absents du nœud "
            "Lookup Restaurant Context."
        )

    lookup_node["parameters"]["query"] = (
        LOOKUP_RESTAURANT_QUERY
    )

    # Un seul restaurant actif existe dans la base isolée
    # de chaque tenant. Si aucun slug n'est fourni, la requête
    # sélectionne ce restaurant actif.
    normalize_node = nodes.get("Normalize Channel Input")

    if normalize_node is None:
        fatal("Nœud Normalize Channel Input absent.")

    js_code = (
        normalize_node
        .get("parameters", {})
        .get("jsCode")
    )

    if not isinstance(js_code, str):
        fatal(
            "Code JavaScript absent dans "
            "Normalize Channel Input."
        )

    # Supprime le canal historique utilisé pour le debug Telegram.
    js_code = re.sub(
        r",\s*['\"]telegram_debug['\"]",
        "",
        js_code,
    )

    normalize_node["parameters"]["jsCode"] = js_code

    postgres_nodes = 0
    webhook_nodes = 0

    for node in workflow["nodes"]:
        if node.get("type") == "n8n-nodes-base.postgres":
            postgres_nodes += 1
            node["credentials"] = {
                "postgres": {
                    "id": POSTGRES_CREDENTIAL_ID,
                    "name": POSTGRES_CREDENTIAL_NAME,
                }
            }

        if node.get("type") == "n8n-nodes-base.webhook":
            webhook_nodes += 1

            deterministic_webhook_id = uuid.uuid5(
                WEBHOOK_NAMESPACE,
                "saas-factory:"
                + str(node.get("name", "")),
            )

            node["webhookId"] = str(
                deterministic_webhook_id
            )

    if webhook_nodes != 5:
        fatal(
            "Nombre inattendu de webhooks : "
            f"{webhook_nodes}, attendu : 5"
        )

    if postgres_nodes != 7:
        fatal(
            "Nombre inattendu de nœuds PostgreSQL après "
            f"nettoyage : {postgres_nodes}, attendu : 7"
        )

    return workflow


def validate_output(workflow: dict) -> None:
    serialized = json.dumps(
        workflow,
        ensure_ascii=False,
    )

    forbidden_values = (
        "Postgres Little Africa",
        "oIKfFfyMDZkHhOm4",
        "reservation_multichannel_router_little_africa",
        "telegram_debug",
    )

    found = [
        value
        for value in forbidden_values
        if value.lower() in serialized.lower()
    ]

    if found:
        fatal(
            "Valeurs spécifiques restantes : "
            + ", ".join(found)
        )

    node_names = {
        node.get("name")
        for node in workflow["nodes"]
    }

    unexpected_ddl_nodes = (
        DDL_NODES_TO_REMOVE & node_names
    )

    if unexpected_ddl_nodes:
        fatal(
            "Nœuds DDL encore présents : "
            + ", ".join(sorted(unexpected_ddl_nodes))
        )

    if workflow.get("active") is not False:
        fatal(
            "Le modèle doit rester inactif avant validation."
        )


def main() -> None:
    if len(sys.argv) != 3:
        print(
            "Usage: build-generic-multichannel-workflow.py "
            "SOURCE.json DESTINATION.json",
            file=sys.stderr,
        )
        raise SystemExit(2)

    source = Path(sys.argv[1]).resolve()
    destination = Path(sys.argv[2]).resolve()

    workflow = load_workflow(source)
    generic_workflow = normalize_workflow(workflow)
    validate_output(generic_workflow)

    destination.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    destination.write_text(
        json.dumps(
            generic_workflow,
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    postgres_nodes = sum(
        node.get("type") == "n8n-nodes-base.postgres"
        for node in generic_workflow["nodes"]
    )

    webhook_nodes = sum(
        node.get("type") == "n8n-nodes-base.webhook"
        for node in generic_workflow["nodes"]
    )

    print(f"[OK] Modèle généré : {destination}")
    print(f"[OK] Nom : {generic_workflow['name']}")
    print(f"[OK] ID : {generic_workflow['id']}")
    print(
        f"[OK] Nœuds : "
        f"{len(generic_workflow['nodes'])}"
    )
    print(f"[OK] Webhooks : {webhook_nodes}")
    print(f"[OK] Nœuds PostgreSQL : {postgres_nodes}")
    print(
        "[OK] Credential attendu : "
        f"{POSTGRES_CREDENTIAL_ID}"
    )
    print("[OK] Workflow inactif par sécurité")


if __name__ == "__main__":
    main()

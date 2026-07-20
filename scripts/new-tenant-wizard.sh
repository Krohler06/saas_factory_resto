#!/usr/bin/env bash
set -Eeuo pipefail

FACTORY_DIR="${FACTORY_DIR:-/root/saas_factory}"
OUTPUT_FILE="${1:-}"
TMPDIR_WIZARD="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WIZARD"' EXIT

fatal() {
  printf '\033[1;31m[ERREUR]\033[0m %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fatal "Commande absente : $1"
}

cancelled() {
  clear || true
  fatal "Wizard annulé."
}

ask() {
  local title="$1" prompt="$2" default_value="${3:-}" result
  result="$(whiptail --title "$title" --inputbox "$prompt" 12 78 "$default_value" 3>&1 1>&2 2>&3)" || cancelled
  printf '%s' "$result"
}

password() {
  local title="$1" prompt="$2" result
  result="$(whiptail --title "$title" --passwordbox "$prompt" 12 78 3>&1 1>&2 2>&3)" || cancelled
  printf '%s' "$result"
}

yesno() {
  local title="$1" prompt="$2" default_mode="${3:-yes}"
  local args=(--title "$title" --yesno "$prompt" 12 78)
  [[ "$default_mode" == "no" ]] && args+=(--defaultno)
  whiptail "${args[@]}" 3>&1 1>&2 2>&3
}

checklist() {
  local title="$1" prompt="$2" rows="$3"
  shift 3
  local result
  result="$(whiptail --title "$title" --checklist "$prompt" 24 90 "$rows" "$@" 3>&1 1>&2 2>&3)" || cancelled
  printf '%s' "$result"
}

menu() {
  local title="$1" prompt="$2" rows="$3"
  shift 3
  local result
  result="$(whiptail --title "$title" --menu "$prompt" 22 90 "$rows" "$@" 3>&1 1>&2 2>&3)" || cancelled
  printf '%s' "$result"
}

selected_lines() {
  python3 - "$1" <<'PY'
import shlex, sys
for item in shlex.split(sys.argv[1]):
    print(item)
PY
}

slugify() {
  python3 - "$1" <<'PY'
import re, sys, unicodedata
value = unicodedata.normalize("NFKD", sys.argv[1]).encode("ascii", "ignore").decode().lower()
value = re.sub(r"[^a-z0-9]+", "_", value).strip("_")
print(value or "restaurant")
PY
}

valid_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

ask_int() {
  local title="$1" prompt="$2" default_value="$3" min="$4" max="$5" value
  while true; do
    value="$(ask "$title" "$prompt" "$default_value")"
    if valid_int "$value" && (( value >= min && value <= max )); then
      printf '%s' "$value"
      return
    fi
    whiptail --title "Valeur invalide" --msgbox "Saisir un entier compris entre $min et $max." 10 70
  done
}

sanitize_field() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

for cmd in whiptail python3 awk sed grep; do need "$cmd"; done
python3 -c 'import yaml' >/dev/null 2>&1 || fatal "PyYAML absent : apt-get install -y python3-yaml"

mkdir -p "$FACTORY_DIR/tenants/private"

whiptail --title "Restaurant SaaS Factory" --msgbox \
"Ce wizard crée un tenant.yml validable et rejouable.\n\nIl ne déploie rien et ne modifie aucune base." 13 78

restaurant_name="$(ask "Informations générales" "Nom public du restaurant" "Restaurant Démo")"
default_slug="$(slugify "$restaurant_name")"
client_id="$(ask "Informations générales" "Identifiant technique du tenant" "$default_slug")"
restaurant_slug="$(ask "Informations générales" "Slug du restaurant présent dans PostgreSQL" "$client_id")"
timezone="$(ask "Informations générales" "Fuseau horaire IANA" "Europe/Paris")"

if [[ -z "$OUTPUT_FILE" ]]; then
  OUTPUT_FILE="$FACTORY_DIR/tenants/private/${client_id}.yml"
fi

if [[ -e "$OUTPUT_FILE" ]]; then
  yesno "Fichier existant" "$OUTPUT_FILE existe déjà. L'écraser ?" "no" || cancelled
fi

allocation_mode="$(menu "Moteur de réservation" "Choisir le mode d'allocation" 3 \
  global_capacity "Capacité globale uniquement" \
  area_capacity "Capacité par zone (recommandé)" \
  table_assignment "Tables physiques détaillées")"

minimum_advance="$(ask_int "Moteur de réservation" "Délai minimum avant réservation, en minutes" "60" 0 10080)"
maximum_advance="$(ask_int "Moteur de réservation" "Nombre maximum de jours à l'avance" "90" 1 730)"
max_party="$(ask_int "Moteur de réservation" "Taille maximale d'un groupe" "12" 1 500)"
default_slot="$(ask_int "Moteur de réservation" "Intervalle par défaut entre créneaux, en minutes" "15" 5 240)"
cleaning_buffer="$(ask_int "Moteur de réservation" "Buffer de nettoyage, en minutes" "15" 0 240)"
closure_years="$(ask_int "Moteur de réservation" "Nombre d'années futures pour les fermetures annuelles" "5" 1 10)"

allow_combinations=false
maximum_combined=1
if [[ "$allocation_mode" == "table_assignment" ]]; then
  if yesno "Combinaison de tables" "Autoriser les combinaisons de tables ?" "no"; then
    allow_combinations=true
    maximum_combined="$(ask_int "Combinaison de tables" "Nombre maximal de tables combinées" "3" 1 20)"
  fi
fi

services_tsv="$TMPDIR_WIZARD/services.tsv"
schedule_tsv="$TMPDIR_WIZARD/schedule.tsv"
areas_tsv="$TMPDIR_WIZARD/areas.tsv"
tables_tsv="$TMPDIR_WIZARD/tables.tsv"
recurring_tsv="$TMPDIR_WIZARD/recurring.tsv"
exceptional_tsv="$TMPDIR_WIZARD/exceptional.tsv"
: > "$services_tsv"; : > "$schedule_tsv"; : > "$areas_tsv"; : > "$tables_tsv"; : > "$recurring_tsv"; : > "$exceptional_tsv"

service_selection="$(checklist "Services" "Sélectionner les services proposés" 7 \
  breakfast "Petit-déjeuner" OFF \
  brunch "Brunch" OFF \
  lunch "Déjeuner" ON \
  afternoon "Goûter / après-midi" OFF \
  dinner "Dîner" ON \
  late_night "Service tardif" OFF \
  custom "Ajouter des services personnalisés" OFF)"
mapfile -t selected_services < <(selected_lines "$service_selection")
((${#selected_services[@]} > 0)) || fatal "Au moins un service est requis."

service_defaults() {
  case "$1" in
    breakfast) echo "Petit-déjeuner|90|15|07:00|07:00|10:00|11:00" ;;
    brunch) echo "Brunch|120|15|10:00|10:00|13:30|15:00" ;;
    lunch) echo "Déjeuner|120|15|11:30|12:00|13:30|15:00" ;;
    afternoon) echo "Goûter|90|15|15:00|15:00|17:00|18:00" ;;
    dinner) echo "Dîner|120|15|18:30|19:00|21:30|23:30" ;;
    late_night) echo "Service tardif|120|15|21:30|22:00|23:30|02:00" ;;
    *) echo "Service|120|15|12:00|12:00|13:30|15:00" ;;
  esac
}

service_tags=()
priority=10
for tag in "${selected_services[@]}"; do
  [[ "$tag" == "custom" ]] && continue
  IFS='|' read -r def_name def_duration def_interval def_open def_first def_last def_close <<< "$(service_defaults "$tag")"
  name="$(ask "Service : $tag" "Nom affiché" "$def_name")"
  duration="$(ask_int "Service : $tag" "Durée moyenne, en minutes" "$def_duration" 15 1440)"
  interval="$(ask_int "Service : $tag" "Intervalle des créneaux, en minutes" "$def_interval" 5 240)"
  opens="$(ask "Horaires par défaut : $name" "Ouverture" "$def_open")"
  first="$(ask "Horaires par défaut : $name" "Première réservation" "$def_first")"
  last="$(ask "Horaires par défaut : $name" "Dernière réservation" "$def_last")"
  closes="$(ask "Horaires par défaut : $name" "Fermeture" "$def_close")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tag" "$(sanitize_field "$name")" "$duration" "$interval" "$priority" "$opens" "$first" "$last" "$closes" >> "$services_tsv"
  service_tags+=("$tag")
  priority=$((priority + 10))
done

if printf '%s\n' "${selected_services[@]}" | grep -Fxq custom; then
  while true; do
    custom_name="$(ask "Service personnalisé" "Nom affiché du service" "Afterwork")"
    custom_slug="$(ask "Service personnalisé" "Slug technique" "$(slugify "$custom_name")")"
    [[ " ${service_tags[*]} " == *" $custom_slug "* ]] && fatal "Service déjà présent : $custom_slug"
    duration="$(ask_int "Service : $custom_name" "Durée moyenne, en minutes" "120" 15 1440)"
    interval="$(ask_int "Service : $custom_name" "Intervalle des créneaux, en minutes" "15" 5 240)"
    opens="$(ask "Horaires par défaut : $custom_name" "Ouverture" "18:00")"
    first="$(ask "Horaires par défaut : $custom_name" "Première réservation" "$opens")"
    last="$(ask "Horaires par défaut : $custom_name" "Dernière réservation" "20:00")"
    closes="$(ask "Horaires par défaut : $custom_name" "Fermeture" "21:30")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$custom_slug" "$(sanitize_field "$custom_name")" "$duration" "$interval" "$priority" "$opens" "$first" "$last" "$closes" >> "$services_tsv"
    service_tags+=("$custom_slug")
    priority=$((priority + 10))
    yesno "Services personnalisés" "Ajouter un autre service personnalisé ?" "no" || break
  done
fi

service_check_args=()
while IFS=$'\t' read -r slug name _; do
  service_check_args+=("$slug" "$name" ON)
done < "$services_tsv"

open_days="$(checklist "Jours d'ouverture" "Sélectionner les jours habituellement ouverts" 7 \
  monday "Lundi" ON \
  tuesday "Mardi" ON \
  wednesday "Mercredi" ON \
  thursday "Jeudi" ON \
  friday "Vendredi" ON \
  saturday "Samedi" ON \
  sunday "Dimanche" OFF)"
mapfile -t selected_days < <(selected_lines "$open_days")
((${#selected_days[@]} > 0)) || fatal "Au moins un jour ouvert est requis."

day_label() {
  case "$1" in
    monday) echo Lundi;; tuesday) echo Mardi;; wednesday) echo Mercredi;; thursday) echo Jeudi;;
    friday) echo Vendredi;; saturday) echo Samedi;; sunday) echo Dimanche;;
  esac
}

for day in "${selected_days[@]}"; do
  label="$(day_label "$day")"
  active="$(checklist "Services du $label" "Choisir les services ouverts le $label" "${#service_tags[@]}" "${service_check_args[@]}")"
  mapfile -t day_services < <(selected_lines "$active")
  for service_slug in "${day_services[@]}"; do
    line="$(awk -F '\t' -v slug="$service_slug" '$1==slug {print; exit}' "$services_tsv")"
    IFS=$'\t' read -r _ service_name _ _ _ def_open def_first def_last def_close <<< "$line"
    opens="$def_open"; first="$def_first"; last="$def_last"; closes="$def_close"
    if ! yesno "$label - $service_name" "Utiliser les horaires par défaut ?\n\n$def_open / $def_first / $def_last / $def_close" "yes"; then
      opens="$(ask "$label - $service_name" "Ouverture" "$def_open")"
      first="$(ask "$label - $service_name" "Première réservation" "$def_first")"
      last="$(ask "$label - $service_name" "Dernière réservation" "$def_last")"
      closes="$(ask "$label - $service_name" "Fermeture" "$def_close")"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$day" "$service_slug" "$opens" "$first" "$last" "$closes" >> "$schedule_tsv"
  done
done

if [[ "$allocation_mode" != "global_capacity" ]]; then
  area_priority=10
  while true; do
    area_name="$(ask "Zones" "Nom de la zone" "Salle principale")"
    area_slug="$(ask "Zones" "Slug de la zone" "$(slugify "$area_name")")"
    [[ -n "$(awk -F '\t' -v slug="$area_slug" '$1==slug {print}' "$areas_tsv")" ]] && fatal "Zone déjà présente : $area_slug"
    capacity="$(ask_int "Zone : $area_name" "Capacité maximale" "20" 1 10000)"
    floor_label="$(ask "Zone : $area_name" "Étage ou emplacement, facultatif" "")"
    aliases="$(ask "Zone : $area_name" "Alias conversationnels séparés par des virgules" "$area_name")"
    selectable=false; accessible=false
    yesno "Zone : $area_name" "Le client peut-il demander cette zone ?" "yes" && selectable=true
    yesno "Zone : $area_name" "Zone accessible PMR ?" "yes" && accessible=true
    printf '%s\t%s\t%s\t%s\ttrue\t%s\t%s\t%s\t%s\n' \
      "$area_slug" "$(sanitize_field "$area_name")" "$capacity" "$area_priority" "$selectable" "$accessible" "$(sanitize_field "$floor_label")" "$(sanitize_field "$aliases")" >> "$areas_tsv"
    area_priority=$((area_priority + 10))
    yesno "Zones" "Ajouter une autre zone ?" "yes" || break
  done
fi

if [[ "$allocation_mode" == "table_assignment" ]]; then
  while IFS=$'\t' read -r area_slug area_name area_capacity _; do
    counter=1
    while true; do
      quantity="$(ask_int "Tables - $area_name" "Nombre de tables à générer dans ce lot" "4" 1 500)"
      max_capacity="$(ask_int "Tables - $area_name" "Capacité maximale de chaque table" "2" 1 "$area_capacity")"
      min_capacity="$(ask_int "Tables - $area_name" "Capacité minimale de chaque table" "1" 1 "$max_capacity")"
      prefix="$(ask "Tables - $area_name" "Préfixe des codes" "$(printf '%s' "$area_slug" | cut -c1-3 | tr '[:lower:]' '[:upper:]')-T")"
      combinable=false; group=""
      if [[ "$allow_combinations" == true ]] && yesno "Tables - $area_name" "Ces tables sont-elles combinables entre elles ?" "no"; then
        combinable=true
        group="$(ask "Tables - $area_name" "Nom du groupe de combinaison" "${area_slug}-groupe-1")"
      fi
      for ((i=0; i<quantity; i++)); do
        code="${prefix}$(printf '%02d' "$counter")"
        printf '%s\t%s\t%s\t%s\t%s\ttrue\t%s\t%s\t%s\n' \
          "$code" "$area_slug" "$min_capacity" "$max_capacity" "$counter" "$combinable" "$(sanitize_field "$group")" "$code" >> "$tables_tsv"
        counter=$((counter + 1))
      done
      yesno "Tables - $area_name" "Ajouter un autre lot de tables dans cette zone ?" "no" || break
    done
  done < "$areas_tsv"
fi

if yesno "Fermetures annuelles" "Configurer des jours de fermeture récurrents ?" "yes"; then
  while true; do
    closure_name="$(ask "Fermeture annuelle" "Nom" "Noël")"
    closure_slug="$(ask "Fermeture annuelle" "Slug" "$(slugify "$closure_name")")"
    date_value="$(ask "Fermeture annuelle" "Date au format JJ-MM" "25-12")"
    day="${date_value%%-*}"; month="${date_value##*-}"
    all_day=true; services_csv=""
    if ! yesno "Fermeture annuelle" "Fermeture toute la journée ?" "yes"; then
      all_day=false
      selected="$(checklist "Fermeture annuelle" "Services concernés" "${#service_tags[@]}" "${service_check_args[@]}")"
      mapfile -t closure_services < <(selected_lines "$selected")
      services_csv="$(IFS=,; echo "${closure_services[*]}")"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$closure_slug" "$(sanitize_field "$closure_name")" "$month" "$day" "$all_day" "$services_csv" >> "$recurring_tsv"
    yesno "Fermetures annuelles" "Ajouter une autre fermeture annuelle ?" "no" || break
  done
fi

if yesno "Fermetures exceptionnelles" "Ajouter une fermeture exceptionnelle déjà connue ?" "no"; then
  while true; do
    closure_name="$(ask "Fermeture exceptionnelle" "Nom" "Travaux")"
    closure_slug="$(ask "Fermeture exceptionnelle" "Slug" "$(slugify "$closure_name")")"
    starts_at="$(ask "Fermeture exceptionnelle" "Début ISO avec fuseau" "2027-02-12T00:00:00+01:00")"
    ends_at="$(ask "Fermeture exceptionnelle" "Fin ISO avec fuseau" "2027-02-13T00:00:00+01:00")"
    all_day=false; yesno "Fermeture exceptionnelle" "Fermeture en journée entière ?" "yes" && all_day=true
    printf '%s\t%s\t%s\t%s\t%s\n' "$closure_slug" "$(sanitize_field "$closure_name")" "$starts_at" "$ends_at" "$all_day" >> "$exceptional_tsv"
    yesno "Fermetures exceptionnelles" "Ajouter une autre fermeture exceptionnelle ?" "no" || break
  done
fi

python3 - "$TMPDIR_WIZARD" "$OUTPUT_FILE" <<PY
from pathlib import Path
import csv, sys, yaml

tmp = Path(sys.argv[1]); output = Path(sys.argv[2])

def rows(name):
    path = tmp / name
    if not path.exists(): return []
    with path.open(encoding='utf-8', newline='') as f:
        return list(csv.reader(f, delimiter='\t'))

def b(value): return str(value).lower() == 'true'
def aliases(value): return [x.strip() for x in value.split(',') if x.strip()]

service_rows = rows('services.tsv')
service_definitions=[]
default_hours={}
for slug,name,duration,interval,priority,opens,first,last,closes in service_rows:
    service_definitions.append({
        'slug':slug,'name':name,'default_duration_minutes':int(duration),
        'slot_interval_minutes':int(interval),'priority':int(priority)
    })
    default_hours[slug]=(opens,first,last,closes)

schedule_rows = rows('schedule.tsv')
weekly={day:{'enabled':False,'services':{}} for day in ['monday','tuesday','wednesday','thursday','friday','saturday','sunday']}
for day,slug,opens,first,last,closes in schedule_rows:
    weekly[day]['enabled']=True
    weekly[day]['services'][slug]={
        'enabled':True,'opens_at':opens,'first_booking_at':first,
        'last_booking_at':last,'closes_at':closes
    }

areas=[]
for slug,name,capacity,priority,enabled,selectable,accessible,floor_label,alias_csv in rows('areas.tsv'):
    area={'slug':slug,'name':name,'capacity':int(capacity),'priority':int(priority),
          'enabled':b(enabled),'customer_selectable':b(selectable),'accessible':b(accessible),
          'aliases':aliases(alias_csv)}
    if floor_label: area['floor_label']=floor_label
    areas.append(area)

tables=[]
for code,area,mincap,maxcap,priority,enabled,combinable,group,name in rows('tables.tsv'):
    item={'code':code,'name':name or None,'area':area,'min_capacity':int(mincap),
          'max_capacity':int(maxcap),'priority':int(priority),'enabled':b(enabled),
          'is_combinable':b(combinable)}
    if group: item['combination_group']=group
    tables.append(item)

recurring=[]
for slug,name,month,day,all_day,services_csv in rows('recurring.tsv'):
    item={'slug':slug,'name':name,'recurrence_type':'annual_date','month':int(month),
          'day':int(day),'all_day':b(all_day)}
    service_list=aliases(services_csv)
    if service_list: item['services']=service_list
    recurring.append(item)

exceptional=[]
for slug,name,starts,ends,all_day in rows('exceptional.tsv'):
    exceptional.append({'slug':slug,'name':name,'starts_at':starts,'ends_at':ends,'all_day':b(all_day)})

config={
 'version':1,
 'tenant':{'client_id':${client_id@Q},'restaurant_slug':${restaurant_slug@Q},'restaurant_name':${restaurant_name@Q}},
 'restaurant':{'timezone':${timezone@Q},'active':True},
 'booking_engine':{
   'allocation_mode':${allocation_mode@Q},'minimum_advance_minutes':int(${minimum_advance@Q}),
   'maximum_advance_days':int(${maximum_advance@Q}),'max_party_size':int(${max_party@Q}),
   'default_slot_interval_minutes':int(${default_slot@Q}),
   'default_cleaning_buffer_minutes':int(${cleaning_buffer@Q}),
   'allow_table_combinations':${allow_combinations^},'maximum_combined_tables':int(${maximum_combined@Q}),
   'recurring_closure_years':int(${closure_years@Q})
 },
 'service_definitions':service_definitions,'weekly_schedule':weekly,'areas':areas,
 'recurring_closures':recurring,'exceptional_closures':exceptional,'tables':tables
}
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(yaml.safe_dump(config, allow_unicode=True, sort_keys=False), encoding='utf-8')
print(output)
PY

validator="$FACTORY_DIR/scripts/validate-tenant.py"
[[ -x "$validator" ]] || fatal "Validateur absent : $validator"
if ! "$validator" "$OUTPUT_FILE"; then
  fatal "Le YAML a été créé mais sa validation a échoué : $OUTPUT_FILE"
fi

summary="Tenant : $client_id\nFichier : $OUTPUT_FILE\nServices : ${#service_tags[@]}\nZones : $(wc -l < "$areas_tsv")\nTables : $(wc -l < "$tables_tsv")"
whiptail --title "Wizard terminé" --msgbox "$summary" 14 78
clear || true
printf '[OK] Tenant créé : %s\n' "$OUTPUT_FILE"
printf '[OK] Validation réussie.\n'


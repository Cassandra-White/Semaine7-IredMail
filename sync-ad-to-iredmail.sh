#!/bin/bash
# =============================================================================
# sync-ad-to-iredmail.sh
# Script de synchronisation Active Directory → iRedMail (MariaDB)
# =============================================================================

set -euo pipefail

# ── CONFIGURATION ─────────────────────────────────────────────────────────────

AD_SERVER="172.16.100.1"
AD_SERVER_BACKUP="172.16.100.2"
AD_BASE="OU=Utilisateurs,OU=paris,OU=France,OU=BillU,DC=billu,DC=local"
AD_BIND_DN="CN=iRedMail Service,OU=Utilisateurs,OU=paris,OU=France,OU=BillU,DC=billu,DC=local"
AD_BIND_PWD="Azerty1*,,,,!"

DB_HOST="localhost"
DB_USER="root"
DB_PASS="azerty1*"     # ← ton mot de passe MariaDB root
DB_NAME="vmail"

IREDMAIL_DOMAIN="billu.com"
DEFAULT_QUOTA_MB=1024               # quota par défaut en Mo (0 = illimité)
MAIL_BASE_DIR="/var/vmail"
MAIL_STORAGE_NODE="vmail1"

# ── FONCTIONS UTILITAIRES ──────────────────────────────────────────────────────

log()      { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
log_ok()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $1"; }
log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️  $1"; }
log_err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $1"; }
log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ℹ️  $1"; }

sql_query() {
    mysql --defaults-extra-file=<(printf "[client]\nuser=%s\npassword=%s\nhost=%s\n" \
        "$DB_USER" "$DB_PASS" "$DB_HOST") \
        "$DB_NAME" --batch --skip-column-names -e "$1" 2>/dev/null
}

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        log_err "Commande '$1' non trouvée. Installe-la : apt install $2"
        exit 1
    fi
}

generate_placeholder_password() {
    local rnd
    rnd=$(head /dev/urandom | tr -dc 'A-Za-z0-9!@#$%' | head -c 32)
    doveadm pw -s SSHA512 -p "$rnd" 2>/dev/null || echo "{SSHA512}PLACEHOLDER"
}

build_maildir() {
    local email="$1"
    local lp="${email%%@*}"
    local dom="${email##*@}"
    local ts; ts=$(date '+%Y.%m.%d.%H.%M.%S')
    local c1="${lp:0:1}" c2="${lp:1:1}" c3="${lp:2:1}"
    [ -z "$c2" ] && c2="$c1"
    [ -z "$c3" ] && c3="$c2"
    echo "${dom}/${c1}/${c2}/${c3}/${lp}-${ts}/"
}

# ── VÉRIFICATIONS PRÉLIMINAIRES ────────────────────────────────────────────────

preflight_checks() {
    log "=== Vérifications préliminaires ==="
    require_cmd ldapsearch "ldap-utils"
    require_cmd mysql      "default-mysql-client"
    require_cmd doveadm    "(installé par iRedMail)"

    # Test connexion AD (primaire puis secondaire)
    if ldapsearch -x -H "ldap://$AD_SERVER" \
        -D "$AD_BIND_DN" -w "$AD_BIND_PWD" \
        -b "$AD_BASE" "(objectClass=user)" dn 2>/dev/null | grep -q "^dn:"; then
        log_ok "AD primaire ($AD_SERVER) : OK"
        ACTIVE_AD_SERVER="$AD_SERVER"
    elif ldapsearch -x -H "ldap://$AD_SERVER_BACKUP" \
        -D "$AD_BIND_DN" -w "$AD_BIND_PWD" \
        -b "$AD_BASE" "(objectClass=user)" dn 2>/dev/null | grep -q "^dn:"; then
        log_warn "AD primaire indisponible → basculement sur $AD_SERVER_BACKUP"
        ACTIVE_AD_SERVER="$AD_SERVER_BACKUP"
    else
        log_err "Impossible de joindre l'AD. Vérifie la connectivité et le compte de service."
        exit 1
    fi

    # Test connexion MariaDB
    sql_query "SELECT 1;" &>/dev/null || {
        log_err "Connexion MariaDB échouée. Vérifie DB_PASS dans le script."
        exit 1
    }
    log_ok "MariaDB : OK"

    # Vérifier que le domaine existe dans iRedMail
    local cnt; cnt=$(sql_query "SELECT COUNT(*) FROM domain WHERE domain='$IREDMAIL_DOMAIN';")
    [ "$cnt" -eq 0 ] && {
        log_err "Domaine '$IREDMAIL_DOMAIN' absent d'iRedMail. Crée-le via iRedAdmin."
        exit 1
    }
    log_ok "Domaine '$IREDMAIL_DOMAIN' : présent dans iRedMail"
}

# ── RÉCUPÉRATION ET PARSING DES UTILISATEURS AD ───────────────────────────────

# Retourne les utilisateurs AD avec une adresse @billu.com
fetch_ad_users() {
    ldapsearch -x \
        -H "ldap://$ACTIVE_AD_SERVER" \
        -D "$AD_BIND_DN" \
        -w "$AD_BIND_PWD" \
        -b "$AD_BASE" \
        "(&(objectClass=user)(objectCategory=person)(mail=*@${IREDMAIL_DOMAIN}))" \
        mail displayName userAccountControl sAMAccountName 2>/dev/null
}

# Parse la sortie LDAP et émet : email|displayName|is_disabled(0/1)
parse_ad_users() {
    local ldap_output="$1"
    local mail="" display="" uac="" sam=""

    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            if [[ -n "$mail" ]]; then
                local disabled=0
                [[ -n "$uac" ]] && (( uac & 2 )) && disabled=1
                echo "${mail}|${display:-$sam}|${disabled}"
            fi
            mail="" display="" uac="" sam=""
            continue
        fi
        [[ "$line" =~ ^mail:\ (.+)$                  ]] && mail="${BASH_REMATCH[1]}"
        [[ "$line" =~ ^displayName:\ (.+)$           ]] && display="${BASH_REMATCH[1]}"
        [[ "$line" =~ ^userAccountControl:\ (.+)$    ]] && uac="${BASH_REMATCH[1]}"
        [[ "$line" =~ ^sAMAccountName:\ (.+)$        ]] && sam="${BASH_REMATCH[1]}"
    done <<< "$ldap_output"

    # Dernier bloc sans ligne vide finale
    if [[ -n "$mail" ]]; then
        local disabled=0
        [[ -n "$uac" ]] && (( uac & 2 )) && disabled=1
        echo "${mail}|${display:-$sam}|${disabled}"
    fi
}

# ── OPÉRATIONS SUR LES COMPTES ────────────────────────────────────────────────

create_iredmail_user() {
    local email="$1" display_name="$2"
    local lp="${email%%@*}" dom="${email##*@}"
    local maildir; maildir=$(build_maildir "$email")
    local quota_kb=$(( DEFAULT_QUOTA_MB * 1024 ))
    local pw; pw=$(generate_placeholder_password)
    local now; now=$(date '+%Y-%m-%d %H:%M:%S')
    local dn_escaped="${display_name//\'/\'\'}"

    log_info "Création : $email (${display_name})"

    sql_query "
    INSERT INTO mailbox (
        username, password, name,
        storagebasedirectory, storagenode, maildir,
        quota, domain, transport, rank,
        isadmin, isglobaladmin,
        enablesmtp, enablesmtpsecured, enablepop3, enablepop3secured,
        enableimap, enableimapsecured, enabledeliver, enableinternal,
        enabledoveadm, enablelmtp, enabledsync,
        active, local_part, created, modified, expired
    ) VALUES (
        '${email}', '${pw}', '${dn_escaped}',
        '${MAIL_BASE_DIR}', '${MAIL_STORAGE_NODE}', '${maildir}',
        ${quota_kb}, '${dom}', 'dovecot', 'normal',
        0, 0,
        1, 1, 1, 1,
        1, 1, 1, 1,
        1, 1, 1,
        1, '${lp}', '${now}', '${now}', '9999-12-31 00:00:00'
    );" || { log_err "Échec INSERT pour $email"; return 1; }

    # Entrée dans la table forwardings (nécessaire pour la délivrabilité)
    sql_query "
    INSERT IGNORE INTO forwardings
        (address, forwarding, domain, dest_domain, is_list, is_forwarding, active)
    VALUES ('${email}', '${email}', '${dom}', '${dom}', 0, 0, 1);
    " 2>/dev/null || true

    # Créer le répertoire maildir physique
    local full_dir="${MAIL_BASE_DIR}/${maildir}"
    mkdir -p "$full_dir" && chown -R vmail:vmail "$full_dir" 2>/dev/null || \
        log_warn "Impossible de créer $full_dir (non bloquant)"

    log_ok "Boîte créée : $email"
}

update_display_name() {
    local email="$1" new_name="$2"
    sql_query "UPDATE mailbox SET name='${new_name//\'/\'\'}', modified=NOW() WHERE username='${email}';"
    log_info "Nom mis à jour : $email → $new_name"
}

set_account_active() {
    local email="$1" active="$2"
    sql_query "UPDATE mailbox SET active=${active}, modified=NOW() WHERE username='${email}';"
    [ "$active" -eq 1 ] && log_ok "Compte réactivé : $email" || log_warn "Compte désactivé : $email"
}

# ── BOUCLE PRINCIPALE ─────────────────────────────────────────────────────────

sync_users() {
    local raw; raw=$(fetch_ad_users)
    [[ -z "$raw" ]] && { log_warn "Aucun utilisateur trouvé dans l'AD (vérifie l'OU et le champ mail)."; return; }

    local parsed; parsed=$(parse_ad_users "$raw")
    local total=0 created=0 updated=0 disabled_count=0 skipped=0 errors=0

    log "=== Traitement des utilisateurs ==="

    while IFS='|' read -r email display is_disabled; do
        [[ -z "$email" ]] && continue
        (( total++ )) || true

        local row
        row=$(sql_query "SELECT username, name, active FROM mailbox WHERE username='${email}';")

        if [[ -z "$row" ]]; then
            # Utilisateur absent d'iRedMail
            if [[ "$is_disabled" -eq 1 ]]; then
                log_warn "Ignoré (AD désactivé) : $email"
                (( skipped++ )) || true
            else
                create_iredmail_user "$email" "$display" \
                    && (( created++ )) || true \
                    || (( errors++ )) || true
            fi
        else
            # Utilisateur déjà présent → synchroniser l'état et le nom
            local db_name db_active
            db_name=$(echo "$row"   | awk -F'\t' '{print $2}')
            db_active=$(echo "$row" | awk -F'\t' '{print $3}')

            if [[ "$is_disabled" -eq 1 && "$db_active" -eq 1 ]]; then
                set_account_active "$email" 0; (( disabled_count++ )) || true
            elif [[ "$is_disabled" -eq 0 && "$db_active" -eq 0 ]]; then
                set_account_active "$email" 1; (( updated++ )) || true
            fi

            if [[ -n "$display" && "$display" != "$db_name" ]]; then
                update_display_name "$email" "$display"; (( updated++ )) || true
            else
                (( skipped++ )) || true
            fi
        fi
    done <<< "$parsed"

    log ""
    log "========================================"
    log "  RAPPORT"
    log "========================================"
    log "  Utilisateurs AD trouvés  : $total"
    log_ok  "  Créés                    : $created"
    log_info "  Mis à jour               : $updated"
    log_warn "  Désactivés               : $disabled_count"
    log_info "  Inchangés / ignorés      : $skipped"
    [ "$errors" -gt 0 ] && log_err "  Erreurs                  : $errors"
    log "========================================"
}

# ── POINT D'ENTRÉE ────────────────────────────────────────────────────────────

log ""
log "========================================"
log "  SYNC AD → iRedMail  |  $(date '+%Y-%m-%d %H:%M:%S')"
log "========================================"
preflight_checks
sync_users
log "=== Terminé ==="

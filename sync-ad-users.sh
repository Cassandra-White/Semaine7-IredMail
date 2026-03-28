#!/bin/bash
# Script de synchronisation AD vers iRedMail
# À exécuter régulièrement via cron

AD_SERVER="172.16.100.1"
AD_BASE="OU=Mail Users,DC=billu,DC=local"
AD_BIND_DN="CN=iRedMail Service,OU=Mail Users,DC=billu,DC=local"
AD_BIND_PWD="P@ssw0rd_SvcMail2024!"
IREDMAIL_DOMAIN="billu.com"

echo "=== Synchronisation AD → iRedMail - $(date) ==="

# Récupérer la liste des emails depuis l'AD
USERS=$(ldapsearch -x \
  -H ldap://$AD_SERVER \
  -D "$AD_BIND_DN" \
  -w "$AD_BIND_PWD" \
  -b "$AD_BASE" \
  "(objectClass=user)" mail 2>/dev/null | grep "^mail:" | awk '{print $2}')

# Pour chaque utilisateur, vérifier s'il existe dans MariaDB
for email in $USERS; do
    # Vérifier si l'utilisateur existe dans MariaDB
    EXISTS=$(mysql -u root -p"MOT_DE_PASSE_MARIADB" vmail \
        -e "SELECT username FROM mailbox WHERE username='$email';" 2>/dev/null | grep -c "$email")
    
    if [ "$EXISTS" -eq 0 ]; then
        echo "Nouvel utilisateur trouvé : $email"
        echo "Créer manuellement dans iRedAdmin : $email"
        # Note : la création automatique via CLI est possible mais complexe
        # Il est recommandé de créer manuellement via iRedAdmin pour l'instant
    fi
done

echo "=== Synchronisation terminée ==="

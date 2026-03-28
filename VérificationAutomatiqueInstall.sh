#!/bin/bash
echo "=== Vérification pré-installation iRedMail ==="
echo ""

# Hostname
FQDN=$(hostname -f 2>/dev/null)
if [ "$FQDN" = "mail.billu.com" ]; then
    echo "✅ Hostname FQDN : $FQDN"
else
    echo "❌ Hostname FQDN incorrect : $FQDN (attendu: mail.billu.com)"
fi

# IP
IP=$(ip addr show | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1)
if echo "$IP" | grep -q "172.20.100.51"; then
    echo "✅ IP : 172.20.100.51"
else
    echo "⚠️  IP détectée : $IP"
fi

# /etc/hosts
if grep -q "172.20.100.51.*mail.billu.com" /etc/hosts; then
    echo "✅ /etc/hosts configuré correctement"
else
    echo "❌ /etc/hosts ne contient pas la bonne entrée"
fi

# RAM
RAM=$(free -m | awk 'NR==2{print $2}')
if [ $RAM -ge 3000 ]; then
    echo "✅ RAM : ${RAM}MB (suffisant)"
else
    echo "⚠️  RAM : ${RAM}MB (minimum 4096MB recommandé)"
fi

# Disque
DISK=$(df -m / | awk 'NR==2{print $4}')
if [ $DISK -ge 20000 ]; then
    echo "✅ Espace disque libre : ${DISK}MB"
else
    echo "❌ Espace disque insuffisant : ${DISK}MB (minimum 20Go)"
fi

echo ""
echo "=== Vérification terminée ==="

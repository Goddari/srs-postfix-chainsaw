# Guida Installazione - Postfix SRS Forward System

Guida passo-passo per l'installazione completa del sistema.

## Prerequisiti

- Server Linux (CentOS 7+, Ubuntu 18.04+, Debian 10+)
- Postfix già configurato e funzionante
- MySQL/MariaDB 5.5+
- Accesso root o sudo
- Perl 5.x

---

## Step 1: Installazione Dipendenze

### CentOS/RHEL

```bash
# Aggiorna sistema
yum update -y

# Installa Perl e moduli
yum install -y perl perl-DBI perl-DBD-MySQL perl-MIME-tools \
               perl-MailTools perl-Digest-HMAC perl-Sys-Syslog

# Verifica installazione
perl -MDBI -e 'print "DBI OK\n"'
perl -MMIME::Parser -e 'print "MIME::Parser OK\n"'
```

### Debian/Ubuntu

```bash
# Aggiorna sistema
apt-get update && apt-get upgrade -y

# Installa Perl e moduli
apt-get install -y libdbi-perl libdbd-mysql-perl libmime-tools-perl \
                   libmailtools-perl libdigest-hmac-perl

# Verifica installazione
perl -MDBI -e 'print "DBI OK\n"'
perl -MMIME::Parser -e 'print "MIME::Parser OK\n"'
```

---

## Step 2: Setup Database

```bash
# Scarica schema
wget https://raw.githubusercontent.com/YOUR_REPO/postfix-srs-forward/main/schema.sql

# Importa nel database
mysql -u root -p < schema.sql

# Oppure se il database esiste già:
mysql -u root -p postfix < schema.sql

# Verifica
mysql -u root -p -e "USE postfix; SHOW TABLES LIKE '%forward%';"
```

---

## Step 3: Creazione Utente Sistema

```bash
# Crea utente dedicato
useradd -r -d /var/spool/forward -s /bin/false forward

# Crea directory
mkdir -p /var/spool/forward

# Imposta ownership
chown forward:forward /var/spool/forward
chmod 750 /var/spool/forward
```

---

## Step 4: Installazione Script

```bash
# Clona repository
cd /tmp
git clone https://github.com/YOUR_REPO/postfix-srs-forward.git
cd postfix-srs-forward

# Copia script
cp srsforward.pl /var/spool/forward/
cp srsbounce.pl /var/spool/forward/

# Imposta permessi
chown forward:forward /var/spool/forward/*.pl
chmod 755 /var/spool/forward/*.pl

# Verifica sintassi
perl -c /var/spool/forward/srsforward.pl
perl -c /var/spool/forward/srsbounce.pl
```

---

## Step 5: Configurazione Script

### srsforward.pl

```bash
vi /var/spool/forward/srsforward.pl

# Modifica le seguenti variabili:
my $DB_HOST = 'localhost';           # Il tuo MySQL host
my $DB_PORT = 3306;
my $DB_NAME = 'postfix';
my $DB_USER = 'postfix_user';        # Utente MySQL
my $DB_PASS = 'your_password';       # Password MySQL
my $SMTP_HOST = 'your-relay.com';    # Il tuo relay SMTP
my $SMTP_PORT = 25;
```

### srsbounce.pl

```bash
vi /var/spool/forward/srsbounce.pl

# Modifica le seguenti variabili:
my $DB_HOST = 'localhost';
my $DB_PORT = 3306;
my $DB_NAME = 'postfix';
my $DB_USER = 'postfix_user';
my $DB_PASS = 'your_password';
my $SMTP_HOST = 'your-mail-server.com';  # Per inviare notifiche
my $SMTP_PORT = 25;
my $MAX_BOUNCE_COUNT = 5;  # Bounce prima di disabilitare
```

---

## Step 6: Configurazione Postfix

### A. Transport Maps

```bash
# Crea directory se non esiste
mkdir -p /etc/postfix/hash

# Crea transport map
cat > /etc/postfix/hash/transport_srs.cf <<'EOF'
# Transport SRS Forward
myforward.yourdomain.com    myforward:
srs.yourdomain.com          srsbounce:
EOF

# IMPORTANTE: Sostituisci 'yourdomain.com' con il tuo dominio!

# Compila
postmap /etc/postfix/hash/transport_srs.cf

# Aggiungi a main.cf
postconf -e "transport_maps = hash:/etc/postfix/hash/transport_srs.cf"

# Se hai già transport_maps configurati:
# postconf -e "transport_maps = hash:/etc/postfix/hash/existing.cf, hash:/etc/postfix/hash/transport_srs.cf"
```

### B. Master.cf

```bash
# Backup
cp /etc/postfix/master.cf /etc/postfix/master.cf.backup

# Aggiungi i servizi
cat >> /etc/postfix/master.cf <<'EOF'

# === SRS Forward Services ===
myforward   unix  -  n  n  -  -  pipe
  flags=Rq user=forward argv=/var/spool/forward/srsforward.pl -f ${sender} -- ${recipient}

srsbounce   unix  -  n  n  -  -  pipe
  flags=Rq user=forward argv=/var/spool/forward/srsbounce.pl -f ${sender} -- ${recipient}
EOF
```

### C. Virtual Alias Maps (MySQL)

```bash
# Crea directory se non esiste
mkdir -p /etc/postfix/mysql

# Crea configurazione MySQL
cat > /etc/postfix/mysql/mysql-virtual-alias-srs.cf <<'EOF'
user = postfix_user
password = your_password
hosts = localhost
dbname = postfix

query = SELECT CONCAT(id, '@myforward.yourdomain.com') as destination
        FROM forward 
        WHERE username = '%s' 
        AND active = 1
EOF

# IMPORTANTE: Sostituisci user, password e dominio!

# Aggiungi a main.cf
# Se NON hai già virtual_alias_maps:
postconf -e "virtual_alias_maps = mysql:/etc/postfix/mysql/mysql-virtual-alias-srs.cf"

# Se hai già virtual_alias_maps configurati:
# postconf -e "virtual_alias_maps = mysql:/etc/postfix/mysql/existing.cf, mysql:/etc/postfix/mysql/mysql-virtual-alias-srs.cf"

# Imposta permessi
chmod 640 /etc/postfix/mysql/mysql-virtual-alias-srs.cf
chown root:postfix /etc/postfix/mysql/mysql-virtual-alias-srs.cf
```

### D. Test Configurazione

```bash
# Verifica sintassi Postfix
postfix check

# Se nessun errore:
postfix reload

# Test lookup
postmap -q "test@yourdomain.com" mysql:/etc/postfix/mysql/mysql-virtual-alias-srs.cf

# Test transport
postmap -q "myforward.yourdomain.com" hash:/etc/postfix/hash/transport_srs
```

---

## Step 7: Configurazione DNS

Aggiungi i seguenti record DNS:

```
# Record MX per dominio bounce
srs.yourdomain.com.     IN  MX  10  mail.yourdomain.com.

# Record A
srs.yourdomain.com.     IN  A       YOUR_SERVER_IP

# Verifica (dopo propagazione DNS)
dig srs.yourdomain.com MX
dig srs.yourdomain.com A
```

---

## Step 8: Test Sistema

### Test Forward

```bash
# Crea forward di test nel database
mysql -u root -p postfix <<EOF
INSERT INTO forward (username, goto, bounce_domain, active)
VALUES ('test@yourdomain.com', 'external@gmail.com', 'srs.yourdomain.com', 1);
EOF

# Invia email di test
echo "Subject: Test SRS Forward
From: sender@example.com
To: test@yourdomain.com

Test body" | sendmail -f sender@example.com test@yourdomain.com

# Monitor log
tail -f /var/log/maillog | grep -E "(srsforward|test@yourdomain)"
```

### Test Bounce

```bash
# Simula bounce (per sviluppo/test)
cat > /tmp/test_bounce.txt <<'EOF'
From: MAILER-DAEMON@gmail.com
Subject: Undelivered Mail

550 User unknown
EOF

# Estrai un indirizzo SRS dai log e testa
cat /tmp/test_bounce.txt | /var/spool/forward/srsbounce.pl \
    -f "MAILER-DAEMON@gmail.com" -- \
    'SRS0=hash=timestamp=domain=ID=user@srs.yourdomain.com'

# Verifica database
mysql -u root -p postfix -e "SELECT * FROM bounce_log ORDER BY bounce_time DESC LIMIT 1;"
```

---

## Step 9: Monitoring

### Setup Log Rotation

```bash
cat > /etc/logrotate.d/srs-forward <<'EOF'
/var/log/maillog {
    daily
    rotate 30
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        /usr/bin/systemctl reload postfix > /dev/null 2>&1 || true
    endscript
}
EOF
```

### Query Monitoring

```bash
# Crea script di monitoring
cat > /usr/local/bin/srs-status.sh <<'EOF'
#!/bin/bash
mysql -u postfix_user -pYOUR_PASSWORD postfix <<SQL
SELECT 
    COUNT(*) as total_forwards,
    SUM(CASE WHEN active = 1 THEN 1 ELSE 0 END) as active,
    SUM(CASE WHEN active = 0 THEN 1 ELSE 0 END) as disabled,
    SUM(bounce_count) as total_bounces
FROM forward;

SELECT 'Recent Bounces (24h):' as '';
SELECT COUNT(*) FROM bounce_log 
WHERE bounce_time > DATE_SUB(NOW(), INTERVAL 24 HOUR);
SQL
EOF

chmod +x /usr/local/bin/srs-status.sh
```

---

## Step 10: Backup

```bash
# Setup backup automatico database
cat > /etc/cron.daily/backup-srs-forward <<'EOF'
#!/bin/bash
BACKUP_DIR="/var/backups/srs-forward"
mkdir -p $BACKUP_DIR
DATE=$(date +%Y%m%d)

mysqldump -u postfix_user -pYOUR_PASSWORD postfix \
    forward srs_keys bounce_log \
    | gzip > $BACKUP_DIR/srs-forward-$DATE.sql.gz

# Mantieni ultimi 30 giorni
find $BACKUP_DIR -name "srs-forward-*.sql.gz" -mtime +30 -delete
EOF

chmod +x /etc/cron.daily/backup-srs-forward
```

---

## Troubleshooting Installazione

### Errore: "Can't locate DBI.pm"

```bash
# CentOS
yum install perl-DBI

# Debian/Ubuntu
apt-get install libdbi-perl
```

### Errore: "Connection refused" (MySQL)

```bash
# Verifica MySQL in ascolto
netstat -tlnp | grep 3306

# Verifica credenziali
mysql -u postfix_user -p postfix -e "SELECT 1"

# Verifica permessi
mysql -u root -p -e "GRANT ALL ON postfix.* TO 'postfix_user'@'localhost' IDENTIFIED BY 'password';"
```

### Errore: "postmap: fatal: open hash:..."

```bash
# Ricrea hash
postmap /etc/postfix/hash/transport_srs.cf

# Verifica permessi
ls -la /etc/postfix/hash/
```

### Log non mostrano nulla

```bash
# Verifica syslog
systemctl status rsyslog

# Verifica configurazione syslog
grep mail /etc/rsyslog.conf

# Riavvia syslog
systemctl restart rsyslog
```

---

## Post-Installazione

### Checklist

- [ ] Database creato e popolato
- [ ] Script installati e funzionanti
- [ ] Postfix configurato e reloaded
- [ ] DNS configurato
- [ ] Test forward completato
- [ ] Test bounce completato
- [ ] Monitoring attivo
- [ ] Backup configurato

### Prossimi Passi

1. Monitora i log per le prime 24 ore
2. Crea forward di test per vari scenari
3. Verifica ricezione notifiche bounce
4. Ottimizza `MAX_BOUNCE_COUNT` se necessario
5. Documenta le customizzazioni specifiche del tuo ambiente

---

## Supporto

Se riscontri problemi:

1. Controlla i log: `/var/log/maillog`
2. Verifica sintassi script: `perl -c script.pl`
3. Test query database manualmente
4. Consulta la sezione Troubleshooting nel README
5. Apri una Issue su GitHub

---

**Installazione completata con successo!** 🎉

# srs-postfix-chainsaw
Perl Scripts to manage srs forward and bounce in postfix.
# Postfix SRS Forward System

Sistema di forward email per Postfix con supporto completo **SRS (Sender Rewriting Scheme)**, gestione automatica dei bounce e notifiche agli utenti.

## 📋 Indice

- [Problema](#problema)
- [Soluzione](#soluzione)
- [Caratteristiche](#caratteristiche)
- [Architettura](#architettura)
- [Requisiti](#requisiti)
- [Installazione](#installazione)
- [Configurazione](#configurazione)
- [Customizzazione](#customizzazione)
- [Troubleshooting](#troubleshooting)
- [Caso d'Uso](#caso-duso)
- [Licenza](#licenza)

---

## 🔴 Problema

Quando un server di posta inoltra email verso destinazioni esterne, può violare le policy **SPF/DKIM/DMARC** del mittente originale, causando il rifiuto delle email.

### Scenario Problematico

```
1. Mittente esterno (es: facebook.com) → Tuo server → Casella locale (user@tuodominio.it)
2. Casella locale ha forward configurato → Destinazione esterna (user@gmail.com)
3. Gmail RIFIUTA l'email perché il tuo server si "spaccia" per facebook.com
4. Violazione SPF/DMARC del dominio originale
```

**Risultato**: Email perse, bounce non gestiti, utenti non informati.

---

## ✅ Soluzione

Questo sistema implementa **SRS (Sender Rewriting Scheme)** per riscrivere il mittente durante il forward, rispettando le policy anti-spam e gestendo automaticamente i bounce.

### Come Funziona

```
1. Email arriva: sender@example.com → user@tuodominio.it
2. Sistema rileva forward attivo
3. Riscrive mittente: SRS0=hash=timestamp=domain=ID=sender@bounce.tuodominio.it
4. Inoltra con mittente riscritto → Gmail ACCETTA ✓
5. In caso di bounce:
   - Decodifica SRS
   - Registra nel database
   - Invia notifica all'utente proprietario del forward
   - Auto-disabilita forward problematici
```

---

## 🎯 Caratteristiche

- ✅ **Conformità SPF/DKIM/DMARC**: Forward senza violare policy
- ✅ **Gestione automatica bounce**: Tracking completo e notifiche
- ✅ **Protezione anti-loop**: Previene loop infiniti di notifiche
- ✅ **Auto-disabilitazione**: Forward problematici disabilitati automaticamente
- ✅ **Database MySQL**: Tracking completo di forward e bounce
- ✅ **Notifiche utente**: Email informative in caso di problemi
- ✅ **Chiavi rotabili**: Sistema di chiavi HMAC per maggiore sicurezza
- ✅ **Compatibile**: Integrazione trasparente con sistemi esistenti (vacation, alias, ecc.)

---

## 🏗️ Architettura

```
┌─────────────────┐
│  Email In       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Postfix        │
│  Virtual Alias  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌──────────────┐
│  MySQL Check    │────▶│  Forward DB  │
└────────┬────────┘     └──────────────┘
         │
         ▼
┌─────────────────┐
│  Transport Map  │
└────────┬────────┘
         │
    ┌────┴────┐
    │         │
    ▼         ▼
┌────────┐  ┌────────┐
│Forward │  │Bounce  │
│Script  │  │Script  │
└───┬────┘  └───┬────┘
    │           │
    ▼           ▼
┌────────┐  ┌────────┐
│External│  │User    │
│Delivery│  │Notify  │
└────────┘  └────────┘
```

### Componenti

1. **srsforward.pl**: Gestisce il forward con riscrittura SRS
2. **srsbounce.pl**: Processa i bounce e notifica gli utenti
3. **Database MySQL**: Tracking forward, bounce log, chiavi SRS
4. **Postfix**: Transport maps e virtual alias integration

---

## 📦 Requisiti

### Software

- **Postfix** (testato su 3.5+)
- **MySQL/MariaDB** (testato su MySQL 5.5+)
- **Perl 5.x** con moduli:
  - `DBI`
  - `DBD::mysql`
  - `MIME::Parser`
  - `MIME::Entity`
  - `Mail::Message`
  - `Mail::Transport::SMTP`
  - `Digest::HMAC_SHA1`
  - `Sys::Syslog`

### Installazione Moduli Perl

```bash
# CentOS/RHEL
yum install -y perl-DBI perl-DBD-MySQL perl-MIME-tools perl-MailTools perl-Digest-HMAC

# Debian/Ubuntu
apt-get install -y libdbi-perl libdbd-mysql-perl libmime-tools-perl libmailtools-perl libdigest-hmac-perl
```

---

## 🚀 Installazione

### 1. Database Setup

```sql
-- Crea database (se non esiste già)
CREATE DATABASE IF NOT EXISTS postfix CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Tabella forward
CREATE TABLE `forward` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `username` varchar(255) NOT NULL,
  `goto` varchar(255) NOT NULL,
  `bounce_domain` varchar(255) NOT NULL,
  `active` tinyint(1) NOT NULL DEFAULT 1,
  `bounce_count` int(11) NOT NULL DEFAULT 0,
  `last_bounce` datetime DEFAULT NULL,
  `disabled_reason` varchar(255) DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `username` (`username`),
  KEY `idx_active` (`active`),
  KEY `idx_bounce_domain` (`bounce_domain`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Tabella chiavi SRS
CREATE TABLE `srs_keys` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `secret` varchar(64) NOT NULL,
  `active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_active` (`active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Tabella log bounce
CREATE TABLE `bounce_log` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `forward_id` int(11) NOT NULL,
  `bounce_time` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `original_sender` varchar(255) NOT NULL,
  `bounce_reason` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_forward_id` (`forward_id`),
  KEY `idx_bounce_time` (`bounce_time`),
  CONSTRAINT `fk_forward_id` FOREIGN KEY (`forward_id`) REFERENCES `forward` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Genera chiave SRS
INSERT INTO srs_keys (secret, active) VALUES (SHA2(CONCAT(RAND(), NOW()), 256), 1);
```

### 2. Script Installation

```bash
# Crea directory per gli script
mkdir -p /var/spool/forward

# Copia gli script
cp srsforward.pl /var/spool/forward/
cp srsbounce.pl /var/spool/forward/

# Crea utente di sistema
useradd -r -d /var/spool/forward -s /bin/false forward

# Imposta permessi
chown forward:forward /var/spool/forward/*.pl
chmod 755 /var/spool/forward/*.pl

# Verifica sintassi
perl -c /var/spool/forward/srsforward.pl
perl -c /var/spool/forward/srsbounce.pl
```

### 3. Postfix Configuration

#### A. Transport Maps

Crea `/etc/postfix/hash/transport_srs.cf`:

```
# Dominio per trigger forward SRS
myforward.yourdomain.com    myforward:

# Dominio per gestione bounce SRS
srs.yourdomain.com          srsbounce:
```

Compila e configura:

```bash
postmap /etc/postfix/hash/transport_srs.cf

# Aggiungi a main.cf
postconf -e "transport_maps = hash:/etc/postfix/hash/transport_srs.cf"
```

#### B. Master.cf Services

Aggiungi a `/etc/postfix/master.cf`:

```
# Servizio forward SRS
myforward   unix  -  n  n  -  -  pipe
  flags=Rq user=forward argv=/var/spool/forward/srsforward.pl -f ${sender} -- ${recipient}

# Servizio bounce SRS  
srsbounce   unix  -  n  n  -  -  pipe
  flags=Rq user=forward argv=/var/spool/forward/srsbounce.pl -f ${sender} -- ${recipient}
```

#### C. Virtual Alias Maps

Crea `/etc/postfix/mysql/mysql-virtual-alias.cf`:

```
user = postfix_user
password = your_password
hosts = mysql_host
dbname = postfix

query = SELECT CONCAT(id, '@myforward.yourdomain.com') as destination
        FROM forward 
        WHERE username = '%s' 
        AND active = 1
```

Aggiungi a `main.cf`:

```bash
postconf -e "virtual_alias_maps = mysql:/etc/postfix/mysql/mysql-virtual-alias.cf"
```

#### D. Reload Postfix

```bash
postfix check
postfix reload
```

---

## ⚙️ Configurazione

### Script Configuration

Modifica le variabili di configurazione in entrambi gli script:

#### srsforward.pl

```perl
# === CONFIGURAZIONE ===
my $DB_HOST = 'your-mysql-host';
my $DB_PORT = 3306;
my $DB_NAME = 'postfix';
my $DB_USER = 'postfix_user';
my $DB_PASS = 'your_password';
my $SRS_TIMEOUT = 21;     # Giorni validità SRS
my $SMTP_HOST = 'your-relay-host';
my $SMTP_PORT = 25;
```

#### srsbounce.pl

```perl
# === CONFIGURAZIONE ===
my $DB_HOST = 'your-mysql-host';
my $DB_PORT = 3306;
my $DB_NAME = 'postfix';
my $DB_USER = 'postfix_user';
my $DB_PASS = 'your_password';
my $SRS_TIMEOUT = 21;
my $MAX_BOUNCE_COUNT = 5;  # Bounce prima di disabilitare
my $SMTP_HOST = 'your-mail-server';  # Per inviare notifiche
my $SMTP_PORT = 25;
```

### DNS Configuration

Configura i record DNS per il dominio bounce:

```
srs.yourdomain.com.    IN  MX  10  mail.yourdomain.com.
srs.yourdomain.com.    IN  A       YOUR_SERVER_IP
```

---

## 🎨 Customizzazione

### Adattamento al Tuo Caso d'Uso

Il sistema è progettato per essere flessibile. Ecco come adattarlo:

#### 1. Integrazione con Tabella Alias Esistente

Se hai già una tabella `alias` in Postfix, puoi far generare automaticamente i record `forward` tramite trigger MySQL:

```sql
DELIMITER $$

CREATE TRIGGER auto_create_srs_forward
AFTER INSERT ON alias
FOR EACH ROW
BEGIN
    DECLARE dest_domain VARCHAR(255);
    DECLARE is_internal INT DEFAULT 0;
    
    -- Estrai dominio destinazione
    SET dest_domain = SUBSTRING_INDEX(SUBSTRING_INDEX(NEW.goto, '@', -1), '>', 1);
    
    -- Verifica se è interno
    SELECT COUNT(*) INTO is_internal
    FROM domain 
    WHERE domain = dest_domain AND active = 1;
    
    -- Se esterno, crea forward SRS
    IF is_internal = 0 AND NEW.goto LIKE '%@%' THEN
        INSERT INTO forward (username, goto, bounce_domain, active)
        VALUES (NEW.address, NEW.goto, 'srs.yourdomain.com', 1)
        ON DUPLICATE KEY UPDATE goto = NEW.goto, active = 1;
    END IF;
END$$

DELIMITER ;
```

#### 2. Modifica Formato Notifiche Bounce

Modifica la funzione `send_bounce_notification` in `srsbounce.pl` per personalizzare il messaggio:

```perl
my $body_text = <<EOF;
Gentile utente,

Il tuo forward email ha riscontrato un problema nella consegna.

Dettagli:
- Mittente: $original_sender
- Destinazione: $failed_destination
- Motivo: $bounce_reason

[Personalizza il messaggio qui]

Cordiali saluti,
Il Team di Sistema
EOF
```

#### 3. Integrazione con PostfixAdmin

Se usi PostfixAdmin, puoi aggiungere funzionalità per gestire i forward SRS dall'interfaccia web. Esempio PHP:

```php
<?php
function createExternalForward($username, $external_email) {
    // Verifica se destinazione è esterna
    $dest_domain = substr(strrchr($external_email, '@'), 1);
    
    $stmt = $pdo->prepare("SELECT 1 FROM domain WHERE domain = ?");
    $stmt->execute([$dest_domain]);
    
    if (!$stmt->fetch()) {
        // Destinazione esterna - crea forward SRS
        $stmt = $pdo->prepare("
            INSERT INTO forward (username, goto, bounce_domain, active)
            VALUES (?, ?, 'srs.yourdomain.com', 1)
        ");
        $stmt->execute([$username, $external_email]);
        
        return $pdo->lastInsertId();
    }
    
    return false;
}
?>
```

#### 4. Ambiente Multi-Server

Se hai più server MDA dietro load balancer:

```perl
# In srsbounce.pl, usa il VIP del load balancer
my $SMTP_HOST = 'mail-mda-vip.yourdomain.com';  # HAProxy VIP
```

#### 5. Modifica Soglia Auto-Disabilitazione

Cambia il numero di bounce prima della disabilitazione automatica:

```perl
# In srsbounce.pl
my $MAX_BOUNCE_COUNT = 10;  # Default: 5
```

#### 6. Logging Personalizzato

Modifica il livello di logging in syslog:

```perl
# Debug verboso
syslog(LOG_DEBUG, "Messaggio di debug dettagliato");

# Solo errori
syslog(LOG_ERR, "Errore critico");
```

---

## 🐛 Troubleshooting

### Test del Sistema

```bash
# 1. Test connessione database
mysql -u postfix_user -p postfix -e "SELECT * FROM forward LIMIT 1"

# 2. Test sintassi script
perl -c /var/spool/forward/srsforward.pl
perl -c /var/spool/forward/srsbounce.pl

# 3. Test lookup Postfix
postmap -q "user@domain.com" mysql:/etc/postfix/mysql/mysql-virtual-alias.cf

# 4. Test transport
postmap -q "myforward.yourdomain.com" hash:/etc/postfix/hash/transport_srs

# 5. Monitor log in tempo reale
tail -f /var/log/maillog | grep -E "(srsforward|srsbounce)"
```

### Problemi Comuni

#### Forward non funziona

```sql
-- Verifica forward attivo
SELECT * FROM forward WHERE username = 'user@domain.com' AND active = 1;

-- Verifica chiave SRS
SELECT * FROM srs_keys WHERE active = 1;
```

#### Bounce non registrati

```bash
# Verifica DNS
dig srs.yourdomain.com MX

# Verifica transport
postmap -q "srs.yourdomain.com" hash:/etc/postfix/hash/transport_srs
```

#### Notifiche non arrivano

```bash
# Test SMTP
telnet your-smtp-host 25

# Verifica log
grep "Notifica bounce" /var/log/maillog
```

### Query Utili

```sql
-- Status generale forward
SELECT 
    id, username, goto, 
    bounce_count, active, 
    last_bounce, disabled_reason
FROM forward 
ORDER BY bounce_count DESC;

-- Bounce recenti
SELECT 
    f.username, f.goto, 
    b.bounce_time, b.bounce_reason
FROM bounce_log b
JOIN forward f ON b.forward_id = f.id
WHERE b.bounce_time > DATE_SUB(NOW(), INTERVAL 24 HOUR)
ORDER BY b.bounce_time DESC;

-- Reset bounce counter
UPDATE forward SET bounce_count = 0, last_bounce = NULL WHERE id = X;

-- Riattiva forward
UPDATE forward SET active = 1, disabled_reason = NULL WHERE id = X;
```

---

## 📖 Caso d'Uso

### Il Nostro Scenario

Sistema di posta aziendale basato su:
- **3 server MDA** (Mail Delivery Agent) dietro HAProxy
- **Postfix** con backend MySQL per virtual domains
- **Migliaia di caselle email** con necessità di forward esterni
- **Integrazione** con sistema vacation esistente per risposte automatiche

### Implementazione

1. **Dominio forward fittizio**: `myforward.semplify.cloud`
2. **Dominio bounce unificato**: `srs.semplify.cloud` (unico per tutti i clienti)
3. **Database condiviso**: Cluster MySQL per alta disponibilità
4. **Load balancing**: HAProxy distribuisce su 3 MDA

### Flusso Operativo

```
Email: sender@external.com → user@cliente.it
       ↓
1. MDA riceve via HAProxy (VIP: mailcl-mda.mailcl.semplify.net)
2. Postfix query MySQL → trova forward attivo (ID 65)
3. Alias rewrite: user@cliente.it → 65@myforward.semplify.cloud
4. Transport map → servizio myforward
5. srsforward.pl:
   - Genera SRS: SRS0=hash=timestamp=domain=65=sender@srs.semplify.cloud
   - Inoltra a destinazione@gmail.com
6. Se bounce:
   - Gmail → bounce a SRS0=...@srs.semplify.cloud
   - DNS MX → ritorna su MDA
   - Transport → servizio srsbounce
   - srsbounce.pl:
     * Decodifica ID=65
     * Query DB → trova user@cliente.it
     * Invia notifica a user@cliente.it
     * Registra in bounce_log
     * Auto-disabilita se troppi bounce
```

### Integrazione con Sistemi Esistenti

Il sistema convive perfettamente con:
- **Vacation/Autoreply**: Script vacation riconosce header anti-loop
- **Alias multipli**: Supporta consegna a più destinatari simultanei
- **Domain aliasing**: Gestisce alias di dominio
- **Quota management**: Non interferisce con limiti di storage

---

## 📊 Metriche e Monitoring

### Dashboard SQL

```sql
-- KPI Forward
SELECT 
    COUNT(*) as total_forward,
    SUM(CASE WHEN active = 1 THEN 1 ELSE 0 END) as active,
    SUM(CASE WHEN active = 0 THEN 1 ELSE 0 END) as disabled,
    AVG(bounce_count) as avg_bounces
FROM forward;

-- Top bounce domains
SELECT 
    SUBSTRING_INDEX(goto, '@', -1) as domain,
    COUNT(*) as forward_count,
    SUM(bounce_count) as total_bounces
FROM forward
GROUP BY domain
ORDER BY total_bounces DESC
LIMIT 10;

-- Bounce trend
SELECT 
    DATE(bounce_time) as date,
    COUNT(*) as bounce_count,
    COUNT(DISTINCT forward_id) as affected_forwards
FROM bounce_log
WHERE bounce_time > DATE_SUB(NOW(), INTERVAL 7 DAY)
GROUP BY DATE(bounce_time)
ORDER BY date;
```

---

## 📝 Note Aggiuntive

### Limitazioni

- Un processo Perl per ogni email forward (overhead minimo ma presente)
- Indirizzo SRS valido per 21 giorni (configurabile)
- Log bounce memorizzati 30 giorni (configurabile)

### Best Practices

1. **Backup regolare** del database `forward` e `bounce_log`
2. **Monitoring** dei bounce rate per dominio
3. **Rotazione chiavi SRS** periodica (opzionale ma consigliato)
4. **Cleanup** dei log vecchi automatico
5. **Alert** su forward disabilitati automaticamente

### Performance

- Testato con **10.000+ forward attivi**
- Overhead medio: **< 50ms per email**
- Database load: **< 5 query per forward**

---

## 🤝 Contributi

Contributi, issue e feature request sono benvenuti!

1. Fork del progetto
2. Crea un branch per la feature (`git checkout -b feature/AmazingFeature`)
3. Commit delle modifiche (`git commit -m 'Add some AmazingFeature'`)
4. Push sul branch (`git push origin feature/AmazingFeature`)
5. Apri una Pull Request

---

## 📄 Licenza

Questo progetto è rilasciato sotto licenza MIT. Vedi il file `LICENSE` per i dettagli.

---

## 👥 Autori
Io, e ausilio di Claude Code.
Sviluppato per gestire forward email complessi in ambienti Postfix multi-server con alta disponibilità.

---

## 🔗 Link Utili

- [Postfix Documentation](http://www.postfix.org/documentation.html)
- [SRS Specification](https://en.wikipedia.org/wiki/Sender_Rewriting_Scheme)
- [SPF/DKIM/DMARC Guide](https://www.cloudflare.com/learning/email-security/)

---

## 📞 Support

Per domande o supporto:
- Apri una Issue su GitHub
- Consulta la sezione [Troubleshooting](#troubleshooting)
- Verifica i log in `/var/log/maillog`

---

**Versione**: 2.0  
**Ultimo aggiornamento**: Ottobre 2025

MIT License

Copyright (c) 2025 [Your Name/Organization]

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

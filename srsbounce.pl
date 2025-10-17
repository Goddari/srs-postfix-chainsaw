#!/usr/bin/perl
use strict;
use warnings;
use DBI;
use MIME::Parser;
use MIME::Entity;
use Mail::Message;
use Mail::Transport::SMTP;
use Digest::HMAC_SHA1 qw(hmac_sha1_hex);
use Sys::Syslog qw(:standard :macros);
use Getopt::Long;
use POSIX qw(strftime);

# =====================================================================
# CONFIGURAZIONE - Modifica questi valori per il tuo ambiente
# =====================================================================
my $DB_HOST = 'your db host';
my $DB_PORT = 3306;
my $DB_NAME = 'your db name';
my $DB_USER = 'your db user';
my $DB_PASS = 'your db pwd';
my $SRS_TIMEOUT = 21;     # Giorni di validità dell'indirizzo SRS
my $MAX_BOUNCE_COUNT = 5; # Numero massimo di bounce prima di disabilitare
my $SMTP_HOST = 'your smtp host';  
my $SMTP_PORT = 25;

# =====================================================================
# INIZIALIZZAZIONE
# =====================================================================

# Parsing argomenti da Postfix
my ($sender, $recipient);
GetOptions(
    'f=s' => \$sender,    # Chi sta inviando il bounce (MTA remoto)
) or die "Errore parsing argomenti\n";

# Il recipient è l'indirizzo SRS che deve essere decodificato
$recipient = $ARGV[0] || die "Recipient mancante\n";

# Apri syslog per logging
openlog('srsbounce', 'pid', 'mail');

syslog(LOG_INFO, "Elaborazione bounce SRS: $recipient da $sender");

# =====================================================================
# CONNESSIONE DATABASE
# =====================================================================

my $dsn = "DBI:mysql:database=$DB_NAME;host=$DB_HOST;port=$DB_PORT";
my $dbh = DBI->connect($dsn, $DB_USER, $DB_PASS, {
    RaiseError => 1,
    AutoCommit => 1,
    mysql_enable_utf8 => 1,
}) or die "Connessione DB fallita: $DBI::errstr\n";

# =====================================================================
# DECODIFICA INDIRIZZO SRS CON ID
# =====================================================================

sub decode_srs_address {
    my ($srs_address_full, $dbh) = @_;
    
    # Estrai la parte locale e il dominio dall'indirizzo
    my ($srs_address, $bounce_domain) = split(/\@/, $srs_address_full, 2);
    
    unless ($bounce_domain) {
        syslog(LOG_WARNING, "Formato indirizzo SRS non valido: $srs_address_full");
        return undef;
    }
    
    # Verifica che il dominio bounce esista nel database
    my ($domain_exists) = $dbh->selectrow_array(q{
        SELECT 1 FROM forward WHERE bounce_domain = ? LIMIT 1
    }, undef, $bounce_domain);
    
    unless ($domain_exists) {
        syslog(LOG_WARNING, "Dominio bounce sconosciuto: $bounce_domain");
        return undef;
    }
    
    # Parse del NUOVO formato: SRS0=hash=timestamp=domain=ID=local
    if ($srs_address =~ /^SRS0=([^=]+)=(\d+)=([^=]+)=(\d+)=(.+)$/i) {
        my ($hash, $timestamp, $domain, $forward_id, $local) = ($1, $2, $3, $4, $5);
        
        syslog(LOG_DEBUG, "SRS analizzato: hash=$hash, timestamp=$timestamp, domain=$domain, forward_id=$forward_id, local=$local");
        
        # Verifica timeout (scadenza dopo SRS_TIMEOUT giorni)
        my $epoch_2000 = 946684800;
        my $current_days = int((time() - $epoch_2000) / 86400);
        
        if (($current_days - $timestamp) > $SRS_TIMEOUT) {
            syslog(LOG_WARNING, "Indirizzo SRS scaduto: $srs_address");
            return undef;
        }
        
        # Recupera chiavi SRS per validazione hash
        my $sth = $dbh->prepare(q{
            SELECT secret, created_at 
            FROM srs_keys 
            WHERE active = 1 OR 
                  (created_at > DATE_SUB(NOW(), INTERVAL ? DAY))
            ORDER BY created_at DESC
        });
        $sth->execute($SRS_TIMEOUT + 7);  # Include chiavi recentemente disattivate
        
        # Prova a validare con ogni chiave disponibile
        while (my ($secret, $created) = $sth->fetchrow_array) {
            my $hash_input = lc("$timestamp=$domain=$forward_id=$local");
            my $computed_hash = substr(hmac_sha1_hex($hash_input, $secret), 0, 6);
            
            if ($computed_hash eq lc($hash)) {
                # Hash valido! Ricostruisci indirizzo originale
                my $original = "$local\@$domain";
                syslog(LOG_INFO, "SRS decodificato con successo: $srs_address -> $original (forward_id=$forward_id)");
                return ($original, $bounce_domain, $forward_id);
            }
        }
        
        syslog(LOG_WARNING, "Validazione hash SRS fallita per: $srs_address");
        return undef;
    }
    
    # Gestisci anche formato SRS1 (bounce di bounce - double bounce)
    if ($srs_address =~ /^SRS1=([^=]+)=([^=]+)=(.+)$/i) {
        syslog(LOG_INFO, "Rilevato SRS1 (double-bounce), ignoro: $srs_address");
        return undef;
    }
    
    syslog(LOG_WARNING, "Formato SRS non valido: $srs_address");
    return undef;
}

# =====================================================================
# DECODIFICA E TROVA FORWARD ORIGINALE
# =====================================================================

my @decode_result = decode_srs_address($recipient, $dbh);
unless (@decode_result) {
    syslog(LOG_WARNING, "Impossibile decodificare SRS o indirizzo scaduto");
    $dbh->disconnect;
    closelog();
    exit 0;  # Exit silenzioso per non generare ulteriori bounce
}

my ($original_sender, $bounce_domain, $forward_id) = @decode_result;

syslog(LOG_INFO, "Decodificato - Mittente originale: $original_sender, Dominio bounce: $bounce_domain, Forward ID: $forward_id");

# =====================================================================
# LEGGI EMAIL BOUNCE DA STDIN
# =====================================================================

my $parser = MIME::Parser->new;
$parser->output_to_core(1);
$parser->tmp_to_core(1);

my $entity;
eval {
    $entity = $parser->parse(\*STDIN);
};
if ($@) {
    syslog(LOG_ERR, "Errore parsing email bounce: $@");
    $dbh->disconnect;
    die "Bounce parsing failed\n";
}

# =====================================================================
# ESTRAI INFORMAZIONI DAL BOUNCE
# =====================================================================

my $bounce_reason = "Unknown";
my $failed_recipient = "";
my $bounce_details = "";

# Cerca header specifici del bounce
if ($entity->head->get('X-Failed-Recipients')) {
    $failed_recipient = $entity->head->get('X-Failed-Recipients');
    chomp($failed_recipient);
}

# Funzione per estrarre tutto il testo dall'email (anche multipart)
sub extract_all_text {
    my ($entity) = @_;
    my $text = "";
    
    # Se ha body diretto
    if ($entity->bodyhandle) {
        $text .= $entity->bodyhandle->as_string . "\n";
    }
    
    # Se è multipart, estrai da tutte le parti
    if ($entity->parts) {
        foreach my $part ($entity->parts) {
            $text .= extract_all_text($part);
        }
    }
    
    return $text;
}

# Estrai tutto il contenuto testuale del bounce
my $full_body = extract_all_text($entity);
$bounce_details = $full_body;

# Cerca anche nel Subject per indizi
my $subject = $entity->head->get('Subject') || "";

# Identifica il tipo di bounce basandosi su pattern comuni
# Cerca sia nel body che nel subject
my $search_text = "$full_body $subject";

if ($search_text =~ /550\s*5\.1\.1/i || $search_text =~ /user\s+unknown/i) {
    $bounce_reason = "User unknown";
} elsif ($search_text =~ /mailbox\s+full/i || $search_text =~ /quota.*exceeded/i) {
    $bounce_reason = "Mailbox full or quota exceeded";
} elsif ($search_text =~ /spam/i || $search_text =~ /blocked/i) {
    $bounce_reason = "Marked as spam or blocked";
} elsif ($search_text =~ /RFC\s*5322/i) {
    $bounce_reason = "RFC 5322 compliance issue";
} elsif ($search_text =~ /RFC\s*\d+/i) {
    $bounce_reason = "RFC compliance issue";
} elsif ($search_text =~ /header.*missing/i) {
    $bounce_reason = "Missing required headers";
} elsif ($search_text =~ /550\s*5\.7\.1/i) {
    $bounce_reason = "Policy rejection (550 5.7.1)";
} elsif ($search_text =~ /550/i) {
    $bounce_reason = "Permanent failure (550)";
} elsif ($search_text =~ /4\d\d/i) {
    $bounce_reason = "Temporary failure (4xx)";
}

# Cerca recipient se non trovato negli header
if (!$failed_recipient && $full_body =~ /([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})/) {
    $failed_recipient = $1;
}

syslog(LOG_INFO, "Dettagli bounce - Mittente originale: $original_sender, Destinatario fallito: $failed_recipient, Motivo: $bounce_reason");

# =====================================================================
# TROVA IL FORWARD USANDO L'ID
# =====================================================================

my $sth = $dbh->prepare(q{
    SELECT id, username, goto, bounce_count, active
    FROM forward 
    WHERE id = ?
    LIMIT 1
});
$sth->execute($forward_id);
my $forward = $sth->fetchrow_hashref;

unless ($forward) {
    syslog(LOG_WARNING, "Forward ID $forward_id non trovato nel database");
    $dbh->disconnect;
    closelog();
    exit 0;
}

syslog(LOG_INFO, "Forward trovato - ID: $forward_id, Username: $forward->{username}, Goto: $forward->{goto}");

# =====================================================================
# REGISTRA BOUNCE E AGGIORNA CONTATORI
# =====================================================================

# Inserisci nel log dei bounce
$dbh->do(q{
    INSERT INTO bounce_log (forward_id, bounce_time, original_sender, bounce_reason)
    VALUES (?, NOW(), ?, ?)
}, undef, $forward->{id}, $original_sender, $bounce_reason);

syslog(LOG_INFO, "Bounce registrato nel database per forward ID $forward_id");

# Aggiorna contatore bounce
$dbh->do(q{
    UPDATE forward 
    SET bounce_count = bounce_count + 1,
        last_bounce = NOW()
    WHERE id = ?
}, undef, $forward->{id});

# =====================================================================
# VERIFICA SE DISABILITARE IL FORWARD
# =====================================================================

# Conta bounce nelle ultime 24 ore
my ($recent_bounces) = $dbh->selectrow_array(q{
    SELECT COUNT(*) 
    FROM bounce_log 
    WHERE forward_id = ? 
      AND bounce_time > DATE_SUB(NOW(), INTERVAL 24 HOUR)
}, undef, $forward->{id});

my $should_disable = 0;
if ($recent_bounces >= $MAX_BOUNCE_COUNT) {
    # Disabilita il forward
    $dbh->do(q{
        UPDATE forward 
        SET active = 0,
            disabled_reason = CONCAT('Too many bounces: ', ?)
        WHERE id = ?
    }, undef, $bounce_reason, $forward->{id});
    
    $should_disable = 1;
    syslog(LOG_WARNING, "Forward ID $forward->{id} DISABILITATO: troppi bounce ($recent_bounces in 24h)");
}

# =====================================================================
# INVIA NOTIFICA BOUNCE AL PROPRIETARIO DEL FORWARD
# =====================================================================

sub send_bounce_notification {
    my ($to_address, $original_sender, $failed_destination, $bounce_reason, $bounce_details, $was_disabled, $forward_id) = @_;
    
    syslog(LOG_INFO, "Preparazione notifica bounce per $to_address");
    
    # Prepara il corpo del messaggio PRIMA di creare l'entity
    my $body_text = <<EOF;
This is the mail system at semplify.cloud.

Your email forward has failed to deliver a message to the external destination.

=== DELIVERY FAILURE DETAILS ===

Original Sender: $original_sender
Your Address: $to_address
Forward Destination: $failed_destination
Failure Reason: $bounce_reason
Time: @{[strftime("%Y-%m-%d %H:%M:%S", localtime)]}

=== ACTION TAKEN ===

EOF

    if ($was_disabled) {
        $body_text .= <<EOF;
WARNING: Your forward has been AUTOMATICALLY DISABLED due to too many delivery 
failures in the last 24 hours. This helps prevent your account from being 
flagged as a spam source.

To re-enable your forward:
1. Verify the destination address is correct and accepting mail
2. Contact your system administrator to re-enable the forward

EOF
    } else {
        $body_text .= <<EOF;
Your forward is still active. If this problem persists, the forward may be 
automatically disabled to protect your account.

EOF
    }

    $body_text .= <<EOF;

=== ORIGINAL ERROR FROM REMOTE SERVER ===

$bounce_details

=== END OF MESSAGE ===

If you believe this is an error, please contact your system administrator.

---
Technical Details:
- Forward ID: $forward_id
- System: SRS Forward v2.0
EOF

    # Crea messaggio di notifica CON il body già incluso
    my $notification = MIME::Entity->build(
        From    => 'Mail Delivery System <postmaster@semplify.cloud>',
        To      => $to_address,
        Subject => 'Mail Delivery Failed - Forward Notification',
        Type    => 'text/plain',
        Encoding => '8bit',
        Data    => $body_text,  # IMPORTANTE: body deve essere fornito qui!
        # HEADER SPECIALE: indica a srsforward.pl di NON forwardare questa mail
        'X-Skip-SRS-Forward' => 'true',
        'Precedence' => 'bulk',
        'Auto-Submitted' => 'auto-replied',
    );
    
    # =====================================================================
    # INVIA NOTIFICA VIA SMTP
    # La notifica avrà header X-Skip-SRS-Forward che srsforward.pl riconoscerà
    # =====================================================================
    
    syslog(LOG_INFO, "Invio notifica bounce via SMTP a $to_address");
    
    eval {
        my $smtp = Mail::Transport::SMTP->new(
            hostname => $SMTP_HOST,
            port     => $SMTP_PORT,
            from     => 'postmaster@semplify.cloud',
        );
        
        my $msg = Mail::Message->read($notification->stringify);
        my $success = $smtp->send($msg, to => $to_address);
        
        unless ($success) {
            die "Invio notifica fallito\n";
        }
        
        syslog(LOG_INFO, "Notifica bounce inviata con successo a $to_address");
        return 1;
    };
    
    if ($@) {
        syslog(LOG_ERR, "Errore invio notifica bounce a $to_address: $@");
        return 0;
    }
    
    return 1;
}

# Invia notifica all'utente proprietario del forward
send_bounce_notification(
    $forward->{username},     # Destinatario della notifica (es: test2@cmadm.store)
    $original_sender,         # Mittente originale (es: daniele.aluigi@semplify.net)
    $forward->{goto},         # Destinazione fallita (es: carlomartone167@gmail.com)
    $bounce_reason,           # Motivo bounce
    $bounce_details,          # Dettagli completi dal server remoto
    $should_disable,          # Se il forward è stato disabilitato
    $forward_id               # ID del forward
);

# =====================================================================
# CLEANUP VECCHI BOUNCE
# =====================================================================

# Elimina bounce log più vecchi di 30 giorni
$dbh->do(q{
    DELETE FROM bounce_log 
    WHERE bounce_time < DATE_SUB(NOW(), INTERVAL 30 DAY)
});

# =====================================================================
# FINALIZZAZIONE
# =====================================================================

my $new_bounce_count = $forward->{bounce_count} + 1;
syslog(LOG_INFO, "Elaborazione bounce completata per forward ID $forward->{id} (totale bounces: $new_bounce_count)");

$dbh->disconnect;
closelog();

exit 0;

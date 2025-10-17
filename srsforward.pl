#!/usr/bin/perl
use strict;
use warnings;
use DBI;
use MIME::Parser;
use Mail::Message;
use Mail::Transport::SMTP;
use Digest::HMAC_SHA1 qw(hmac_sha1_hex);
use POSIX qw(strftime);
use Sys::Syslog qw(:standard :macros);
use Getopt::Long;

# =====================================================================
# CONFIGURAZIONE - Modifica questi valori per il tuo ambiente
# =====================================================================
my $DB_HOST = 'YOUR DB HOST';
my $DB_PORT = 3306;
my $DB_NAME = 'your db name';
my $DB_USER = 'your db user';
my $DB_PASS = 'your db pwd';
my $SRS_TIMEOUT = 21;     # Giorni di validità dell'indirizzo SRS
my $SMTP_HOST = 'your smtp host';
my $SMTP_PORT = 25;
# =====================================================================
# INIZIALIZZAZIONE
# =====================================================================

# Parse argomenti da Postfix
my ($sender, $recipient);
GetOptions(
    'f=s' => \$sender,    # Sender originale
) or die "Errore parsing argomenti\n";

# Il recipient viene passato dopo --
$recipient = $ARGV[0] || die "Recipient mancante\n";

# Apri syslog
openlog('srsforward', 'pid', 'mail');

# Estrai l'ID dal recipient (formato: ID@myforward.semplify.cloud)
my ($forward_id, $domain) = split(/\@/, $recipient, 2);
unless ($forward_id =~ /^\d+$/) {
    syslog(LOG_ERR, "Recipient non valido: $recipient");
    die "Recipient format error\n";
}

syslog(LOG_INFO, "Elaborazione forward ID $forward_id da $sender");

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
# RECUPERA DATI FORWARD
# =====================================================================

my $sth = $dbh->prepare(q{
    SELECT id, username, goto, bounce_domain, active 
    FROM forward 
    WHERE id = ? AND active = 1
});
$sth->execute($forward_id);
my $forward = $sth->fetchrow_hashref;

unless ($forward) {
    syslog(LOG_WARNING, "Forward ID $forward_id non trovato o non attivo");
    $dbh->disconnect;
    die "Forward not found or inactive\n";
}

unless ($forward->{bounce_domain}) {
    syslog(LOG_ERR, "Nessun bounce_domain configurato per forward ID $forward_id");
    $dbh->disconnect;
    die "Missing bounce_domain configuration\n";
}

my $forward_to = $forward->{goto};
my $bounce_domain = $forward->{bounce_domain};
syslog(LOG_INFO, "Forward verso $forward_to usando bounce domain $bounce_domain");

# =====================================================================
# RECUPERA CHIAVE SRS
# =====================================================================

$sth = $dbh->prepare(q{
    SELECT secret 
    FROM srs_keys 
    WHERE active = 1 
    ORDER BY created_at DESC 
    LIMIT 1
});
$sth->execute();
my ($srs_secret) = $sth->fetchrow_array;

unless ($srs_secret) {
    syslog(LOG_ERR, "Nessuna chiave SRS attiva trovata");
    $dbh->disconnect;
    die "No active SRS key\n";
}

# =====================================================================
# LEGGI EMAIL DA STDIN
# =====================================================================

my $parser = MIME::Parser->new;
$parser->output_to_core(1);
$parser->tmp_to_core(1);

my $entity;
eval {
    $entity = $parser->parse(\*STDIN);
};
if ($@) {
    syslog(LOG_ERR, "Errore parsing email: $@");
    $dbh->disconnect;
    die "Email parsing failed\n";
}

# =====================================================================
# VERIFICA HEADER ANTI-LOOP
# Controlla se questa mail NON deve essere forwardata
# =====================================================================

my $skip_forward = $entity->head->get('X-Skip-SRS-Forward');
if ($skip_forward && $skip_forward =~ /true/i) {
    syslog(LOG_INFO, "Mail con header X-Skip-SRS-Forward rilevato - NON forwardo (previene loop)");
    
    # Questa è una notifica di sistema (es: bounce notification)
    # NON deve essere forwardata, ma solo consegnata localmente
    # Exit con successo - Postfix consegnerà la mail localmente tramite gli altri transport
    
    $dbh->disconnect;
    closelog();
    exit 0;
}

# =====================================================================
# GENERA INDIRIZZO SRS CON ID
# =====================================================================

sub generate_srs_address {
    my ($original_sender, $secret, $bounce_domain, $forward_id) = @_;
    
    # Estrai dominio e parte locale dal sender originale
    my ($local, $domain) = split(/\@/, $original_sender, 2);
    return $original_sender unless $domain;  # Se non è un'email valida, non modificare
    
    # Genera timestamp (giorni dal 1/1/2000)
    my $epoch_2000 = 946684800;
    my $timestamp = int((time() - $epoch_2000) / 86400);
    
    # Crea stringa da hashare (include anche forward_id per maggiore sicurezza)
    my $hash_input = lc("$timestamp=$domain=$forward_id=$local");
    
    # Genera hash (primi 6 caratteri)
    my $hash = substr(hmac_sha1_hex($hash_input, $secret), 0, 6);
    
    # Costruisci indirizzo SRS0 con ID
    # Format: SRS0=hash=timestamp=domain=ID=local@bounce_domain
    my $srs_address = "SRS0=$hash=$timestamp=$domain=$forward_id=$local\@$bounce_domain";
    
    return $srs_address;
}

my $srs_sender = generate_srs_address($sender, $srs_secret, $bounce_domain, $forward_id);
syslog(LOG_INFO, "SRS riscritto: $sender -> $srs_sender (forward_id=$forward_id)");

# =====================================================================
# MODIFICA HEADERS
# =====================================================================

# Rimuovi eventuali Return-Path esistenti
$entity->head->delete('Return-Path');

# Aggiungi header informativi
$entity->head->add('X-SRS-Rewrite', "true");
$entity->head->add('X-Original-Sender', $sender);
$entity->head->add('X-Forwarded-For', $forward->{username});
$entity->head->add('X-Forwarded-To', $forward_to);
$entity->head->add('X-SRS-Forward-ID', $forward_id);

# =====================================================================
# INVIA EMAIL
# =====================================================================

eval {
    my $msg = Mail::Message->read($entity->stringify);
    
    my $smtp = Mail::Transport::SMTP->new(
        hostname => $SMTP_HOST,
        port     => $SMTP_PORT,
        from     => $srs_sender,
    );
    
    my $success = $smtp->send(
        $msg,
        to => $forward_to,
    );
    
    unless ($success) {
        die "SMTP send failed\n";
    }
    
    syslog(LOG_INFO, "Email inoltrata con successo da $sender a $forward_to");
};

if ($@) {
    syslog(LOG_ERR, "Errore invio email: $@");
    
    # Incrementa contatore bounce nel DB
    $dbh->do(q{
        UPDATE forward 
        SET bounce_count = bounce_count + 1,
            last_bounce = NOW()
        WHERE id = ?
    }, undef, $forward_id);
    
    # Se troppi bounce, disabilita il forward
    my ($bounce_count) = $dbh->selectrow_array(q{
        SELECT bounce_count FROM forward WHERE id = ?
    }, undef, $forward_id);
    
    if ($bounce_count >= 5) {
        $dbh->do(q{
            UPDATE forward 
            SET active = 0,
                disabled_reason = 'Too many failures'
            WHERE id = ?
        }, undef, $forward_id);
        syslog(LOG_WARNING, "Forward ID $forward_id disabilitato per troppi errori");
    }
    
    $dbh->disconnect;
    die "Forward failed\n";
}

# =====================================================================
# CLEANUP
# =====================================================================

$dbh->disconnect;
closelog();

exit 0;

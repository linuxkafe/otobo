#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use DBI;
use LWP::UserAgent;
use HTTP::Request::Common qw(POST GET DELETE);
use JSON::MaybeXS;
# use Parallel::ForkManager; # <-- Removido
use HTML::Entities 'decode_entities';
use File::Basename qw(basename);
use File::Spec;
use Getopt::Long;
use POSIX qw( strftime );
use Time::HiRes qw(sleep); # <-- Adicionado para 'sleep' com backoff

# --- INÍCIO DA ALTERAÇÃO (Cache Buster Otimizado) ---
# Usar um carimbo UNIX como ID, que é mais curto
my $run_id = time(); 
# --- FIM DA ALTERAÇÃO ---

# --- Configuração ---
my $db_name     = "otobo";
# User/Pass/Host virão do .my.cnf
my $export_dir  = "/root/scripts/llm/files/";
my $api_key     = "sk-**********************";
my $api_url_base= "https://linuxkafe.com";
my $knowledge_id= "*******-**********-**************";
# my $max_parallel= 1; # <-- Removido
my $max_retries = 3; # <-- Número de tentativas por chamada API
my $retry_delay = 1; # <-- Tempo base de espera (segundos)
# --- Fim Configuração ---

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

sub log_msg {
    my ($level, $message) = @_;
    my $timestamp = strftime "%Y-%m-%d %H:%M:%S", localtime;
    print STDERR "[$timestamp] [$level] $message\n";
}

log_msg("INFO", "Iniciando Sync. Run ID: $run_id");

# NOTA: A função clean_filename já não é usada para nomes de ficheiro
# com a alteração abaixo, mas pode ser mantida.
sub clean_filename {
    my $subject = shift // "";
    $subject =~ s/[\/:*?"<>|@(),]/_/g;
    $subject =~ s/\s+/ /g; $subject =~ s/^\s+|\s+$//g;
    $subject = substr($subject, 0, 200) if length($subject) > 200;
    return $subject || "faq_sem_titulo";
}

sub clean_content {
    my $text = shift // "";
    # Decodificar entidades PRIMEIRO
    eval { decode_entities($text); };
    if ($@) { log_msg("WARN", "Erro ao descodificar entidades: $@"); }

    $text =~ s/<[^>]*>//g; # Remove HTML

    # Remover o caractere 'bullet' (•) que estava a causar problemas
    $text =~ s/•//g;

    $text =~ s/\s+/ /g;    # Whitespace vira espaço
    $text =~ s/\\n/ /g;    # Literal \n
    $text =~ s/\\r/ /g;    # Literal \r
    $text =~ s/\\t/ /g;    # Literal \t
    
    # --- ALTERAÇÃO: A linha abaixo foi comentada ---
    # Esta linha estava a remover todos os acentos, 'ç' e pontuação.
    # $text =~ s/[^A-Za-z0-9 ]//g;
    # --- Fim da alteração ---

    $text =~ s/ {2,}/ /g;    # Colapsa espaços
    $text =~ s/^\s+|\s+$//g; # Trim
    return $text;
}


my $ua = LWP::UserAgent->new(timeout => 120, agent => "SyncFAQScript/1.0");

sub api_request_lwp {
    my ($request) = @_;
    $request->header('Authorization' => "Bearer $api_key");
    $request->header('Accept' => 'application/json');
    log_msg("DEBUG", "API Request: " . $request->method . " " . $request->uri);
    my $response = $ua->request($request);

    unless ($response->is_success) {
        log_msg("ERROR", "API Request Failed: " . $response->status_line);
        log_msg("ERROR", "Response Content: " . ($response->decoded_content(-limit => 500) || 'N/A'));
        # Retorna a própria resposta LWP em caso de erro HTTP para análise posterior
        return $response;
    }

    my $json_data = undef;
    my $content = $response->decoded_content; # Tenta sempre descodificar
    if (length $content) {
        if ($response->header('Content-Type') && $response->header('Content-Type') =~ /application\/json/) {
            eval { $json_data = decode_json($content); };
            if ($@) {
                log_msg("ERROR", "Failed to decode JSON (HTTP OK) from " . $request->uri . ": $@");
                log_msg("ERROR", "Response Content: " . $content);
                # Retorna a resposta LWP + flag de erro JSON
                return { _lwp_response => $response, _json_error => 1 };
            }
            # Retorna o JSON decodificado + a resposta LWP original
            return { _lwp_response => $response, _json_data => $json_data };
        } else {
             log_msg("WARN", "API response is not JSON (" . $request->uri . "). Status: " . $response->code . ". Content: " . substr($content, 0, 200));
             # Retorna a resposta LWP + flag not_json
             return { _lwp_response => $response, _not_json => 1 };
        }
    } else {
      # HTTP Success sem conteúdo
      # Retorna a resposta LWP + flag no_content
      return { _lwp_response => $response, _no_content => 1 };
    }
}


# --- Parte 1: Extração e Limpeza de Dados ---
log_msg("INFO", "Limpando ficheiros antigos de $export_dir...");
unless (-d $export_dir) { require File::Path; File::Path::make_path($export_dir) or die "..."; }
my @old_files = glob(File::Spec->catfile($export_dir, '*.txt'));
unlink @old_files or log_msg("WARN", "Não foi possível apagar alguns ficheiros antigos: $!") if @old_files;

log_msg("INFO", "Exportando e limpando itens da FAQ do banco de dados...");
my $dsn = "DBI:mysql:database=$db_name";
my $dbh_options = { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 };
$dbh_options->{mysql_read_default_file} = File::Spec->catfile($ENV{HOME}, '.my.cnf') if $ENV{HOME};
my $dbh = DBI->connect($dsn, undef, undef, $dbh_options)
    or die "Erro ao conectar à base de dados ($dsn) usando .my.cnf: $DBI::errstr";

my $sql = "SELECT id, f_subject, f_field1, f_field2, f_field3, f_field4, f_field5, f_field6 FROM faq_item";
my $sth = $dbh->prepare($sql); $sth->execute();
my @files_to_upload;
while (my @row = $sth->fetchrow_array()) {
    my ($faq_id, $f_subject, @fields) = @row;
    $f_subject //= "";
    my $full_content = $f_subject;
    foreach my $field (@fields) { $full_content .= " " . ($field // ""); }
    my $cleaned_content = clean_content($full_content);
    if ($cleaned_content eq "") { log_msg("WARN", "Ignorado (Vazio): $f_subject (ID: $faq_id)..."); next; }
    
    # --- ALTERAÇÃO: Usar o ID da FAQ para o nome do ficheiro ---
    my $filename = File::Spec->catfile($export_dir, "faq_" . $faq_id . ".txt");
    # --- Fim da Alteração ---

    my $fh;
    unless (open($fh, ">:utf8", $filename)) {
        # Se falhar (ex: permissões), regista o erro e passa ao próximo.
        log_msg("ERROR", "Erro fatal ao abrir $filename: $! (FAQ ID: $faq_id)");
        next;
    }
    
    # --- INÍCIO DA CORREÇÃO (CACHE BUSTER Otimizado) ---
    # Adiciona um ID único como comentário HTML para forçar um novo hash
    # e minimizar a interferência com o RAG.
    print $fh "\n";
    # --- FIM DA CORREÇÃO ---
    
    print $fh $cleaned_content;
    
    close($fh);
    log_msg("INFO", "Criado: $filename (ID: $faq_id)");
    push @files_to_upload, $filename;
}
$sth->finish(); $dbh->disconnect();
log_msg("INFO", "Exportação concluída. ". scalar(@files_to_upload) . " ficheiros para upload.");

# --- Parte 2: Limpeza da KB (APENAS Desassociação) ---
log_msg("INFO", "Listando ficheiros na KB $knowledge_id...");
my $list_req = GET "$api_url_base/api/v1/knowledge/$knowledge_id";
my $list_data_resp = api_request_lwp($list_req); # Agora retorna um hash
my @file_ids_to_remove;

# Verifica se a chamada foi bem sucedida e se temos dados JSON
if (defined $list_data_resp && $list_data_resp->{_lwp_response}->is_success && $list_data_resp->{_json_data}) {
    my $json = $list_data_resp->{_json_data};
    if ($json->{files} && ref $json->{files} eq 'ARRAY') {
        @file_ids_to_remove = map { $_->{id} } grep { $_->{id} } @{$json->{files}};
    } else {
        log_msg("WARN", "Resposta da API OK, mas sem array 'files'.");
    }
} else {
    log_msg("WARN", "Falha ao obter lista de ficheiros válidos da KB ou KB está vazia.");
    # O erro HTTP já foi logado por api_request_lwp
}

if (!@file_ids_to_remove) { log_msg("INFO", "Nenhum ficheiro na KB para desassociar."); }
else {
    log_msg("INFO", "Iniciando a desassociação de ". scalar(@file_ids_to_remove) . " ficheiros...");
    foreach my $file_id (@file_ids_to_remove) {
        
        # --- PASSO 2A: Desassociar ---
        my $remove_success = 0;
        for (my $attempt = 1; $attempt <= $max_retries; $attempt++) {
            log_msg("INFO", "Desassociando ficheiro ID: $file_id (Tentativa $attempt/$max_retries)...");
            my $remove_payload = encode_json({ file_id => $file_id });
            my $remove_req = POST "$api_url_base/api/v1/knowledge/$knowledge_id/file/remove",
                                    Content_Type => 'application/json', Content => $remove_payload;
            
            my $remove_resp_data = api_request_lwp($remove_req);

            if (defined $remove_resp_data && $remove_resp_data->{_lwp_response}->is_success) {
                my $json = $remove_resp_data->{_json_data}; 
                if ($json && exists $json->{detail} && defined $json->{detail}) {
                    if ($json->{detail} =~ /not found/i) {
                        log_msg("WARN", "Aviso: Ficheiro $file_id não encontrado na KB.");
                    } else {
                        log_msg("ERROR", "Falha ao desassociar $file_id. Detalhe API: " . $json->{detail});
                    }
                } else {
                    log_msg("INFO", "Ficheiro $file_id desassociado com sucesso.");
                }
                $remove_success = 1;
                last; # Sucesso, sai do loop de retentativa
            } else {
                # Falha HTTP (logada por api_request_lwp)
                log_msg("WARN", "Falha na requisição HTTP para desassociar $file_id (Tentativa $attempt).");
                if ($attempt < $max_retries) {
                    my $wait = $retry_delay * (2 ** ($attempt - 1)); # Backoff (1, 2 seg)
                    log_msg("INFO", "Aguardando $wait seg. antes de tentar novamente...");
                    sleep $wait;
                }
            }
        } # fim for $attempt

        unless ($remove_success) {
             log_msg("ERROR", "Falha permanente ao desassociar $file_id (ver logs anteriores).");
        }
        
        # --- PASSO 2B (DELETE) foi REMOVIDO porque a API deu 404 ---

    } # fim do loop 'foreach my $file_id'
    log_msg("INFO", "Desassociação concluída.");
} # fim do 'else'

# --- Parte 3: Upload de Novos Ficheiros ---
log_msg("INFO", "Iniciando upload sequencial de ".scalar(@files_to_upload)." ficheiros...");
my $upload_errors = 0;

# Loop principal sequencial, sem ForkManager
foreach my $file (@files_to_upload) {
    my $file_basename = basename($file);
    log_msg("INFO", "Processando $file_basename...");
    
    unless (-r $file) {
        log_msg("ERROR", "Não lê $file");
        $upload_errors++;
        next;
    }
    if (-z $file) {
        log_msg("WARN", "Ficheiro $file está vazio no disco. A saltar upload.");
        next;
    }

    my ($upload_resp, $upload_json, $file_id);
    my $upload_success = 0;

    # --- Tentativa 1: Upload do Ficheiro ---
    for (my $attempt = 1; $attempt <= $max_retries; $attempt++) {
        log_msg("DEBUG", "Upload $file_basename (Tentativa $attempt/$max_retries)...");
        my $upload_req = POST "$api_url_base/api/v1/files/", Content_Type => 'form-data', Content => [ file => [$file] ];
        $upload_req->header('Authorization' => "Bearer $api_key"); $upload_req->header('Accept' => 'application/json');
        
        # Usa o $ua principal, não um $ua_child
        $upload_resp = $ua->request($upload_req); 
        
        if ($upload_resp->is_success) {
            eval { $upload_json = decode_json($upload_resp->decoded_content); };
            if ($@ || !$upload_json || !$upload_json->{id}) {
                log_msg("WARN", "Upload $file_basename (Tentativa $attempt) OK mas JSON inválido: $@ Cont: ".substr($upload_resp->decoded_content(-limit=>200),0,200));
                last; # Não tentar novamente se o JSON for inválido
            }
            $file_id = $upload_json->{id};
            $upload_success = 1;
            log_msg("INFO", "Upload OK $file_basename (ID: $file_id). Adicionando à KB...");
            last; # Sucesso, sai do loop de retentativa
        } else {
            log_msg("WARN", "Upload $file_basename (Tentativa $attempt) falhou: ".$upload_resp->status_line);
            if ($attempt < $max_retries) {
                my $wait = $retry_delay * (2 ** ($attempt - 1)); # Backoff (1, 2 seg)
                log_msg("INFO", "Aguardando $wait seg. antes de tentar novamente...");
                sleep $wait;
            }
        }
    }

    unless ($upload_success && $file_id) {
        log_msg("ERROR", "Upload falhou permanentemente para $file_basename. Resposta: ".($upload_resp ? $upload_resp->status_line : 'N/A'));
        $upload_errors++;
        next; # Passa ao próximo ficheiro
    }

    # --- Tentativa 2: Adicionar à KB ---
    my ($add_resp, $add_json);
    my $add_success = 0;
    my $add_content = '';

    for (my $attempt = 1; $attempt <= $max_retries; $attempt++) {
        log_msg("DEBUG", "Add KB $file_id (Tentativa $attempt/$max_retries)...");
        my $add_payload = encode_json({ file_id => $file_id });
        my $add_req = POST "$api_url_base/api/v1/knowledge/$knowledge_id/file/add", Content_Type => 'application/json', Content => $add_payload;
        $add_req->header('Authorization' => "Bearer $api_key"); $add_req->header('Accept' => 'application/json');
        
        $add_resp = $ua->request($add_req);
        $add_content = $add_resp->decoded_content(-limit=>500);

        if ($add_resp->is_success) {
            eval { $add_json = decode_json($add_content); };
            if ($@) {
                log_msg("WARN", "Add $file_id (Tentativa $attempt) OK mas JSON inválido: $@. Cont: $add_content. Presumindo sucesso.");
            } elsif ($add_json && $add_json->{created_at}) {
                log_msg("INFO", "Sucesso: $file_basename (ID: $file_id) adicionado.");
            } else {
                if ($add_json && $add_json->{detail}) {
                    if ($add_json->{detail}=~/duplicate|already exists/i) { log_msg("INFO", "Nota: $file_basename (ID: $file_id) - Já existe (JSON OK)."); }
                    else { log_msg("WARN", "Add $file_id (Tentativa $attempt) OK mas JSON com erro inesperado: ".$add_json->{detail}); }
                } else {
                    log_msg("WARN", "Add $file_id (Tentativa $attempt) OK mas JSON inesperado (sem created_at/detail): $add_content");
                }
            }
            $add_success = 1; # Considera sucesso ou duplicado como sucesso
            last; # Sai do loop de retentativa
        } else {
            # Falha HTTP
            eval { $add_json = decode_json($add_content); };
            if ($add_json && $add_json->{detail}) {
                if ($add_json->{detail}=~/duplicate|already exists/i) {
                    log_msg("INFO", "Nota: $file_basename (ID: $file_id) - Já existe (HTTP 400).");
                    $add_success = 1;
                    last; # É um "sucesso"
                } elsif ($add_json->{detail}=~/content provided is empty/i) {
                    log_msg("WARN", "Falha Add (Empty API): $file_basename (ID: $file_id).");
                    $add_success = 1; # Não é um erro fatal
                    last; 
                } else {
                     log_msg("WARN", "Falha Add KB (API Detail) $file_id (Tentativa $attempt): ".$add_json->{detail});
                }
            } else {
                log_msg("WARN", "Falha Add KB Req $file_id (Tentativa $attempt). Status: ".$add_resp->status_line);
            }
            
            if ($attempt < $max_retries && !$add_success) {
                 my $wait = $retry_delay * (2 ** ($attempt - 1));
                 log_msg("INFO", "Aguardando $wait seg. antes de tentar novamente...");
                 sleep $wait;
            }
        }
    } # fim for $attempt
    
    unless ($add_success) {
         log_msg("ERROR", "Add KB falhou permanentemente para $file_id ($file_basename). Resposta: ".($add_resp ? $add_resp->status_line : 'N/A'));
         $upload_errors++;
    }
} # Fim do foreach $file

log_msg("INFO", "Upload de ficheiros concluído.");
if ($upload_errors > 0) { log_msg("WARN", "$upload_errors uploads falharam."); }
log_msg("INFO", "Sincronização concluída.");
exit($upload_errors > 0 ? 1 : 0);

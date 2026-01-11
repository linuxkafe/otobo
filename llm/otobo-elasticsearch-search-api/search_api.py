#!/usr/bin/env python3

import http.server
import socketserver
import urllib.parse
import json
import datetime
import re
from elasticsearch import Elasticsearch

# --- Configuração ---
PORT = 5678
HOST = 'localhost'  # Escuta APENAS localmente (para o Apache Proxy)

# !! ADICIONE O SEU SEGREDO PARTILHADO AQUI !!
API_KEY = "*****************************************************"

# Configuração da ligação ao Elasticsearch
ES_CONFIG = {
    'host': 'localhost',
    'port': 9200
    # Adicione user/pass se necessário:
    # 'http_auth': ('username', 'password')
}
ES_INDEX = "ticket"

# Filtro Estático (o seu filtro 'From')
FROM_FILTER = ["Helpdesk <helpdesk@linuxkafe.com>", "helpdesk@linuxkafe.com"]

# Variável de Filtro de Fila (colocar os IDs das filas a serem pesquisadas)
QUEUEID_FILTER = [1, 2, 3]

# Padrões a ocultar (Regex)
PATTERNS_TO_HIDE = [
    r"https://keysender\.linuxkafe\.com/lounge\.php\?\S+",
    r"https://filesender\.linuxkafe\.com/\?s=download\S+"
]
# ---------------------------------------------


# Inicializa o cliente Elasticsearch
try:
    es = Elasticsearch([ES_CONFIG])
    if not es.ping():
        print("Erro: Nao foi possivel ligar ao Elasticsearch em localhost:9200.")
        exit(1)
except Exception as e:
    print(f"Erro ao inicializar cliente Elasticsearch: {e}")
    exit(1)


class MyHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        try:
            # --- VERIFICAÇÃO DA API KEY ---
            received_key = self.headers.get('X-API-Key')
            if received_key != API_KEY:
                self.send_response(401) # Unauthorized
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"error": "Autenticacao invalida ou ausente"}')
                return
            # --------------------------------

            parsed_path = urllib.parse.urlparse(self.path)
            query_params = urllib.parse.parse_qs(parsed_path.query)
            search_query = query_params.get('q', [''])[0]

            if not search_query:
                self.send_response(400) # Bad Request
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"error": "Parametro \\"q\\" em falta"}')
                return

            # --- (2) CÁLCULO DO TIMESTAMP (para filtro de 1 ano) ---
            # O campo 'Created' é 'long', logo espera um timestamp Unix (segundos)
            now_dt = datetime.datetime.now()
            # Usamos 365 dias como "1 ano"
            one_year_ago_dt = now_dt - datetime.timedelta(days=365)
            
            # Converter para timestamp (inteiro, em segundos)
            timestamp_now = int(now_dt.timestamp())
            timestamp_one_year_ago = int(one_year_ago_dt.timestamp())
            # -----------------------------------------------------

            # --- Constrói a Query DSL do Elasticsearch (VALIDADA PELO MAPPING) ---
            es_query_dsl = {
                "size": 5,
                # --- MODIFICADO: Garantir que pedimos Body e From Externos ---
                "_source": ["Title", "TicketID", "ArticlesExternal.Body", "ArticlesExternal.From", "AttachmentsExternal.Content"],
                "query": {
                    "bool": {
                        "must": [
                            # Pesquisa apenas nos campos "sinal" e ignora o "ruído"
                            {
                                "multi_match": {
                                    "query": search_query,
                                    "fields": [
                                        "Title",
                                        # --- MODIFICADO: Pesquisar no Body Externo ---
                                        "ArticlesExternal.Body",
                                        "AttachmentsExternal.Content",
                                        "AttachmentsInternal.Content"
                                    ]
                                }
                            }
                        ],
                        "filter": [
                            # O seu filtro "From" (correto)
                            {
                                "bool": {
                                    "should": [
                                        {"terms": {"ArticlesExternal.From.keyword": FROM_FILTER}},
                                        {"terms": {"ArticlesInternal.From.keyword": FROM_FILTER}}
                                    ],
                                    "minimum_should_match": 1
                                }
                            },
                            # Filtro de QueueID (com variável)
                            {
                                "terms": {
                                    "QueueID": QUEUEID_FILTER
                                }
                            }, 
                            # --- (3) MODIFICAÇÃO: Filtro de data (1 ano) usando Timestamp ---
                            {
                                "range": {
                                    "Created": {
                                        "gte": timestamp_one_year_ago,
                                        "lt": timestamp_now
                                    }
                                }
                            }
                            # ---------------------------------------------
                        ]
                    }
                }
            }
            # ---------------------------------------------

            # (4) Executa a pesquisa
            response = es.search(index=ES_INDEX, body=es_query_dsl)

            # --- Formata a resposta para o SearXNG (COM PRIORIDADE INVERTIDA) ---
            results_list = []
            for hit in response.get('hits', {}).get('hits', []):
                source = hit.get('_source', {})
                title = source.get('Title')
                ticket_id = source.get('TicketID')
                
                # Encontra o primeiro snippet de conteúdo disponível
                content = ""
                
                # --- LÓGICA DE PRIORIDADE CORRIGIDA ---
                
                # Prioridade 1: Artigos Externos (Mas SÓ do Helpdesk)
                if not content and 'ArticlesExternal' in source:
                    # Iterar por todos os artigos externos
                    for article in source.get('ArticlesExternal', []):
                        # --- MODIFICADO: Verificar se o 'From' está na lista de filtros ---
                        if article.get('From') in FROM_FILTER and article.get('Body'):
                            content = article.get('Body')
                            break # Encontrámos uma resposta do helpdesk
                
                # Prioridade 2: Anexos Externos (se não houver resposta do helpdesk)
                # (Nota: Isto deve estar FORA do loop 'for article' anterior)
                if not content and 'AttachmentsExternal' in source:
                     for attachment in source.get('AttachmentsExternal', []):
                        if attachment.get('Content'):
                            content = attachment.get('Content')
                            break
                
                # Artigos Internos (Notas) e Artigos Externos (do Cliente) são ignorados
                
                # --- LIMPEZA DE DADOS SENSÍVEIS (REGEX) ---
                if content:
                    for pattern in PATTERNS_TO_HIDE:
                        # Substitui o link por [REMOVIDO]
                        content = re.sub(pattern, "[REMOVIDO]", content)
                # ------------------------------------------

                results_list.append({
                    "title": title,
                    "ticket_id": ticket_id,
                    "content": content
                })
            # ---------------------------------------------
            
            # Envia a resposta JSON
            self.send_response(200) # OK
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(results_list).encode('utf-8'))

        except Exception as e:
            self.send_response(500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"error": "Erro interno da API", "details": str(e)}).encode('utf-8'))


print(f"A escutar em {HOST}:{PORT}...")
print(f"Ligado ao Elasticsearch em {ES_CONFIG['host']}:{ES_CONFIG['port']}, Indice: {ES_INDEX}")

with socketserver.TCPServer((HOST, PORT), MyHandler) as httpd:
    httpd.serve_forever()

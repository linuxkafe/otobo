# /usr/local/searxng/searx/engines/otobo_tickets.py

import urllib.parse
from lxml import html # Embora não usemos lxml, é boa prática mantê-lo se o template o tinha

# --- CONFIGURAÇÃO (EDITAR ESTES VALORES) ---

# 1. O URL público do seu OTOBO (para construir os links)
# Ex: "https://tickets.uporto.pt"
OTOBO_BASE_URL = "https://tickets.linuxkafe.com"

# 2. O URL COMPLETO DO SEU REVERSE PROXY SEGURO
# (Este é o endpoint HTTPS que você criou no Nginx/Caddy)
TICKETS_API_URL = "https://tickets.linuxkafe.com/searx-api-tickets/" 

# 3. A CHAVE DE API (DEVE SER IGUAL À DO search_api.py)
API_KEY = "***************************************"

# ----------------------------------------------

# Configuração do motor
categories = ['general', 'it']
paging = False
language_support = False
about = {
    "website": OTOBO_BASE_URL,
    "wikidata_id": None,
    "official_api_documentation": '',
    "use_official_api": True,
    "require_api_key": False,
    "results": 'JSON',
}

# 1. FUNÇÃO PARA CONSTRUIR O URL DE PESQUISA (HTTPS + AUTH)
def request(query, params):
    """
    Constrói o URL para a nossa micro-API privada (via Reverse Proxy HTTPS).
    """
    
    # Usa o URL base seguro
    base_url = TICKETS_API_URL
    
    # Codifica a query do SearXNG para um parâmetro de URL
    query_params = {'q': query}
    query_string = urllib.parse.urlencode(query_params)
    
    params['url'] = base_url + '?' + query_string
    params['method'] = 'GET'
    params['timeout'] = 10 # Timeout de 10 segundos
    
    # !! ADICIONA O CABEÇALHO DE AUTENTICAÇÃO !!
    params['headers'] = {
        'X-API-Key': API_KEY
    }
    
    return params


# 2. FUNÇÃO PARA ANALISAR A RESPOSTA JSON
def response(resp):
    """
    Analisa a resposta JSON da nossa micro-API.
    """
    
    # Se a API falhar (500, 400, etc.)
    # Se a autenticação falhar (401), também cairá aqui.
    if not resp.ok:
        return []

    try:
        data = resp.json() # SearXNG trata de carregar o JSON
    except Exception as e:
        # print(f"Erro no motor otobo_tickets: JSON invalido - {e}")
        return []

    # Processa os resultados JSON
    results = []
    for item in data:
        try:
            title = item.get('title')
            ticket_id = item.get('ticket_id')
            
            # Pega o snippet de conteúdo e limita a 500 caracteres
            content = item.get('content', '')
            if content and len(content) > 500:
                content = content[:500] + '...'

            # Constrói o URL do ticket OTOBO
            url = f"{OTOBO_BASE_URL}/otobo/index.pl?Action=AgentTicketZoom;TicketID={ticket_id}"

            results.append(
                {
                    'title': title,
                    'url': url,
                    'content': content,
                }
            )
        except Exception:
            # Ignora resultados mal formados
            continue

    return results

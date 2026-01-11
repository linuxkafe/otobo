# /usr/local/searxng/searx/engines/updigital.py

# Usamos apenas módulos Python padrão para garantir que o motor carrega.
import urllib.parse
import urllib.request 
from lxml import html
import logging

# Configuração do motor
categories = ['general', 'it']
paging = False
language_support = True

# REMOVIDO: parsed_url = 'xpath' 

about = {
    # pylint: disable-line-too-long
    "website": 'https://up.pt/it',
    "wikidata_id": None,
    "official_api_documentation": '',
    "use_official_api": False,
    "require_api_key": False,
    "results": 'JSON',
}

# User-Agent para simular um browser
USER_AGENT_HEADER = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/108.0.0.0 Safari/537.36'
}

# --- INÍCIO DA MODIFICAÇÃO (Listas de Limpeza) ---

# Lista de prefixos (em minúsculas) que queremos remover
# Adicionada a sua sugestão "acessar "
PREFIXES_TO_STRIP = [
    "como configurar ",
    "onde encontrar ",
    "como aceder ",
    "o que é ",
    "como ",
    "onde ",
    "configurar ",
    "instalar ",
    "ajuda ",
    "acessar ",
    "aceder ",
]

# Lista de palavras (em minúsculas) que queremos remover
NOISE_WORDS_TO_REMOVE = [
    'updigital',
    'universidade',
    'up.pt',
    'u.porto',
    'up porto',
    'porto',
    'up',
    'reset',
    'recuperar',
    'de',
    'do',
    'a',
    'o',
]
# --- FIM DA MODIFICAÇÃO ---

# Setup do Logger
log = logging.getLogger(__name__)


# 1. FUNÇÃO PARA CONSTRUIR O URL DE PESQUISA (Página de Lista)
def request(query, params):
    """
    Constrói o URL para a pesquisa no portal UpDigital usando urllib.
    """

    original_query = query
    modified_query = query
    query_lower = query.lower()

    # --- INÍCIO DA MODIFICAÇÃO (Limpeza de Query) ---

    # 1. Remove Prefixos (ex: "como configurar ")
    for prefix in PREFIXES_TO_STRIP:
        if query_lower.startswith(prefix):
            modified_query = modified_query[len(prefix):].lstrip()
            query_lower = modified_query.lower() # Atualiza a versão lower
            break

    # 2. Remove Palavras-Ruído (ex: "UPdigital", "de", "a")
    #    Divide a query em palavras
    words_in_query = modified_query.split()

    # Reconstrói a lista de palavras, mantendo apenas as que NÃO são ruído
    final_words = []
    for word in words_in_query:
        if word.lower() not in NOISE_WORDS_TO_REMOVE:
            final_words.append(word)

    # Junta as palavras limpas
    modified_query = ' '.join(final_words)

    # Se a limpeza removeu tudo, reverte para a query original (para evitar pesquisas vazias)
    if not modified_query.strip():
        modified_query = original_query

    # --- FIM DA MODIFICAÇÃO ---


    # A base URL DEVE usar HTTPS
    base_url = 'https://www.up.pt/portal/pt/updigital/search/'
    query_params = {'query': modified_query}

    if params.get('language') and params['language'] != 'all':
        query_params['lang'] = params['language']

    query_string = urllib.parse.urlencode(query_params)
    params['url'] = base_url + '?' + query_string

    # Adiciona o User-Agent
    params['headers'] = USER_AGENT_HEADER

    # --- DEBUG LOG ---
    log.warning('DEBUG UPDIGITAL (Request): Query Original: %s', original_query)
    log.warning('DEBUG UPDIGITAL (Request): Query Modificada: %s', modified_query)
    log.warning('DEBUG UPDIGITAL (Request): A visitar URL da lista: %s', params['url'])
    # --- FIM DEBUG ---

    return params


# 2. FUNÇÃO PARA ANALISAR O HTML E EXTRAIR TUDO (LENTO)
def response(resp):
    """
    Analisa a lista E VISITA OS PRIMEIROS 3 LINKS (método síncrono).
    """
    if not resp.ok:
        log.warning('DEBUG UPDIGITAL (Response): Falha ao obter lista. Status: %s', resp.status_code)
        return []

    dom = html.fromstring(resp.text)
    results = []

    # XPath original do seu ficheiro
    results_list = dom.xpath('//main//ul/li')

    log.warning('DEBUG UPDIGITAL (Response): Encontrados %s resultados na lista.', len(results_list))

    if not results_list:
        return []

    BASE_URL = 'https://www.up.pt'

    # Itera com um contador (i)
    for i, li in enumerate(results_list):

        a_tags = li.xpath('./a') #

        if not a_tags: 
            continue

        a_tag = a_tags[0]

        # Extração de dados (Título e URL)
        url = a_tag.get('href', '')
        title = a_tag.text_content().strip()

        if url.startswith('/'):
            url = BASE_URL + url

        content = ' ' # Conteúdo por defeito

        # --- LÓGICA DE VISITA (Apenas os 3 primeiros) ---
        # Só visita os 3 primeiros resultados para evitar o TIMEOUT
        if i < 3:
            try:
                log.warning('DEBUG UPDIGITAL (Response): A visitar link [ %s / 10 ]: %s', (i+1), url)

                # Cria o pedido com o User-Agent
                req = urllib.request.Request(url, headers=USER_AGENT_HEADER)

                # Visita o link individual (LENTO)
                with urllib.request.urlopen(req, timeout=5) as details_resp:
                    if details_resp.status == 200:
                        html_content = details_resp.read()
                        details_dom = html.fromstring(html_content)

                        # XPath 1 (Principal,)
                        content_elements = details_dom.xpath("//div[contains(@class, 'richtext-content')]")

                        # XPath 2 (Fallback, se o 1 falhar)
                        if not content_elements:
                            log.warning('DEBUG UPDIGITAL (Response): XPath (richtext-content) falhou. A tentar fallback (//main)...')
                            content_elements = details_dom.xpath("//main")

                        if content_elements:
                            content_parts = [el.text_content().strip() for el in content_elements]
                            content = '\n'.join(part for part in content_parts if part)
                        else:
                            log.warning('DEBUG UPDIGITAL (Response): XPath falhou (richtext E main) em %s', url)
                    else:
                         log.warning('DEBUG UPDIGITAL (Response): Falha ao visitar link %s. Status: %s', url, details_resp.status)

            except Exception as e:
                log.warning('DEBUG UPDIGITAL (Response): Exceção ao visitar link %s: %s', url, str(e))
        # --- FIM DA LÓGICA DE VISITA ---

        if not content:
            content = ' ' # Garante que não está vazio

        results.append(
                {
                    'title': title,
                    'url': url,
                    'content': content, # Adiciona o conteúdo extraído (ou ' ')
                }
            )

    return results

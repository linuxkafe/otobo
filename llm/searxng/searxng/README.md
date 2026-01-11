# Motores SearXNG Personalizados (UPdigital e OTOBO Tickets)

Este documento descreve a instalação e configuração de dois motores de pesquisa personalizados para o SearXNG, desenhados para o ecossistema da Universidade do Porto.

1.  **UPdigital (`updigital.py`):** Um motor de *scraping* público que pesquisa o portal UPdigital (up.pt/it).
2.  **OTOBO Tickets (`tickets.py`):** Um motor interno seguro que pesquisa tickets do OTOBO através de um backend Elasticsearch, utilizando uma micro-API como intermediário.

---

## 1. Motor UPdigital (updigital.py)

Este motor pesquisa o portal público de IT da U.Porto (UPdigital).

### Funcionalidades Principais

* **Limpeza de Query:** O motor otimiza a pesquisa do utilizador antes de a enviar. Ele remove prefixos comuns (como "como configurar", "aceder a") e palavras-ruído ("up", "porto", "de", "a") para melhorar a relevância dos resultados.
* **Scraping Detalhado (Top 3):** Para os 3 primeiros resultados encontrados na lista de pesquisa, o motor visita ativamente o link de destino.
* **Extração de Conteúdo:** Ele extrai o conteúdo principal da página de destino (usando XPaths como `//div[contains(@class, 'richtext-content')]`) para fornecer um *snippet* de conteúdo rico e informativo diretamente na página de resultados do SearXNG.
* **Fallback:** Se a extração principal falhar, ele tenta um XPath de recurso (`//main`) para garantir que algum conteúdo seja capturado.

### Instalação

1.  Copie o ficheiro `updigital.py` para o diretório de motores do seu SearXNG.
    * Exemplo de localização: `/usr/local/searxng/searx/engines/`
2.  Adicione `updigital` à secção `engines` do seu ficheiro `settings.yml` para o ativar.

---

## 2. Motor OTOBO Tickets (tickets.py)

Este motor permite pesquisar *dentro* da base de dados de tickets do OTOBO (tickets.up.pt), utilizando o Elasticsearch como backend.

**Importante:** Este não é um motor de *scraping* simples. Ele depende de uma arquitetura de backend segura para proteger os dados dos tickets.

### Arquitetura da Solução

O fluxo de dados é o seguinte:

1.  **SearXNG (com `tickets.py`)** faz um pedido HTTPS.
2.  **Um Reverse Proxy (Nginx/Caddy)** (ex: `https://tickets.up.pt/searx-api-tickets/`) que valida o HTTPS e passa o pedido para...
3.  **A Micro-API Python (`search_api.py`)** (ex: `http://localhost:5678`) que verifica a `X-API-Key` e...
4.  **O Elasticsearch** que executa a pesquisa filtrada no índice de tickets e devolve os resultados à API.

### Componentes

#### A. A Micro-API (`search_api.py`)

Este é o *backend* que faz a ponte segura entre o SearXNG e o Elasticsearch.

* **Função:** Escuta em `localhost:5678` (ou outra porta interna).
* **Segurança:** Requer um cabeçalho de autenticação (`X-API-Key`) em todos os pedidos. Se a chave estiver errada ou ausente, devolve um erro `401 Unauthorized`.
* **Lógica:**
    * Recebe uma query simples (ex: `?q=eduroam`).
    * Constrói uma query DSL complexa para o Elasticsearch.
    * **Filtra** a pesquisa para incluir apenas os `QUEUEID_FILTER` (filas específicas) e `FROM_FILTER` (apenas respostas do Helpdesk).
    * Pesquisa nos campos `Title`, `ArticlesExternal.Body`, e anexos.
    * Formata e devolve os 5 melhores resultados (Título, TicketID, Conteúdo) em JSON.

#### B. O Motor SearXNG (`tickets.py`)

Este é o ficheiro que o SearXNG usa para *falar* com a micro-API.

* **Função:** Constrói o pedido para a micro-API privada.
* **Segurança:** Adiciona automaticamente o cabeçalho `X-API-Key` a cada pedido enviado.
* **Lógica:**
    * Aponta para o URL do *Reverse Proxy* (`TICKETS_API_URL`).
    * Recebe a resposta JSON da API.
    * Formata os resultados para o SearXNG, construindo o URL clicável para o OTOBO (ex: `...Action=AgentTicketZoom;TicketID=...`).

#### C. O Reverse Proxy (Ex: Nginx)

Este componente (que *você* deve configurar) é essencial para a segurança.

* **Função:** Expor a micro-API interna (`http://localhost:5678`) à rede de forma segura através de HTTPS.
* **Exemplo (Nginx):**
    ```nginx
    # No seu bloco server HTTPS para tickets.up.pt
    
    location /searx-api-tickets/ {
        # O IP/Porto onde o search_api.py está a correr
        # (use 127.0.0.1 se estiver na mesma máquina)
        proxy_pass http://localhost:5678/; 
        
        # Passar os cabeçalhos necessários para a API
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    ```

### Guia de Instalação (Motor OTOBO)

#### Passo 1: Configurar a Micro-API (`search_api.py`)

1.  **Localização:** Coloque `search_api.py` no servidor que tem acesso ao Elasticsearch (idealmente, o próprio servidor Elasticsearch ou um servidor de aplicações).
2.  **Dependências:** Instale a biblioteca Elasticsearch: `pip install elasticsearch`.
3.  **Configuração:** Edite as constantes no topo do `search_api.py`:
    * `PORT` e `HOST`: `5678` e `localhost` são recomendados (escuta apenas local).
    * `API_KEY`: **Gere um segredo forte e único.** (ex: `openssl rand -hex 30`). Deve ser igual ao `API_KEY` em `tickets.py`.
    * `ES_CONFIG`: Confirme o `host` e `port` do seu Elasticsearch.
    * `ES_INDEX`: Confirme o nome do índice (ex: `ticket`).
    * `FROM_FILTER` e `QUEUEID_FILTER`: Ajuste estes filtros às suas necessidades.
4.  **Execução:** Execute o script como um serviço persistente (usando `systemd`, `supervisor`, ou `screen`):
    ```bash
    python3 search_api.py
    ```

#### Passo 2: Configurar o Reverse Proxy

1.  Configure o seu servidor web (Nginx, Caddy, Apache) para fazer proxy de um URL público (ex: `/searx-api-tickets/`) para o serviço interno (`http://localhost:5678`), como mostrado no exemplo Nginx acima.
2.  **Certifique-se de que este endpoint está protegido por HTTPS.**

#### Passo 3: Configurar o Motor SearXNG (`tickets.py`)

1.  **Localização:** Copie `tickets.py` para o diretório de motores do SearXNG (ex: `/usr/local/searxng/searx/engines/`).
2.  **Configuração:** Edite as constantes no topo do `tickets.py`:
    * `OTOBO_BASE_URL`: O URL público do seu OTOBO (ex: `"https://tickets.up.pt"`).
    * `TICKETS_API_URL`: O URL **completo** do Reverse Proxy que criou no Passo 2 (ex: `"https://tickets.up.pt/searx-api-tickets/"`).
    * `API_KEY`: A chave secreta **exatamente igual** à que definiu no `search_api.py`.
3.  **Ativação:** Adicione `otobo_tickets` (ou o nome do ficheiro) à secção `engines` do seu `settings.yml`.

### Considerações de Segurança 🚨

* **Firewall:** A porta da Micro-API (ex: `5678`) **NÃO DEVE** estar aberta à Internet. Deve aceitar ligações apenas de `localhost` ou do IP do seu Reverse Proxy.
* **API Key:** A `API_KEY` é a única proteção da sua API de pesquisa. Trate-a como uma password.
* **HTTPS:** O Reverse Proxy **DEVE** usar HTTPS. Isto impede que a `API_KEY` e os dados de pesquisa sejam transmitidos em texto claro.

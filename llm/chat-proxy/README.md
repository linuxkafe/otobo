# README: LLM Proxy (chat_proxy.py)

Este serviço (`chat_proxy.py`) atua como um proxy intermediário seguro entre o frontend do OTOBO (`myhelpdesk.up.pt`) e uma API de backend de LLM (neste caso, a API do OpenWebUI).

O objetivo principal é expor a API do chatbot de forma controlada, utilizando a infraestrutura de autenticação existente do Apache (Shibboleth) para proteger o acesso ao modelo de linguagem. O script corre localmente no servidor e só é exposto publicamente através do Apache.

---

## 🚀 Funcionalidades

* **Proxy API:** Recebe pedidos nos endpoints `/api/chat` (para processar perguntas) e `/api/health` (para verificação de estado pelo frontend).
* **Integração OpenWebUI:** Comunica com o backend do OpenWebUI para obter as respostas do chat.
* **Serviço Local:** Corre como um serviço leve em `llm.uporto.pt` (ex: porta `5001`), acessível apenas pelo Apache na mesma máquina.

---

## 🛠️ Configuração e Dependências

Este serviço foi desenhado para ser servido por trás de um proxy reverso Apache, que também gere a autenticação.

### 1. Dependências (Exemplo)

O script `chat_proxy.py` (normalmente um script Python/Flask ou similar) necessita de bibliotecas como:

* `flask` (para criar o servidor web)
* `requests` (para comunicar com a API OpenWebUI)
* `gunicorn` (recomendado para produção)
* `python-dotenv` (para gerir chaves de API, etc.)

### 2. Configuração do Apache (Proxy Reverso)

Para que o frontend do OTOBO possa aceder a este script (que corre em `http://llm.uporto.pt:5001/`) através do URL público `/llmproxy/`, a configuração do Virtual Host do Apache (ex: `myhelpdesk.up.pt.conf`) deve incluir:

```apache
# Permite que o Apache funcione como proxy
SSLProxyEngine On
ProxyPreserveHost On

# Redireciona /llmproxy/ para o script local na porta 5001
ProxyPass /llmproxy/ http://llm.uporto.pt:5001/
ProxyPassReverse /llmproxy/ http://localhost:5001/

# Protege o endpoint com Shibboleth
<Location /llmproxy>
    AuthType shibboleth
    ShibRequestSetting applicationId myhelpdesk
    ShibRequireSession On
    require shibboleth
    ShibRequestSetting redirectToSSL 443
    #ShibRequireAll on
    require valid-user
</Location>

# Formulário de Suporte com Sugestões e Chatbot (CakePHP)

Este template fornece um formulário de contacto padrão (Subscrição + Mensagem) e integra duas funcionalidades avançadas de JavaScript para melhorar a experiência do utilizador:

1.  **Sugestões Dinâmicas (AJAX)**: Enquanto o utilizador escreve uma mensagem, o script analisa a última palavra e faz um pedido `fetch` a um endpoint da API do CakePHP (`/pesquisa-portal`) para sugerir links de ajuda relevantes.
2.  **Assistente Virtual (Chatbot)**: Um botão de chat é adicionado dinamicamente ao `<aside>` da página. Ao ser clicado, abre uma janela de chat flutuante que se liga a um backend de LLM (ex: `/llmproxy/api/chat`).

## 1. Implementação e Fragmentos de Código

Abaixo estão os três componentes (HTML, CSS, JavaScript) necessários para o funcionamento do **Assistente Virtual (Chatbot)**.

### 1.1. Fragmento HTML do Chat

Este bloco deve ser colocado no seu template (`suporte.php`) **fora** de qualquer outro `<form>` (como o formulário de Suporte) para evitar conflitos de "form nesting". Um bom local é imediatamente antes de fechar a tag `</body>`.

```html
<div id="chat-widget-container" style="visibility: hidden;">
    <div id="chat-bubble" class="chat-button-in-aside" style="visibility: hidden;">
        <span style="font-size: 1.1em; margin-right: 8px;">&#128172;</span>
        <span style="font-weight: bold; font-size: 0.9rem;">Abrir Assistente Virtual</span>
    </div>

    <div id="chat-popup" class="chat-popup">
        <div class="chat-popup-header">
            <h3>Assistente Virtual</h3>
            <span class="chat-close-btn">&times;</span>
        </div>
        <div id="chat-container" class="chat-container">
            </div>
        <form id="chat-form" class="chat-form">
            <input type="text" id="chat-input" placeholder="Escreva a sua mensagem..." autocomplete="off" />
            <button type="submit" aria-label="Enviar">&#9658;</button>
        </form>
    </div>
</div>

** Erros comuns **
O serviço não pode ser executado diretamente pelo Python, se o quiser executar manualmente basta executar o comando gunicorn -w 4 chat_proxy:app

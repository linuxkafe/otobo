# Adaptador OpenWebUI para API iaedu.pt (Versão 2)

Este projeto é um servidor *adapter* (middleware) em Node.js. O seu objetivo principal é atuar como uma "ponte" de tradução entre o [OpenWebUI](https://github.com/open-webui/open-webui) e uma API proprietária (iaedu.pt).

O OpenWebUI comunica usando o formato da API OpenAI (JSON), enquanto a API `iaedu.pt` espera um formato `multipart/form-data` e devolve um *stream* de objetos JSON (NDJSON). Este *adapter* faz a conversão em tempo real.

**Funcionalidades desta Versão:**

  * Converte pedidos OpenAI para o formato `FormData` da iaedu.pt.
  * Converte o *stream* de resposta NDJSON para o formato `text/event-stream` (SSE) que o OpenWebUI espera.
  * **Gestão de Sessão:** Mapeia o `chat_id` do OpenWebUI para o `thread_id` da API iaedu.pt, permitindo conversas com contexto separado.
  * **Segurança:** A API key é lida a partir de variáveis de ambiente do sistema, não estando *hardcoded* no código-fonte.

## Pré-requisitos

  * Um servidor Linux (ex: Ubuntu, Debian) com acesso `sudo`.
  * [Node.js](https://nodejs.org/) (versão 18+ recomendada) e `npm`.
  * OpenWebUI a correr (provavelmente em Docker).
  * Acesso de rede do servidor para `api.iaedu.pt`.

## Instalação e Configuração

Esta instalação assume que o *adapter* corre em `/opt/iaedu-adapter` e é gerido por um serviço `systemd` com o utilizador `www-data`.

### Passo 1: Criar o Ficheiro do Adapter

1.  Crie o diretório do projeto:

    ```bash
    sudo mkdir -p /opt/iaedu-adapter
    ```

2.  Crie o ficheiro do *adapter* usando o editor de texto **Vim** (Regra 1):

    ```bash
    sudo vim /opt/iaedu-adapter/adapter-server.mjs
    ```

3.  Pressione `i` para entrar no Modo de Inserção e cole o seguinte conteúdo **completo** (Regra 2):

    ```javascript
    // Ficheiro: adapter-server.mjs
    // (Versão 2: Gestão de Threads e Variáveis de Ambiente)

    import Fastify from 'fastify';

    // --- ALTERAÇÕES DE CONFIGURAÇÃO ---
    const ADAPTER_PORT = 4000;
    const MODEL_NAME_TO_USE = "iaedu-custom";

    // 1. (SEGURANÇA) A chave API é lida das variáveis de ambiente
    const IAEDU_API_KEY = process.env.IAEDU_API_KEY;

    const IAEDU_ENDPOINT = "https://api.iaedu.pt/agent-chat//api/v1/agent/*************************/stream";

    // 2. (SESSÃO) IDs estáticos usados como FALLBACK
    const IAEDU_CHANNEL_ID_DEFAULT = "***********************";
    const IAEDU_THREAD_ID_DEFAULT = "fallback-thread-all-users"; // ID de fallback
    // ------------------------------------

    const fastify = Fastify({ logger: true });

    // Verificação de arranque
    if (!IAEDU_API_KEY) {
        fastify.log.fatal("ERRO FATAL: IAEDU_API_KEY não definida nas variáveis de ambiente!");
        process.exit(1);
    }

    /**
     * Endpoint /v1/chat/completions (Chamado pelo OpenWebUI)
     */
    fastify.post('/v1/chat/completions', async (request, reply) => {
        
        const requestBody = request.body;
        let userMessage = "Olá";
        if (requestBody.messages && requestBody.messages.length > 0) {
            userMessage = requestBody.messages[requestBody.messages.length - 1].content;
        }

        // --- LÓGICA DE EXTRAÇÃO DE ID ---
        // O OpenWebUI envia 'chat_id' no corpo do pedido.
        const channelId = IAEDU_CHANNEL_ID_DEFAULT;
        const threadId = requestBody.chat_id || IAEDU_THREAD_ID_DEFAULT;
        // -----------------------------------------------

        fastify.log.info(`Recebido (Thread: ${threadId}): "${userMessage}"`);

        const formData = new FormData();
        formData.append("channel_id", channelId);
        formData.append("thread_id", threadId); // <- ID Dinâmico
        formData.append("user_info", "{}"); 
        formData.append("message", userMessage);

        try {
            const response = await fetch(IAEDU_ENDPOINT, {
                method: "POST",
                headers: { 'x-api-key': IAEDU_API_KEY },
                body: formData,
            });

            if (!response.ok) {
                const errorText = await response.text();
                fastify.log.error(`Erro da API iaedu.pt: ${response.status} - ${errorText}`);
                reply.status(500).send({ error: "Erro ao contactar a API iaedu.pt" });
                return;
            }

            // Iniciar a TRADUÇÃO do Stream (NDJSON -> SSE)
            reply.raw.setHeader('Content-Type', 'text/event-stream');
            reply.raw.setHeader('Cache-Control', 'no-cache');
            reply.raw.setHeader('Connection', 'keep-alive');
            
            const reader = response.body.getReader();
            const decoder = new TextDecoder();
            const modelId = `chatcmpl-${Date.now()}`;
            let buffer = '';

            while (true) {
                const { done, value } = await reader.read();
                if (done) break;

                buffer += decoder.decode(value, { stream: true });

                let newlineIndex;
                while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
                    const line = buffer.substring(0, newlineIndex).trim();
                    buffer = buffer.substring(newlineIndex + 1);

                    if (line === '') continue;

                    let parsedLine;
                    try {
                        parsedLine = JSON.parse(line);
                    } catch (e) {
                        fastify.log.warn(`Falha ao interpretar JSON da API: ${line}`);
                        continue;
                    }

                    if (parsedLine.type === "token" && parsedLine.content) {
                        const chunkText = parsedLine.content;
                        const ssePayload = {
                            id: modelId,
                            object: "chat.completion.chunk",
                            created: Math.floor(Date.now() / 1000),
                            model: MODEL_NAME_TO_USE,
                            choices: [{ index: 0, delta: { content: chunkText }, finish_reason: null }]
                        };
                        reply.raw.write(`data: ${JSON.stringify(ssePayload)}\n\n`);
                    }
                }
            }

            // Fechar o stream (Envia o [DONE] ao OpenWebUI)
            const finishPayload = {
                id: modelId,
                object: "chat.completion.chunk",
                created: Math.floor(Date.now() / 1000),
                model: MODEL_NAME_TO_USE,
                choices: [{ index: 0, delta: {}, finish_reason: "stop" }]
            };
            reply.raw.write(`data: ${JSON.stringify(finishPayload)}\n\n`);
            reply.raw.write(`data: [DONE]\n\n`);
            
            fastify.log.info(`Stream concluído (Thread: ${threadId})`);
            reply.raw.end();

        } catch (error) {
            fastify.log.error(error, `Erro fatal no adapter (Thread: ${threadId})`);
            if (!reply.raw.headersSent) {
                reply.status(500).send({ error: "Erro interno do servidor adapter" });
            } else {
                reply.raw.end();
            }
        }
    });

    // Endpoint /v1/models (Necessário para o OpenWebUI)
    fastify.get('/v1/models', async (request, reply) => {
        reply.send({
            object: "list",
            data: [{
                id: MODEL_NAME_TO_USE,
                object: "model",
                created: Date.now(),
                owned_by: "iaedu.pt",
            }]
        });
    });

    // Iniciar o servidor
    const start = async () => {
        try {
            await fastify.listen({ port: ADAPTER_PORT, host: '0.0.0.0' });
            // Os logs agora são geridos pelo fastify logger ou systemd
        } catch (err) {
            fastify.log.error(err);
            process.exit(1);
        }
    };

    start();
    ```

4.  Pressione `Esc` e depois escreva `:wq` e pressione `Enter` para gravar e sair.

### Passo 2: Instalar Dependências e Definir Permissões

```bash
# Limpa instalações antigas, se existirem
sudo rm -rf /opt/iaedu-adapter/node_modules
sudo rm -f /opt/iaedu-adapter/package-lock.json

# Instala o fastify explicitamente nesse diretório
sudo npm install --prefix /opt/iaedu-adapter fastify

# Define o www-data como proprietário de todos os ficheiros
sudo chown -R www-data:www-data /opt/iaedu-adapter
```

### Passo 3: Criar o Serviço Systemd

Isto garante que o *adapter* corre automaticamente e que a API key é injetada de forma segura.

1.  Primeiro, descobra o caminho exato do seu executável `node`:

    ```bash
    which node
    ```

    (Tome nota deste caminho, ex: `/usr/bin/node`. Terá de o usar abaixo.)

2.  Crie o ficheiro de serviço usando o **Vim**:

    ```bash
    sudo vim /etc/systemd/system/iaedu-adapter.service
    ```

3.  Pressione `i` e cole o seguinte conteúdo **completo** (Regra 2).
    **(Lembre-se de substituir `/usr/bin/node` e a API key\!)**

    ```ini
    [Unit]
    Description=IAEDU API Adapter for OpenWebUI
    After=network.target

    [Service]
    Type=simple

    # Utilizador e Grupo
    User=www-data
    Group=www-data

    # Diretório de Trabalho
    WorkingDirectory=/opt/iaedu-adapter

    # Comando de Execução
    # SUBSTITUA /usr/bin/node pelo resultado de 'which node'
    ExecStart=/usr/bin/node adapter-server.mjs

    # --- CONFIGURAÇÃO DE SEGURANÇA ---
    # A API Key é injetada aqui, removida do código
    Environment="IAEDU_API_KEY=sk-usr-hlwl7kkgz8byfkzl3sb6umf33kw4rnx3e1o"
    # --------------------------------

    # Reiniciar automaticamente em caso de falha
    Restart=on-failure
    RestartSec=10

    # Redirecionar output para o journal do systemd
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=multi-user.target
    ```

4.  Grave e saia (`Esc`, `:wq`, `Enter`).

### Passo 4: Gerir o Serviço

Agora, vamos testar e ativar o serviço.

1.  Recarregue o `systemd` para ler o novo ficheiro:

    ```bash
    sudo systemctl daemon-reload
    ```

2.  Inicie o serviço:

    ```bash
    sudo systemctl start iaedu-adapter.service
    ```

3.  **Teste (Regra 4):** Verifique se está a correr corretamente:

    ```bash
    sudo systemctl status iaedu-adapter.service
    ```

    (Deverá ver `active (running)` a verde. Pressione `q` para sair.)

4.  Se estiver a funcionar, ative-o para iniciar no *boot*:

    ```bash
    sudo systemctl enable iaedu-adapter.service
    ```

**Para ver os logs (em caso de erro):**

```bash
sudo journalctl -u iaedu-adapter.service -f
```

### Passo 5: Configuração do OpenWebUI

O seu *adapter* está agora a correr em `http://[IP_DO_SERVIDOR]:4000`.

1.  Abra o OpenWebUI.

2.  Vá a Definições (Ícone Roda Dentada) -\> Ligações (Connections).

3.  Configure a sua ligação de API:

      * **URL Base da API:** `http://host.docker.internal:4000/v1`
        *(Use `host.docker.internal` se o OpenWebUI estiver em Docker no mesmo *host* que o *adapter*. Caso contrário, use o IP do *host*.)*
      * **Chave API:** `dummy_key` (não é usado pelo *adapter*).
      * **Nome do Modelo:** `iaedu-custom`

4.  **Sugestões de Follow-up:** Vá a Definições -\> Interface -\> Sugestões de Follow-up -\> e coloque em **OFF** (ou mude o Modelo de Sugestões para `iaedu-custom` em Definições -\> Geral).

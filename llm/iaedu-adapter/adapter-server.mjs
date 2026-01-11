// Ficheiro: adapter-server.mjs
// (Versão 5: Estável - Com correção de Duplex, Boundary e Latência)

import Fastify from 'fastify';
import { randomUUID } from 'crypto'; 

// --- CONFIGURAÇÃO ---
const ADAPTER_PORT = 4000;
const MODEL_NAME_TO_USE = "iaedu-custom";

// Variáveis de Ambiente
const IAEDU_API_KEY = process.env.IAEDU_API_KEY;
// URL corrigido (sem dupla barra)
const IAEDU_ENDPOINT = "https://api.iaedu.pt/agent-chat/api/v1/agent/**********************/stream";
const FIXED_CHANNEL_ID = "********************";

const fastify = Fastify({ 
    logger: true,
    // Aumentar timeouts do Fastify para evitar cortes prematuros
    connectionTimeout: 0, 
    keepAliveTimeout: 5000
});

if (!IAEDU_API_KEY) {
    fastify.log.fatal("ERRO FATAL: IAEDU_API_KEY em falta nas variáveis de ambiente.");
    process.exit(1);
}

fastify.post('/v1/chat/completions', async (request, reply) => {
    // 1. Otimização de TCP (Low Latency)
    if (reply.raw.socket) {
        reply.raw.socket.setNoDelay(true);
    }

    const requestBody = request.body;
    
    // Extrair apenas o prompt atual (evitar re-enviar histórico antigo para o Agente)
    let userMessage = "Olá";
    if (requestBody.messages && requestBody.messages.length > 0) {
        userMessage = requestBody.messages[requestBody.messages.length - 1].content;
    }

    // Thread Efémera: Garante contexto limpo no lado do Agente a cada pedido
    const threadId = `req-${randomUUID()}`;
    
    // Preparar FormData
    const formData = new FormData();
    formData.append("channel_id", FIXED_CHANNEL_ID);
    formData.append("thread_id", threadId);
    formData.append("user_info", "{}");
    formData.append("message", userMessage);

    fastify.log.info(`Novo pedido. Thread: ${threadId}`);

    try {
        // 2. O FETCH CORRIGIDO
        const response = await fetch(IAEDU_ENDPOINT, {
            method: "POST",
            headers: { 
                'x-api-key': IAEDU_API_KEY,
                // IMPORTANTE: 'Content-Type' REMOVIDO para gerar boundary automático
                'Connection': 'keep-alive'
            },
            body: formData,
            // CRÍTICO: Resolve o problema do 'hanging' no Node.js
            duplex: 'half' 
        });

        if (!response.ok) {
            const errText = await response.text();
            fastify.log.error(`Erro Upstream: ${response.status} - ${errText}`);
            reply.status(response.status).send({ error: `Erro na IA: ${errText}` });
            return;
        }

        // Cabeçalhos SSE para o OpenWebUI
        reply.raw.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache, no-transform',
            'Connection': 'keep-alive',
            'X-Accel-Buffering': 'no'
        });

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        const modelId = `chatcmpl-${Date.now()}`;
        let buffer = '';

        // Loop de Leitura do Stream
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            buffer += decoder.decode(value, { stream: true });
            let newlineIndex;

            while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
                const line = buffer.substring(0, newlineIndex).trim();
                buffer = buffer.substring(newlineIndex + 1);

                if (!line) continue;

                try {
                    const parsed = JSON.parse(line);
                    
                    // Filtrar apenas tokens de conteúdo
                    if (parsed.type === "token" && parsed.content) {
                        const chunk = JSON.stringify({
                            id: modelId,
                            object: "chat.completion.chunk",
                            created: Math.floor(Date.now() / 1000),
                            model: MODEL_NAME_TO_USE,
                            choices: [{ 
                                index: 0, 
                                delta: { content: parsed.content }, 
                                finish_reason: null 
                            }]
                        });
                        reply.raw.write(`data: ${chunk}\n\n`);
                    }
                } catch (e) {
                    // Ignorar erros de parse (ex: linhas de keep-alive ou lixo)
                }
            }
        }

        // Finalização (Stop Token)
        const finishChunk = JSON.stringify({
            id: modelId,
            object: "chat.completion.chunk",
            created: Math.floor(Date.now() / 1000),
            model: MODEL_NAME_TO_USE,
            choices: [{ index: 0, delta: {}, finish_reason: "stop" }]
        });
        reply.raw.write(`data: ${finishChunk}\n\n`);
        reply.raw.write(`data: [DONE]\n\n`);
        reply.raw.end();

    } catch (error) {
        fastify.log.error(error);
        if (!reply.raw.headersSent) reply.status(500).send({ error: "Internal Adapter Error" });
        else reply.raw.end();
    }
});

// Endpoint obrigatório para o OpenWebUI reconhecer o serviço
fastify.get('/v1/models', async (req, reply) => {
    reply.send({
        object: "list",
        data: [{ id: MODEL_NAME_TO_USE, object: "model", created: Date.now(), owned_by: "iaedu" }]
    });
});

// Arranque do servidor
const start = async () => {
    try {
        await fastify.listen({ port: ADAPTER_PORT, host: '0.0.0.0' });
        console.log(`Adaptador IAEDU a correr no porto ${ADAPTER_PORT}`);
    } catch (err) {
        fastify.log.error(err);
        process.exit(1);
    }
};

start();

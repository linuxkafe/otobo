# OTOBO LLM 🤖

> **Transforma o teu Service Desk num ecossistema inteligente.**
> Uma ponte segura entre o OTOBO Helpdesk e Modelos de Linguagem (LLMs), desenhada para automação de respostas, soberania de dados e suporte assistido.

Este projeto implementa uma camada de inteligência artificial sobre o OTOBO, permitindo duas funcionalidades críticas sem alterar o código base do helpdesk: **Respostas Automáticas Contextuais** (via Email) e um **Assistente Virtual** (RAG) na dashboard do cliente.

---

## 🚀 Funcionalidades Principais

### 1. Automação de Tickets (Email Handler)
O sistema interceta notificações de novos tickets e gera respostas ou sugestões técnicas imediatas.

* **Triagem Inteligente via Metadados:** O comportamento da IA é definido pela configuração da Fila (Queue) no OTOBO.
* **Contexto Dinâmico:** Uma notificação vinda da fila "Recursos Humanos" gera uma resposta administrativa; uma vinda da fila "Servidores" gera uma resposta técnica de SysAdmin.
* **Modo Híbrido:**
    * **Público:** Envia uma sugestão de "auto-ajuda" diretamente ao cliente enquanto aguarda um agente.
    * **Interno (Shadow Mode):** Envia apenas uma nota oculta para os agentes com uma análise preliminar e sugestão de resolução.

### 2. Assistente Virtual (Chat Widget)
Um chat integrado na interface do cliente (*Customer Dashboard*) que atua como primeira linha de suporte.

* **RAG (Retrieval-Augmented Generation):** O assistente consulta bases de conhecimento internas (Elasticsearch), manuais e estados de serviço antes de responder.
* **Kill-Switch de Infraestrutura:** Se um serviço crítico estiver em baixo (detetado via monitorização), o chat informa imediatamente o utilizador sobre a avaria geral, impedindo sugestões de *troubleshooting* desnecessárias.
* **Privacidade:** Opção de correr modelos locais (Ollama) ou transbordar para APIs externas apenas em picos de carga.

*Como exemplo para um template para o chat, poderá ser utilizado o código incluído no diretório templates na raiz deste projeto*
---

## ⚙️ Integração: O Segredo está na Notificação

A integração não requer plugins complexos. Utilizamos o sistema nativo de **Notificações de Eventos** do OTOBO para enviar o contexto necessário à IA.

### Como Configurar (Exemplo `Export-Notification.yml`)

Ao criar uma notificação no OTOBO (`AdminNotificationEvent`), injetamos um bloco de metadados no corpo do email que é invisível para o utilizador final, mas interpretado pelo nosso serviço.

**Exemplo de Corpo da Notificação:**

```yaml
Subject: 'LLM Request: [Ticket#<OTOBO_TICKET_TicketNumber>] <OTOBO_TICKET_Title>'
Body: |
  <p>
  ### METADATA START ###
  CustomerEmail: <OTOBO_CUSTOMER_DATA_UserEmail>
  TargetBCC: equipa.tecnica@tua-organizacao.com
  Internal: Yes  # AQUI DEFINES A PERSONALIDADE DA IA PARA ESTA FILA:
  SystemContext: O utilizador está a reportar problemas de Alojamento Web.
  Age como um SysAdmin Sénior. Sê conciso.
  Sugere verificações de DNS e acesso SSH.
  ### METADATA END ###

  <OTOBO_CUSTOMER_BODY[3000]>
  </p>
```
#Fluxo de Execução:

**Gatilho**: Ticket criado na Fila Alojamento Web.

**Ação**: OTOBO envia este email para o LLM-Email-Service (via SMTP local).

**Processamento**: O serviço extrai o SystemContext, ignora o texto HTML extra, consulta o LLM e devolve a resposta ao ticket.

*Poderá ser utilizado o exemplo de notificação incluído no Notification.yml

## 📦 Arquitetura do Sistema

O sistema opera com microsserviços que complementam o OTOBO:

### Componentes

* **`llm_email_service.py`**: Servidor SMTP Python que recebe as notificações, processa o pedido com base no `SystemContext` e envia a resposta. Inclui proteção contra loops de email e métricas de consumo energético.
* **`chat_proxy.py`**: API Middleware para o chat widget. Gere a memória de conversação, faz a gestão de filas de espera e decide se a resposta deve vir da base de conhecimento local ou do LLM.
* **Search Modules**: Scripts personalizados que permitem ao LLM "ler" tickets antigos resolvidos (via Elasticsearch) ou consultar páginas de estado de serviços para dar respostas factuais.

## 🛡️ Privacidade e Segurança

Ideal para ambientes institucionais ou empresariais:

* **Sanitização de Dados**: O sistema remove automaticamente padrões sensíveis (como URLs de redefinição de password ou dados pessoais) antes de enviar o prompt para o modelo.
* **Soberania**: Preparado para funcionar 100% *on-premise* com modelos Open Source (Llama 3, Mistral, etc.), garantindo que dados confidenciais não saem da infraestrutura.
* **Auditoria**: Todas as interações ficam registadas no próprio ticket do OTOBO como artigos (notas ou emails), permitindo revisão humana.

## 📋 Requisitos

* **OTOBO** (ou outro sistema que faça uso do serviço de mail com recurso a notificações).
* **Python**: 3.9+ (para os serviços de middleware).
* **OpenWebUI**: Frontend essencial para servir a interface de chat e gerir a orquestração com o LLM.
* **SearXNG**: Motor de metapesquisa necessário para executar as consultas RAG (Status, Tickets, Web).
* **Backend LLM**: Ollama (recomendado para local) ou endpoint compatível com OpenAI.
* **Acesso SMTP**: O servidor onde corre o serviço de LLM deve conseguir enviar emails para o OTOBO.

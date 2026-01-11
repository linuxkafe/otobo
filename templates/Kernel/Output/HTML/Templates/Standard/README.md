# README: Personalização do Dashboard OTOBO (myhelpdesk.up.pt)

Este ficheiro é o template `CustomerDashboard.tt` modificado para o OTOBO, especificamente para a instância `myhelpdesk.up.pt`. Ele injeta CSS e JavaScript personalizados para alterar a aparência e adicionar novas funcionalidades à página inicial do cliente.

---

## 🤖 Funcionalidades Principais

Este template implementa três personalizações principais:

1.  **Logo UPdigital:** Adiciona o logótipo "UPdigital" no canto superior esquerdo da barra de navegação principal, com um link para `https://up.pt/it`.
2.  **Botões de Ticket Modernizados:** Substitui o "tile" (bloco) padrão de "Novo Ticket" por dois botões maiores e mais descritivos:
    * **Criar novo Ticket:** Mantém a funcionalidade original de criar um ticket na instância atual (`myhelpdesk`).
    * **Criar Ticket para outros serviços da UP:** Redireciona o utilizador para uma instância OTOBO separada (`balcao.up.pt`) para abertura de tickets de outros serviços.
3.  **Assistente Virtual (Chatbot):**
    * Adiciona um ícone flutuante de chat (bubble) no canto inferior esquerdo.
    * Ao ser clicado, abre uma janela de chat para um "Assistente Virtual".
    * O widget verifica a disponibilidade de um serviço de proxy (`/llmproxy/api/health`) antes de ser exibido.
    * A comunicação do chat é feita através do endpoint `/llmproxy/api/chat`.
    * A resposta do assistente simula o "escrever" (typing simulation).

---

## 🔧 Instalação

Para aplicar este template no seu sistema OTOBO:

1.  Aceda ao servidor onde o OTOBO está instalado.
2.  Localize o diretório de templates do OTOBO. Se estiver a usar o tema `Standard`, o caminho será:
    * `/opt/otobo/Kernel/Output/HTML/Templates/Standard/`
    * (Se estiver a usar um tema personalizado, substitua `Standard` pelo nome do seu tema).
3.  Faça um backup do ficheiro **`CustomerDashboard.tt`** existente.
4.  Utilize o seu editor de texto preferido, como o **Vim**, para abrir ou criar o ficheiro `CustomerDashboard.tt` no diretório acima.
5.  Copie e cole **todo** o conteúdo do código fornecido (HTML, CSS e JS) para dentro deste ficheiro.
6.  Salve as alterações.
7.  Limpe a cache do OTOBO e recompile a configuração para que as alterações do template sejam aplicadas. Execute os seguintes comandos a partir do diretório `/opt/otobo/`:

    ```bash
    # Limpar a cache de templates
    sudo -u otobo bin/otobo.Console.pl Maint::Cache::Delete

    # Reconstruir a configuração (boa prática)
    sudo -u otobo bin/otobo.Console.pl Maint::Config::Rebuild
    ```

---

## ⚠️ Pré-requisitos e Dependências

Para que todas as funcionalidades operem corretamente, certifique-se de que:

1.  **Imagem do Logo:** O ficheiro `https://myhelpdesk.up.pt/UPdigital-logo.png` está acessível publicamente.
2.  **Proxy do Chatbot:** O OTOBO está configurado com um proxy reverso (ex: no Nginx ou Apache) que redireciona os caminhos `/llmproxy/api/health` e `/llmproxy/api/chat` para o serviço de backend do assistente virtual.
3.  **Permissões:** O OTOBO permite a execução de scripts e estilos inline (geralmente é o padrão).

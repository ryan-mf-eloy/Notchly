# Notchly

Notchly e um assistente nativo para reunioes no macOS. Ele fica em uma pequena ilha no topo da tela, inspirada na Dynamic Island, e acompanha reunioes com captura de audio, transcricao ao vivo, respostas sugeridas, historico, resumos, traducao e contexto local.

Repositorio publico: <https://github.com/ryan-mf-eloy/Notchly>

O nome publico do app, do repositorio e do produto gerado e `Notchly`. Alguns identificadores tecnicos internos ainda usam `NotchCopilot`, incluindo target, modulo Swift, scheme, pasta de fontes e alguns nomes de testes. Eles foram mantidos nesta fase para preservar estabilidade de build e evitar uma refatoracao ampla de projeto Xcode; nao sao marca de produto.

## Status

Este projeto esta em fase de MVP experimental. A base ja inclui uma arquitetura nativa macOS, persistencia local criptografada, roteamento entre provedores de IA, deteccao de reunioes e uma suite ampla de testes, mas alguns caminhos ainda sao propositalmente limitados ou dependem de recursos recentes do macOS.

Principais caracteristicas:

- UI nativa em SwiftUI/AppKit com painel no notch, menu bar app e janelas auxiliares.
- Captura de microfone e, quando autorizado, audio do sistema.
- Transcricao local com Apple Speech por padrao.
- Transcricao cloud realtime opcional com ElevenLabs.
- Respostas sugeridas durante reunioes e modo copilot fora de reunioes.
- Suporte a OpenAI, Apple Local, Google Gemini, Anthropic Claude, Perplexity e ElevenLabs.
- RAG local por documentos `.txt`, `.md` e PDFs simples.
- Historico, sumarios, perguntas/respostas e memoria local usando SwiftData.
- Criptografia local com AES.GCM e chave de 256 bits no Keychain.
- Modo local primeiro: cloud processing vem desligado por padrao.

## Decisoes De Produto

### Apple-first

Notchly foi desenhado como um app macOS nativo, nao como uma webview. A decisao aparece em varias partes do codigo:

- `SwiftUI` para telas e componentes.
- `AppKit` para menu bar app, janelas nao ativantes, overlay do notch e comportamento fino de foco.
- `SwiftData` para persistencia local.
- `AVFoundation`, `Speech`, `ScreenCaptureKit`, `EventKit`, `NaturalLanguage`, `SoundAnalysis`, `Metal` e `CoreML` para capacidades locais do sistema.

Isso reduz dependencias externas, deixa o app mais integrado ao macOS e facilita politicas de privacidade local.

### Local-first

O padrao do app e `localOnlyMode = true`. Isso significa que o app inicia sem exigir API key e bloqueia rotas cloud enquanto o usuario nao habilitar explicitamente processamento em nuvem.

Essa escolha existe por tres motivos:

- reunioes geralmente contem informacao sensivel;
- transcricao e historico devem continuar uteis sem conta de provedor;
- o usuario precisa entender quando audio, texto ou contexto podem sair da maquina.

### Consentimento explicito

`requireConfirmationBeforeRecording` vem ligado por padrao. Mesmo com deteccao automatica de reunioes, o app oferece iniciar a captura em vez de gravar invisivelmente.

O overlay tambem mostra estados como ouvindo, gravando, transcrevendo, pensando e resposta sugerida. A intencao e que o usuario nunca fique sem saber o que o app esta fazendo.

### Provedores por capacidade

O app nao amarra toda IA a um unico fornecedor. A configuracao separa capacidades como:

- chat e sumario;
- traducao;
- realtime;
- transcricao;
- embeddings/RAG;
- web search.

O `ProviderRouter` decide a rota com base nas preferencias, no modo local e na disponibilidade de credenciais. Isso permite usar Apple Speech para transcricao, OpenAI ou Claude para respostas, Perplexity para busca e ElevenLabs para STT realtime sem misturar responsabilidades.

### Privacidade sem bypass

O modo "Stealth Mode (Privacy)" e deliberadamente descrito como protecao de privacidade baseada em APIs publicas do macOS. Ele usa `NSWindow.SharingType.none` e `NSAccessibility.setMayContainProtectedContent`, mas nao tenta esconder processo, interceptar auditoria, burlar MDM/EDR, apagar eventos do sistema ou usar APIs privadas.

Essa decisao e importante: o app tenta reduzir exposicao acidental de conteudo em capturas onde o macOS respeita a protecao, mas nao promete invisibilidade contra ferramentas legitimas de administracao, auditoria ou seguranca.

### Estado centralizado e camadas testaveis

`AppState` concentra estado publicado para a UI, enquanto servicos especificos cuidam de captura, transcricao, IA, persistencia, seguranca e deteccao. A maior parte das regras tem protocolos, doubles ou construtores injetaveis, o que explica a suite de testes extensa em `NotchCopilotTests`.

## Requisitos

- macOS 14 ou superior para a base do app.
- macOS 15 ou superior para preparar pares de Apple Translation com a ferramenta auxiliar.
- macOS 26 ou superior para caminhos que usam Foundation Models, quando disponiveis.
- Xcode 26.5 ou superior recomendado. A validacao atual foi feita com Xcode 26.5 / build 17F42.
- Swift 6.
- XcodeGen opcional, apenas para regenerar o projeto Xcode a partir de `project.yml`.
- Conta/credenciais de provedores sao opcionais. O app inicia em modo local.

## Como Rodar

1. Abra `NotchCopilot.xcodeproj` no Xcode.
2. Selecione o scheme tecnico `NotchCopilot`; o app gerado aparece como `Notchly.app`.
3. Ajuste signing se o certificado local `Atlas Voice Dev` nao existir na sua maquina.
4. Rode o app.
5. Use o icone da menu bar ou a ilha no notch para iniciar uma reuniao, abrir settings ou executar o demo.

O app e `LSUIElement`, entao roda como acessorio/menu bar app e nao como uma aplicacao tradicional com janela principal fixa.

## Verificacao Por Linha De Comando

Para rodar testes:

```bash
./Tools/xcodebuild-clean.sh -skipPackagePluginValidation -skipMacroValidation -scheme NotchCopilot -destination 'platform=macOS,arch=arm64' test
```

As flags `-skipPackagePluginValidation` e `-skipMacroValidation` ajudam execucoes reprodutiveis pela CLI quando ha package plugins e macros Swift, como os macros do MLX/HuggingFace. No Xcode, o ambiente interativo ainda pode pedir confianca para novos plugins e macros.

O wrapper `Tools/xcodebuild-clean.sh` chama `xcodebuild`, preserva o exit code e filtra apenas ruidos internos conhecidos do Xcode 26.5 (`IDELaunchParametersSnapshot`/`IDETestOperationsObserverDebug`). Se preferir o log bruto, rode o mesmo comando trocando o wrapper por `xcodebuild`; em caso de falha, o wrapper tambem imprime o caminho do log bruto. Se o Xcode avisar que o CoreSimulator esta desatualizado, confirme que `xcode-select -p` aponta para o Xcode atual e rode `xcrun simctl list runtimes` uma vez para forcar o refresh do servico.

Para build simples:

```bash
./Tools/xcodebuild-clean.sh -skipPackagePluginValidation -skipMacroValidation -scheme NotchCopilot -destination 'platform=macOS,arch=arm64' build
```

## Live Reload De Desenvolvimento

Durante desenvolvimento:

```bash
Tools/dev-live-reload.sh
```

O script observa fontes Swift, assets, plist, JSON, YAML e o projeto Xcode. Quando algo muda, ele recompila o app Debug e relanca `Notchly.app`. Logs ficam em:

```text
/tmp/notchcopilot-live-reload/live-reload.log
```

Para manter o watcher em um terminal destacado:

```bash
Tools/install-dev-live-reload.sh
```

Para parar:

```bash
Tools/uninstall-dev-live-reload.sh
```

## Regenerando O Projeto Xcode

O arquivo fonte da configuracao de projeto e `project.yml`. Se voce alterar targets, packages, signing ou settings de build, regenere o `.xcodeproj` com XcodeGen:

```bash
xcodegen generate
```

O projeto gerado versionado ainda e `NotchCopilot.xcodeproj`; o produto final e `Notchly.app`.

## Permissoes

Notchly pede permissoes progressivamente e continua funcionando em modo limitado quando alguma permissao e negada.

| Permissao | Uso |
| --- | --- |
| Microfone | Captura de voz do usuario e audio ambiente aprovado. |
| Speech Recognition | Transcricao com Apple Speech. |
| Screen Recording | Captura de audio do sistema via ScreenCaptureKit. |
| Calendar | Deteccao opcional de reunioes no calendario. |
| Arquivos selecionados pelo usuario | Importacao de documentos para Knowledge/RAG e exportacoes. |
| Rede | Chamadas opcionais para provedores cloud quando habilitadas. |

O app nao deve iniciar gravacao invisivel. A automacao de reunioes respeita confirmacao por padrao.

## Fluxo Principal Do MVP

1. Ao abrir, o app cria uma ilha discreta no topo da tela.
2. O usuario pode iniciar manualmente uma reuniao ou aceitar uma deteccao automatica.
3. O `MeetingSessionManager` coordena captura, transcricao, ledger de segmentos, Q&A realtime, traducao e persistencia.
4. O painel mostra transcricao ao vivo, waveform, perguntas detectadas, respostas sugeridas e historico do copilot.
5. Ao encerrar, o app salva historico, segmentos, sumario e registros de Q&A localmente.
6. O usuario pode revisar historico, apagar dados locais e ajustar provedores em Settings.

## Deteccao E Automacao De Reunioes

A deteccao usa duas fontes principais:

- atividade de apps conhecidos de reuniao, combinada com uso do microfone por outro processo;
- calendario, quando autorizado.

Apps conhecidos e heuristicas ficam em `AppPreferences.KnownMeetingApp.defaults` e incluem variantes de browsers e ferramentas de reuniao. O detector tenta evitar falsos positivos em abas comuns de media, como paginas de video sem contexto de reuniao.

Por padrao:

- `autoDetectMeetings = true`;
- `smartMeetingDetectionEnabled = true`;
- `autoStartListening = false`;
- `requireConfirmationBeforeRecording = true`;
- `autoEndDetectedMeetings = true`;
- `autoEndGraceSeconds = 5`.

Essa combinacao favorece descoberta automatica sem capturar antes da confirmacao do usuario.

## Transcricao

O app tem uma abstracao `TranscriptionService` com implementacoes locais e cloud.

Rotas principais:

- Apple Speech local/nativo como padrao.
- Apple Speech multi-source para microfone e audio do sistema separados quando possivel.
- Auto language switching para idiomas suportados.
- ElevenLabs Realtime STT opcional via WebSocket, com `scribe_v2_realtime`.
- Fallback para servico indisponivel quando permissao, idioma ou credencial nao estao disponiveis.

O pipeline de audio inclui:

- `AVAudioEngine` para microfone;
- `ScreenCaptureKit` para audio do sistema;
- mixagem/roteamento de fontes;
- condicionamento de audio para alta acuracia;
- conversao PCM16 mono 16 kHz para cloud realtime;
- monitoramento de qualidade, clipping, silencio e reinicio controlado do reconhecedor.

## Perguntas E Respostas Em Tempo Real

O modulo `RealtimeQuestionAnswering` detecta perguntas relevantes no fluxo da transcricao e decide quando gerar uma resposta.

Fluxo atual:

```text
MeetingSessionManager.append(_:)
  -> RealtimeQuestionAnsweringEngine.ingest(...)
  -> QuestionDetectionService / QuestionClassifier / gates locais
  -> MeetingAnswerProvider
  -> RealtimeQuestionEventBus
  -> AppState / MeetingPanelView
```

Ele combina:

- janela de transcript;
- deduplicacao de parciais/finais;
- filtro de perguntas retoricas e auto-respondidas;
- scoring de prioridade;
- modos de precisao (`highPrecision`, `balanced`, `highCoverage`);
- sinais textuais, temporais e acusticos leves;
- contexto RAG local;
- web search opcional quando permitido;
- geracao de resposta com provider roteado.

O objetivo do modo padrao e reduzir interrupcoes: alta precisao e preferida a cobertura agressiva.

### MultiQT treinado e fallback local

O Notchly inclui um primeiro artefato treinado MultiQT-style, multilingual e local-first para decidir se uma transcricao de reuniao contem uma pergunta real que precisa de resposta. O modelo fica em `NotchCopilot/Resources/Models/notchly-multiqt-v1.mlmodelc`, com sidecar `notchly-multiqt-v1.metadata.json`, e e carregado por `CoreMLQuestionMultiQTModelRunner`. O fallback "MultiQT-lite" deterministico permanece apenas como degradacao segura quando o modelo estiver ausente, desativado ou falhar.

O plano final esta em `docs/MULTIQT_FINAL_CONSOLIDATION_PLAN.md`. O workspace executavel de treino fica em `Tools/multiqt/` e define:

- schema JSONL do dataset multilingual;
- validador de manifesto;
- modelo PyTorch audio+texto com fusao concat;
- avaliacao por precision/recall, negativos criticos e latencia;
- manifest expandido com `qa_intent_gold.jsonl` + `copilot_intent_gold.jsonl`, incluindo `calculation`, `conversion`, `news`, `web`, `reminder` e `memory` mapeados para o schema MultiQT;
- materializacao de features log-mel em `.npy` via `Tools/multiqt/materialize_audio_features.py`, para treinar de audio sintetico/publico/consentido sem reter waveform bruto;
- importacao de shadow logs redigidos via `Tools/multiqt/build_shadow_manifest.py`, com rejeicao de texto/audio bruto e treino por `signal_proxy`;
- export para Core ML (`notchly-multiqt-v1.mlpackage`/`.mlmodelc`) com sidecar `notchly-multiqt-v1.metadata.json`.

No runtime, `CoreMLQuestionMultiQTModelRunner` procura `notchly-multiqt-v1.mlmodelc` e o metadata no bundle, incluindo `Resources/Models`. Quando esses artefatos existem, `QuestionClassifier` usa a predicao treinada em `shadow`/`enforced`; quando nao existem, degrada para o fallback atual sem crash. A entrada acustica e escolhida pelo contrato exportado em `audio_feature_contract`: modelos treinados com log-mel podem consumir o ring buffer in-memory (`QuestionAudioLogMelRingBuffer`), enquanto o checkpoint empacotado atual prefere o proxy numerico redigivel (`signal_proxy`) de RMS/peak/energia/noise/duracao/pausa/confidence/estabilidade. Nenhum audio bruto e persistido.

Checkpoint atual:

- dataset bootstrap hardened expandido: 94.222 exemplos, 34.087 positivos, 60.135 negativos, pt-BR/en-US/es-ES/ja-JP;
- treino: `qa_intent_gold.jsonl` + `copilot_intent_gold.jsonl` via `signal_proxy`, `Tools/multiqt/augment_manifest.py`, ASR sem pontuacao, fillers, code-switching, parciais truncadas, perguntas reportadas e auto-respondidas;
- modelo: texto + scalars + proxy acustico/temporal, exportado para Core ML, threshold global `0.55`, thresholds por idioma `pt-BR=0.55`, `en-US=0.99`, `es-ES=0.99`, `ja-JP=0.99`, `critical_negative_weight = 2.5`;
- calibracao: o threshold e escolhido por gates de precision/recall globais, por idioma e por label negativa critica, nao apenas pelo score global;
- contrato de runtime: a metadata inclui `label_policy` e `language_thresholds`; se a cabeca treinada `label_logits` prever uma label negativa critica, o runner Core ML suprime o candidato mesmo antes do provider;
- contrato acustico: `preferred_runtime_feature=signal_proxy`, ou seja, este checkpoint deve receber o mesmo proxy numerico usado no treino em vez de log-mel capturado;
- test split hardened: TP 3425, FP 0, FN 1, TN 4596, precision 1.0000, recall 0.9997, p95 0.002 ms;
- hard_test split hardened: TP 2076, FP 0, FN 0, TN 4309, precision 1.0000, recall 1.0000, p95 0.002 ms;
- zero FP em negativos criticos nos splits avaliados.

Comparativo de baselines treinaveis (`Tools/multiqt/compare_baselines.py`, 16 epocas, seed 42, mesmos splits hardened):

| Modo | test precision/recall | hard_test precision/recall | FP criticos hard_test | p95 test |
| --- | ---: | ---: | ---: | ---: |
| `multimodal` | 1.0000 / 0.9997 | 1.0000 / 1.0000 | 0 | 0.002 ms |
| `text_only` | 1.0000 / 0.9982 | 1.0000 / 0.9986 | 0 | 0.002 ms |
| `audio_only` | 1.0000 / 0.3357 | 1.0000 / 0.3348 | 0 | 0.002 ms |

O multimodal passa os gates absolutos, supera `audio_only` em recall e vence `text_only` em recall no test/hard_test adversarial sem aumentar FP critico (`promotion.promote_to_enforced = true`). Por isso o default de produto continua `enforced`: o modelo Core ML treinado participa da decisao local, enquanto os hard-blocks textuais continuam protegendo negativos criticos.

O metadata empacotado registra gates detalhados: 67/67 gates passam, incluindo precision >= 0.990 e recall >= 0.950 por idioma (`pt-BR`, `en-US`, `es-ES`, `ja-JP`), p95 <= 60 ms, p99 <= 100 ms e zero FP critico por label negativo (`fragment`, `operational_check`, `reported_question`, `rhetorical`, `self_answered`, `small_talk`, `title_noise`, `statement`). A mesma metadata carrega os thresholds por idioma e o contrato `preferred_runtime_feature`, permitindo ajustar calibracao/entrada acustica sem alterar o binario do app.

O app cria `QuestionMultimodalSignal` a partir do `TranscriptSegment`, qualidade de audio por fonte, energia disponivel e, quando o audio recente esta no ring buffer, `captured_logmel`. O runner decide entre `captured_logmel` e `signal_proxy` pelo metadata do modelo. Os campos de decisao sao numericos/redigiveis: idioma, confidence ASR, final/partial, speaker/source, duracao, estabilidade entre parciais, pausa terminal, RMS/peak, clipping, silencio/tooQuiet, gaps, noise floor e `audioEnergy`.

`QuestionMultimodalScorer` combina o entendimento textual com boosts leves para segmento final, ASR confiavel, duracao plausivel, pausa terminal e energia consistente. Ele penaliza partial instavel, ASR baixo, clipping forte, silencio/tooQuiet e gaps. Negativos criticos continuam como hard-blocks locais: small talk, operational checks, retoricas, perguntas reportadas, auto-respondidas, fragmentos, titulos e ruido ASR.

`QAMultimodalMode` fica em `AppPreferences`:

- `off`: usa apenas os sinais textuais.
- `shadow`: calcula scores multimodais para auditoria sem bloquear decisoes.
- `enforced`: default atual; aplica o gate multimodal porque o checkpoint hardened passa os gates locais, zera FP critico no multimodal e vence `text_only` no hard_test adversarial.

`QuestionClassification` registra `textualConfidence`, `multimodalConfidence`, `decisionScore`, `decisionSignals` e `suppressionSignals`, permitindo diagnostico sem gravar audio bruto. O fluxo respeita a regra dura:

```text
responseNeeded && complete && !rhetorical && priority != .low
```

Somente quando essa regra passa o provider e chamado. Perguntas urgentes podem cancelar geracoes anteriores; pergunta auto-respondida cancela/ignora a geracao; final estavel substitui partial via deduplicacao.

Gates minimos para promover o modelo treinado:

- precision geral >= 0.995;
- recall geral >= 0.970;
- zero falsos positivos em negativos criticos;
- precision >= 0.990 e recall >= 0.950 em pt-BR, en-US, es-ES e ja-JP;
- p95 local <= 60 ms e p99 local <= 100 ms em Mac alvo.

### Limpeza Da Pergunta

`QuestionSpanExtractor` limpa `classification.extractedQuestion` antes de exibir na UI. Ele remove fillers, prefixos e enderecamentos comuns em `pt-BR`, `en-US`, `es-ES` e `ja-JP`, como "quick question", "uma duvida", "entao" e chamadas por nome, preservando sentido, casing util e nunca reduzindo a pergunta para string vazia.

Tipos cobertos incluem perguntas diretas e indiretas, status, risco, decisao tecnica, prazo, ownership, follow-up, negocio e action requests. Para prazo, risco, producao e aprovacao, respostas geradas usam tom curto e cauteloso, evitando prometer datas, aprovar rollout ou assumir risco sem verificacao.

### UX De Q&A

O painel usa estados visiveis para evitar loading infinito:

```text
Listening -> Understanding -> Retrieving Context -> Drafting -> Ready / Failed / Cancelled
```

A fila de perguntas preserva selecao, deduplica partial/final, permite dispensar, copiar, salvar e alternar entre `Transcript` e `Answer`. A UI usa `classification.extractedQuestion` como texto principal da pergunta, nao o `rawText` do ASR.

## Traducao Ao Vivo

O app inclui traducao ao vivo para pares de idioma suportados. O caminho local usa Apple Translation quando disponivel e preparado no sistema. Quando cloud esta liberada, a traducao pode ser roteada para um provedor de IA configurado.

Ferramenta auxiliar:

```bash
swift Tools/TranslationLanguageDownloader.swift
```

Ela abre uma pequena janela para preparar pares `pt-BR <-> en-US` usando os frameworks de Translation quando disponiveis no SDK/macOS.

## Knowledge / RAG

Settings > Knowledge permite importar:

- `.txt`;
- `.md`;
- PDFs simples.

O MVP armazena documentos localmente e usa busca por palavras-chave como fallback principal. A interface de embeddings ja existe (`EmbeddingProvider`) para permitir evolucao futura para Core ML local ou embeddings cloud, mas o comportamento padrao e local e simples.

O escopo de conhecimento considera `workspaceId`, evitando misturar contexto entre workspaces.

## Provedores De IA

O app separa autenticacao, modelo e capacidade. API keys e metadados de sessao ficam no Keychain.

| Provedor | Autenticacao | Capacidades previstas |
| --- | --- | --- |
| Apple Local | Local | transcricao, traducao e Foundation Models quando disponiveis. |
| OpenAI | Codex CLI account login ou API key legacy habilitada manualmente | chat, sumario, realtime, embeddings e web search. |
| Google Gemini | API key ou Gemini CLI | chat, traducao, embeddings e realtime quando disponivel. |
| Anthropic Claude | API key ou Claude CLI | chat e traducao. |
| Perplexity | API key | chat, traducao e web/search via Sonar. |
| ElevenLabs | API key | transcricao realtime com `scribe_v2_realtime`. |

Decisoes importantes:

- Cloud processing fica desligado por padrao.
- API key legacy da OpenAI exige modo avancado.
- OpenAI account login direto via OAuth/PKCE so e tentado quando houver configuracao oficial de desktop no bundle.
- Por padrao, login de conta OpenAI delega para o Codex CLI device flow.
- O app nao le cookies de browser, nao raspa sessoes web e nao acessa arquivos privados de tokens de CLIs.
- Gemini e Claude account login usam os CLIs oficiais quando instalados.
- Perplexity OAuth/account login fica indisponivel ate existir um fluxo desktop oficial para esse caso.
- ElevenLabs realtime exige verificacao com zero retention; contas que nao aceitam esse requisito falham na validacao.

## Configuracao De Modelos

`AIProviderConfig.default` define:

```json
{
  "provider": "openAI",
  "authMode": "openAICodexCLI",
  "model": "gpt-5-mini",
  "realtimeModel": "gpt-realtime",
  "realtimeTranscriptionProvider": "elevenLabs",
  "realtimeTranscriptionModel": "scribe_v2_realtime",
  "embeddingModel": "text-embedding-3-small",
  "translationEnabled": false,
  "webSearchEnabled": false,
  "ragEnabled": true,
  "cloudProcessingEnabled": false,
  "legacyAPIKeyAccessEnabled": false
}
```

`Config.example.json` documenta uma configuracao local segura para desenvolvimento, mas preferencias reais sao gerenciadas pelo app e persistidas localmente.

## Privacidade E Seguranca

### Criptografia local

Dados sensiveis sao criptografados com `CryptoKit` usando `AES.GCM`. A chave mestre local tem 256 bits, e fica no Keychain em `local-encryption.master-key.v1`.

O formato de string criptografada usa prefixo:

```text
ncenc:v1:
```

Arquivos criptografados usam cabecalho:

```text
NCENC1
```

Campos criptografados incluem:

- titulo, participantes, tags, app e URL de reuniao;
- segmentos de transcript;
- traducoes;
- sumarios;
- registros de Q&A;
- memoria do copilot;
- lembretes;
- documentos Knowledge/RAG;
- vocabulario de fala customizado;
- preferencias persistidas.

Transcricoes internas sao gravadas como:

```text
~/Library/Application Support/Notchly/transcripts/<meeting-id>.json.ncenc
```

O banco SwiftData fica em:

```text
~/Library/Application Support/Notchly/database.sqlite
```

Diretorios locais antigos em `~/Library/Application Support/Notch Copilot` sao migrados para `~/Library/Application Support/Notchly` quando o app inicializa. Arquivos legacy plaintext de transcript (`.json`) sao migrados para `.json.ncenc` e removidos apos escrita atomica bem-sucedida do equivalente criptografado.

### Excecoes deliberadas

Gravacoes de audio opcionais em `recordings/*.caf` e exportacoes explicitas do usuario continuam como arquivos plaintext nesta versao. Elas sao tratadas como artefatos controlados pelo usuario, fora do armazenamento interno criptografado.

Se a chave local for removida do Keychain, dados locais criptografados nao podem ser recuperados.

### Redacao antes da nuvem

`PrivacyGuard` remove padroes obvios de segredo antes de rotas cloud:

- API keys;
- tokens;
- senhas/secret strings comuns;
- e-mails.

Isso e uma camada defensiva, nao uma garantia formal de DLP.

## Persistencia

O schema SwiftData inclui:

- `StoredMeeting`;
- `StoredTranscriptSegment`;
- `StoredSummary`;
- `StoredKnowledgeDocument`;
- `StoredSpeechVocabularyTerm`;
- `StoredQuestionAnswerRecord`;
- `StoredCopilotInteraction`;
- `StoredCopilotMemoryEntry`;
- `StoredCopilotReminder`.

`MeetingRepository`, `SettingsRepository`, `FileStorageService`, `LocalKnowledgeStore` e `SpeechVocabularyStore` encapsulam leitura, escrita, migracao e criptografia.

## Arquitetura De Pastas

```text
NotchCopilot/
  App/                         Ciclo de vida, estado global, permissoes e bootstrap.
  Apple/                       Integracoes Apple locais: Accelerate, CoreML, Metal, Translation, SoundAnalysis.
  Audio/                       Captura, mixagem, gravacao, condicionamento e modelos de audio.
  Auth/                        Keychain, API keys, OAuth/PKCE e adaptadores de CLIs oficiais.
  AI/                          Provedores, prompts, respostas, sumarios, realtime e catalogs.
  Meetings/                    Modelos de reuniao, deteccao, automacao e session manager.
  Persistence/                 SwiftData, repositorios e storage de arquivos.
  ProviderRouting/             Registro, capacidade local e roteamento entre provedores.
  RAG/                         Knowledge store, ingestao, embeddings e busca vetorial/keyword.
  RealtimeQuestionAnswering/   Deteccao de perguntas, fila, scoring, prompt e resposta.
  Security/                    Keychain, criptografia local, privacy guard e retencao.
  Settings/                    Tela de conexoes de IA.
  UI/                          Notch island, painel, historico, sumario e componentes.
  Utilities/                   Logger, debounce e formatacao.
  Resources/                   Info.plist, assets e politicas JSON.

NotchCopilotTests/
  Fixtures/                    Goldens e streams sinteticos para intent/ASR/Q&A.
  NotchCopilotTests.swift      Suite principal de testes.
  TestDoubles.swift            Doubles para provedores, repositorios e servicos.

Tools/
  dev-live-reload.sh           Watcher de build/relaunch.
  install-dev-live-reload.sh   Instalacao do watcher em background.
  uninstall-dev-live-reload.sh Remocao/parada do watcher.
  xcodebuild-clean.sh          Wrapper de xcodebuild com filtro para ruidos conhecidos do Xcode 26.5.
  TranslationLanguageDownloader.swift Preparacao de idiomas Apple Translation.
```

## Bibliotecas E Frameworks

### Dependencias Swift Package Manager

Dependencias diretas em `project.yml`:

| Package | Uso no projeto |
| --- | --- |
| `mlx-swift-lm` | suporte a LLM local via MLX (`MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`). |
| `swift-huggingface` | carregamento de modelos HuggingFace em caminhos locais. |
| `swift-transformers` | tokenizacao e suporte a modelos transformer. |
| `grpc-swift` | base para clientes/transportes gRPC quando necessario. |
| `swift-nio` | primitives de IO usadas por dependencias e rotas de rede. |

`Package.resolved` fixa tambem dependencias transitivas como `mlx-swift`, `swift-collections`, `swift-crypto`, `swift-log`, `swift-protobuf`, `swift-syntax`, `EventSource`, `yyjson` e pacotes NIO auxiliares.

### Frameworks Apple

O codigo usa, entre outros:

| Framework | Uso |
| --- | --- |
| `SwiftUI` | UI declarativa. |
| `AppKit` | menu bar, janelas, overlay nao ativante, eventos e detalhes de macOS. |
| `Combine` | observacao de estado e lifecycle. |
| `SwiftData` | persistencia local. |
| `AVFoundation` | captura e manipulacao de audio. |
| `Speech` | Apple Speech Recognition. |
| `ScreenCaptureKit` | audio do sistema. |
| `EventKit` | calendario e deteccao de reunioes. |
| `Security` | Keychain e geracao segura de bytes. |
| `CryptoKit` | AES.GCM e PKCE S256. |
| `AuthenticationServices` | base para fluxos OAuth oficiais. |
| `ServiceManagement` | launch at login. |
| `UserNotifications` | lembretes/avisos do copilot. |
| `CoreAudio` e `CoreMedia` | audio baixo nivel e buffers. |
| `CoreML` | classificadores locais. |
| `Metal`, `MetalKit`, `QuartzCore`, `Accelerate` | waveform, analise e aceleracao local. |
| `NaturalLanguage` | deteccao de idioma. |
| `SoundAnalysis` | analise de audio local. |
| `PDFKit` | ingestao simples de PDF para Knowledge. |
| `UniformTypeIdentifiers` | selecao/importacao de arquivos. |
| `FoundationModels` | caminho Apple Foundation Models em macOS 26+. |

## Interface

A UI e composta por:

- `NotchIslandWindowController`: cria o painel nao ativante e fixa no topo da tela.
- `NotchIslandView`: estado compacto/expandido, hover e acoes primarias.
- `MeetingPanelView`: experiencia principal de reuniao.
- `TranscriptLiveView`: transcript ao vivo.
- `HistoryView`: historico de reunioes e interacoes.
- `SummaryView`: sumarios.
- `SettingsView` e `AIConnectionSettingsView`: preferencias, privacidade, providers e credenciais.
- Componentes compartilhados em `UI/Components`, incluindo tema minimalista, waveform, renderer de respostas ricas, preview de links e botoes.

O design favorece uma superficie pequena e sempre disponivel, com expansao apenas quando o usuario precisa ver transcript, resposta, historico ou settings.

## Politicas E Fixtures

Recursos JSON versionados:

- `Resources/CopilotIntentPolicy/default.json`: thresholds, pesos e sinais para ativacao do copilot.
- `Resources/CopilotSpeechPolicy/default.json`: alternativas, reparos e regras de ASR para fala multi-idioma.
- `Resources/speech-default.json`: configuracao vocabularia/base de fala.

Fixtures de teste em `NotchCopilotTests/Fixtures` cobrem:

- intent do copilot;
- ASR parcial/final;
- Q&A realtime;
- sinais multimodais sinteticos;
- benchmarks sinteticos;
- goldens JSONL.

## Testes

A suite cobre camadas criticas, incluindo:

- redacao de segredos;
- criptografia e migracao de dados plaintext;
- Keychain;
- autosave de preferencias;
- deteccao de intents e perguntas;
- ASR e estabilidade de segmentos;
- roteamento de provedores;
- Apple Speech e ElevenLabs realtime;
- traducao;
- Knowledge/RAG;
- persistencia SwiftData;
- renderizacao de UI;
- protecao de janela e politicas de foco;
- auth via API key, OAuth/PKCE e CLIs oficiais;
- streaming OpenAI e catalogs de modelos.
- `NotchCopilotUITests` com `--qa-ui-harness`, cobrindo janela real, alternancia Transcript/Answer, copy, save e dismiss.

Como o app integra APIs recentes e recursos do sistema, alguns testes podem depender de SDK, permissoes ou disponibilidade de hardware/software local.

Benchmarks atuais do Q&A em `main`:

```text
QA_BENCHMARK fixture=2018 tp=808 fp=0 fn=0 tn=1210 precision=1.0000 recall=1.0000 detection_p95_ms=7.993 classification_p95_ms=15.861 pipeline_p95_ms=19.880
QA_MULTIMODAL_BENCHMARK fixture=2018 baseline_precision=1.0000 baseline_recall=1.0000 multimodal_precision=1.0000 multimodal_recall=1.0000 multimodal_p95_ms=19.908 critical_fp=0
QA_REPLAY one_hour_segments=1200 fp=0 tn=1200 visible_false_alerts=0 p95_ms=5.112
```

A ultima validacao completa executou `339` testes unitarios, `3` skips opt-in de captura real e `1` XCUITest, com `0` falhas. Os skips opt-in sao os harnesses que exigem permissao/execucao manual de captura real (`screencapture` e `ScreenCaptureKit`). O `.xcresult` final ficou sem `issue summaries`/`testWarningSummaries`.

## Configuracoes Padrao

Alguns defaults relevantes de `AppPreferences`:

| Preferencia | Default | Motivo |
| --- | --- | --- |
| `localOnlyMode` | `true` | evitar cloud por padrao. |
| `cloudProcessingEnabled` | `false` | exigir escolha explicita do usuario. |
| `requireConfirmationBeforeRecording` | `true` | impedir gravacao silenciosa. |
| `autoDetectMeetings` | `true` | sugerir reunioes automaticamente. |
| `autoStartListening` | `false` | deteccao nao implica captura automatica. |
| `audioCaptureMode` | `microphoneAndSystem` | preparar experiencia completa de reuniao. |
| `saveAudioRecordings` | `false` | nao salvar audio bruto por padrao. |
| `realtimeSuggestionsEnabled` | `true` | habilitar o fluxo central do copilot. |
| `qaPrecisionMode` | `highPrecision` | reduzir falsos positivos. |
| `qaMultimodalMode` | `enforced` | usar o checkpoint MultiQT hardened treinado quando presente, com fallback seguro se o artefato estiver ausente. |
| `allowLocalModelDownloads` | `true` | permitir caminhos locais quando configurados. |
| `copilotHotkeyEnabled` | `true` | acesso rapido ao copilot. |
| `copilotRetentionDays` | `7` | reduzir memoria local de curto prazo. |
| `retentionDays` | `30` | manter historico de reunioes por periodo limitado. |

## Limitacoes Conhecidas

- Speaker diarization ainda usa rotulos simples.
- Captura de audio do sistema existe via ScreenCaptureKit, mas conversao/mixagem completa de alguns fluxos ainda e area de evolucao.
- Web search e parcialmente dependente do provedor escolhido e das flags de cloud.
- RAG usa keyword search como fallback principal; embeddings locais/cloud ainda sao caminho de evolucao.
- Transcricao realtime cloud esta focada em ElevenLabs.
- O MultiQT treinado empacotado e um checkpoint hardened gerado com texto gold + proxy acustico/temporal e augmentations adversariais. Ele passa os gates locais e fica em `enforced` por padrao; o caminho de log-mel materializado ja existe, mas a validacao final ainda exige audio consentido de reunioes reais antes de tratar o modelo como producao extrema.
- Gemini e Claude account login dependem dos CLIs oficiais instalados e autenticados.
- Perplexity account/OAuth esta indisponivel por design nesta versao.
- Launch at login aparece nas preferencias, mas a integracao final pode exigir ajustes de signing/entitlements.
- Foundation Models exigem macOS 26+ e disponibilidade do hardware/sistema.
- Stealth Mode depende de apps e caminhos de captura respeitarem APIs publicas do macOS.

## Roadmap

- Completar conversao e mixagem de audio do sistema para transcricao ao vivo.
- Melhorar diarizacao e separacao real de falantes.
- Adicionar embeddings locais com Core ML.
- Refinar export bundle com audio, transcript, resumo, fontes e citacoes.
- Melhorar command palette e atalhos globais.
- Expandir suporte de provedores realtime alem de OpenAI/ElevenLabs.
- Tornar launch at login totalmente operacional.
- Evoluir RAG para busca semantica local.
- Coletar/validar dataset consentido de reunioes reais para substituir ou reforcar o checkpoint bootstrap `notchly-multiqt-v1`.
- Publicar politica de contribuicao e licenca.

## Licenca

Nenhuma licenca foi adicionada ainda neste repositorio. Enquanto nao houver um arquivo `LICENSE`, o codigo esta publico para leitura, mas permissoes formais de uso, copia, modificacao e distribuicao ainda nao estao definidas.

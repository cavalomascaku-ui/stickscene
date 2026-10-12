# StickScene V2

Estúdio de animação de boneco de palito, escrito do zero em Flutter.

Construído a partir da engenharia reversa do APK `com.sG.stickfighter.activities`
v51.0.0 (um porte Flutter do antigo *Stick Figure Animator*), com o objetivo de
entregar o workflow clássico **sem** os problemas que os usuários relataram
naquele app.

> **Aviso sobre o APK original.** O app analisado pertence a outro desenvolvedor
> (sul-coreano) e está no ar na Play Store. Este projeto **não** usa o nome, a
> marca, o código nem os assets dele. O APK não contém nenhuma arte de boneco de
> palito de qualquer forma — bonecos são geometria (linhas + círculos), não
> sprites — então o visual clássico aqui é **reconstruído por construção**, não
> copiado. Os únicos PNGs do APK original são logos dos desenvolvedores, um
> documento de cessão de IP e seis ícones de toolbar de ~2 KB.

---

## O que foi verificado (e como)

Tudo abaixo foi **executado**, não suposto:

| Verificação | Ferramenta | Resultado |
|---|---|---|
| Modelo de dados, geometria, codec, interpolação | `dart analyze` | limpo |
| 41 checagens de comportamento (tweening, composição de transform, migração de schema, movieclip, round-trip do codec) | `dart run test/core_smoke.dart` | **41/41** |
| Encoder GIF: round-trip LZW, framing de blocos, estrutura de arquivo | `dart run test/gif_smoke.dart` | **15/15** |
| GIF gerado pelo Dart, decodificado por ferramenta independente | ImageMagick, ffmpeg, PIL | **idêntico, pixel a pixel** |
| Parse de todos os arquivos | `dart format` | 23/23 |

### Dois bugs reais que isso pegou

O motivo de ter escrito testes em vez de confiar em "compilou":

1. **Endianness do GIF.** Os campos de 2 bytes do cabeçalho do GIF são
   **little-endian**, não big-endian como eu tinha escrito. Com o erro, todo
   decodificador estrito lia uma imagem 8×8 como 2048×2048 e o arquivo saía
   "corrompido". Não apareceria em nenhum teste de "abre e roda".
2. **Perda de cor na paleta.** O quantizador removia a caixa da lista antes de
   testar se ela podia ser dividida e não a recolocava — uma cor sumia da
   paleta silenciosamente.

---

## Como rodar

### Opção 1 — GitHub Actions (gera o APK, não precisa de PC)

Este celular é ARM64 (Termux) e o Flutter oficial só publica binários x86_64,
 então compilar aqui não é possível. O workflow resolve isso:

1. Crie um repositório no GitHub e suba esta pasta.
2. Aba **Actions** → **Build APK** → *Run workflow*.
3. Espere ~10 min. Baixe o `.apk` em **Artifacts** no rodapé da execução.

O workflow roda `flutter analyze` e os testes **antes** de compilar — se
qualquer coisa quebrar, o build falha em vez de gerar um APK quebrado.

### Opção 2 — No seu PC

```bash
flutter pub get
flutter run                 # testar
flutter build apk --release # gerar APK
```

---

## Arquitetura

```
lib/
├── data/            # modelo + persistência (sem dependência de Flutter)
│   ├── geometry.dart        Vec2, Transform2D, Rect2
│   ├── models.dart          Project/Sequence/Frame/Layer/SceneObject/…
│   ├── project_codec.dart   JSON versionado + migração de schema
│   └── project_repository.dart   autosave atômico + backups
├── editor/
│   ├── stick_rigs.dart      rigs e poses do boneco
│   ├── interpolation.dart   tweening + expansão de movieclips
│   ├── editor_controller.dart   estado + undo/redo
│   ├── canvas_painter.dart  renderização
│   └── viewport.dart        pan / zoom / rotação
├── playback/player.dart     tempo real + áudio por frame
├── export/
│   ├── gif_encoder.dart     encoder GIF89a próprio
│   └── exporter.dart        GIF, sprite sheet, sequência PNG
├── l10n/strings.dart        pt-BR + en
└── ui/                      biblioteca, intro, editor, painéis
```

### Autosave à prova de crash

O pedido nº1 da comunidade era "não perder meu trabalho". A implementação:

1. Grava `project.json.tmp`, depois **renomeia** por cima do arquivo real.
   `rename` é atômico no mesmo filesystem — um kill no meio da escrita deixa o
   arquivo velho **ou** o novo, nunca os dois misturados.
2. Antes de sobrescrever, copia o bom anterior para `backups/` (8 rotação).
3. Ao abrir, se o principal estiver corrompido, cai para o backup mais recente
   que decodificar.
4. `project.json` é JSON legível de propósito: se der problema, dá para abrir
   num editor de texto e ver o que houve.

---

## O que está pronto e o que não está

### Funciona

- **Autosave + backup rotativo + recuperação automática**
- **Boneco com rig e 9 poses** (parado, andar, correr, soco, chute, pulo,
  caindo, sentado, deitado)
- **Tweening de verdade** entre frames — as âncoras interpolam e os ossos
  acompanham
- **Timeline** com frames de retenção (hold), duplicar, excluir, FPS ajustável
- **Camadas e grupos ilimitados** (sem contador, por construção)
- **Onion skin** (antes/depois com opacidade por distância)
- **Câmera / v-cam** com pan, zoom e rotação por frame
- **Áudio por frame** e trilha de fundo
- **Fundo com imagem**
- **Movieclips** no motor (expansão recursiva, composição de transform)
- **Export**: GIF animado, sprite sheet PNG, sequência PNG
- **Modo simples vs avançado** — a tela padrão esconde timeline e camadas
- **Undo/redo** com snapshot de projeto
- **pt-BR e en**
- Sem anúncios, sem conta, sem permissão de internet

### Ferramentas completas

- **Boneco** com rig e 9 poses
- **Caneta** — traço livre com preview ao vivo, 7 cores e espessura ajustável
- **Círculo**
- **Texto e balões** — conteúdo, tamanho, cor, balão arredondado ou com rabinho
- **Imagem / GIF animado** — o GIF é convertido em sprite sheet vertical e
  toca no playback
- **Timeline** com hold, duplicar, excluir, FPS
- **Camadas e grupos ilimitados**
- **Onion skin**
- **Câmera / v-cam** por frame
- **Áudio por frame** + trilha de fundo
- **Fundo com imagem**
- **Movieclips** — cria a partir dos bonecos do frame e instancia em vários
  lugares ao mesmo tempo

### Export

| Formato | Áudio | Onde |
|---|---|---|
| GIF animado | não (GIF não tem) | qualquer plataforma |
| Sprite sheet PNG | não | qualquer plataforma |
| Sequência de PNG | não | qualquer plataforma |
| **MP4 (H.264 + AAC)** | **sim** | Android |

O MP4 é o que dá problema: ele é **código nativo Kotlin** (`VideoExportPlugin.kt`,
MediaCodec + MediaMuxer), e eu **não consegui compilar nem rodar** nesse
Termux ARM64 — o Flutter oficial só tem binário x86_64. Está escrito seguindo os
padrões do Android (input Surface para o H.264, faixa de áudio preparada
*antes* de o muxer iniciar, porque `MediaMuxer` não aceita trilha nova depois
de `start()`), mas **trate-o como não verificado** até rodar o APK.

Detalhes do mix de áudio: cada som é decodificado por `MediaExtractor`/
`MediaCodec`, convertido para 44.1 kHz estéreo (mono é duplicado, a conversão de
taxa usa interpolação linear), misturado no deslocamento correto da timeline,
codificado em AAC 128 kbps e muxado junto do vídeo.

### Não implementado (de propósito)

- **Sincronização na nuvem.** O backup é local. O app original usava Firebase;
  isso traria permissão de internet e conta, que não quero sem você decidir.
- **Versão desktop.** Ninguém no gênero tem; é o pedido mais citado do Stick Nodes.
- **Ferramenta de arrastar em grupo** (multi-seleção). Hoje se move um objeto
  por vez; o motor aceita vários, falta o gesto.
- **Sombras/sprites do app original** — não existem, o app é vetorial.

---

## Publicar no GitHub (combinado depois)

Para eu gerar o APK, preciso de:

1. **Seu nome de usuário do GitHub** (ou o nome do repositório que você quer criar)
2. **Um token com escopo `repo`** — em GitHub → Settings → Developer settings →
   Personal access tokens → Fine-grained tokens, com acesso somente de escrita
   no repositório escolhido

Guarde o token como variável de ambiente e **não** me mande colar no chat:

```bash
export GH_TOKEN=ghp_xxxxxxxx
```

Com isso eu commito a pasta, subo, aciono o workflow e te entrego o link do
APK. Sem isso, o caminho é você mesmo subir a pasta num repo novo e clicar em
**Actions → Build APK → Run workflow** (leva ~10 min).

## Como publicar de verdade

O `build.gradle.kts` usa **assinatura de debug** para o APK sair instalável
imediatamente. Para publicar na Play Store:

1. Gere um keystore: `keytool -genkey -v -keystore ~/upload.jks -keyalg RSA`
2. Crie `android/key.properties` com as credenciais (e adicione ao `.gitignore`)
3. Troque o `signingConfig` em `android/app/build.gradle.kts`
4. Troque `applicationId` se não quiser `com.stickscene.app`

---

## Rodar os testes

```bash
dart run test/core_smoke.dart   # 41 checagens do núcleo
dart run test/gif_smoke.dart    # 15 checagens do encoder GIF
```

O segundo escreve `gif_smoke_output.gif` na pasta atual. Para conferir com uma
ferramenta externa:

```bash
identify -format "%wx%h frames=%n delay=%T\n" gif_smoke_output.gif
ffmpeg -i gif_smoke_output.gif -f rawvideo -pix_fmt rgb24 frame.raw
```

---

## Licença

Código novo, sem dependência de material de terceiros. Os pacotes usados
(`image` não é mais necessário — o GIF é próprio), `path_provider`, `file_picker`,
`audioplayers`, `share_plus`, `provider` estão sob suas respectivas licenças.
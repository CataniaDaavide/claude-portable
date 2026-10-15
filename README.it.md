# claude-portable - guida in italiano

[![tests](https://github.com/CataniaDaavide/claude-portable/actions/workflows/tests.yml/badge.svg)](https://github.com/CataniaDaavide/claude-portable/actions/workflows/tests.yml)

Tiene tutto quello che [Claude Code](https://code.claude.com) sa dei tuoi progetti (chat, memoria,
impostazioni, skill) in **un'unica cartella** che puoi portare su un altro PC, e ricollega ogni
progetto alle sue chat anche se si trova in un percorso diverso.

Windows, macOS e Linux. [English](README.md).

![Come claude-portable ricollega un progetto spostato alle sue chat](docs/images/how-it-works.svg)

## Il problema

Claude Code salva i dati in `~/.claude` (`%USERPROFILE%\.claude` su Windows). Ogni progetto ha una
cartella dentro `projects/` il cui nome è il percorso del progetto con ogni carattere non
alfanumerico sostituito da `-`:

```
C:\Users\mario\Desktop\mia-app  ->  .claude\projects\C--Users-mario-Desktop-mia-app\
/home/mario/code/mia-app        ->  .claude/projects/-home-mario-code-mia-app/
```

Lì dentro ci sono le chat (`*.jsonl`) e la memoria (`memory/`). Se sposti il progetto, o lo apri su un
PC con un altro nome utente, il percorso cambia e Claude riparte da zero anche se hai copiato i dati.
In più, per impostazione predefinita le chat più vecchie di 30 giorni vengono cancellate.

## Cosa fa

| Parte | Cosa fa |
|---|---|
| **Una cartella unica** | Imposta la variabile ufficiale `CLAUDE_CONFIG_DIR`: Claude Code salva tutto nella cartella che scegli (predefinita `~/claude-data`). |
| **Chat conservate** | Imposta `cleanupPeriodDays` a 36500 (circa 100 anni). Claude Code non permette di disattivare la pulizia (`0` viene rifiutato), quindi si usa un periodo lunghissimo. |
| **Registro dei workspace** | `portable/workspaces.json` collega ogni percorso di progetto alla sua cartella in `projects/`. Un hook `SessionStart` lo aggiorna ogni volta che apri un progetto. |
| **Ricollegamento** | Quando un progetto si sposta, un comando rinomina (o unisce) la sua cartella col nuovo percorso: `/resume` e memoria tornano a funzionare. |
| **Progetti spostati riconosciuti** | Apri un progetto spostato e Claude ti dice subito che sembra un workspace registrato il cui vecchio percorso non esiste più, e propone di ricollegarlo. |
| **Claude sa come fare** | Un blocco nel `CLAUDE.md` utente spiega a Claude il registro: puoi semplicemente dirgli *"mia-app ora è in D:\lavoro\mia-app"*. |
| **Esporta / Importa** | Uno zip senza il tuo login da portare su un altro PC, e un'importazione guidata che chiede dove si trova ora ogni progetto. Funziona anche tra sistemi diversi. |
| **Autocontrollo** | Lo Status verifica che Claude Code si comporti ancora come claude-portable si aspetta, e ti avvisa quando esce una nuova versione. |

Gli script per tutti i sistemi, un avvio rapido (`claude-portable.bat` / `claude-portable.sh`), un
breve readme e queste guide complete (`portable/docs`) vengono copiati dentro la cartella dati: sul
nuovo PC funziona da sola, anche senza internet e senza questo repository
(vedi [Solo la cartella dati](#solo-la-cartella-dati)).

## Avvio rapido

Chiudi VS Code, tutti i terminali con Claude Code e l'app desktop di Claude, poi:

**Windows** (PowerShell):
```powershell
irm https://raw.githubusercontent.com/CataniaDaavide/claude-portable/main/get.ps1 | iex
```

**macOS / Linux** (serve `python3`; su macOS, se manca, esegui `xcode-select --install`):
```sh
curl -fsSL https://raw.githubusercontent.com/CataniaDaavide/claude-portable/main/get.sh | sh
```

Scarica l'ultima versione e apre il menu: scegli **1. Install**. Poi riapri VS Code / il terminale
(su un desktop Linux esci e rientra nella sessione) e scegli **2. Status** per controllare.

Preferisci non eseguire uno script preso da internet? Scarica questo repository (pulsante verde
**Code**, **Download ZIP**, oppure `git clone https://github.com/CataniaDaavide/claude-portable.git`)
e avvia **`start.bat`** (Windows) o **`sh start.sh`** (macOS/Linux). Il menu è lo stesso.

L'installazione **copia** i dati, non li sposta: la vecchia `~/.claude` resta come backup finché non
la cancelli tu. Su macOS il login sta nel Portachiavi ed è legato alla cartella dati: dopo
l'installazione rifai una volta `/login`.

**Aggiornare**: riesegui lo stesso comando, che propone di aggiornare la cartella dati in uso.
**2. Status** ti avvisa quando esce una nuova versione. Vedi il [changelog](CHANGELOG.md).

## Menu

![Il menu di claude-portable](docs/images/menu.svg)

| Voce | Script Windows | Quando |
|---|---|---|
| 1. Install or update | `scripts\install.ps1` | Una volta per PC, o per aggiornare la cartella dati |
| 2. Status | `scripts\status.ps1` | Quando vuoi: versione, cartella, conservazione, hook, workspace, compatibilità |
| 3. Relink | `scripts\relink-workspace.ps1` | Un progetto si è spostato |
| 4. Export | `scripts\export-data.ps1` | Prima di passare a un altro PC |
| 5. Import | `scripts\import-data.ps1` | Sul nuovo PC, o dopo aver spostato la cartella dati |
| 6. Uninstall | `scripts\uninstall.ps1` | Tornare alla `~/.claude` predefinita |
| 7. Forget | `scripts\forget-workspace.ps1` | Un progetto cancellato: le sue chat vanno in `portable/forgotten` |
| 8. Archive old chats | `scripts\archive-chats.ps1` | Le chat non toccate da mesi (predefinito 180 giorni) vengono compresse in `portable/archive` ed escono da `/resume` |
| 9. Restore archived chats | `scripts\restore-chats.ps1` | Le rimette al loro posto, con le date originali |

Su macOS/Linux gli stessi comandi sono `python3 unix/claude_portable.py <install|status|relink|export|import|uninstall|forget|archive|restore>`;
aggiungi `--help` per le opzioni.

## Passare a un altro PC

![Passare a un altro PC](docs/images/new-computer.svg)

**Vecchio PC**: menu **4. Export**. Trovi `claude-data-export-<data>.zip` (sul Desktop su Windows,
nella cartella home su macOS/Linux).

**Nuovo PC**:
1. Installa Claude Code e copia lo zip.
2. Avvia il comando di installazione (o `start.bat` / `start.sh` di questo repository) e scegli
   **5. Import**, indicando lo zip e la nuova cartella dati.
3. Per ogni workspace il cui percorso qui non esiste, scrivi il nuovo percorso (o Invio per farlo dopo).
4. Riavvia VS Code / i terminali e rifai il login (`/login`).

Windows, macOS e Linux si possono mescolare: una cartella esportata da Windows si importa su un Mac e
viceversa. Funziona anche copiando l'intera cartella dati (chiavetta, sincronizzazione) invece dello
zip: vedi la sezione successiva.

## Solo la cartella dati

Se sul nuovo PC hai solo la cartella dati (niente repository, niente zip):

1. Installa Claude Code e copia la cartella dati dove vuoi, ad esempio `~/claude-data`.
2. Avvia lo script al suo interno, **`claude-portable.bat`** (Windows) o **`sh claude-portable.sh`**
   (macOS/Linux), e scegli **5. Import**.
3. Come cartella da importare indica la cartella copiata stessa, poi Invio per lasciarla dov'è.
4. La cartella contiene il login del vecchio PC (`.credentials.json`): l'importazione chiede se
   tenerlo. La scelta più sicura è cancellarlo e rifare il login con `/login`.
5. Scrivi il nuovo percorso di ogni progetto (o Invio per ricollegarlo dopo), poi riavvia VS Code.

Senza lo script di avvio (cartelle dati create con la 1.0.0), apri il menu con:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\<tu>\claude-data\portable\scripts\claude-portable.ps1"
```

## Spostare un progetto sullo stesso PC

Chiudi Claude Code in quel progetto, sposta la cartella e aprila semplicemente dal nuovo posto:
Claude si accorge che sembra il workspace spostato e propone di ricollegarlo. In alternativa:
- menu **3. Relink**, oppure
- chiedi a Claude da qualsiasi progetto: *"mia-app è stata spostata in D:\lavoro\mia-app, ricollegala"*.

Se Claude propone di ricollegare un progetto che in realtà è un altro con lo stesso nome di cartella,
diglielo: lo registra come nuovo workspace e non te lo chiede più.

## Spostare la cartella dati sullo stesso PC

Chiudi VS Code, sposta la cartella (ad esempio in `D:\claude-data`), avvia lo script al suo interno e
scegli **5. Import** col nuovo percorso (Invio alla seconda domanda). Claude Code userà il nuovo
posto; quando chiede del login tienilo, è il tuo PC.

## Cosa non viaggia

- **Il login** (`.credentials.json`) non finisce mai nello zip di esportazione: sul nuovo PC rifai
  il login. Una cartella dati copiata così com'è invece lo contiene, e l'importazione chiede se tenerlo.
- **La fiducia nella cartella e i permessi per progetto** (salvati per percorso in `.claude.json`)
  vengono copiati al nuovo percorso dal ricollegamento. Se Claude Code era aperto durante il
  ricollegamento potrebbe chiederlo ancora una volta: accetta.
- **I punti di ripristino** (`file-history`) puntano ai vecchi percorsi e dopo lo spostamento non servono.

## Privacy

Le chat contengono tutto quello che hai scritto e tutto quello che i comandi hanno stampato: possono
esserci password, token o dati di clienti. Tieni privati la cartella dati e lo zip, non metterli mai
su git e non metterli in una cartella cloud pubblica senza cifratura.

## Test

A ogni push i test vengono eseguiti su Windows, Linux e macOS (vedi il badge in alto). Per eseguirli
in locale:

```sh
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1   # Windows
python3 tests/test_unix.py -v                                  # macOS / Linux
```

Lavorano su dati finti in una cartella temporanea e non toccano mai i tuoi dati veri.

## Requisiti

- Windows 10/11 con Windows PowerShell 5.1 (già presente), oppure macOS / Linux con Python 3.8+
- Claude Code (CLI, estensione VS Code o app desktop)

## Licenza

MIT, vedi [LICENSE](LICENSE).

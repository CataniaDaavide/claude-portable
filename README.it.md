# claude-portable - guida in italiano

Tiene tutto quello che [Claude Code](https://code.claude.com) sa dei tuoi progetti (chat, memoria,
impostazioni, skill) in **un'unica cartella** che puoi portare su un altro PC, e ricollega ogni
progetto alle sue chat anche se si trova in un percorso diverso.

Solo Windows (usa PowerShell 5.1, già presente in Windows). [English](README.md).

## Il problema

Claude Code salva i dati in `%USERPROFILE%\.claude`. Ogni progetto ha una cartella dentro `projects\`
il cui nome è il percorso del progetto con ogni carattere non alfanumerico sostituito da `-`:

```
C:\Users\mario\Desktop\mia-app  ->  .claude\projects\C--Users-mario-Desktop-mia-app\
```

Lì dentro ci sono le chat (`*.jsonl`) e la memoria (`memory\`). Se sposti il progetto, o lo apri su un
PC con un altro nome utente, il percorso cambia e Claude riparte da zero anche se hai copiato i dati.
In più, per impostazione predefinita le chat più vecchie di 30 giorni vengono cancellate.

## Cosa fa

| Parte | Cosa fa |
|---|---|
| **Una cartella unica** | Imposta la variabile ufficiale `CLAUDE_CONFIG_DIR`: Claude Code salva tutto nella cartella che scegli (predefinita `%USERPROFILE%\claude-data`). |
| **Chat conservate** | Imposta `cleanupPeriodDays` a 36500 (circa 100 anni). Claude Code non permette di disattivare la pulizia (`0` viene rifiutato), quindi si usa un periodo lunghissimo. |
| **Registro dei workspace** | `portable\workspaces.json` collega ogni percorso di progetto alla sua cartella in `projects\`. Un hook `SessionStart` lo aggiorna ogni volta che apri un progetto. |
| **Ricollegamento** | Quando un progetto si sposta, un comando rinomina (o unisce) la sua cartella col nuovo percorso: `/resume` e memoria tornano a funzionare. |
| **Claude sa come fare** | Un blocco nel `CLAUDE.md` utente spiega a Claude il registro: puoi semplicemente dirgli *"studio-app ora è in D:\lavoro\studio-app"*. |
| **Esporta / Importa** | Uno zip senza il tuo login da portare su un altro PC, e un'importazione guidata che chiede dove si trova ora ogni progetto. |

Gli script vengono copiati anche dentro la cartella dati (`portable\scripts`), insieme a un
`claude-portable.bat` per aprire il menu, a un breve readme e a queste guide complete
(`portable\docs`): sul nuovo PC la cartella funziona da sola, anche senza internet e senza questo
repository (vedi [Solo la cartella dati](#solo-la-cartella-dati)).

## Avvio rapido

1. Scarica questo repository (pulsante verde **Code**, **Download ZIP**) oppure clonalo:
   ```
   git clone https://github.com/CataniaDaavide/claude-portable.git
   ```
2. Chiudi VS Code, tutti i terminali con Claude Code e l'app desktop di Claude.
3. Doppio clic su **`start.bat`** e scegli **1. Install**.
4. Riapri VS Code / il terminale e scegli **2. Status** per controllare.

L'installazione **copia** i dati, non li sposta: la vecchia `%USERPROFILE%\.claude` resta come
backup finché non la cancelli tu.

## Menu

| Voce | Script | Quando |
|---|---|---|
| 1. Install | `scripts\install.ps1` | Una volta per PC |
| 2. Status | `scripts\status.ps1` | Quando vuoi: cartella, conservazione, hook e tutti i workspace |
| 3. Relink | `scripts\relink-workspace.ps1` | Un progetto si è spostato |
| 4. Export | `scripts\export-data.ps1` | Prima di passare a un altro PC |
| 5. Import | `scripts\import-data.ps1` | Sul nuovo PC |
| 6. Uninstall | `scripts\uninstall.ps1` | Tornare alla `~/.claude` predefinita |

## Passare a un altro PC

**Vecchio PC**: menu **4. Export**. Sul Desktop trovi `claude-data-export-<data>.zip`.

**Nuovo PC**:
1. Installa Claude Code e copia lo zip (e questo repository, oppure solo lo zip).
2. Avvia `start.bat`, scegli **5. Import**, indica lo zip e la nuova cartella dati.
3. Per ogni workspace il cui percorso qui non esiste, scrivi il nuovo percorso (o Invio per farlo dopo).
4. Riavvia VS Code / i terminali e rifai il login (`/login`).

Funziona anche copiando l'intera cartella dati (chiavetta, sincronizzazione) invece dello zip:
vedi la sezione successiva.

## Solo la cartella dati

Se sul nuovo PC hai solo la cartella dati (niente repository, niente zip):

1. Installa Claude Code e copia la cartella dati dove vuoi, ad esempio `C:\Users\<tu>\claude-data`.
2. Doppio clic su **`claude-portable.bat`** dentro la cartella copiata e scegli **5. Import**.
3. Come cartella da importare indica la cartella copiata stessa, poi Invio per lasciarla dov'è.
4. La cartella contiene il login del vecchio PC (`.credentials.json`): l'importazione chiede se
   tenerlo. La scelta più sicura è cancellarlo e rifare il login con `/login`.
5. Scrivi il nuovo percorso di ogni progetto (o Invio per ricollegarlo dopo), poi riavvia VS Code.

Senza il `.bat` (cartelle dati create con versioni precedenti), apri il menu con:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\<tu>\claude-data\portable\scripts\claude-portable.ps1"
```

## Spostare un progetto sullo stesso PC

Chiudi Claude Code in quel progetto, sposta la cartella, poi:
- menu **3. Relink**, oppure
- chiedi a Claude da un altro progetto: *"mia-app è stata spostata in D:\lavoro\mia-app, ricollegala"*.

## Cosa non viaggia

- **Il login** (`.credentials.json`) non finisce mai nello zip di esportazione: sul nuovo PC rifai
  il login. Una cartella dati copiata così com'è invece lo contiene, e l'importazione chiede se tenerlo.
- **La fiducia nella cartella e i permessi per progetto** sono legati al percorso in `.claude.json`:
  Claude chiederà di nuovo di fidarsi del progetto spostato. È normale.
- **I punti di ripristino** (`file-history`) puntano ai vecchi percorsi e dopo lo spostamento non servono.

## Privacy

Le chat contengono tutto quello che hai scritto e tutto quello che i comandi hanno stampato: possono
esserci password, token o dati di clienti. Tieni privati la cartella dati e lo zip, non metterli mai
su git e non metterli in una cartella cloud pubblica senza cifratura.

## Licenza

MIT, vedi [LICENSE](LICENSE).

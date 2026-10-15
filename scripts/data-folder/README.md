# This is a claude-portable data folder

This folder holds everything Claude Code saved on a computer: chats, auto memory, settings,
skills and plugins. It was set up by [claude-portable](https://github.com/CataniaDaavide/claude-portable)
and works on its own: you do not need the repository to use it.

- `claude-portable.bat` (one level up): opens the menu (status, relink, export, import, uninstall).
- `portable\workspaces.json`: which project path belongs to which folder under `projects\`.
- `portable\scripts\`: the scripts the menu runs.
- `portable\docs\`: the full guides (`README.md` in English, `README.it.md` in Italian).

## Use it on another computer

1. Install Claude Code on the new computer.
2. Copy this whole folder there, for example to `C:\Users\<you>\claude-data`.
3. Double-click `claude-portable.bat` in the copied folder and choose **5. Import**.
4. As the folder to import, give the copied folder itself; press Enter to keep it where it is.
5. For each project, type where it lives now (or press Enter to do it later with **3. Relink**).
6. Close and reopen VS Code / terminals.

## Keep it private

- The chats contain everything typed and printed in them, possibly passwords or customer data.
  Never put this folder in git or in a shared/public location.
- `.credentials.json` (in the parent folder) is the Claude login. Copying the folder copies the
  login too: the import asks whether to keep it or remove it and log in again with `/login`.
  Menu **4. Export** makes a zip without it.

---

# Questa è una cartella dati di claude-portable

Contiene tutto quello che Claude Code ha salvato su un PC: chat, memoria, impostazioni, skill e
plugin. È stata preparata da [claude-portable](https://github.com/CataniaDaavide/claude-portable) e
funziona da sola: il repository non serve.

- `claude-portable.bat` (nella cartella sopra): apre il menu (stato, ricollega, esporta, importa, disinstalla).
- `portable\workspaces.json`: quale percorso di progetto corrisponde a quale cartella in `projects\`.
- `portable\scripts\`: gli script usati dal menu.
- `portable\docs\`: le guide complete (`README.md` in inglese, `README.it.md` in italiano).

## Usarla su un altro PC

1. Installa Claude Code sul nuovo PC.
2. Copia lì tutta questa cartella, ad esempio in `C:\Users\<tu>\claude-data`.
3. Doppio clic su `claude-portable.bat` nella cartella copiata e scegli **5. Import**.
4. Come cartella da importare indica la cartella copiata stessa; premi Invio per lasciarla dov'è.
5. Per ogni progetto scrivi dove si trova ora (o Invio per farlo dopo con **3. Relink**).
6. Chiudi e riapri VS Code / i terminali.

## Tienila privata

- Le chat contengono tutto quello che è stato scritto e stampato: possono esserci password o dati
  di clienti. Non metterla mai su git né in posti condivisi o pubblici.
- `.credentials.json` (nella cartella sopra) è il login di Claude. Copiando la cartella copi anche
  il login: l'importazione chiede se tenerlo o cancellarlo e rifare `/login`. La voce **4. Export**
  crea uno zip senza login.

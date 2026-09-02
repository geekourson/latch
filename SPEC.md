# SPEC — Latch

**Latch** — gestionnaire de sessions distantes pour macOS.

Application macOS native, open source, qui ouvre en un clic une session
`mosh`/`ssh` + `tmux` sur un serveur distant, se reconnecte seule au réveil du
Mac, et s'intègre finement à Claude Code.

Ce document est la source de vérité du projet. En cas de contradiction entre ce
fichier et une demande ponctuelle, signale la contradiction avant d'agir.

### Conventions de nommage

Le nom est un loquet : ce qui s'accroche et tient. Il renvoie au `tmux attach`
sans en avoir le jargon.

| Élément | Valeur |
|---|---|
| Nom affiché | Latch |
| Dépôt | `latch` |
| Identifiant de bundle | `app.latch.Latch` (à ajuster si tu possèdes un domaine) |
| Cask Homebrew | `latch` (vérifié libre) |
| Dossier de support | `~/Library/Application Support/app.latch.Latch/` |
| Cible Xcode | `Latch` |
| Accroche | « Your sessions, still running. » |

Le verbe maison est *to latch on* : dans l'interface et les messages d'erreur,
on écrit « latch on to billy », pas « connect to billy ». Rester cohérent —
c'est ce qui donne une identité à un outil en ligne de commande.

Ne pas décliner le nom en sous-produits (`latchd`, `latch-cli`, `LatchKit`)
tant que la v0.4 n'est pas livrée.

---

## 1. Objectif

Un utilisateur clique sur une session dans la barre latérale. L'app ouvre un
terminal attaché à une session `tmux` distante, quel que soit l'état de la
connexion précédente. Il ferme son Mac, le rouvre le lendemain, et retrouve la
session exactement où il l'avait laissée — sans saisir de mot de passe et sans
action manuelle.

### Non-objectifs (ne pas construire)

- Un émulateur de terminal écrit de zéro. On embarque SwiftTerm.
- Une implémentation de SSH. On pilote les binaires `ssh` et `mosh` du système.
- Un moteur de workflow générique avec conditions et boucles.
- Une installation automatique de paquets sur le serveur distant.
- Le support de Windows ou Linux.

---

## 2. Stack technique

| Élément | Choix | Note |
|---|---|---|
| Langage | Swift 5.9+ | |
| Cible | macOS 14+ | |
| UI | SwiftUI, AppKit via `NSViewRepresentable` | |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) | seule dépendance obligatoire |
| Projet | XcodeGen (`project.yml`) | pas de `.xcodeproj` versionné |
| Tests | Swift Testing ou XCTest | |
| Licence | MIT | |

**Règle sur les dépendances** : n'ajoute aucune bibliothèque tierce sans la
proposer d'abord et attendre validation. SwiftTerm est la seule pré-approuvée.

---

## 3. Architecture

Quatre couches, à garder strictement séparées. Aucune couche ne connaît la
couche au-dessus d'elle.

```
AppState / SessionStore      état, persistance JSON, trousseau
        ↓
CommandBuilder               modèle → chaîne de commande unique
        ↓
ConnectionDriver             lance un binaire dans un PTY, expose des octets
        ↓
TerminalPane                 SwiftTerm branché sur le flux
```

### 3.1 `PTYProcess`

Encapsule `forkpty(3)`. Responsabilités :

- Ouvrir un PTY, `fork`, `execv("/bin/sh", ["-c", command])` dans l'enfant.
- Exposer le descripteur maître, le PID, un flux d'octets entrants.
- `resize(rows:cols:)` via `TIOCSWINSZ`.
- Détecter la mort du process (`waitpid` sur une file dédiée) et publier un
  état `.exited(code:)`.
- `terminate()` propre : `SIGHUP` puis `SIGKILL` après 2 s.

Pas de logique métier ici. Cette classe ne sait pas ce qu'est ssh.

### 3.2 `ConnectionDriver`

Protocole avec trois implémentations : `MoshDriver`, `SSHDriver`, `LocalDriver`.
Chacune construit une commande et délègue à `PTYProcess`.

```swift
protocol ConnectionDriver {
    var state: AnyPublisher<ConnectionState, Never> { get }
    func connect(_ shortcut: Shortcut) throws
    func disconnect()
    func send(_ data: Data)
}

enum ConnectionState {
    case idle, connecting, connected, reconnecting
    case degraded(reason: String)
    case failed(Error)
}
```

`MoshDriver` utilise le binaire embarqué dans le bundle (voir §7), pas celui du
`PATH`.

### 3.3 `CommandBuilder`

Fonction pure, entièrement testable, qui transforme un `Shortcut` en une seule
chaîne. C'est le cœur du projet — écris les tests avant le code.

### 3.4 `TerminalPane`

`NSViewRepresentable` autour de `TerminalView` de SwiftTerm. Reçoit un
`ConnectionDriver`, écrit les frappes dedans, affiche les octets reçus.

---

## 4. Modèle de données

Persisté en JSON dans
`~/Library/Application Support/app.latch.Latch/shortcuts.json`.
**Aucun secret dans ce fichier.**

```swift
struct Shortcut: Codable, Identifiable {
    var id: UUID
    var name: String              // "API · Claude"
    var preflight: [Preflight]    // commandes locales, ordre significatif
    var connection: Connection    // exactement une, non supprimable
    var windows: [TmuxWindow]     // fenêtres tmux, ordre significatif
    var customCommand: String?    // si non nil, remplace tout le reste
}

struct Preflight: Codable, Identifiable {
    var id: UUID
    var label: String
    var command: String           // exécutée localement via /bin/sh -c
    var failureIsFatal: Bool      // sinon : avertir et continuer
}

struct Connection: Codable {
    var transport: Transport
    var host: String              // alias ~/.ssh/config de préférence
    var jumpHost: String?         // -J, seulement si transport == .sshJump
    var tmuxSession: String       // "api"
    var workingDirectory: String? // "~/api"
    var initialCommand: InitialCommand
    var extraArgs: String?        // "--model opus --permission-mode acceptEdits"
    var keepShellOnExit: Bool     // ajoute "; exec $SHELL"
    var controlMode: Bool         // tmux -CC (incompatible mosh, voir §5)
}

enum Transport: String, Codable {
    case mosh, ssh, sshJump, eternalTerminal, local
}

enum InitialCommand: Codable, Equatable {
    case shell                    // rien
    case claude
    case claudeContinue           // claude --continue
    case claudeResume             // claude --resume
    case custom(String)
}

struct TmuxWindow: Codable, Identifiable {
    var id: UUID
    var name: String              // "logs"
    var command: String           // "journalctl -fu api"
}
```

### Serveurs

Séparés des raccourcis, pour que plusieurs raccourcis partagent un hôte :

```swift
struct Server: Codable, Identifiable {
    var id: UUID
    var name: String              // "billy"
    var sshAlias: String          // entrée Host de ~/.ssh/config
    var probe: ProbeResult?       // mis en cache, voir §6
    var probedAt: Date?
}
```

---

## 5. Construction de la commande

### Règle générale

```
<transport> <préfixe tmux> 'commande initiale[; exec $SHELL]'
```

Exemples attendus, à couvrir par des tests :

```bash
# mosh + claude, avec dossier de travail
mosh billy -- tmux new -A -s api -c ~/api 'claude; exec $SHELL'

# ssh + reprise de conversation
ssh -t billy "tmux new -A -s api -c ~/api 'claude --continue; exec \$SHELL'"

# ssh via bastion
ssh -t -J bastion billy "tmux new -A -s api"

# shell seul, pas de dossier
mosh billy -- tmux new -A -s dev

# local, sans connexion
tmux new -A -s notes -c ~/notes
```

### Points non négociables

- `tmux new -A -s <session>` : attache si la session existe, la crée sinon.
  **Ne jamais écrire de logique conditionnelle « la session existe-t-elle ? »**
  — `-A` s'en charge, et c'est ce qui rend la reconnexion triviale.
- `ssh` exige `-t` (allocation de TTY). Sans lui, tmux refuse de démarrer.
- `mosh` sépare ses arguments de la commande distante par `--`.
- La commande initiale n'est exécutée **qu'à la création** de la session. Aux
  lancements suivants, `-A` attache et l'ignore. C'est voulu.
- `keepShellOnExit` ajoute `; exec $SHELL` pour que la session tmux survive à
  la sortie de `claude`.
- `controlMode` (`tmux -CC`) : refuser la combinaison avec `mosh` au niveau du
  modèle, avec un message clair dans l'interface. Ne pas l'autoriser puis
  échouer à l'exécution.

### Échappement

Le point le plus fragile du projet. Écris une fonction dédiée et teste-la avec
des noms de session et des dossiers contenant espaces, apostrophes, `$` et `"`.
Un raccourci mal formé ne doit jamais être exécuté : préfère une erreur de
validation à une commande approximative.

---

## 6. Sonde du serveur et dégradation

À la première connexion à un hôte, un seul aller-retour :

```bash
ssh <alias> 'command -v tmux mosh-server claude; tmux -V 2>/dev/null; . /etc/os-release 2>/dev/null && echo $ID'
```

Résultat mis en cache dans `Server.probe`, avec invalidation manuelle depuis
l'interface et expiration après 7 jours.

### Cascade de dégradation

| État du serveur | Comportement |
|---|---|
| tmux + mosh | commande nominale |
| tmux seul | bascule sur `ssh -t`, bandeau non bloquant proposant mosh |
| aucun des deux | `ssh -t <alias>` sur un shell nu, bandeau signalant que la session ne survivra pas |

**La connexion réussit toujours, même dégradée.** Aucune modale bloquante avant
d'avoir donné accès au serveur. Le bandeau est cliquable et ouvre le panneau
d'amélioration décrit ci-dessous.

**Interdits** : `sudo -S` avec un mot de passe injecté, `sshpass`, toute
installation silencieuse.

### Panneau d'amélioration du serveur

Ouvert depuis le bandeau, ou depuis les réglages du serveur. Ce n'est pas une
modale bloquante : la session reste utilisable derrière.

Contenu, de haut en bas :

1. **Diagnostic** — une ligne par outil, avec son état : `tmux 3.4 ✓`,
   `mosh-server absent ✗`. Les versions viennent de la sonde du §6.
2. **Conséquence en une phrase**, pas de jargon : « sans mosh, la session se
   fige après une mise en veille et doit être relancée à la main ».
3. **Commande exacte**, en mono, sélectionnable, construite à partir du champ
   `ID` de `/etc/os-release` :

| `ID` détecté | Commande proposée |
|---|---|
| `debian`, `ubuntu`, `raspbian`, `linuxmint`, `pop` | `sudo apt install -y tmux mosh` |
| `fedora`, `rhel`, `centos`, `rocky`, `almalinux` | `sudo dnf install -y tmux mosh` |
| `arch`, `manjaro`, `endeavouros` | `sudo pacman -S --noconfirm tmux mosh` |
| `alpine` | `sudo apk add tmux mosh` |
| `opensuse*`, `sles` | `sudo zypper install -y tmux mosh` |
| `freebsd` | `sudo pkg install -y tmux mosh` |
| inconnu ou vide | pas de commande : afficher les paquets requis (`tmux`, `mosh`) et un lien vers la doc, avec un champ libre où l'utilisateur écrit sa propre commande |

   N'inclure que les paquets réellement manquants. Si seul mosh manque, la
   commande ne doit pas réinstaller tmux.

4. **Note pare-feu**, affichée uniquement si mosh fait partie des paquets à
   installer : mosh a besoin des ports UDP 60000–61000, avec la commande `ufw`
   correspondante en second bloc, présentée comme optionnelle.
5. **Deux boutons** :
   - `Copier` — copie la commande, sans rien exécuter. C'est l'action par
     défaut et la plus sûre.
   - `Exécuter dans un panneau` — ouvre un nouvel onglet terminal sur cet hôte,
     y écrit la commande **sans l'exécuter**, et laisse le curseur en fin de
     ligne. L'utilisateur appuie lui-même sur Entrée et tape son mot de passe
     sudo dans un vrai TTY. L'app ne lit ni ne stocke ce mot de passe.

Après la fermeture du panneau, invalider le cache de la sonde pour cet hôte et
la relancer, afin que le bandeau disparaisse tout seul si l'installation a
réussi. Si elle a échoué, le bandeau reste et le panneau rouvre sur le même
diagnostic — ne pas afficher de confirmation de succès qu'on n'a pas vérifiée.

Prévoir une case « ne plus proposer pour cet hôte », stockée sur le `Server`.
Un serveur géré par quelqu'un d'autre ne sera jamais amélioré, et redemander à
chaque connexion est le meilleur moyen de faire désinstaller l'app.

### Piège connu

`mosh-server` et `claude` doivent être trouvables dans un shell **non
interactif**. Si la sonde ne les trouve pas alors qu'ils fonctionnent en
session, c'est que le `PATH` est défini dans `~/.bashrc` au lieu de
`~/.profile` / `~/.zshenv`. Mentionne-le dans le message d'erreur — c'est le
support n°1 attendu.

---

## 7. Binaire mosh embarqué

`mosh-client` est compilé et placé dans `Latch.app/Contents/MacOS/mosh-client`.
L'app l'invoque par chemin absolu, jamais via le `PATH`. Objectif : ne pas
exiger Homebrew de l'utilisateur.

Note la version embarquée dans le README — mosh est sensible aux écarts de
version entre client et serveur.

Aucun binaire n'est requis côté Mac pour tmux : tmux ne tourne que sur le
serveur.

---

## 8. Reconnexion et cycle de vie

```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
) { _ in sessionStore.reconnectAll() }
```

- `didSleepNotification` → marquer les sessions `.reconnecting`, ne rien tuer.
- `didWakeNotification` → pour chaque session, vérifier si le process est
  vivant. S'il l'est (cas normal avec mosh), ne rien faire. S'il est mort,
  relancer **exactement la même commande** : `-A` fait le reste.
- Backoff exponentiel plafonné à 30 s, avec annulation si l'utilisateur ferme
  l'onglet.
- Jamais de reconnexion silencieuse en boucle sur un échec d'authentification :
  après 3 échecs, passer en `.failed` et attendre une action.

---

## 9. Interface

### 9.1 Fenêtre principale

- Barre de titre transparente (`titlebarAppearsTransparent`,
  `titleVisibility = .hidden`), feux de circulation atténués au repos.
- Barre latérale ~180 px, **sans bordure** — la séparation se fait par le vide.
  Serveurs en gras, sessions tmux indentées en mono en dessous. Pastille d'état
  par serveur : vert (connecté), ambre (veille / dégradé), gris (hors ligne).
- Onglets : fond légèrement plus clair pour l'actif, aucun séparateur entre les
  inactifs.
- Zone terminal : padding 18–22 px, interligne 1,8.
- Barre d'état basse, très discrète : état Claude Code, branche git, diff,
  latence.

### 9.2 Écran du builder

Étapes empilées et réordonnables, une carte par étape :

1. **Pré-vol** — badge « local », supprimable, réordonnable entre elles.
2. **Connexion** — une seule, **non supprimable** (pas d'icône corbeille),
   dépliable, contient les champs du §4.
3. **Fenêtres** — supprimables, réordonnables entre elles.

Le glisser-déposer est contraint : un pré-vol ne peut pas passer après la
connexion, une fenêtre ne peut pas passer avant. Refuse le drop plutôt que de
désactiver la poignée.

En bas, l'aperçu de la commande générée, **éditable**. Si l'utilisateur le
modifie, `customCommand` est renseigné et le formulaire passe en mode
« personnalisé » avec un bouton pour revenir au mode assisté.

Contenu des sélecteurs :

- **Transport** : mosh (défaut) · ssh · ssh via rebond · Eternal Terminal · local
- **À la création** : shell seul · claude · claude --continue · claude --resume ·
  commande personnalisée…

### 9.3 Thème

Palette par défaut « braise », charbon chaud plutôt que gris neutre :

```
fond          #17130F
surface       #1D1813
surface haute #241D18
bordure       #2A231D / #3A302A
texte         #EDE4D8
texte faible  #7C6F63
texte discret #57493F
accent        #C89B6A   (ambre)
succès        #8FB09A   (sauge)
violet        #B3A0D6   (Claude Code)
```

Prévoir l'import de thèmes au format base16 ou iTerm2 dès la v0.2 — ne pas
inventer un format maison.

Typographie : police mono configurable, défaut JetBrains Mono avec repli sur SF
Mono. Ligatures activables/désactivables. Largeur de cellule dérivée de
l'avance d'un glyphe de référence, jamais des métriques globales de la police.

---

## 10. Intégration Claude Code

Claude Code tourne **sur le serveur**, pas sur le Mac. Tout passe par le tunnel.

### v0.3 — Hooks (priorité haute, effort faible)

Un hook côté serveur écrit chaque événement en JSON sur une socket Unix ou un
fichier ; l'app le lit via une connexion ssh secondaire persistante.

Événements exploités : `SessionStart`, `PreToolUse`, `PostToolUse`,
`SessionEnd`. Utilisations dans l'app :

- indicateur « Claude Code actif » dans la barre latérale et la barre d'état ;
- fichier en cours de modification, affiché en direct ;
- notification macOS + rebond du Dock quand une tâche se termine ou qu'une
  permission est attendue.

Fournir un script d'installation du hook, exécuté depuis l'app avec
confirmation explicite de l'utilisateur.

### v0.4 — Serveur MCP (différenciateur)

Exposer l'app à Claude Code : ouvrir un panneau, lancer une commande dans un
split, afficher un fichier. Une centaine de lignes suffisent.

### Plus tard — headless

Pour les panneaux latéraux qui n'ont pas besoin d'un terminal (« explique ce
diff ») :

```bash
claude -p "<prompt>" --output-format json --json-schema '<schema>'
```

Le résultat structuré arrive dans le champ `structured_output` ; le champ
`result` contient le texte. Pour du streaming, `--output-format stream-json`
avec `--verbose` et `--include-partial-messages`, chaque ligne étant un objet
JSON, la dernière étant un message `result`.

⚠️ `--bare` accélère le démarrage mais ne lit ni les identifiants OAuth ni le
trousseau : il exige `ANTHROPIC_API_KEY`. Les fonctions headless sont donc
facturées à l'usage API, pas sur l'abonnement. Signale-le clairement dans
l'interface avant la première utilisation.

### v2 — Permissions natives

Remplacer le prompt ASCII par une feuille macOS avec diff coloré, via
`--input-format stream-json` bidirectionnel, ou un démon Node/Python utilisant
l'Agent SDK côté serveur. **Ne pas commencer par là.** La case « ne plus
demander » doit écrire une règle dans `permissions.allow` côté serveur, jamais
garder l'état localement.

---

## 11. Sécurité

- Authentification par clé uniquement. Le fichier de config ne contient jamais
  de secret.
- Si un mot de passe est indispensable : lecture depuis le trousseau
  (`kSecClassInternetPassword`), écriture **sur le PTY** après détection du
  prompt, jamais en argument de commande. Prévoir plusieurs motifs de prompt
  (`password:`, `Mot de passe :`) et un délai d'attente.
- `sshpass` est explicitement interdit.
- Proposer un bouton « configurer une clé pour cet hôte » qui exécute
  `ssh-keygen` puis `ssh-copy-id` dans un panneau visible.

---

## 12. Feuille de route

Livre une version fonctionnelle à chaque étape. Ne commence pas la suivante
avant que la précédente compile, passe ses tests et soit utilisable.

### v0.1 — Ça marche

Une fenêtre, un `TerminalPane`, un `PTYProcess` qui lance une commande codée en
dur. Critère d'acceptation : `mosh billy -- tmux new -A -s api` s'ouvre,
`vim` et `htop` s'affichent correctement, le redimensionnement fonctionne.

### v0.2 — C'est une app

`SessionStore` + JSON, barre latérale avec serveurs et sessions, onglets,
`CommandBuilder` complet avec tests, écran du builder, thème.

### v0.3 — C'est utile

`MoshDriver` avec binaire embarqué, sonde et cascade de dégradation,
reconnexion au réveil, hooks Claude Code.

### v0.4 — C'est distinctif

`tmux -CC` pour peupler la barre latérale avec les vraies fenêtres tmux, serveur
MCP, import de thèmes.

---

## 13. Qualité et dépôt

- Tests unitaires obligatoires sur `CommandBuilder` et l'échappement. Le reste
  au jugé.
- `project.yml` (XcodeGen), pas de `.xcodeproj` versionné.
- README avec une capture d'écran dès le premier commit.
- GitHub Actions : build + tests sur chaque PR ; sur tag, build, signature,
  notarisation et publication d'un `.dmg`.
- Note dans le README que la notarisation exige un compte développeur Apple
  (99 €/an) et que, sans elle, le premier lancement demande clic droit →
  Ouvrir.

---

## 14. Environnement de test

Serveur de référence : `billy@192.168.1.37`, alias ssh `billy`, clé ed25519
déjà installée, connexion sans mot de passe fonctionnelle.

L'IP est attribuée par DHCP : le README doit recommander une réservation dans le
routeur, un nom mDNS (`billy.local`), ou Tailscale pour un accès hors du réseau
local.

---

## 15. Consignes de travail

- Pose des questions avant de coder si une décision structurante n'est pas
  tranchée ici.
- Un commit par sous-étape cohérente, message en anglais, format conventionnel.
- Après chaque étape de la feuille de route : compile, lance les tests, et
  décris en trois lignes ce qui est testable manuellement.
- N'invente pas d'API SwiftTerm — lis le code source du paquet dans
  `.build/checkouts/` avant d'utiliser une classe que tu ne connais pas.
- Si une contrainte de ce document rend une étape impossible, dis-le au lieu de
  contourner silencieusement.

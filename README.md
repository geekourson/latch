<h1 align="center">Latch</h1>
<p align="center"><em>Your sessions, still running.</em></p>
<p align="center">
  <img alt="statut : alpha" src="https://img.shields.io/badge/statut-alpha-D97757">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-8FB09A">
  <img alt="licence MIT" src="https://img.shields.io/badge/licence-MIT-C89B6A">
</p>

> [!WARNING]
> **Alpha.** Latch est complet au sens de sa feuille de route, et utilisé tous
> les jours par son auteur — mais sur **une seule machine et un seul serveur**.
> Rien n'a été éprouvé ailleurs. Attendez-vous à des arêtes vives, et voyez
> [Ce qui n'a pas été vérifié](#ce-qui-na-pas-été-vérifié) avant de compter
> dessus.

Latch est un gestionnaire de sessions distantes pour macOS. Un clic sur une
session ouvre un terminal attaché à une session `tmux` sur un serveur, quel que
soit l'état de la connexion précédente. Vous fermez le Mac, vous le rouvrez le
lendemain, la session est là où vous l'aviez laissée.

![Latch : la barre latérale, ses sessions et leurs fenêtres tmux, et la barre d'état](docs/screenshot.png)

## État

**v0.4 — alpha.** La feuille de route est parcourue : raccourcis persistés en
JSON, barre latérale, onglets, écran du builder, import de thèmes, sonde serveur
et cascade de dégradation, reconnexion au réveil, drivers de connexion, hooks
Claude Code, fenêtres tmux réelles et serveur MCP. 315 tests passent.

Parcourue ne veut pas dire éprouvée. Ce qui suit est décrit tel que c'est
construit ; ce qui n'a jamais tourné ailleurs que sur la machine de
développement est dit plus bas, nommément.

### Ce qui n'a pas été vérifié

| | |
|---|---|
| **Un seul serveur** | Tout a été validé contre un hôte Debian. La sonde prétend reconnaître six familles de distributions ; **cinq n'ont jamais été exercées**. |
| **La reconnexion au réveil** | Le code et ses tests existent, le scénario complet — capot fermé, réseau perdu, retour — n'a jamais été observé de bout en bout. |
| **Le MCP piloté par Claude Code** | Le serveur a été exercé à la main. Le chemin réel, Claude Code sur le serveur appelant Latch par le tunnel, reste à voir tourner. |
| **La distribution** | Aucune release n'a été produite : signature et notarisation exigent un compte développeur Apple. Le workflow existe, il n'a jamais été joué. |
| **Le glisser-déposer** | Réordonner les étapes de pré-vol et les fenêtres fonctionne en théorie, jamais essayé sérieusement. |

Rien de tout cela n'est cassé à ma connaissance. C'est simplement non vérifié,
et la différence compte quand quelqu'un d'autre s'en sert.

### La barre latérale montre les vraies fenêtres

Sous chaque session ouverte, Latch liste les fenêtres que tmux a réellement, avec
ce qui tourne dedans. Un clic bascule la session distante dessus ; le terminal
suit tout seul, c'est tmux qui décide de ce qu'il affiche.

### Claude Code peut piloter Latch

Un serveur MCP tourne dans l'app et expose quatre outils : lister les onglets,
ouvrir un raccourci, lancer une commande, afficher un fichier. Claude Code, qui
tourne sur le serveur, l'atteint par un `-R` porté par la connexion des hooks —
tout passe par le tunnel, rien n'est exposé au réseau.

Le serveur n'écoute que sur `127.0.0.1` et exige un jeton tiré à chaque
lancement de Latch. La commande `claude mcp add` à jouer sur le serveur est
affichée dans le panneau d'amélioration.

### La clé d'abord, le mot de passe en dernier

L'authentification se fait par clé. Quand un hôte n'en a pas encore, le panneau
propose de la mettre en place : `ssh-keygen` puis `ssh-copy-id` s'exécutent
dans un panneau **visible**, parce que `ssh-copy-id` demande le mot de passe du
compte distant et qu'il doit le demander dans un vrai TTY. Latch ne le voit
pas. Une clé existante n'est jamais écrasée, et la phrase de passe reste à
votre main.

Si un serveur n'accepte décidément que les mots de passe, Latch peut en garder
un — dans le **trousseau du système**, jamais dans son fichier de
configuration — et l'écrit sur le pseudo-terminal après avoir vu l'invite. Avec
trois garde-fous, parce qu'un automate qui tape un mot de passe tout seul est
une mauvaise idée dès qu'il se trompe de moment : une fenêtre de temps après la
connexion, trois tentatives au maximum, et pas deux réponses à la même invite
redessinée.

### La barre d'état dit où on en est

Discrète, en bas : l'état de la connexion, l'activité de Claude Code et le
fichier qu'il touche, la **branche git et le diff** du panneau actif de la
session distante, et la **latence** — le temps d'ouverture d'une connexion TCP
vers le port ssh de l'hôte. Ce qu'on ne sait pas ne s'affiche pas : un vide
vaut mieux qu'un chiffre inventé.

### Les pastilles se lisent, elles ne se devinent pas

Six couleurs, pas une de plus, et la même grammaire partout — barre latérale,
onglets, barre d'état. La légende est dans **Réglages → Repères**, pour ne pas
avoir à revenir ici.

| | | |
|---|---|---|
| ● | **sauge** | connecté, tout ce qui était demandé est en place |
| ● | **ardoise** | en cours : connexion, ou reconnexion après une veille |
| ● | **ambre** | dégradé — ça marche, mais mosh ou tmux manque |
| ● | **terracotta** | bloqué : une connexion a échoué, ou Claude attend une autorisation |
| ○ | **terracotta, en anneau** | à toi — Claude a rendu la main et attend ta réponse |
| ● | **violet** | une session Claude Code travaille |
| ● | **gris** | inactif : rien ne tourne, et rien n'attend |

Le remplissage porte l'urgence : plein, quelque chose t'attend ; en anneau, tu
peux prendre ton temps. Et le violet n'appartient qu'à Claude Code — c'est ce
qui permet de le repérer du coin de l'œil.

### La session se rattrape toute seule

Le Mac s'endort : rien n'est tué, les sessions sont simplement marquées. Il se
réveille : un process encore vivant — le cas normal avec mosh — est laissé
tranquille, un process mort est relancé avec **exactement la même commande**,
que `tmux new -A` transforme en la session qui était là.

Les tentatives suivent un backoff exponentiel plafonné à 30 secondes et
s'arrêtent après trois échecs, laissant un bouton « Réessayer » plutôt qu'une
boucle silencieuse sur une authentification refusée.

## Ce que fait Latch

Un clic sur une session dans la barre latérale ouvre un onglet attaché à
`tmux new -A -s <session>` sur le serveur. `-A` attache si la session existe et
la crée sinon : il n'y a nulle part de logique « la session existe-t-elle ? »,
et c'est ce qui rend la reconnexion triviale.

### La commande est construite, pas devinée

L'écran du builder empile des étapes — pré-vol local, connexion, fenêtres tmux —
et affiche en bas la commande générée, **éditable**. La modifier bascule le
raccourci en mode personnalisé, avec un bouton pour revenir au mode assisté.

```bash
ssh -t alex "tmux new -A -s api -c ~/api 'claude --continue; exec \$SHELL'"
mosh alex -- tmux new -A -s dev
tmux new -A -s notes -c ~/notes
```

L'échappement est la partie fragile, et elle est testée en faisant réellement
traverser un `/bin/sh` aux commandes produites, avec de faux `tmux`, `ssh` et
`mosh` qui impriment les arguments reçus.

### Claude Code, sur le serveur comme sur le Mac

Latch suit l'activité de Claude Code par ses hooks : un petit script écrit
chaque événement sur une ligne dans `~/.latch/events.jsonl`, qu'une connexion
ssh secondaire suit en direct. Sur le Mac, il n'y a pas de connexion — le
journal est un fichier d'ici, et `tail -F` suffit. Rien dans ce mécanisme n'est
propre à ssh : le hook écrit un fichier, le suivi lit un fichier, et
l'installation n'écrit que dans le dossier personnel, sans `sudo`.

La barre latérale et la barre d'état montrent alors si Claude travaille et quel
fichier il touche, et **quelle session** l'attend : les hooks ne connaissent
qu'un `cwd`, qu'on rapproche du répertoire du panneau actif relevé par la boucle
tmux. Une notification et un rebond du Dock préviennent quand une tâche se
termine ou qu'**une permission est attendue** — et rien d'autre, parce que
chaque outil utilisé ne mérite pas d'interrompre.

L'installation se fait depuis le panneau d'amélioration, script visible avant
exécution. Les hooks déjà présents dans `~/.claude/settings.json` sont
conservés, et une copie est mise de côté avant modification.

### Le serveur est sondé, jamais modifié

À la première connexion à un hôte, un aller-retour unique relève `tmux`,
`mosh-server`, `claude` et l'identifiant de la distribution. Le résultat est mis
en cache sept jours.

| État du serveur | Ce que fait Latch |
|---|---|
| tmux + mosh | commande nominale |
| tmux seul | bascule sur `ssh -t`, bandeau non bloquant proposant mosh |
| aucun des deux | `ssh -t` sur un shell nu, bandeau signalant que la session ne survivra pas |

**La connexion réussit toujours, même dégradée.** Le bandeau est cliquable et
ouvre un panneau qui affiche le diagnostic, la conséquence en une phrase, et la
commande d'installation exacte construite depuis `/etc/os-release` :

| `ID` détecté | Commande proposée |
|---|---|
| `debian` `ubuntu` `raspbian` `linuxmint` `pop` | `sudo apt install -y …` |
| `fedora` `rhel` `centos` `rocky` `almalinux` | `sudo dnf install -y …` |
| `arch` `manjaro` `endeavouros` | `sudo pacman -S --noconfirm …` |
| `alpine` | `sudo apk add …` |
| `opensuse*` `sles` | `sudo zypper install -y …` |
| `freebsd` | `sudo pkg install -y …` |
| inconnu | aucune commande — les paquets requis, un lien, et un champ libre |

Seuls les paquets réellement manquants y figurent. Claude Code a sa propre
ligne, **sans `sudo`** : son installeur officiel refuse de tourner sous sudo et
installe dans `$HOME/.local/bin`.

Latch n'exécute rien de tout ça. Le bouton par défaut est `Copier` ; l'autre
ouvre un onglet sur l'hôte et y **écrit** la commande sans appuyer sur Entrée,
pour que le mot de passe `sudo` soit tapé dans un vrai TTY. Aucun `sudo -S`,
aucun `sshpass`, aucune installation silencieuse.

## Prérequis

- macOS 14 ou plus récent
- Xcode 16 ou plus récent, avec la chaîne d'outils Metal
  (`xcodebuild -downloadComponent MetalToolchain`) — SwiftTerm embarque un
  shader Metal, et depuis Xcode 26 ce composant se télécharge à part
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) : `brew install xcodegen`
- Côté serveur : `tmux`. `mosh` en plus si vous voulez que la session survive
  à une mise en veille sans se reconnecter.

Rien à installer côté Mac pour tmux : tmux ne tourne que sur le serveur.

## Construire

```bash
xcodegen generate
xcodebuild -project Latch.xcodeproj -scheme Latch \
           -destination 'platform=macOS' \
           -skipPackagePluginValidation build
```

Le `.xcodeproj` n'est pas versionné : il est régénéré depuis `project.yml`.

### Tests

```bash
xcodebuild -project Latch.xcodeproj -scheme Latch \
           -destination 'platform=macOS' \
           -skipPackagePluginValidation test
```

## Premier lancement

Deux autorisations macOS peuvent se mettre en travers, et elles ne se voient
qu'au lancement depuis le Finder — depuis un terminal, l'app hérite de celles
du terminal :

- **Réseau local** (Réglages → Confidentialité et sécurité → Réseau local).
  Sans elle, un serveur du LAN est injoignable et Latch affiche
  `ssh: connect to host 192.168.1.10 port 22: No route to host`. macOS propose
  la demande au premier lancement ; si elle a été refusée, il faut la
  réactiver à la main.
- **Signature**. Latch est signée localement pendant le développement. Un `.app`
  téléchargé et non notarisé est bloqué au premier lancement — voir
  [Ouvrir une version non notarisée](#ouvrir-une-version-non-notarisée).

### Ouvrir une version non notarisée

Glissez d'abord `Latch.app` sur **Applications** : lancée depuis le disque
monté, en lecture seule, elle ne saurait pas s'écrire.

macOS affiche ensuite une alerte qui ne propose que **Terminer** ou **Déplacer
vers la corbeille**. Choisissez *Terminer*, puis **Réglages Système →
Confidentialité et sécurité**, descendez jusqu'à la section Sécurité, et
cliquez **Ouvrir quand même**.

> [!NOTE]
> Jusqu'à macOS 14, un clic droit → *Ouvrir* suffisait. **Apple a supprimé ce
> contournement dans macOS 15** : le menu contextuel ne propose plus rien, et
> seul le passage par les Réglages Système fonctionne.

En une ligne, si vous préférez le terminal :

```bash
xattr -dr com.apple.quarantine /Applications/Latch.app
```

## Configuration

Les raccourcis vivent dans
`~/Library/Application Support/app.latch.Latch/shortcuts.json`.
**Ce fichier ne contient jamais de secret** : l'authentification se fait par
clé, et Latch ne stocke aucun mot de passe.

Au premier lancement, la barre latérale se remplit avec les alias `Host` de
`~/.ssh/config`. Ajoutez-y l'entrée correspondant à votre serveur :

```
Host alex
    HostName 192.168.1.10
    User alex
    IdentityFile ~/.ssh/id_ed25519
```

L'authentification se fait **par clé uniquement**. Latch ne stocke aucun mot de
passe et ne lit jamais celui que vous tapez dans le terminal.

`TERM` est imposé à `xterm-256color` — ce que SwiftTerm émule réellement — et
jamais hérité du terminal d'où Latch a été lancée. Sans cela, une app démarrée
depuis Ghostty enverrait `TERM=xterm-ghostty` à un serveur qui n'a pas ce
terminfo, et le tmux distant refuserait de démarrer sur
`missing or unsuitable terminal`.

### Sur l'adresse du serveur

L'IP d'un serveur de maison est souvent attribuée par DHCP et change. Trois
façons de ne pas avoir à modifier `~/.ssh/config` tous les mois, de la plus
simple à la plus solide :

1. réserver l'adresse dans le routeur, par adresse MAC ;
2. utiliser le nom mDNS de la machine, `alex.local`, valable sur le réseau
   local ;
3. installer [Tailscale](https://tailscale.com), qui donne un nom stable et
   fonctionne aussi hors du réseau local.

## Architecture

Quatre couches, strictement séparées — aucune ne connaît celle du dessus :

| Couche | Rôle | État |
|---|---|---|
| `SessionStore` | état, persistance JSON, trousseau | ✅ |
| `CommandBuilder` | modèle → chaîne de commande | ✅ |
| `ConnectionDriver` | lance un binaire dans un PTY | v0.3 |
| `PTYProcess` | `forkpty(3)`, octets, `SIGWINCH`, fin de vie | ✅ |
| `TerminalPane` | SwiftTerm branché sur le flux | ✅ |

## Dépendances

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0 (MIT) — le seul
  émulateur de terminal embarqué. Il tire lui-même `swift-argument-parser`.

### mosh et la GPLv3

Les binaires publiés embarquent **mosh-client 1.4.0** dans
`Latch.app/Contents/MacOS/mosh-client`, invoqué par chemin absolu et jamais via
le `PATH` — l'objectif étant de ne pas exiger Homebrew de l'utilisateur. La
version est figée : mosh est sensible aux écarts entre client et serveur.

mosh est sous **GPL-3.0-or-later**. Latch, sous licence MIT, se contente de le
lancer comme exécutable séparé : de la simple agrégation, qui ne change pas la
licence de Latch. En revanche chaque release publie, à côté du `.dmg`, les
sources exactes de mosh, le script qui l'a compilé
([`Scripts/build-mosh-client.sh`](Scripts/build-mosh-client.sh)) et leurs
sommes de contrôle. C'est ce que la GPLv3 exige, et c'est aussi ce qui ferme
définitivement la porte du Mac App Store — le `.dmg` notarisé reste le seul
canal de distribution.

Pour une compilation locale, produisez-le une fois et posez-le dans `Vendor/` :

```bash
Scripts/build-mosh-client.sh Vendor arm64 x86_64
```

La compilation suivante l'embarquera et le signera toute seule. Sans lui, Latch
retombe sur le `mosh` du système s'il est installé, et le dit dans la barre
d'état ; sans mosh nulle part, le panneau d'amélioration propose
`brew install mosh` et le transport ssh reste disponible.

## Distribution

Les binaires publiés seront signés et notarisés, ce qui exige un compte
développeur Apple (99 €/an). Sans notarisation, macOS bloque le premier
lancement d'un `.app` téléchargé : voir
[Ouvrir une version non notarisée](#ouvrir-une-version-non-notarisée).

## Licence

MIT — voir [LICENSE](LICENSE).

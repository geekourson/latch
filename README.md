<h1 align="center">Latch</h1>
<p align="center"><em>Your sessions, still running.</em></p>

Latch est un gestionnaire de sessions distantes pour macOS. Un clic sur une
session ouvre un terminal attaché à une session `tmux` sur un serveur, quel que
soit l'état de la connexion précédente. Vous fermez le Mac, vous le rouvrez le
lendemain, la session est là où vous l'aviez laissée.

<!-- La capture d'écran de la SPEC §13 attend l'autorisation « Enregistrement
     de l'écran » sur la machine de développement : ![Latch](docs/screenshot.png) -->

## État

**v0.1** — une fenêtre, un terminal, une commande codée en dur. C'est la
première marche de la [feuille de route](SPEC.md#12-feuille-de-route) : le
pseudo-terminal, le rendu et le redimensionnement fonctionnent, le reste
(raccourcis, barre latérale, onglets, `CommandBuilder`) arrive en v0.2.

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
  `ssh: connect to host 192.168.1.37 port 22: No route to host`. macOS propose
  la demande au premier lancement ; si elle a été refusée, il faut la
  réactiver à la main.
- **Signature**. Latch est signée localement pendant le développement. Un `.app`
  téléchargé et non notarisé demande un clic droit → **Ouvrir** au premier
  lancement.

## Configuration de la v0.1

La commande lancée au démarrage est codée en dur dans
`Sources/Latch/UI/ContentView.swift` :

```swift
ssh -t billy "tmux new -A -s api"
```

`billy` est un alias de `~/.ssh/config`. Adaptez-le, ou ajoutez l'entrée
correspondante :

```
Host billy
    HostName 192.168.1.37
    User billy
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
2. utiliser le nom mDNS de la machine, `billy.local`, valable sur le réseau
   local ;
3. installer [Tailscale](https://tailscale.com), qui donne un nom stable et
   fonctionne aussi hors du réseau local.

## Architecture

Quatre couches, strictement séparées — aucune ne connaît celle du dessus :

| Couche | Rôle | État |
|---|---|---|
| `SessionStore` | état, persistance JSON, trousseau | v0.2 |
| `CommandBuilder` | modèle → chaîne de commande | v0.2 |
| `ConnectionDriver` | lance un binaire dans un PTY | v0.3 |
| `PTYProcess` | `forkpty(3)`, octets, `SIGWINCH`, fin de vie | ✅ |
| `TerminalPane` | SwiftTerm branché sur le flux | ✅ |

## Dépendances

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0 (MIT) — le seul
  émulateur de terminal embarqué. Il tire lui-même `swift-argument-parser`.

Le binaire `mosh-client` sera embarqué dans le bundle en v0.3, pour ne pas
exiger Homebrew de l'utilisateur ; sa version exacte sera notée ici, mosh étant
sensible aux écarts entre client et serveur.

## Distribution

Les binaires publiés seront signés et notarisés, ce qui exige un compte
développeur Apple (99 €/an). Sans notarisation, le premier lancement d'un `.app`
téléchargé demande un clic droit → **Ouvrir** au lieu d'un double-clic.

## Licence

MIT — voir [LICENSE](LICENSE).

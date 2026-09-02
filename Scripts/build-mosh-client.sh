#!/bin/bash
#
# build-mosh-client.sh — compile le `mosh-client` embarqué dans Latch (SPEC §7).
#
# Objectif : un binaire autonome, sans dépendance hors du système, pour que
# l'utilisateur de Latch n'ait pas à installer Homebrew.
#
# mosh est sous GPL-3.0-or-later. Latch, sous MIT, se contente de le lancer
# comme exécutable séparé — de la simple agrégation, qui ne contamine pas Latch.
# En revanche, **le .dmg distribué doit accompagner ce binaire de ses sources**.
# Ce script écrit donc à côté du binaire l'archive source exacte et sa somme de
# contrôle, que la CI attache à la release.
#
# Usage :
#   Scripts/build-mosh-client.sh <répertoire-de-sortie> [arch…]
#
# Exemple :
#   Scripts/build-mosh-client.sh build/mosh arm64 x86_64
#
set -euo pipefail

OUTPUT_DIR="${1:?usage: build-mosh-client.sh <répertoire-de-sortie> [arch…]}"
shift || true
ARCHS=("$@")
[ ${#ARCHS[@]} -eq 0 ] && ARCHS=("$(uname -m)")

# Versions figées : mosh est sensible aux écarts entre client et serveur, et
# une compilation reproductible vaut mieux qu'une compilation récente.
MOSH_VERSION="1.4.0"
MOSH_SHA256="872e4b134e5df29c8933dff12350785054d2fd2839b5ae6b5587b14db1465ddd"
# protobuf 21.12 est la dernière version antérieure à la dépendance abseil :
# elle se compile en statique avec autotools, sans traîner une seconde
# bibliothèque C++ derrière elle.
# Le tag est « v21.12 » mais l'archive C++ garde la numérotation 3.x.
PROTOBUF_TAG="21.12"
PROTOBUF_VERSION="3.21.12"
PROTOBUF_SHA256="4eab9b524aa5913c6fffb20b2a8abf5ef7f95a80bc0701f3a6dbb4c607f73460"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/latch-mosh.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# macOS 14 est la cible de Latch ; le binaire embarqué doit s'y exécuter.
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export MACOSX_DEPLOYMENT_TARGET

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

fetch() {
  local url="$1" file="$2" sha="$3"
  log "Téléchargement de $(basename "$file")"
  curl -fsSL "$url" -o "$file"
  echo "$sha  $file" | shasum -a 256 -c - >/dev/null \
    || { echo "somme de contrôle invalide pour $file" >&2; exit 1; }
}

# OpenSSL fournit l'AES de mosh. On prend la version statique de Homebrew si
# elle est là : la libcrypto du système n'a pas d'en-têtes publics.
find_openssl() {
  for prefix in /opt/homebrew/opt/openssl@3 /usr/local/opt/openssl@3; do
    [ -f "$prefix/lib/libcrypto.a" ] && { echo "$prefix"; return; }
  done
  echo "OpenSSL introuvable — « brew install openssl@3 »" >&2
  exit 1
}

OPENSSL_PREFIX="$(find_openssl)"
log "OpenSSL : $OPENSSL_PREFIX"

fetch "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_TAG}/protobuf-cpp-${PROTOBUF_VERSION}.tar.gz" \
      "$WORK_DIR/protobuf.tar.gz" "$PROTOBUF_SHA256"
fetch "https://github.com/mobile-shell/mosh/releases/download/mosh-${MOSH_VERSION}/mosh-${MOSH_VERSION}.tar.gz" \
      "$WORK_DIR/mosh.tar.gz" "$MOSH_SHA256"

# La source exacte part avec la release : c'est l'obligation GPLv3.
cp "$WORK_DIR/mosh.tar.gz" "$OUTPUT_DIR/mosh-${MOSH_VERSION}.tar.gz"
cp "$0" "$OUTPUT_DIR/build-mosh-client.sh"
shasum -a 256 "$OUTPUT_DIR/mosh-${MOSH_VERSION}.tar.gz" > "$OUTPUT_DIR/SHA256SUMS"

JOBS="$(sysctl -n hw.ncpu)"
HOST_ARCH="$(uname -m)"

# protobuf sert deux fois : ses bibliothèques statiques, propres à chaque
# architecture, et son compilateur `protoc`, qui doit tourner **ici**. Une
# tranche x86_64 compilée sur un Mac Apple Silicon produirait un protoc
# inexécutable — on compile donc d'abord une version native, une seule fois.
HOST_PREFIX="$WORK_DIR/host/prefix"

build_protobuf() {
  local arch="$1" prefix="$2" dir="$3" protoc="${4:-}"
  mkdir -p "$dir" "$prefix"
  tar xzf "$WORK_DIR/protobuf.tar.gz" -C "$dir"
  (
    cd "$dir/protobuf-${PROTOBUF_VERSION}"
    local args=(--prefix="$prefix" --disable-shared --enable-static
                --with-pic --disable-dependency-tracking)
    [ -n "$protoc" ] && args+=(--with-protoc="$protoc")
    CFLAGS="-arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    CXXFLAGS="-arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    LDFLAGS="-arch $arch" \
    ./configure "${args[@]}" >/dev/null
    make -j"$JOBS" >/dev/null
    make install >/dev/null
  )
}

log "Compilation de protobuf pour l'hôte ($HOST_ARCH)"
build_protobuf "$HOST_ARCH" "$HOST_PREFIX" "$WORK_DIR/host"

BUILT_SLICES=()

for arch in "${ARCHS[@]}"; do
  log "Compilation pour $arch"
  ARCH_DIR="$WORK_DIR/$arch"
  mkdir -p "$ARCH_DIR"

  if [ "$arch" = "$HOST_ARCH" ]; then
    PREFIX="$HOST_PREFIX"
  else
    PREFIX="$ARCH_DIR/prefix"
    build_protobuf "$arch" "$PREFIX" "$ARCH_DIR" "$HOST_PREFIX/bin/protoc"
  fi

  # --- mosh ------------------------------------------------------------------
  tar xzf "$WORK_DIR/mosh.tar.gz" -C "$ARCH_DIR"
  (
    cd "$ARCH_DIR/mosh-${MOSH_VERSION}"
    # mosh trouve protobuf par pkg-config, et `protoc` par le PATH — celui de
    # l'hôte, le seul qui puisse s'exécuter.
    PATH="$HOST_PREFIX/bin:$PATH" \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$OPENSSL_PREFIX/lib/pkgconfig" \
    CFLAGS="-arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    CXXFLAGS="-arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    ./configure --prefix="$ARCH_DIR/install" \
                --disable-dependency-tracking \
                --without-utempter \
                CPPFLAGS="-I$OPENSSL_PREFIX/include" \
                LDFLAGS="-arch $arch -L$OPENSSL_PREFIX/lib" >/dev/null
    # Compilation complète : `mosh-client` dépend d'en-têtes générés — les
    # protobufs et `version.h` — que seule la cible racine produit. On ne garde
    # ensuite que le client ; mosh-server tourne sur le serveur, pas ici.
    PATH="$HOST_PREFIX/bin:$PATH" make -j"$JOBS" >/dev/null
  )

  SLICE="$ARCH_DIR/mosh-client"
  cp "$ARCH_DIR/mosh-${MOSH_VERSION}/src/frontend/mosh-client" "$SLICE"
  BUILT_SLICES+=("$SLICE")
done

log "Assemblage"
if [ ${#BUILT_SLICES[@]} -gt 1 ]; then
  lipo -create "${BUILT_SLICES[@]}" -output "$OUTPUT_DIR/mosh-client"
else
  cp "${BUILT_SLICES[0]}" "$OUTPUT_DIR/mosh-client"
fi
chmod 755 "$OUTPUT_DIR/mosh-client"

log "Vérification des dépendances dynamiques"
# Un binaire embarqué ne doit dépendre que de bibliothèques du système : tout
# ce qui pointe vers /opt/homebrew ou /usr/local casserait chez l'utilisateur.
if otool -L "$OUTPUT_DIR/mosh-client" | grep -qE '/opt/homebrew|/usr/local'; then
  otool -L "$OUTPUT_DIR/mosh-client" >&2
  echo "le binaire dépend de bibliothèques non systèmes" >&2
  exit 1
fi

otool -L "$OUTPUT_DIR/mosh-client"
lipo -info "$OUTPUT_DIR/mosh-client"
log "mosh-client prêt : $OUTPUT_DIR/mosh-client"
log "Sources GPL à publier avec la release : $OUTPUT_DIR/mosh-${MOSH_VERSION}.tar.gz"

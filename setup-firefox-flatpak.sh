#!/usr/bin/env bash
#
# setup-firefox-flatpak.sh
#
# 1. Elimina el Firefox instalado por snap
# 2. Instala Flatpak + soporte GNOME Software + remoto Flathub
# 3. Instala Firefox (org.mozilla.firefox) desde Flathub
# 4. Fuerza la instalación de uBlock Origin y DocsAfterDark vía políticas
#
# Idempotente. Ubuntu 22.04 / 24.04.
# Uso: ./setup-firefox-flatpak.sh   (usa sudo internamente)
#
set -euo pipefail

readonly FLATHUB_REPO="https://dl.flathub.org/repo/flathub.flatpakrepo"
readonly FIREFOX_APP_ID="org.mozilla.firefox"

# "id_gecko|slug_amo|nombre"
# El ID gecko es la clave que Firefox exige en ExtensionSettings.
readonly FIREFOX_EXTENSIONS=(
  "uBlock0@raymondhill.net|ublock-origin|uBlock Origin"
  "{e8ffc3db-2875-4c7f-af38-d03e7f7f8ab9}|docsafterdark|DocsAfterDark"
)

# ------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------
info()  { printf '\e[1;34m[INFO]\e[0m %s\n' "$*"; }
ok()    { printf '\e[1;32m[ OK ]\e[0m %s\n' "$*"; }
warn()  { printf '\e[1;33m[WARN]\e[0m %s\n' "$*" >&2; }
error() { printf '\e[1;31m[ERROR]\e[0m %s\n' "$*" >&2; }

trap 'error "Fallo en la línea $LINENO"; exit 1' ERR

# ------------------------------------------------------------------
# Paso 1: eliminar Firefox snap
# ------------------------------------------------------------------
remove_snap_firefox() {
  printf '\e[1;35m==> ELIMINACIÓN DE FIREFOX INSTALADO ACTUALMENTE (snap)\e[0m\n'

  if ! command -v snap >/dev/null 2>&1; then
    ok "snap no está presente; nada que eliminar."
    return 0
  fi

  if ! snap list firefox >/dev/null 2>&1; then
    ok "Firefox snap no está instalado."
    return 0
  fi

  info "Desinstalando Firefox (snap)..."
  sudo snap remove firefox
  ok "Firefox snap eliminado."
}

# ------------------------------------------------------------------
# Paso 2: Flatpak + Flathub
# ------------------------------------------------------------------
install_flatpak_support() {
  info "Verificando Flatpak..."
  local missing=()
  local pkg
  for pkg in flatpak gnome-software-plugin-flatpak; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "Flatpak y gnome-software-plugin-flatpak ya instalados."
    return 0
  fi

  sudo apt update -y
  sudo apt install -y "${missing[@]}"
  ok "Instalados: ${missing[*]}"
}

add_flathub_remote() {
  info "Verificando remoto Flathub..."
  if flatpak remote-list --system 2>/dev/null | grep -q '^flathub'; then
    ok "Flathub ya configurado."
    return 0
  fi
  sudo flatpak remote-add --if-not-exists flathub "$FLATHUB_REPO"
  ok "Flathub agregado."
}

# ------------------------------------------------------------------
# Paso 3: Firefox flatpak
# ------------------------------------------------------------------
install_firefox_flatpak() {
  info "Verificando Firefox (Flatpak)..."
  if flatpak list --system --app --columns=application 2>/dev/null | grep -qx "$FIREFOX_APP_ID"; then
    ok "$FIREFOX_APP_ID ya instalado."
    return 0
  fi
  sudo flatpak install -y --system flathub "$FIREFOX_APP_ID"
  ok "$FIREFOX_APP_ID instalado."
}

# ------------------------------------------------------------------
# Paso 4: extensiones forzadas vía policies.json
# Ruta leída por Firefox Flatpak (punto de extensión systemconfig):
#   /var/lib/flatpak/extension/org.mozilla.firefox.systemconfig/<arch>/stable/policies/policies.json
# ------------------------------------------------------------------
build_policies_json() {
  local entries="" id slug name entry first=1
  for entry in "${FIREFOX_EXTENSIONS[@]}"; do
    IFS='|' read -r id slug name <<<"$entry"
    [[ $first -eq 0 ]] && entries+=$',\n'
    first=0
    entries+="      \"${id}\": {
        \"installation_mode\": \"force_installed\",
        \"install_url\": \"https://addons.mozilla.org/firefox/downloads/latest/${slug}/latest.xpi\"
      }"
  done

  cat <<EOF
{
  "policies": {
    "ExtensionSettings": {
${entries}
    }
  }
}
EOF
}

configure_firefox_extensions() {
  info "Configurando extensiones de Firefox..."

  local arch dir file tmp
  arch=$(flatpak --default-arch)
  dir="/var/lib/flatpak/extension/org.mozilla.firefox.systemconfig/${arch}/stable/policies"
  file="${dir}/policies.json"

  tmp=$(mktemp)
  build_policies_json > "$tmp"

  if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
    ok "policies.json ya está actualizado."
    return 0
  fi

  sudo mkdir -p "$dir"
  sudo install -m 644 "$tmp" "$file"
  rm -f "$tmp"
  ok "policies.json escrito en $file"
}

# ------------------------------------------------------------------
main() {
  remove_snap_firefox
  install_flatpak_support
  add_flathub_remote
  install_firefox_flatpak
  configure_firefox_extensions

  echo
  ok "Listo. Abre Firefox y revisa about:policies y about:addons."
}

main "$@"

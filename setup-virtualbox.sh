#!/usr/bin/env bash
#
# setup-virtualbox.sh
#
# Instala VirtualBox en Ubuntu con sus dependencias (dkms, headers, build-essential),
# el Extension Pack (USB 2.0/3.0) y agrega el usuario al grupo vboxusers
# para que VirtualBox pueda leer dispositivos USB.
#
# Idempotente. Ubuntu 22.04 / 24.04.
# Uso: ./setup-virtualbox.sh   (usa sudo internamente)
#
set -euo pipefail

readonly VBOX_GROUP="vboxusers"
readonly BASE_PKGS=(build-essential dkms)
readonly VBOX_PKGS=(virtualbox virtualbox-qt virtualbox-guest-additions-iso)
readonly EXT_PACK_PKG="virtualbox-ext-pack"

# ------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------
info()  { printf '\e[1;34m[INFO]\e[0m %s\n' "$*"; }
ok()    { printf '\e[1;32m[ OK ]\e[0m %s\n' "$*"; }
warn()  { printf '\e[1;33m[WARN]\e[0m %s\n' "$*" >&2; }
error() { printf '\e[1;31m[ERROR]\e[0m %s\n' "$*" >&2; }

trap 'error "Fallo en la línea $LINENO"; exit 1' ERR

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
target_user() {
  # Usuario real aunque el script se ejecute con sudo
  echo "${SUDO_USER:-$USER}"
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# Instala solo los paquetes que faltan
apt_install_missing() {
  local missing=() pkg
  for pkg in "$@"; do
    pkg_installed "$pkg" || missing+=("$pkg")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "Ya instalados: $*"
    return 0
  fi

  info "Instalando: ${missing[*]}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  ok "Instalados: ${missing[*]}"
}

# ------------------------------------------------------------------
# Pasos
# ------------------------------------------------------------------
check_not_root() {
  if [[ $EUID -eq 0 && -z "${SUDO_USER:-}" ]]; then
    error "No lo ejecutes como root directo; usa tu usuario (o sudo) para que el grupo se asigne bien."
    exit 1
  fi
}

enable_multiverse() {
  info "Verificando repositorio multiverse (necesario para el Extension Pack)..."
  if grep -rqsE '^\s*(deb|Components:).*\bmultiverse\b' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    ok "multiverse ya habilitado."
    return 0
  fi

  sudo add-apt-repository -y multiverse
  sudo apt-get update -y
  ok "multiverse habilitado."
}

install_dependencies() {
  info "Instalando dependencias de compilación de módulos..."
  sudo apt-get update -y
  apt_install_missing "${BASE_PKGS[@]}" "linux-headers-$(uname -r)"
}

install_virtualbox() {
  info "Instalando VirtualBox..."
  apt_install_missing "${VBOX_PKGS[@]}"
}

install_extension_pack() {
  info "Verificando Extension Pack (USB 2.0/3.0)..."
  if pkg_installed "$EXT_PACK_PKG"; then
    ok "$EXT_PACK_PKG ya instalado."
    return 0
  fi

  # Preaceptar la licencia PUEL para evitar el diálogo interactivo
  echo "$EXT_PACK_PKG $EXT_PACK_PKG/license select true" | sudo debconf-set-selections
  apt_install_missing "$EXT_PACK_PKG"
}

ensure_kernel_module() {
  info "Verificando módulo del kernel vboxdrv..."
  if lsmod | grep -q '^vboxdrv'; then
    ok "vboxdrv cargado."
    return 0
  fi

  if sudo modprobe vboxdrv 2>/dev/null; then
    ok "vboxdrv cargado."
  else
    warn "No se pudo cargar vboxdrv."
    if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
      warn "Secure Boot está activo: el módulo debe firmarse (MOK) o desactivar Secure Boot."
    fi
    warn "Revisa: sudo dkms status  y  sudo journalctl -xe"
  fi
}

add_user_to_vboxusers() {
  local user
  user=$(target_user)
  info "Verificando que '$user' pertenezca a '$VBOX_GROUP' (acceso USB)..."

  if ! getent group "$VBOX_GROUP" >/dev/null; then
    sudo groupadd "$VBOX_GROUP"
  fi

  if id -nG "$user" | tr ' ' '\n' | grep -qx "$VBOX_GROUP"; then
    ok "'$user' ya está en $VBOX_GROUP."
    return 0
  fi

  sudo usermod -aG "$VBOX_GROUP" "$user"
  ok "'$user' agregado a $VBOX_GROUP."
  NEEDS_RELOGIN=1
}

# ------------------------------------------------------------------
main() {
  NEEDS_RELOGIN=0

  check_not_root
  enable_multiverse
  install_dependencies
  install_virtualbox
  install_extension_pack
  ensure_kernel_module
  add_user_to_vboxusers

  echo
  ok "VirtualBox listo: $(vboxmanage --version 2>/dev/null || echo 'versión no disponible')"
  if [[ $NEEDS_RELOGIN -eq 1 ]]; then
    warn "Cierra sesión y vuelve a entrar (o reinicia) para que el grupo $VBOX_GROUP tenga efecto."
  fi
}

main "$@"

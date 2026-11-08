#!/usr/bin/env bash
#
# setup-gns3.sh
#
# Instala GNS3 (gns3-gui + gns3-server) desde el PPA oficial en Ubuntu.
# Preconfigura los diálogos de debconf (ubridge y wireshark) para que no sea
# interactivo y agrega el usuario a los grupos necesarios.
#
# Idempotente. Uso: ./setup-gns3.sh   (usa sudo internamente)
#
set -euo pipefail

readonly PPA_NAME="ppa:gns3/ppa"
readonly PPA_MATCH="gns3/ppa"
readonly GNS3_PKGS=(gns3-gui gns3-server)
readonly PREREQ_PKGS=(software-properties-common)
# Grupos útiles para GNS3; solo se agregan los que existan en el sistema
readonly USER_GROUPS=(ubridge libvirt kvm wireshark docker)

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
  echo "${SUDO_USER:-$USER}"
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

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
    error "No lo ejecutes como root directo; usa tu usuario (o sudo)."
    exit 1
  fi
}

install_prerequisites() {
  info "Verificando prerrequisitos..."
  apt_install_missing "${PREREQ_PKGS[@]}"
}

add_gns3_ppa() {
  info "Verificando PPA de GNS3..."
  if grep -rqs "$PPA_MATCH" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    ok "PPA $PPA_NAME ya configurado."
    return 1   # señal: no hay que forzar apt update por el PPA
  fi

  sudo add-apt-repository -y "$PPA_NAME"
  ok "PPA $PPA_NAME agregado."
  return 0
}

preseed_debconf() {
  info "Preconfigurando debconf (ubridge / wireshark)..."
  # Permite captura de paquetes sin root y setuid de ubridge sin diálogos
  {
    echo "ubridge ubridge/install-setuid boolean true"
    echo "wireshark-common wireshark-common/install-setuid boolean true"
  } | sudo debconf-set-selections
  ok "debconf preconfigurado."
}

install_gns3() {
  info "Instalando GNS3..."
  apt_install_missing "${GNS3_PKGS[@]}"
}

add_user_to_groups() {
  local user group added=()
  user=$(target_user)
  info "Verificando grupos de '$user' para GNS3..."

  for group in "${USER_GROUPS[@]}"; do
    getent group "$group" >/dev/null || continue
    if id -nG "$user" | tr ' ' '\n' | grep -qx "$group"; then
      continue
    fi
    sudo usermod -aG "$group" "$user"
    added+=("$group")
  done

  if [[ ${#added[@]} -eq 0 ]]; then
    ok "'$user' ya pertenece a todos los grupos aplicables."
  else
    ok "'$user' agregado a: ${added[*]}"
    NEEDS_RELOGIN=1
  fi
}

# ------------------------------------------------------------------
main() {
  NEEDS_RELOGIN=0

  check_not_root
  install_prerequisites

  if add_gns3_ppa; then
    sudo apt-get update -y
  elif ! pkg_installed gns3-gui; then
    # PPA ya existía pero GNS3 aún no está: asegurar índices al día
    sudo apt-get update -y
  fi

  preseed_debconf
  install_gns3
  add_user_to_groups

  echo
  ok "GNS3 listo: $(gns3 --version 2>/dev/null || dpkg-query -W -f='${Version}' gns3-gui)"
  if [[ $NEEDS_RELOGIN -eq 1 ]]; then
    warn "Cierra sesión y vuelve a entrar (o reinicia) para aplicar los nuevos grupos."
  fi
}

main "$@"

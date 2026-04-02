#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Этот скрипт нужно запускать от root."
  echo "Пример: sudo bash install.sh"
  exit 1
fi

echo "=== Обновление системы ==="
apt update && apt upgrade -y

echo "=== Установка и настройка UFW ==="
apt install -y ufw

ufw allow OpenSSH

echo
echo "Укажи дополнительные порты, которые нужно открыть."
echo "Примеры:"
echo "  80"
echo "  80,443"
echo "  51820/udp"
echo "  10000:20000/udp"
echo "Если ничего не нужно — просто нажми Enter."
read -r -p "Дополнительные порты: " EXTRA_PORTS

if [[ -n "${EXTRA_PORTS// }" ]]; then
  IFS=',' read -ra PORT_ITEMS <<< "$EXTRA_PORTS"
  for item in "${PORT_ITEMS[@]}"; do
    port_rule="$(echo "$item" | xargs)"
    if [[ -n "$port_rule" ]]; then
      echo "Открываю: $port_rule"
      ufw allow "$port_rule"
    fi
  done
fi

ufw --force enable

echo "=== Установка и запуск fail2ban ==="
apt install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban

echo "=== Установка ca-certificates ==="
apt-get install -yqq --no-install-recommends ca-certificates

echo "=== Настройка sysctl ==="

add_sysctl_if_missing() {
  local line="$1"
  if ! grep -qxF "$line" /etc/sysctl.conf; then
    echo "$line" | tee -a /etc/sysctl.conf > /dev/null
  else
    echo "Уже есть: $line"
  fi
}

add_sysctl_if_missing "net.core.default_qdisc=fq"
add_sysctl_if_missing "net.ipv4.tcp_congestion_control=bbr"
add_sysctl_if_missing "fs.file-max=2097152"
add_sysctl_if_missing "net.ipv4.tcp_timestamps=1"
add_sysctl_if_missing "net.ipv4.tcp_sack=1"
add_sysctl_if_missing "net.ipv4.tcp_window_scaling=1"
add_sysctl_if_missing "net.core.rmem_max=16777216"
add_sysctl_if_missing "net.core.wmem_max=16777216"
add_sysctl_if_missing "net.ipv4.tcp_rmem=4096 87380 16777216"
add_sysctl_if_missing "net.ipv4.tcp_wmem=4096 65536 16777216"
add_sysctl_if_missing "net.ipv4.icmp_echo_ignore_all=1"

sysctl -p

echo
echo "=== Настройка завершена ==="
ufw status verbose
systemctl status fail2ban --no-pager || true

echo
echo "⚠️ Сервер будет перезагружен через 10 секунд"
echo "Нажми Ctrl+C, чтобы отменить"

sleep 10

reboot
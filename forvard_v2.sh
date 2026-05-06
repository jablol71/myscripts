#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------------------------------
# Interactive TCP port forward + firewall lock-down (Multi-target)
# ------------------------------------------------------------

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Ошибка: запускай скрипт от root."
    exit 1
  fi
}

validate_ip() {
  local ip="$1"
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then return 1; fi
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    if (( octet < 0 || octet > 255 )); then return 1; fi
  done
  return 0
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

disable_ufw_if_present() {
  if command -v ufw >/dev/null 2>&1; then
    echo "[+] Отключаю UFW..."
    ufw --force disable >/dev/null 2>&1 || true
    systemctl disable ufw >/dev/null 2>&1 || true
    systemctl stop ufw >/dev/null 2>&1 || true
  fi
}

enable_ip_forwarding() {
  echo "[+] Включаю net.ipv4.ip_forward..."
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ip-forward.conf
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

install_persistence() {
  echo "[+] Установка iptables-persistent..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y iptables-persistent >/dev/null
}

save_rules() {
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
}

main() {
  require_root

  local ssh_port=""
  local -a config_list=() # Формат: "src_port|dst_ip|dst_port"

  echo "=== Настройка гибкого TCP Forwarding ==="
  echo

  # 1. Спрашиваем SSH порт сразу
  while true; do
    read -r -p "Какой порт используется для SSH? " ssh_port
    validate_port "$ssh_port" && break
    echo "Неверный порт. Попробуй ещё раз."
  done

  # 2. Цикл сбора конфигураций портов
  while true; do
    local src_p="" dst_ip="" dst_p=""

    echo "--- Настройка правила ---"
    while true; do
      read -r -p "Какой ВХОДЯЩИЙ порт настраиваем? " src_p
      validate_port "$src_p" && break
      echo "Ошибка в порте."
    done

    while true; do
      read -r -p "На какой IP форвардим трафик для порта $src_p? " dst_ip
      validate_ip "$dst_ip" && break
      echo "Неверный IP."
    done

    while true; do
      read -r -p "На какой ПОРТ на $dst_ip форвардим? " dst_p
      validate_port "$dst_p" && break
      echo "Ошибка в порте."
    done

    config_list+=("${src_p}|${dst_ip}|${dst_p}")

    read -r -p "Настроить еще один порт? (y/N): " choice
    [[ "$choice" =~ ^[Yy]$ ]] || break
    echo
  done

  # Применяем настройки
  disable_ufw_if_present
  enable_ip_forwarding

  echo "[+] Очистка правил iptables..."
  iptables -F
  iptables -t nat -F
  iptables -X
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT

  echo "[+] Применяю правила форвардинга:"
  for item in "${config_list[@]}"; do
    IFS='|' read -r s_port d_ip d_port <<< "$item"
    echo "    TCP/$s_port -> $d_ip:$d_port"

    # DNAT
    iptables -t nat -A PREROUTING -p tcp --dport "$s_port" -j DNAT --to-destination "$d_ip:$d_port"
    
    # FORWARD
    iptables -A FORWARD -p tcp -d "$d_ip" --dport "$d_port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
    
    # MASQUERADE
    iptables -t nat -A POSTROUTING -p tcp -d "$d_ip" --dport "$d_port" -j MASQUERADE
    
    # Открываем входящий на всякий случай
    iptables -A INPUT -p tcp --dport "$s_port" -j ACCEPT
  done

  install_persistence
  save_rules

  echo
  echo "[OK] Конфигурация завершена."
  echo "[OK] SSH открыт на порту: $ssh_port"
  echo "[OK] Все остальные порты, кроме указанных в форвардинге, закрыты."
}

main "$@"

#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------------------------------
# Interactive TCP port forward + firewall lock-down
# Debian/Ubuntu + iptables
#
# One-line запуск, например:
# bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/setup_forward.sh)
#
# Что делает:
# 1. спрашивает IP назначения
# 2. спрашивает порты для форварда (Enter = 80,443)
# 3. спрашивает SSH порт
# 4. разрешает только SSH + выбранные входящие порты
# 5. форвардит выбранные TCP порты на указанный backend IP
# 6. запрещает всё остальное
# ------------------------------------------------------------

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Ошибка: запускай скрипт от root."
    echo "Пример:"
    echo "sudo bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/setup_forward.sh)"
    exit 1
  fi
}

validate_ip() {
  local ip="$1"
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi

  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    if (( octet < 0 || octet > 255 )); then
      return 1
    fi
  done
  return 0
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

parse_ports() {
  local raw="$1"
  local -n out_arr_ref=$2
  out_arr_ref=()

  raw="${raw// /}"
  IFS=',' read -r -a tmp <<< "$raw"

  for p in "${tmp[@]}"; do
    [[ -n "$p" ]] || continue
    validate_port "$p" || return 1

    local exists=0
    for ep in "${out_arr_ref[@]:-}"; do
      if [[ "$ep" == "$p" ]]; then
        exists=1
        break
      fi
    done
    (( exists == 0 )) && out_arr_ref+=("$p")
  done

  [[ "${#out_arr_ref[@]}" -gt 0 ]]
}

disable_ufw_if_present() {
  if command -v ufw >/dev/null 2>&1; then
    echo "[+] Отключаю UFW"
    ufw --force disable || true
    systemctl disable ufw >/dev/null 2>&1 || true
    systemctl stop ufw >/dev/null 2>&1 || true
  fi
}

enable_ip_forwarding() {
  echo "[+] Включаю net.ipv4.ip_forward"
  cat >/etc/sysctl.d/99-ip-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl --system >/dev/null 2>&1 || true
}

install_persistence() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y iptables-persistent >/dev/null
}

save_rules() {
  mkdir -p /etc/iptables
  iptables-save >/etc/iptables/rules.v4
}

main() {
  require_root

  local backend_ip=""
  local ssh_port=""
  local forward_ports_input=""
  local -a forward_ports=()

  echo "=== Настройка TCP forwarding + firewall ==="
  echo

  while true; do
    read -r -p "На какой IP делать перенаправление? " backend_ip
    if validate_ip "$backend_ip"; then
      break
    fi
    echo "Неверный IPv4 адрес. Попробуй ещё раз."
  done

  echo
  read -r -p "Какие порты форвардить? (через запятую, Enter = 80,443): " forward_ports_input
  if [[ -z "${forward_ports_input// }" ]]; then
    forward_ports=("80" "443")
  else
    if ! parse_ports "$forward_ports_input" forward_ports; then
      echo "Ошибка: список портов некорректный."
      exit 1
    fi
  fi

  echo
  while true; do
    read -r -p "Какой порт используется для SSH? " ssh_port
    if validate_port "$ssh_port"; then
      break
    fi
    echo "Неверный SSH порт. Попробуй ещё раз."
  done

  echo
  echo "[+] Итоговая конфигурация:"
  echo "    Backend IP: $backend_ip"
  echo "    SSH порт:   $ssh_port"
  echo "    Форвард:    ${forward_ports[*]}"
  echo

  disable_ufw_if_present
  enable_ip_forwarding

  echo "[+] Очищаю старые правила iptables"
  iptables -F
  iptables -t nat -F
  iptables -X

  echo "[+] Ставлю политики по умолчанию"
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  echo "[+] Разрешаю loopback"
  iptables -A INPUT -i lo -j ACCEPT

  echo "[+] Разрешаю ESTABLISHED,RELATED"
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  echo "[+] Разрешаю SSH на TCP/$ssh_port"
  iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT

  for port in "${forward_ports[@]}"; do
    echo "[+] Форвард TCP/$port -> $backend_ip:$port"

    # Входящий трафик на VDS перенаправляем на backend
    iptables -t nat -A PREROUTING -p tcp --dport "$port" \
      -j DNAT --to-destination "$backend_ip:$port"

    # Разрешаем форвард до backend
    iptables -A FORWARD -p tcp -d "$backend_ip" --dport "$port" \
      -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT

    # Маскарадинг, чтобы ответы шли обратно через VDS
    iptables -t nat -A POSTROUTING -p tcp -d "$backend_ip" --dport "$port" \
      -j MASQUERADE

    # Разрешаем сам вход на эти порты на внешнем интерфейсе
    # (не обязательно строго для DNAT, но удобно и явно)
    iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
  done

  echo "[+] Устанавливаю сохранение правил"
  install_persistence
  save_rules

  echo
  echo "[OK] Готово."
  echo "[OK] Разрешены только:"
  echo "     - SSH: TCP/$ssh_port"
  for port in "${forward_ports[@]}"; do
    echo "     - Forward: TCP/$port -> $backend_ip:$port"
  done
  echo "[OK] Все остальные входящие порты запрещены."
  echo
  echo "[+] Текущие правила FILTER:"
  iptables -S
  echo
  echo "[+] Текущие правила NAT:"
  iptables -t nat -S
}

main "$@"
#!/bin/bash

LOG_DIR="/var/www"
LIST_FILE="$LOG_DIR/list.json"
LIST_TXT_FILE="$LOG_DIR/list.txt"

show_usage() {
    echo "Использование: $0 <IP-сеть1> [<IP-сеть2> ...]"
    echo ""
    echo "Примеры:"
    echo "  $0 10.0.0.0/24"
    echo "  $0 192.168.1.0/24 192.168.2.0/24"
    echo "  $0 10.0.0.0/24 172.16.0.0/16 192.168.0.0/24"
    echo ""
    echo "Параметры:"
    echo "  <IP-сеть>  - IP адрес сети в формате CIDR (например, 192.168.1.0/24)"
    exit 1
}

validate_network() {
    local network="$1"

    if ! [[ "$network" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        echo "Ошибка: Неверный формат сети '$network'. Используйте формат CIDR: 192.168.1.0/24" >&2
        return 1
    fi

    return 0
}

setup_environment() {
    echo "Настройка окружения..." >&2
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"
}

check_dependencies() {
    local deps=("arp-scan" "jq")

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "Ошибка: $dep не установлен" >&2
            exit 1
        fi
    done
}

scan_network() {
    local network="$1"

    echo "Сканирование сети: $network" >&2

    local temp_file=$(mktemp)
    local scanned_successfully=false

    for interface in "wlan0" "eth0" "eth1" "wlan1"; do
        if ip link show "$interface" &>/dev/null; then
            echo "Пробуем интерфейс: $interface" >&2
            if timeout 60 arp-scan --interface="$interface" "$network" 2>/dev/null > "$temp_file"; then
                if grep -q -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\s+[0-9a-fA-F:]{17}' "$temp_file"; then
                    echo "Успешно просканировано через $interface" >&2
                    scanned_successfully=true
                    break
                fi
            fi
        fi
    done

    if [ "$scanned_successfully" = true ]; then
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\s+[0-9a-fA-F:]{17}' "$temp_file" | \
        while IFS= read -r line; do
            echo "$line"
        done
        rm -f "$temp_file"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

main() {
    local networks=("$@")

    echo "=== Запуск сканирования сетей: $(date) ===" >&2

    if [ ${#networks[@]} -eq 0 ]; then
        show_usage
    fi

    for network in "${networks[@]}"; do
        if ! validate_network "$network"; then
            exit 1
        fi
    done

    check_dependencies
    setup_environment

    local all_devices_file=$(mktemp)
    local total_devices_found=0

    for network in "${networks[@]}"; do
        echo "Сканируем сеть: $network" >&2
        local network_devices_file=$(mktemp)

        if scan_network "$network" > "$network_devices_file"; then
            local device_count=$(grep -c -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\s+[0-9a-fA-F:]{17}' "$network_devices_file" 2>/dev/null || echo 0)
            echo "Найдено устройств в сети $network: $device_count" >&2
            total_devices_found=$((total_devices_found + device_count))

            cat "$network_devices_file" >> "$all_devices_file"
        else
            echo "Не удалось просканировать сеть $network" >&2
        fi

        rm -f "$network_devices_file"
    done

    echo "Создание TXT файла..." >&2
    echo "# Сканирование от $(date)" > "$LIST_TXT_FILE"
    echo "# Сканируемые сети: ${networks[*]}" >> "$LIST_TXT_FILE"
    echo "# IP-адрес MAC-адрес Производитель" >> "$LIST_TXT_FILE"
    echo "==============================================" >> "$LIST_TXT_FILE"

    if [ -s "$all_devices_file" ]; then
        sort -u "$all_devices_file" >> "$LIST_TXT_FILE"
        echo "TXT файл создан: $LIST_TXT_FILE" >&2
    else
        echo "# Устройства не найдены" >> "$LIST_TXT_FILE"
        echo "Устройства не найдены" >&2
    fi

    chmod 644 "$LIST_TXT_FILE"

    echo "Создание JSON файла..." >&2

    local timestamp=$(date -Iseconds)
    local json_file=$(mktemp)

    cat > "$json_file" << EOF
{
  "scan_info": {
    "timestamp": "$timestamp",
    "total_devices": 0,
    "target_networks": [
EOF

    local first_network=true
    for network in "${networks[@]}"; do
        if [ "$first_network" = true ]; then
            first_network=false
        else
            echo "," >> "$json_file"
        fi
        echo "      \"$network\"" >> "$json_file"
    done

    cat >> "$json_file" << EOF
    ]
  },
  "devices": [
EOF

    local first_device=true
    local device_count=0

    if [ -s "$all_devices_file" ]; then
        while IFS= read -r line; do
            if [[ $line =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]+([0-9a-fA-F:]{17})[[:space:]]+(.*)$ ]]; then
                local ip="${BASH_REMATCH[1]}"
                local mac="${BASH_REMATCH[2]}"
                local vendor="${BASH_REMATCH[3]}"

                vendor=$(echo "$vendor" | sed 's/"/\\"/g')

                if [ "$first_device" = true ]; then
                    first_device=false
                else
                    echo "," >> "$json_file"
                fi

                cat >> "$json_file" << EOF
    {
      "IP": "$ip",
      "MAC": "$mac",
      "info": "$vendor"
    }
EOF
                device_count=$((device_count + 1))
            fi
        done < <(sort -u "$all_devices_file")
    fi

    cat >> "$json_file" << EOF
  ]
}
EOF

    sed -i "s/\"total_devices\": 0/\"total_devices\": $device_count/" "$json_file"

    if jq -e . >/dev/null 2>&1 < "$json_file"; then
        cp "$json_file" "$LIST_FILE"
        echo "JSON файл создан: $LIST_FILE" >&2
    else
        echo "Ошибка: не удалось создать валидный JSON" >&2
        jq -n \
            --arg timestamp "$timestamp" \
            --argjson networks "$(printf '%s\n' "${networks[@]}" | jq -R . | jq -s .)" \
            '{
                "scan_info": {
                    "timestamp": $timestamp,
                    "total_devices": 0,
                    "target_networks": $networks
                },
                "devices": []
            }' > "$LIST_FILE"
    fi

    chmod 644 "$LIST_FILE"

    rm -f "$all_devices_file" "$json_file"

    echo "=== Сканирование завершено: $(date) ===" >&2
    echo "Всего найдено устройств: $device_count" >&2
    echo "Сканируемые сети: ${networks[*]}" >&2
    echo "Результаты сохранены в:" >&2
    echo "  $LIST_FILE" >&2
    echo "  $LIST_TXT_FILE" >&2
}

cleanup() {
    rm -f /tmp/tmp.* 2>/dev/null
}

trap cleanup EXIT

if [ $# -eq 0 ]; then
    show_usage
else
    main "$@"
fi


# Отчёт по настройке, аудиту и восстановлению VPN-узлов (Сервер A и Сервер B)

## Часть 1. Сервер А — Поднятие узла с нуля

### Архитектура и протоколы
Входящий порт: Единый TCP 443 (без использования дополнительных внешних портов).
Основной профиль (Vision): VLESS + Reality + TCP Vision (xtls-rprx-vision) для максимальной скорости и минимальных накладных расходов.
Резервный профиль (XHTTP): VLESS + Reality + XHTTP (mode: "auto", path: /xhttp-stream) с перенаправлением через fallback на локальный Unix-сокет @xhttp-in внутри единого процесса Xray.

### Выбор и обоснование SNI (Dest-донора)
Выбранный домен: www.nvidia.com

Почему именно он:
1. Поддерживает TLS 1.3, HTTP/2 и современные наборы шифров.
2. В отличие от заезженных CDN-гигантов (Cloudflare, Google), домен NVIDIA не находится под проактивным блокированием или дросселированием ТСПУ в РФ.
3. Генерирует полностью естественный и нейтральный HTTPS-трафик.

Команда проверки донора:
openssl s_client -connect www.nvidia.com:443 -servername www.nvidia.com -tls1_3 </dev/null
Результат: Рукопожатие TLS 1.3 прошло моментально и без ошибок.

### Автоматизация установки
Написан и проверен идемпотентный скрипт install.sh со строгой обработкой ошибок (set -euo pipefail):
Автоматически устанавливает Xray-core.
Генерирует ключи x25519, UUID и ShortID.
Формирует корректный /usr/local/etc/xray/config.json.
Сохраняет параметры подключения в /etc/xray/access_info.txt.
Проверяет запуск службы через systemctl is-active.

---

## Часть 2. Сервер B (136.148.220.108) — Разбор проблем и восстановление

### Найдено и исправлено

Проблема 1: «Не подключается вообще»
Симптом: Клиенты отваливались при попытке соединения, TLS-рукопожатие сбрасывалось.
Как нашли: Изучили файл /root/HANDOVER.md. В исходной ссылке стояли sni=www.cloudflare.com и fp=randomized.
Причина: Домены Cloudflare заблокированы или жестко режутся ТСПУ в РФ. Параметр fp=randomized выдает случайные TLS ClientHello. Реальные браузеры так себя не ведут, поэтому DPI определяет такой трафик мгновенно.
Что исправили: В /usr/local/etc/xray/config.json сменили dest и serverNames на www.nvidia.com. В клиентской ссылке прописали sni=www.nvidia.com и зафиксировали реальный отпечаток fp=chrome.

Проблема 2: «Правил конфиг — ничего не менялось»
Симптом: Изменения в config.json не влияли на работу узла.
Как нашли: Проверили юниты через systemctl list-units | grep -i xray.
Причина: Предыдущий админ правил файл, но не перезапускал службу xray.service (либо допускал синтаксические ошибки в JSON, из-за чего сервис не мог перезапуститься).
Что исправили: Ввели регламент проверки синтаксиса перед рестартом:
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
systemctl restart xray

Проблема 3: Низкая скорость, фризы видео и лаги
Симптом: Трафик идёт, но тяжёлые страницы виснут, видео буферизируется.
Как нашли: Проверили параметр sysctl net.ipv4.tcp_congestion_control.
Причина: Использовался стандартный алгоритм TCP CUBIC, который резко режет окно передачи при минимальных трансграничных потерях пакетов.
Что исправили: Включили TCP BBR через /etc/sysctl.conf:
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

### Специфика окружения (LXC)
При выполнении sysctl -p возникла ошибка: sysctl: cannot stat /proc/sys/net/core/default_qdisc: No such file or directory.
Причина: Сервер работает внутри LXC-контейнера (что видно по Drop-In юниту zzz-lxc-service.conf). Управление очередями qdisc ограничено гипервизором.
Влияние: Настройкам сокетов это не мешает — net.ipv4.tcp_congestion_control = bbr успешно встал, скорость и отзывчивость сети восстановились.

### Аудит безопасности и маскировки исходного конфига
Использование Cloudflare в качестве SNI: Худший выбор для РФ, провоцирует блокировку по IP или TCP RST.
fp=randomized: Прямой сигнатурный маркер для систем глубокого анализа пакетов (DPI). Обязательно менять на fp=chrome или fp=ios.
Один транспорт (только TCP Vision): Отсутствие резервного протокола (например, XHTTP с xmux) оставляет пользователей без связи при точечной блокировке TCP-потоков на порту 443.

## Часть 3. Итоговые конфигурации и ссылки

### Конфигурация Сервера B (server_b_config_redacted.json)
```json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "2050382c-3f59-4824-9a8c-5fc0ec7e4951",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "[www.nvidia.com:443](https://www.nvidia.com:443)",
          "xver": 0,
          "serverNames": [
            "[www.nvidia.com](https://www.nvidia.com)"
          ],
          "privateKey": "**REDACTED**",
          "shortIds": [
            "b3498e33"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}

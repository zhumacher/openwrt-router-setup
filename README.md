# OpenWrt router setup

Установщик DDNS DuckDNS и удалённого SSH-доступа для роутера 4.
Подготовлен для OpenWrt 24.10.2; поддерживает opkg и apk.

Запускать **в SSH-терминале роутера под root**:

```sh
wget -4 -O /tmp/router4-setup.sh 'https://raw.githubusercontent.com/zhumacher/openwrt-router-setup/main/router4-setup.sh' && sh /tmp/router4-setup.sh
```

Имя DuckDNS и токен задаются непосредственно на роутере, токен вводится скрыто.
В репозитории токенов,
паролей и приватных SSH-ключей нет.

Скрипт создаёт бэкап, устанавливает DDNS, настраивает отдельный WAN SSH
на указанном в установщике TCP-порту с доступом только по публичному ключу администратора.
Существующий LAN SSH сохраняется. За основным роутером выполняется попытка
UPnP-проброса; при его отказе выводится инструкция для ручного проброса.
DDNS не устраняет CGNAT — после установки нужен тест доступа извне.

Прошивка, Podkop и VPN-конфиги не обновляются. Перезагрузки роутера нет.
После завершения сохранить итоговый вывод с моделью, архитектурой и
SSH-отпечатками. Токен DuckDNS не пересылать.

## Если AX6S подключён за MikroTik

При отказе UPnP открыть **New Terminal на MikroTik** (WinBox или WebFig).
Сначала задать глобальные переменные `forwardTargetAddress` (WAN IPv4
целевого OpenWrt) и `forwardTargetPort` (его SSH-порт). Конкретные значения
задаются локально на устройстве, в репозитории их нет. Затем выполнить:

```routeros
{
    /tool fetch url="https://raw.githubusercontent.com/zhumacher/openwrt-router-setup/main/mikrotik-forward.rsc" dst-path="mikrotik-forward.rsc" check-certificate=yes;
    /import file-name="mikrotik-forward.rsc";
}
```

Этот блок предназначен для RouterOS MikroTik. В консоли OpenWrt он не работает.
Скрипт проверяет DHCP lease и существующую WAN interface list, сохраняет
экспорты firewall и DHCP leases в Files, закрепляет адрес целевого устройства
и добавляет проброс/разрешение только заданного TCP-порта на этот адрес.
При конфликте порта останавливается. Результат: `FORWARD_OK`.
На основном MikroTik нужен публичный IPv4; результат извне проверяется отдельно.
Скрипт подготовлен по документации RouterOS; на устройстве пока не исполнялся.

Источники: [MikroTik: port forwarding](https://help.mikrotik.com/docs/spaces/RKB/pages/154042388/Port+forwarding),
[DHCP static leases](https://manual.mikrotik.com/docs/network-management/dhcp/).

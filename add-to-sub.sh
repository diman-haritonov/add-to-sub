#!/usr/bin/env bash
#
# add-to-sub.sh — объединить клиента 3x-ui с общей подпиской (общий subId)
#
# Использование:
#   ./add-to-sub.sh <email_клиента> <target_sub_id>
#
# Пример:
#   ./add-to-sub.sh user1-f2 ivan123
#
# ПОЧЕМУ ПРОСТОЙ "UPDATE clients SET sub_id=..." НЕ РАБОТАЕТ:
#   В 3x-ui (проверено на v3.4.2, internal/database/model/model.go +
#   internal/web/service/inbound.go) данные о клиенте хранятся в ДВУХ
#   местах:
#     1. Таблица `clients` (model.ClientRecord, колонка sub_id) —
#        вспомогательная, для traffic-статистики и проверки уникальности
#        при сохранении через панель. НЕ используется для генерации
#        самой подписки.
#     2. JSON-блоб в колонке `inbounds.settings` (`{"clients":[...]}`,
#        поле "subId") — это и есть настоящий источник данных, который
#        читает Xray и генератор подписки (internal/sub/service.go ->
#        internal/web/service/inbound.go:GetClients()).
#   Значит правку нужно делать именно в JSON внутри inbounds.settings —
#   этот скрипт делает это через jq, а таблицу clients правит "заодно",
#   для консистентности данных в панели (счётчики трафика и т.п.).
#
# Что делает скрипт:
#   1. Проверяет версию 3x-ui (>= 3.2.5 — версия, где панель запретила
#      дублирующийся subId через обычный UI/API)
#   2. Проверяет наличие sqlite3 и jq, ставит при необходимости
#   3. Бэкапит x-ui.db
#   4. Останавливает x-ui
#   5. Находит inbound, где есть клиент с указанным email
#   6. Правит subId этого клиента внутри JSON (inbounds.settings)
#   7. Заодно синхронизирует sub_id в таблице clients
#   8. Запускает x-ui обратно, показывает итоговое состояние
#
# ВАЖНО — что вы теряете, используя этот скрипт:
#   После склейки клиентов по одному subId редактирование ЛЮБОГО клиента
#   из этой связки через панель (Клиенты -> Изменить -> Сохранить) будет
#   падать с ошибкой "Duplicate subId: ..." — даже если вы меняли не сам
#   subId, а, например, лимит трафика или срок действия. Панель проверяет
#   уникальность при КАЖДОМ сохранении. Дальнейшие правки таких клиентов
#   делайте только через этот же метод (JSON в inbounds.settings) или
#   напрямую через sqlite3/jq.
#
set -euo pipefail

DB_PATH="/etc/x-ui/x-ui.db"
BACKUP_DIR="/etc/x-ui/backups"
SERVICE_NAME="x-ui"
MIN_VERSION="3.2.5"

if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: запусти скрипт от root (sudo ./add-to-sub.sh ...)" >&2
    exit 1
fi

if [[ $# -ne 2 ]]; then
    echo "Использование: $0 <email_клиента> <target_sub_id>" >&2
    echo "Пример:        $0 user1-f2 ivan123" >&2
    exit 1
fi

EMAIL="$1"
TARGET_SUBID="$2"

# --- Сравнение версий вида X.Y.Z ---
version_ge() {
    [[ "$1" == "$2" ]] && return 0
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do ver1[i]=0; done
    for ((i=0; i<${#ver1[@]}; i++)); do
        if ((10#${ver1[i]:-0} > 10#${ver2[i]:-0})); then
            return 0
        elif ((10#${ver1[i]:-0} < 10#${ver2[i]:-0})); then
            return 1
        fi
    done
    return 0
}

XUI_BIN="/usr/local/x-ui/x-ui"

if [[ ! -x "$XUI_BIN" ]]; then
    # Фолбэк на случай нестандартной установки — ищем x-ui в PATH
    if command -v x-ui >/dev/null 2>&1; then
        XUI_BIN="$(command -v x-ui)"
    else
        echo "Ошибка: не найден бинарник 3x-ui ни по пути $XUI_BIN, ни в PATH." >&2
        exit 1
    fi
fi

if [[ ! -f "$DB_PATH" ]]; then
    echo "Ошибка: не найден файл БД по пути $DB_PATH" >&2
    echo "Проверь путь (для Docker-инсталляций может отличаться)." >&2
    exit 1
fi

# ВАЖНО: команда "x-ui" без флагов открывает интерактивное меню управления,
# а не печатает версию. Версию отдаёт именно бинарник напрямую с флагом -v:
#   /usr/local/x-ui/x-ui -v
RAW_VERSION_OUTPUT="$("$XUI_BIN" -v 2>/dev/null || true)"
CURRENT_VERSION="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "$RAW_VERSION_OUTPUT" | head -n1 || true)"

if [[ -z "$CURRENT_VERSION" ]]; then
    echo "Не удалось автоматически определить версию 3x-ui." >&2
    echo "Проверь вручную: $XUI_BIN -v" >&2
    read -rp "Продолжить без проверки версии на свой страх и риск? [y/N] " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Прервано пользователем."
        exit 1
    fi
else
    echo "[i] Обнаружена версия 3x-ui: $CURRENT_VERSION"
    if ! version_ge "$CURRENT_VERSION" "$MIN_VERSION"; then
        echo "Версия 3x-ui ($CURRENT_VERSION) старше $MIN_VERSION." >&2
        echo "В этих версиях панель ещё разрешает одинаковый subId через обычный UI" >&2
        echo "(Клиенты -> Изменить -> ID подписки) — обход не требуется." >&2
        exit 1
    fi
fi

for tool in sqlite3 jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool не установлен. Устанавливаю..."
        apt-get update -qq && apt-get install -y "$tool" -qq
    fi
done

mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/x-ui.db.$(date +%Y%m%d-%H%M%S).bak"
cp "$DB_PATH" "$BACKUP_FILE"
echo "[i] Бэкап создан: $BACKUP_FILE"

# --- Ищем inbound, где в settings JSON есть клиент с этим email ---
echo "[i] Ищу inbound с клиентом '$EMAIL'..."

INBOUND_ID=""
INBOUND_IDS=$(sqlite3 "$DB_PATH" "SELECT id FROM inbounds;")

for id in $INBOUND_IDS; do
    SETTINGS_JSON=$(sqlite3 "$DB_PATH" "SELECT settings FROM inbounds WHERE id = $id;")
    HAS_CLIENT=$(echo "$SETTINGS_JSON" | jq -r --arg email "$EMAIL" \
        '[.clients[]? | select(.email == $email)] | length' 2>/dev/null || echo "0")
    if [[ "$HAS_CLIENT" -gt 0 ]]; then
        INBOUND_ID="$id"
        break
    fi
done

if [[ -z "$INBOUND_ID" ]]; then
    echo "Ошибка: клиент с email '$EMAIL' не найден ни в одном inbound (settings JSON)." >&2
    echo "Проверь точное значение email (регистр важен)." >&2
    exit 1
fi

echo "[i] Найден в inbound id=$INBOUND_ID"

OLD_SETTINGS=$(sqlite3 "$DB_PATH" "SELECT settings FROM inbounds WHERE id = $INBOUND_ID;")

NEW_SETTINGS=$(echo "$OLD_SETTINGS" | jq -c --arg email "$EMAIL" --arg subid "$TARGET_SUBID" \
    '(.clients[] | select(.email == $email) | .subId) = $subid')

if [[ -z "$NEW_SETTINGS" || "$NEW_SETTINGS" == "null" ]]; then
    echo "Ошибка: не удалось сгенерировать новый JSON через jq." >&2
    exit 1
fi

echo
echo "======================================================================"
echo " ВНИМАНИЕ: после этой операции клиент '$EMAIL' (inbound id=$INBOUND_ID)"
echo " будет иметь subId '$TARGET_SUBID', совпадающий с другими клиентами"
echo " этой подписки."
echo
echo " Из-за этого редактирование ЛЮБОГО клиента из этой группы через"
echo " веб-панель (Клиенты -> Изменить -> Сохранить) будет завершаться"
echo " ошибкой:"
echo "     Something went wrong (Duplicate subId: $TARGET_SUBID)"
echo " даже если вы меняли не subId, а, например, лимит трафика или срок."
echo
echo " Дальнейшие правки таких клиентов делайте только через этот скрипт"
echo " / напрямую через sqlite3+jq — см. комментарий в начале файла."
echo "======================================================================"
echo
read -rp "Продолжить? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Прервано пользователем."
    exit 1
fi

echo "[i] Останавливаю $SERVICE_NAME..."
systemctl stop "$SERVICE_NAME"

# --- Пишем новый settings JSON обратно (экранируем одинарные кавычки для SQL) ---
ESCAPED_SETTINGS=$(printf '%s' "$NEW_SETTINGS" | sed "s/'/''/g")
TMP_SQL=$(mktemp)
trap 'rm -f "$TMP_SQL"' EXIT

{
    echo "UPDATE inbounds SET settings = '$ESCAPED_SETTINGS' WHERE id = $INBOUND_ID;"
    echo "UPDATE clients SET sub_id = '$TARGET_SUBID' WHERE email = '$EMAIL';"
} > "$TMP_SQL"

sqlite3 "$DB_PATH" < "$TMP_SQL"

echo "[i] Запускаю $SERVICE_NAME обратно..."
systemctl start "$SERVICE_NAME"

sleep 1

echo
echo "=== Проверка: клиенты inbound id=$INBOUND_ID с subId='$TARGET_SUBID' ==="
sqlite3 "$DB_PATH" "SELECT settings FROM inbounds WHERE id = $INBOUND_ID;" | \
    jq -r --arg subid "$TARGET_SUBID" '.clients[] | select(.subId == $subid) | "\(.email)  ->  subId=\(.subId)"'

echo
echo "=== Таблица clients (для сверки) ==="
sqlite3 "$DB_PATH" ".headers on" ".mode column" "SELECT id, email, sub_id FROM clients WHERE sub_id = '$TARGET_SUBID';"

echo
echo "Готово. Проверь итоговую подписку curl'ом:"
echo "  curl -sk 'https://<IP>:<sub_port>/<sub_path>/$TARGET_SUBID' | base64 -d"
echo
echo "Напоминание: не редактируйте этих клиентов через панель —"
echo "сохранение упадёт с ошибкой Duplicate subId."

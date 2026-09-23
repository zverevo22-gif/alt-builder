#!/bin/bash
# ============================================================================
#  build-iso.sh — запуск собственно сборки ISO-образа
#
#  Требует сформированного профиля (см. scripts/gen-profile.sh или build.sh).
#  От имени пользователя с правами hasher (см. README.md).
#
#  Дополнительные опции передаются make-переменными, например:
#      DEBUG=1 scripts/build-iso.sh          - отладочная сборка
#      CHECK=1 scripts/build-iso.sh          - только проверка конфигурации
# ============================================================================

source "$(dirname "$0")/lib/common.sh"
assert_tool make

load_conf "${CONF_DIR}/build.conf"

# переопределения из окружения (заданы build.sh: --desktop/--branch/--arch/--target/--out)
config_env_override DESKTOP TARGET BRANCH ARCH IMAGEDIR

DESKTOP=$(get_conf DESKTOP gnome | tr '[:upper:]' '[:lower:]')
DESKTOP=$(desktop_canon "$DESKTOP")
desktop_valid "$DESKTOP" || die "DESKTOP='$DESKTOP' неизвестен (допустимо: gnome|cinnamon|plasma)"
TARGET="$(get_conf TARGET "distro/alt-${DESKTOP}.iso")"

# метапрофиль должен быть подготовлен
MP_DIR="${MP_DIR:-${WORK_DIR}/mkimage-profiles}"
[ -s "$MP_DIR/main.mk" ] || die "профиль не готов: нет $MP_DIR/main.mk (запустите scripts/gen-profile.sh)"
[ -s "$MP_DIR/conf.d/999-alt-desktop.mk" ] || die "нет конфигурации профиля (запустите scripts/gen-profile.sh)"
[ -s "$MK_VARS_FILE" ] || die "нет файла переменных $MK_VARS_FILE (запустите scripts/gen-profile.sh)"

# собираем аргументы make из сгенерированного файла переменных
declare -a MAKE_ARGS=()
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    MAKE_ARGS+=("$line")
done < "$MK_VARS_FILE"
# переменные из окружения тоже нужно передавать (DEBUG=1 и т.п.)
for v in DEBUG CHECK REPORT; do
    if [ -n "${!v:-}" ]; then
        MAKE_ARGS+=("$v=${!v}")
    fi
done

iprint "сборка цели $TARGET в $MP_DIR"
iprint "make: варианты: $(printf '%q ' "${MAKE_ARGS[@]}")"

LOGFILE="${OUT_DIR}/build-$(date_stamp).log"
mkdir -p "$OUT_DIR"

(
    set -o pipefail
    export PATH="$MP_DIR/bin:$PATH"
    cd "$MP_DIR"
    make -r --no-print-directory -f main.mk "${MAKE_ARGS[@]}" "$TARGET"
) 2>&1 | tee "$LOGFILE"
rc=${PIPESTATUS[0]}

if [ "$rc" -eq 0 ]; then
    iok "сборка завершена успешно. Журнал: $LOGFILE"
elif latest="$(ls -t "${OUT_DIR}"/alt-*.iso 2>/dev/null | head -1)" \
     && [ -n "$latest" ] && [ -f "$latest" ]; then
    # mkimage иногда возвращает ненулевой код в финальном шаге проверки
    # ("[: : integer expression expected"), хотя ISO уже собран
    iwarn "make вернул код $rc, но образ собран (пост-проверка mkimage ругнулась)"
    iok "считаем сборку успешной"
else
    ierr "сборка не удалась (код $rc). Журнал: $LOGFILE"
    iwarn "повторите с DEBUG=1 для полного лога: DEBUG=1 scripts/build-iso.sh"
    exit "$rc"
fi

    latest="$(ls -t "${OUT_DIR}"/alt-*.iso "${OUT_DIR}/${TARGET##*/}" 2>/dev/null | head -1)"
    echo "  ISO: $latest" >&2
    echo "  проверка: scripts/check-iso.sh $latest" >&2
exit 0
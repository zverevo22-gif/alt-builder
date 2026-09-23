#!/bin/bash
# ============================================================================
#  clean.sh — уборка рабочего состояния сборки
#
#  Использование:
#      scripts/clean.sh [--out] [--force]
#
#    --out    дополнительно удалить готовые ISO из out/
#    --force  очистить даже при отсутствии make (безусловное rm)
#
#  По умолчанию: останавливает незавершённую сборку и удаляет рабочее
#  состояние work/ (копию метапрофиля, сгенерированные файлы), сохраняя
#  готовые образы в out/.
# ============================================================================

source "$(dirname "$0")/lib/common.sh"

CLEAN_OUT=0
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --out) CLEAN_OUT=1 ;;
        --force) FORCE=1 ;;
        *) die "неизвестная опция: $1" ;;
    esac
    shift
done

if [ -d "${WORK_DIR}/mkimage-profiles" ] && [ -s "${WORK_DIR}/mkimage-profiles/main.mk" ] && command -v make >/dev/null 2>&1; then
    iprint "делаю distclean метапрофиля"
    ( cd "${WORK_DIR}/mkimage-profiles" && make distclean ) 2>&1 | tail -5 || FORCE=1
fi

if [ -d "/tmp/mkimage-profiles.build"* ] 2>/dev/null; then
    iprint "удаляю временные BUILDDIR из /tmp/mkimage-profiles.build.*"
    rm -rf /tmp/mkimage-profiles.build.* 2>/dev/null || true
fi

iok "удаляю рабочее состояние: $WORK_DIR"
rm -rf -- "$WORK_DIR"
mkdir -p "$WORK_DIR"

if [ "$CLEAN_OUT" = "1" ]; then
    iok "удаляю готовые образы: $OUT_DIR"
    rm -f -- "$OUT_DIR"/*.iso
fi

iok "очистка завершена. Следующая сборка начнётся с формирования профиля."
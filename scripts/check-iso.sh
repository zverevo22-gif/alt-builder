#!/bin/bash
# ============================================================================
#  check-iso.sh — проверка собранного ISO-образа
#
#  Использование:
#      scripts/check-iso.sh [ISO [ISO...]]
#      scripts/check-iso.sh --latest            проверить свежий образ в out/
#
#  Проверки:
#    * наличие файла и ненулевой размер;
#    * (если есть утилита file) тип ISO-9660;
#    * признаки гибридного образа (MBR-сигнатура 55AA при гибридной записи);
#    * наличие ключевых элементов структуры ALT-образа: .disk/, ALTLinux/,
#      загрузчик (boot/grub, isolinux/syslinux, EFI/);
#    * SHA-256.
#  Тип утилиты file на системе сборки (ALT) — gcc builtin file; изменение
#  вывода не критично: итоговую оценку можно сделать вручную по полю type.
# ============================================================================

source "$(dirname "$0")/lib/common.sh"

get_tool() { command -v "$1" 2>/dev/null || true; }

[ $# -eq 0 ] && set -- "${OUT_DIR}/"alt-*.iso
[ $# -eq 0 ] && { echo "ISO не указан и в out/ пусто" >&2; exit 2; }

rc=0
for iso in "$@"; do
    echo
    iprint "проверка: $iso"

    [ -f "$iso" ] || { ierr "файл не найден"; rc=1; continue; }
    size=$(stat -c %s -- "$iso" 2>/dev/null || stat -f %z -- "$iso" 2>/dev/null || 0)
    if [ "$size" -le 0 ]; then ierr "файл пуст"; rc=1; continue; fi
    iok "размер: $size байт ($(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo --))"

    F=$(get_tool file)
    if [ -n "$F" ]; then
        type="$($F -b -- "$iso")"
        echo "  тип: $type"
        case "$type" in
            *'ISO 9660'*|*'DOS/MBR boot sector'*) iok "ISO-9660 распознан" ;;
            *) iwarn "тип отличается от ожидаемого ISO-9660 (см. выше)" ;;
        esac
        case "$type" in
            *'DOS/MBR boot sector'*|*'isohdpfx'*|*'hybrid'*) iok "гибридный (MMBR) признак присутствует" ;;
        esac
    else
        iwarn "утилита file не найдена; тип не определён"
    fi

    # сигнатура главной загрузочной записи в конце сектора 0 (гибрид)
    MBRSIG=$(od -An -tx1 -j 510 -N 2 -- "$iso" 2>/dev/null | tr -d ' ')
    case "$MBRSIG" in
        55aa) iok "MBR-сигнатура 55AA найдена (offset 510)" ;;
        *)    iwarn "MBR-сигнатура не определена (не гибрид или файл без MBR)" ;;
    esac

    # структура образа
    print_iso_listing() {
        if [ -n "$(get_tool isoinfo)" ]; then
            isoinfo -i "$iso" -R -f 2>/dev/null
            return
        fi
        if [ -n "$(get_tool xorriso)" ]; then
            xorriso -indev "$iso" -osirrox on -find . -name '*' -print 2>/dev/null | head -200
            return
        fi
        # fallback без isoinfo/xorriso/strings: читаем первые 8 МБ образа
        # (\0 -> \n, чтобы пакет-GREP-строки попали в отдельные строки)
        head -c 8388608 -- "$iso" 2>/dev/null | tr '\000' '\n' | grep -a -E '(^|/)(\.disk|ALTLinux|boot|EFI|isolinux|syslinux)/' | sort -u | head -50
    }
    LISTING="$(print_iso_listing || true)"
    found=""
    for needle in ".disk/arch" "ALTLinux/" "boot/grub" "EFI/" "isolinux" "syslinux" "kernel" "vmlinuz"; do
        if printf '%s\n' "$LISTING" | grep -qiF "$needle"; then
            found="$found $needle"
        fi
    done
    if [ -n "$found" ]; then
        iok "найдены ключевые элементы: $found"
    else
        ierr "не удалось разобрать структуру образа (isoinfo/xorriso/strings отсутствуют?)"
        rc=1
    fi

    SHA="$(get_tool sha256sum)"
    if [ -n "$SHA" ]; then
        shaf="$("$SHA" -- "$iso" 2>/dev/null || true)"
        echo "  sha256: ${shaf%% *}"
    fi
done

exit "$rc"
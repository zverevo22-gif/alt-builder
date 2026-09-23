#!/bin/bash
# ============================================================================
#  selfcheck.sh — самопроверка набора скриптов и конфигурации
#
#  Использование:
#      scripts/selfcheck.sh [--mp-dir КАТАЛОГ] [--no-net]
#
#  Проверяет:
#    1. синтаксис всех скриптов (bash -n);
#    2. наличие обязательных файлов и прав исполнения;
#    3. корректность config/*.conf (загрузка без ошибок);
#    4. соответствие пользовательского overlay структуре mkimage-profiles;
#     5. опционально: результирующий conf.d/999-alt-desktop.mk после gen-profile.
#
#  MP_DIR по умолчанию: $MP_DIR, иначе work/mkimage-profiles.
#  БЕЗ СЕТИ клон не выполняется (--no-net отключает клонирование).
# ============================================================================

source "$(dirname "$0")/lib/common.sh"

FAIL=0
ok()   { iok "$1"; }
warn() { if [ "${OS_LISTD_WARN_AS_ERR:-0}" != "1" ]; then iwarn "$1"; else ierr "$1"; FAIL=1; fi; }
bad()  { ierr "$1"; FAIL=1; }

MP_DIR_OPT=""
NO_NET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --mp-dir) MP_DIR_OPT="${2:?--mp-dir требует значение}"; shift ;;
        --no-net|--no-network) NO_NET=1 ;;
        --warn-as-err) OS_LISTD_WARN_AS_ERR=1 ;;
        *) bad "неизвестная опция: $1" ;;
    esac
    shift
done

# --- 1. синтаксис ----------------------------------------------------------
iprint "==> 1. синтаксис скриптов (bash -n)"
for f in "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/lib/*.sh "$TOOLS_DIR"/*.sh; do
    [ -f "$f" ] || continue
    for sh in bash; do
        if out=$(bash -n "$f" 2>&1); then
            ok "   ok: ${f#$PROJ_ROOT/}"
        else
            bad "   SYNTAX: ${f#$PROJ_ROOT/}: $out"
        fi
    done
done

# --- 2. обязательные файлы ---------------------------------------------------
iprint "==> 2. наличие обязательных файлов"
for f in \
    config/build.conf config/branding.conf config/packages.conf \
    scripts/lib/common.sh scripts/gen-profile.sh scripts/build.sh \
    scripts/build-iso.sh scripts/env-setup-alt.sh scripts/env-setup-debian.sh \
    scripts/check-iso.sh scripts/clean.sh scripts/selfcheck.sh \
    tools/make-aptconf.sh tools/mk-branding.sh \
    profile/conf.d/999-alt-desktop.mk.in \
    profile/features.in/custom-brand/config.mk \
    profile/features.in/custom-brand/99-custom-brand.sh.in \
    profile/pkg.in/lists/custom/gnome-extra \
    README.md; do
    [ -f "$PROJ_ROOT/$f" ] || { bad "   отсутствует: $f"; continue; }
    case "$f" in
        scripts/*.sh|tools/*.sh)
            [ -x "$PROJ_ROOT/$f" ] || warn "   нет бита исполнения: $f (chmod +x)"
            ;;
    esac
    ok "   $f"
done

# --- 3. конфигурация ----------------------------------------------------------
iprint "==> 3. загрузка config/*.conf"
for c in build branding packages; do
    if bash -c "source '${PROJ_ROOT}/scripts/lib/common.sh'; load_conf '${PROJ_ROOT}/config/$c.conf' >/dev/null 2>&1 || exit 1"; then
        ok "   config/$c.conf"
    else
        bad "   config/$c.conf не загружается"
    fi
done
load_conf "${CONF_DIR}/build.conf"
load_conf "${CONF_DIR}/branding.conf"
load_conf "${CONF_DIR}/packages.conf"
BRANDING_MODE="$(get_conf BRANDING_MODE auto)"
case "$BRANDING_MODE" in
    auto|repo|files) ok "   BRANDING_MODE=$BRANDING_MODE" ;;
    *) bad "   BRANDING_MODE='$BRANDING_MODE' (допустимо: auto|repo|files)" ;;
esac
[ -n "$(get_conf BRANDING alt-starterkit)" ] || warn "   пустое BRANDING"
# режим repo: локальный репозиторий брендинга обязан существовать и быть свежим
if [ "$BRANDING_MODE" = "repo" ]; then
    LREPO="$(get_conf BRANDING_LOCAL_REPO work/apt.d/localrepo)"
    case "$LREPO" in /*) ;; *) LREPO="${PROJ_ROOT}/$LREPO" ;; esac
    if [ -d "$LREPO" ] && compgen -G "$LREPO/RPMS.classic/branding-*.rpm" >/dev/null 2>&1; then
        ok "   локальный репозиторий брендинга: $LREPO ($(ls -1 "$LREPO"/RPMS.classic/branding-*.rpm 2>/dev/null | wc -l) pkg)"
    else
        warn "   BRANDING_MODE=repo, а локального репозитория брендинга нет в $LREPO (выполните tools/mk-branding.sh)"
    fi
fi
# branding-template наполнен, но режим не repo: содержимое в образ не попадёт
if branding_template_has_content && [ "$BRANDING_MODE" != "repo" ]; then
    warn "в branding-template/ есть содержимое, но BRANDING_MODE=$BRANDING_MODE - в образ оно НЕ попадёт (переключите на repo)"
fi
DESKTOP="$(get_conf DESKTOP gnome | tr '[:upper:]' '[:lower:]')"
DESKTOP="$(desktop_canon "$DESKTOP")"
if desktop_valid "$DESKTOP"; then
    ok "   DESKTOP=$DESKTOP ($(desktop_parent "$DESKTOP"))"
else
    bad "   DESKTOP='$DESKTOP' (допустимо: gnome|cinnamon|plasma)"
fi

# --- 4. структура overlay ------------------------------------------------------
iprint "==> 4. соответствие overlay структуре mkimage-profiles"
# Для проверки нужен ЭТАЛОННЫЙ (нетронутый) метапрофиль — наша сборка
# (gen-profile.sh) overlay-ом меняет рабочую копию, поэтому по умолчанию
# используем отдельный каталог work/selfcheck-etalon.
ETALON="${MP_DIR_OPT:-${MP_DIR:-${WORK_DIR}/selfcheck-etalon}}"
# если передан готовый грязный рабочий каталог без эталонных путей - считаем его эталоном
MP_DIR="$ETALON"
if [ -s "$MP_DIR/main.mk" ]; then
    ok "   эталон: $MP_DIR"
else
    if [ "$NO_NET" = "1" ]; then
        warn "   эталон не задан/не клонирован (--no-net); структурные проверки пропускаются"
    else
        iprint "   клонирую mkimage-profiles в $MP_DIR (--no-net отключает)"
        mkdir -p "$(dirname -- "$MP_DIR")"
        git clone --depth 1 "${MP_GIT_URL:-https://git.altlinux.org/gears/m/mkimage-profiles.git}" "$MP_DIR" \
            || warn "   не удалось клонировать метапрофиль"
    fi
fi

if [ -s "$MP_DIR/main.mk" ]; then
    # файлы/каталоги метапрофиля, на которые опирается наш шаблон
    for p in \
        features.in/blacklist-pkgs \
        features.in/branding \
        conf.d/regular.mk \
        conf.d/mixin.mk \
        lib/sugar.mk; do
        if [ -e "$MP_DIR/$p" ] || [ -d "$MP_DIR/$p" ]; then
            ok "   $p"
        else
            warn "   отсутствует в эталоне: $p"
        fi
    done
    # наша фича поставляется в репозитории и накладывается при сборке
    if [ -f "$PROJ_ROOT/profile/features.in/custom-brand/config.mk" ]; then
        ok "   features.in/custom-brand (исходник проекта; в эталон не входит)"
    fi
    # цели, заимствуемые нашим шаблоном (определяются в conf.d/)
    DE_PARENT=$(desktop_parent "$DESKTOP")
    DE_MIXIN=$(desktop_mixin "$DESKTOP")
    for pair in "conf.d/regular.mk distro/${DE_PARENT}:" "conf.d/mixin.mk ${DE_MIXIN}:"; do
        set -- $pair
        if grep -Fq "$2" "$MP_DIR/$1"; then
            ok "   цель $2 ($1)"
        else
            warn "   цель не найдена: $2 ($1)"
        fi
    done
    # связи из нашего шаблона conf.d (должны существовать как make-связи)
    # в шаблоне цель/родитель заданы токенами, которые подставляет gen-profile
    TPL="$PROJ_ROOT/profile/conf.d/999-alt-desktop.mk.in"
    if [ -f "$TPL" ]; then
        for t in "distro/alt-@DESKTOP@:" "distro/@DESKTOP_PARENT@ " "use/blacklist-pkgs" "use/custom-brand"; do
            if grep -Fq "$t" "$TPL"; then
                ok "   токен в шаблоне: $t"
            else
                warn "   не найдено в 999-alt-desktop.mk.in: $t"
            fi
        done
    fi
    # списки пакетов из конфигурации
    load_conf "${CONF_DIR}/packages.conf"
    for L in THE_LISTS_EXTRA LIVE_LISTS_EXTRA; do
        v="$(get_conf $L '')"
        [ -z "$v" ] && continue
        for lst in $v; do
            # допустимые пути: имя в pkg.in/lists/… либо безусловный файл
            if [ -e "$PROJ_ROOT/profile/pkg.in/lists/$lst" ] || [ -e "$PROJ_ROOT/$lst" ]; then
                ok "   список: $lst"
            else
                warn "   список не найден ни локально, ни в overlay: $lst"
            fi
        done
    done
fi

# --- 5. отчёт -----------------------------------------------------------------------
iprint "==> Итог"
if [ "$FAIL" = "0" ]; then
    iok "самопроверка успешна"
else
    ierr "самопроверка НЕ пройдена (см. выше)"
fi
exit "$FAIL"
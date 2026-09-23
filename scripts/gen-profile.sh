#!/bin/bash
# ============================================================================
#  gen-profile.sh — формирование сборочного профиля mkimage-profiles
#
#  Делает:
#   1. получает свежую копию метапрофиля mkimage-profiles (work/mkimage-profiles,
#      либо использует существующую; можно задать MP_DIR и MP_GIT_URL);
#   2. накладывает пользовательский overlay из profile/ (conf.d, features.in,
#      pkg.in) поверх метапрофиля;
#   3. генерирует conf.d/999-alt-desktop.mk и файл переменных make
#      (work/mkimage-vars.cnf) из config/*.conf;
#   4. наполняет фичу use/custom-brand (хуки image-scripts.d и, при
#      BRANDING_MODE=files, копию пользовательских файлов);
#   5. при USE_APTCONF=1 готовит APTCONF (см. tools/make-aptconf.sh).
# ============================================================================

source "$(dirname "$0")/lib/common.sh"
assert_tool git sed date

load_conf "${CONF_DIR}/build.conf"
load_conf "${CONF_DIR}/branding.conf"
load_conf "${CONF_DIR}/packages.conf"

# переопределения из окружения (заданы build.sh: --desktop/--branch/--arch/--target/--out)
config_env_override BRANCH ARCH DESKTOP TARGET IMAGEDIR

BRANCH=$(get_conf BRANCH p10)
ARCH=$(get_conf ARCH x86_64)
DESKTOP=$(get_conf DESKTOP gnome | tr '[:upper:]' '[:lower:]')
DESKTOP=$(desktop_canon "$DESKTOP")
desktop_valid "$DESKTOP" || die "DESKTOP='$DESKTOP' неизвестен (допустимо: gnome|cinnamon|plasma)"
DE_PARENT=$(desktop_parent "$DESKTOP")
TARGET=$(get_conf TARGET "distro/alt-${DESKTOP}.iso")
BRANDING_MODE=$(get_conf BRANDING_MODE auto)
BRANDING=$(get_conf BRANDING alt-starterkit)

mkdir -p "$WORK_DIR"

# --- 1. источник метапрофиля -------------------------------------------------
MP_DIR="${MP_DIR:-}"
if [ -z "$MP_DIR" ]; then
    MP_DIR="${WORK_DIR}/mkimage-profiles"
    if [ -s "$MP_DIR/main.mk" ]; then
        iok "используется существующий метапрофиль: $MP_DIR"
    else
        MP_GIT_URL="${MP_GIT_URL:-https://git.altlinux.org/gears/m/mkimage-profiles.git}"
        iwarn "клонируем метапрофиль mkimage-profiles: $MP_GIT_URL"
        rm_project "$MP_DIR"
        git clone --depth 1 "$MP_GIT_URL" "$MP_DIR" \
            || die "не удалось клонировать mkimage-profiles"
    fi
fi
[ -s "$MP_DIR/main.mk" ] || die "метапрофиль по пути $MP_DIR не содержит main.mk (неверно задан MP_DIR?)"
[ -s "$MP_DIR/bin/mp-commit" ] || die "в метапрофиле $MP_DIR отсутствует bin/mp-commit - повреждённая копия"

# --- 2. наложение overlay -------------------------------------------------------
iprint "накладываем пользовательский overlay на $MP_DIR"
# merge (не --delete): в каталогах метапрофиля лежат штатные файлы, их нельзя
# удалять; в gen-profile-е уже была удалена рабочая копия features.in/custom-brand
overlay_dir "$PROJ_ROOT/profile/conf.d"      "$MP_DIR/conf.d"
overlay_dir "$PROJ_ROOT/profile/features.in" "$MP_DIR/features.in"
overlay_dir "$PROJ_ROOT/profile/pkg.in"      "$MP_DIR/pkg.in"

# --- 3. генерация конфигурационного файла метапрофиля ---------------------------
tmpl_escape() { printf '%s' "$1" | sed 's#[/&\#\\]#\\&#g'; }

render_confd() {
    local tpl="$1" dst="$2"
    # Переопределение RELNAME поверх значения, заданного фичами grub/syslinux
    # родительского профиля (они делают set RELNAME,ALT ($(IMAGE_NAME))).
    local relname relname_set relname_xport
    relname="$(get_conf RELNAME '')"
    if [ -n "$relname" ]; then
        relname_set="		@\$(call set,RELNAME,$(tmpl_escape "$relname"))"
        relname_xport="		@\$(call xport,RELNAME)"
    else
        relname_set="		# RELNAME пуст в config/branding.conf: оставляем имя родительского профиля"
        relname_xport=""
    fi
    sed \
        -e "s#@DESKTOP@#$(tmpl_escape "$DESKTOP")#g" \
        -e "s#@DESKTOP_PARENT@#$(tmpl_escape "$DE_PARENT")#g" \
        -e "s#@RELNAME_SET@#$(printf '%s' "$relname_set")#g" \
        -e "s#@RELNAME_XPORT@#$(printf '%s' "$relname_xport")#g" \
        -e "s#@THE_PACKAGES_EXTRA@#$(tmpl_escape "$(get_conf THE_PACKAGES_EXTRA '')")#g" \
        -e "s#@THE_LISTS_EXTRA@#$(tmpl_escape "$(get_conf THE_LISTS_EXTRA '')")#g" \
        -e "s#@BASE_PACKAGES_EXTRA@#$(tmpl_escape "$(get_conf BASE_PACKAGES_EXTRA '')")#g" \
        -e "s#@MAIN_PACKAGES_EXTRA@#$(tmpl_escape "$(get_conf MAIN_PACKAGES_EXTRA '')")#g" \
        -e "s#@LIVE_PACKAGES_EXTRA@#$(tmpl_escape "$(get_conf LIVE_PACKAGES_EXTRA '')")#g" \
        -e "s#@LIVE_LISTS_EXTRA@#$(tmpl_escape "$(get_conf LIVE_LISTS_EXTRA '')")#g" \
        -e "s#@INSTALL2_PACKAGES_EXTRA@#$(tmpl_escape "$(get_conf INSTALL2_PACKAGES_EXTRA '')")#g" \
        -e "s#@BLACKLIST_PKGS@#$(tmpl_escape "$(get_conf BLACKLIST_PKGS '')")#g" \
        -e "s#@THE_BRANDING@#$(tmpl_escape "$(get_conf THE_BRANDING '')")#g" \
        "$tpl" > "$dst"
}

# конфигурации более не актуального окружения убираем (могли остаться
# от прошлого прогона с другим DESKTOP)
rm -f "$MP_DIR"/conf.d/999-alt-*.mk
DNC="${MP_DIR}/conf.d/999-alt-desktop.mk"
render_confd "$PROJ_ROOT/profile/conf.d/999-alt-desktop.mk.in" "$DNC"
iok "конфигурация метапрофиля: $DNC (DE=$DESKTOP, $DE_PARENT)"

# --- 4. переменные make ---------------------------------------------------------
conf_get_nz() { # конфиг-значение без значения по умолчанию
    get_conf "$1" ''
}

write_var() { # write_var KEY [значение]
    [ -n "$2" ] || return 0
    printf '%s=%q\n' "$1" "$2"
}

VENDOR_NAME=$(get_conf VENDOR_NAME '')
RELNAME=$(get_conf RELNAME '')

IMAGEDIR="$(get_conf IMAGEDIR "$OUT_DIR")"
mkdir -p "$IMAGEDIR"
IMAGEDIR="$(cd -P -- "$IMAGEDIR" && pwd)"

{
    write_var BRANCH "$BRANCH"
    write_var ARCH "$ARCH"
    write_var BRANDING "$BRANDING"
    write_var BRANDING_MODE "$BRANDING_MODE"
    write_var RELNAME "$RELNAME"
    write_var META_PUBLISHER "$VENDOR_NAME"
    write_var IMAGEDIR "$IMAGEDIR"
    write_var THE_BRANDING "$(conf_get_nz THE_BRANDING)"
    write_var THE_PACKAGES_EXTRA "$(conf_get_nz THE_PACKAGES_EXTRA)"
    write_var THE_LISTS_EXTRA "$(conf_get_nz THE_LISTS_EXTRA)"
    write_var BASE_PACKAGES_EXTRA "$(conf_get_nz BASE_PACKAGES_EXTRA)"
    write_var MAIN_PACKAGES_EXTRA "$(conf_get_nz MAIN_PACKAGES_EXTRA)"
    write_var LIVE_PACKAGES_EXTRA "$(conf_get_nz LIVE_PACKAGES_EXTRA)"
    write_var LIVE_LISTS_EXTRA "$(conf_get_nz LIVE_LISTS_EXTRA)"
    write_var INSTALL2_PACKAGES_EXTRA "$(conf_get_nz INSTALL2_PACKAGES_EXTRA)"
    write_var BLACKLIST_PKGS "$(conf_get_nz BLACKLIST_PKGS)"
    write_var ISO_LEVEL "$(conf_get_nz ISO_LEVEL)"
    write_var SQUASHFS "$(conf_get_nz SQUASHFS)"
    write_var DISTRO_VERSION "$(conf_get_nz DISTRO_VERSION)"
    write_var STATUS "$(conf_get_nz STATUS)"
    write_var CHECK "$(conf_get_nz CHECK)"
    write_var DEBUG "$(conf_get_nz DEBUG)"
    write_var AUTOCLEAN "$(conf_get_nz AUTOCLEAN)"
} > "$MK_VARS_FILE"
iok "значения make записаны: $MK_VARS_FILE"

# --- 5. наполнение фичи use/custom-brand -----------------------------------------
CF_FEATURE="$MP_DIR/features.in/custom-brand"
rm -rf "$CF_FEATURE/live" "$CF_FEATURE/install2" "$CF_FEATURE/files"
mkdir -p "$CF_FEATURE/live/image-scripts.d"
mkdir -p "$CF_FEATURE/install2/image-scripts.d"

BUILD_DATE="$(date +%F)"
render_hook() { # render_hook <каталог-назначения>
    local dst="$1"
    mkdir -p "$(dirname "$dst")"
    sed \
        -e "s#@BRANDING@#$(tmpl_escape "$BRANDING")#g" \
        -e "s#@RELNAME@#$(tmpl_escape "$RELNAME")#g" \
        -e "s#@VENDOR_NAME@#$(tmpl_escape "$VENDOR_NAME")#g" \
        -e "s#@BUILD_DATE@#$(tmpl_escape "$BUILD_DATE")#g" \
        "$PROJ_ROOT/profile/features.in/custom-brand/99-custom-brand.sh.in" > "$dst"
    chmod +x "$dst"
}
render_hook "$CF_FEATURE/live/image-scripts.d/99-custom-brand"
render_hook "$CF_FEATURE/install2/image-scripts.d/99-custom-brand"
iok "хуки брендинга сгенерированы (live, install2)"

# файлы брендинга (BRANDING_MODE=files)
if [ "$BRANDING_MODE" = "files" ]; then
    SRC="$(get_conf BRANDING_FILES_DIR profile/branding/files)"
    case "$SRC" in
        /*) ;;
        *) SRC="${PROJ_ROOT}/$SRC" ;;
    esac
    if [ -d "$SRC" ] && [ -n "$(find "$SRC" -mindepth 1 ! -name README.md -print -quit 2>/dev/null)" ]; then
        sync_dir "$SRC" "$CF_FEATURE/files"
        rm -f "$CF_FEATURE/files/README.md"
        iok "файлы брендинга: $SRC -> custom-brand/files/"
    else
        iwarn "BRANDING_MODE=files, но каталог '$SRC' пуст/отсутствует - пропускаю"
    fi
fi

# --- 6. APTCONF: фиксированное зеркало ветки -------------------------------------
# Сборка НЕ зависит от репозиториев хост-системы: aptbox/установка пакетов
# берут пакеты из закреплённого зеркала целевой ветки (см. tools/make-aptconf.sh).
# Отключить можно: USE_APTCONF="0" в config/build.conf.
USE_APTCONF="${USE_APTCONF:-$(get_conf USE_APTCONF 1)}"
if [ "$USE_APTCONF" != "0" ]; then
    # зеркало и протокол можно переопределить (см. tools/make-aptconf.sh):
    # через переменные окружения или ключи APT_MIRROR/APT_PROTO в config/build.conf
    _apt_mirror="$(get_conf APT_MIRROR '')"; [ -n "$_apt_mirror" ] && export APT_MIRROR="$_apt_mirror"
    _apt_proto="$(get_conf APT_PROTO '')";   [ -n "$_apt_proto" ]  && export APT_PROTO="$_apt_proto"
    unset _apt_mirror _apt_proto

    # BRANDING_MODE=repo: локальный репозиторий собственного брендинга
    # (tools/mk-branding.sh) подключается ДОПОЛНИТЕЛЬНО к сетевому зеркалу,
    # а не вместо него (см. APT_EXTRA_MIRROR в tools/make-aptconf.sh).
    if [ "$BRANDING_MODE" = "repo" ]; then
        _lrepo="$(get_conf BRANDING_LOCAL_REPO work/apt.d/localrepo)"
        case "$_lrepo" in
            /*) ;;
            *) _lrepo="${PROJ_ROOT}/$_lrepo" ;;
        esac
        if [ -d "$_lrepo" ]; then
            export APT_EXTRA_MIRROR="file://$_lrepo"
            iok "локальный репозиторий брендинга добавлен в apt: $_lrepo"
        else
            iwarn "BRANDING_MODE=repo, но локальный репозиторий '$_lrepo' ещё не собран (выполните tools/mk-branding.sh)"
        fi
        unset _lrepo
    fi

    APTCONF="$(bash "$PROJ_ROOT/tools/make-aptconf.sh" "$BRANCH" "$ARCH")" \
        || die "не удалось сгенерировать APTCONF (см. tools/make-aptconf.sh)"
    write_var APTCONF "$APTCONF" >> "$MK_VARS_FILE"
    iok "APTCONF: $APTCONF (зеркало ветки $BRANCH, независимо от хост-системы)"
else
    iwarn "USE_APTCONF=0: пакеты берутся из apt-настроек ХОСТА (результат невоспроизводим)"
fi

# --- итог ----------------------------------------------------------------------------
# отпечаток источников профиля: build.sh по нему решает, нужна ли пересборка
profile_fingerprint > "$PROFILE_FP_FILE"
iok "профиль готов. Для сборки образа выполните: scripts/build-iso.sh (или build.sh)"
echo "  метапрофиль : $MP_DIR" >&2
echo "  цель сборки : $TARGET" >&2
echo "  переменные  : $MK_VARS_FILE" >&2
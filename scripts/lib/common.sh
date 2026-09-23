#!/bin/bash
# =====================================================================
#  common.sh — общие функции и переменные набора для сборки
#  образа ALT Linux GNOME. Подключается во всех скриптах проекта:
#      source "$(dirname "$0")/lib/common.sh"
# =====================================================================

set -Eeuo pipefail

# --- корни проекта ----------------------------------------------------
_SELF="${BASH_SOURCE[0]}"
while [ -L "$_SELF" ]; do
    _target="$(readlink -- "$_SELF")"
    case "$_target" in
        /*) _SELF="$_target" ;;
        *)  _SELF="$(dirname -- "$_SELF")/$_target" ;;
    esac
done
SCRIPTS_DIR="$(cd -P -- "$(dirname -- "$_SELF")/.." && pwd)"
PROJ_ROOT="$(cd -P -- "${SCRIPTS_DIR}/.." && pwd)"

CONF_DIR="${PROJ_ROOT}/config"
WORK_DIR="${PROJ_ROOT}/work"
OUT_DIR="${PROJ_ROOT}/out"
TOOLS_DIR="${PROJ_ROOT}/tools"
BRANDING_FILES_TEMPLATE="${PROJ_ROOT}/profile/branding/files"

# сюда gen-profile.sh кладёт переменные make (командная строка главного make)
MK_VARS_FILE="${WORK_DIR}/mkimage-vars.cnf"

# --- настройки вывода -------------------------------------------------
use_color=true
if [ ! -t 2 ] || [ -z "${TERM:-}" ] || [ "$TERM" = "dumb" ]; then
    use_color=false
fi

_c() {
    [ "$use_color" = true ] || return 0
    printf '%s' "$1"
}
RESET="$(_c '\033[0m')"
BOLD="$(_c '\033[1m')"
RED="$(_c '\033[31m')"
GREEN="$(_c '\033[32m')"
YELLOW="$(_c '\033[33m')"
BLUE="$(_c '\033[34m')"

iprint() { printf '%s[ BUILD ]%s %s\n' "$BOLD$BLUE" "$RESET" "$*" >&2; }
iok()    { printf '%s[   OK  ]%s %s\n' "$BOLD$GREEN" "$RESET" "$*" >&2; }
iwarn()  { printf '%s[ WARN  ]%s %s\n' "$BOLD$YELLOW" "$RESET" "$*" >&2; }
ierr()   { printf '%s[ ERROR ]%s %s\n' "$BOLD$RED" "$RESET" "$*" >&2; }
die()    { ierr "$*"; exit 1; }

# --- загрузка конфигурации ---------------------------------------------
# Формат: KEY="value" либо KEY=value. Комментарии начинаются с '#'/';'.
# Значения с подстановками ($(...), `...`) отклоняются намеренно.
load_conf() {
    local file="$1" line key val
    [ -f "$file" ] || die "не найден файл конфигурации: $file"

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*|';'*) continue ;;
        esac
        case "$line" in
            *'='*) ;;
            *) iwarn "$file: пропущена строка без '=': $line"; continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        case "$key" in
            [A-Za-z_][A-Za-z0-9_]*) ;;
            *) iwarn "$file: некорректное имя переменной: $key"; continue ;;
        esac
        case "$val" in
            *'$('*|*'`'*)
                iwarn "$file: отклонена строка с подстановкой: $line"
                continue ;;
        esac
        # срезаем обрамляющие одинарные/двойные кавычки
        case "$val" in
            \"*\") val="${val%\"}"; val="${val#\"}" ;;
            \'*\') val="${val%\'}"; val="${val#\'}" ;;
        esac
        eval "__cf_${key}=\$val"
    done < "$file"
}

# получить значение ранее загруженной переменной
get_conf() { # get_conf KEY [default]
    local key="$1" default="${2:-}"
    local var="__cf_${key}"
    [ -n "${!var:-}" ] && printf '%s' "${!var}" || printf '%s' "$default"
}

# применить переопределения конфигурации, пришедшие из окружения
# (ALT_GNOME_<КЛЮЧ>=значение; устанавливает scripts/build.sh по ключам
# --branch/--arch/--desktop/--target/--out и передаёт вложенным скриптам:
# gen-profile.sh, build-iso.sh), вызовы load_conf в каждом процессе читают
# свои конфиг-файлы, поэтому переопределения должны применяться явно.
config_env_override() { # config_env_override КЛЮЧ [КЛЮЧ...]
    local key var val
    for key in "$@"; do
        var="ALT_GNOME_${key}"
        val="${!var:-}"
        [ -n "$val" ] || continue
        eval "__cf_${key}=\$val"
        iok "переопределено из окружения: $key=$val"
    done
}

# --- работа с каталогами -------------------------------------------------
# синхронизация каталога: rsync если есть, иначе эквивалент через cp
if command -v rsync >/dev/null 2>&1; then
    _SYNC_MODE=rsync
else
    _SYNC_MODE=cp
fi

# overlay_dir <src> <dst>  — ДОПОЛНЕНИЕ содержимого src к dst (merge без
# удаления чужих файлов; в отличие от rsync --delete это безопасно для
# наложения пользовательского overlay на метапрофиль, где в тех же
# каталогах лежат штатные файлы mkimage-profiles).
_overlay_rsync() { rsync -a "$1/" "$2/"; }
_overlay_cp() {
    local src="$1" dst="$2"
    mkdir -p -- "$dst"
    cp -a -- "$src/." "$dst/"
}
overlay_dir() { # overlay_dir <src> <dst>
    [ -d "$1" ] || die "overlay_dir: каталог не найден: $1"
    mkdir -p -- "$2"
    case "$_SYNC_MODE" in
        rsync) _overlay_rsync "$1" "$2" ;;
        *)     _overlay_cp "$1" "$2" ;;
    esac
}

# sync_dir <src/> <dst/>  — выравнивание каталогов (экв. rsync -a --delete)
_sync_rsync() { rsync -a --delete "$1/" "$2/"; }
_sync_cp() {
    local src="$1" dst="$2"
    rm -rf -- "$dst"
    mkdir -p -- "$dst"
    cp -a -- "$src/." "$dst/"
}
sync_dir() { # sync_dir <src> <dst>
    [ -d "$1" ] || die "sync_dir: каталог не найден: $1"
    mkdir -p -- "$2"
    case "$_SYNC_MODE" in
        rsync) _sync_rsync "$1" "$2" ;;
        *)     _sync_cp "$1" "$2" ;;
    esac
}

# --- отпечатки источников (условие пересборки профиля/брендинга) --------------
# Изменение конфигурации, шаблонов профиля или каталога брендинга должно
# приводить к пересборке профиля/брендинг-пакетов. Отпечаток считается по
# содержимому файлов (detached-порядок), поэтому не зависит от mtime.
PROFILE_FP_FILE="${WORK_DIR}/.profile-fingerprint.sha"
BRAND_FP_FILE="${WORK_DIR}/.branding-fingerprint.sha"

fp_dirs() { # fp_dirs <каталог|файл>... — стабильный отпечаток дерева
    local d
    { for d in "$@"; do [ -e "$d" ] && find "$d" -type f -print0 2>/dev/null; done; } \
        | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print $1}'
}
profile_fingerprint() { # что влияет на сформированный профиль (conf.d/999-*)
    # отпечаток считаем по содержимому ФАЙЛОВ-источников И по действующим
    # значениям, влияющим на рендер (в т.ч. runtime-переопределения из
    # ALT_GNOME_*: например DESKTOP=cinnamon при неизменённом файле).
    {
        fp_dirs \
            "$CONF_DIR" \
            "$PROJ_ROOT/profile" \
            "$SCRIPTS_DIR/gen-profile.sh" \
            "$TOOLS_DIR/make-aptconf.sh"
        printf 'DESKTOP=%s\n' "$(desktop_canon "$(get_conf DESKTOP gnome)")"
        printf 'TARGET=%s\n'  "$(get_conf TARGET "")"
        printf 'BRANCH=%s\n'  "$(get_conf BRANCH '')"
        printf 'ARCH=%s\n'    "$(get_conf ARCH '')"
    } | sha256sum | awk '{print $1}'
}
brand_fingerprint() { # что влияет на брендинг-пакеты (branding-template/)
    fp_dirs "$PROJ_ROOT/branding-template"
}

branding_template_has_content() { # есть ли реальные файлы в branding-template/
    [ -n "$(find "$PROJ_ROOT/branding-template" -mindepth 1 -type f \
             ! -name README.md -print -quit 2>/dev/null)" ]
}

# --- прочие утилиты -----------------------------------------------------
assert_tool() { # assert_tool имя [имя...]
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || die "не найдена программа '$t'; установите её (см. README.md)"
    done
}

tool_present() { command -v "$1" >/dev/null 2>&1; }

date_stamp() { date +%Y%m%d; }

# безопасное удаление (не разрешаем удалять корень или проект)
rm_project() { # rm_project <каталог-внутри-проекта>
    local dir="$1"
    case "$dir" in
        /|"$PROJ_ROOT") die "rm_project: отказ удалять '$dir'" ;;
    esac
    [ -d "$dir" ] && rm -rf -- "$dir"
    return 0
}

# --- выбор графического окружения (config/build.conf, DESKTOP=) -------------------
# Допустимые значения: gnome | cinnamon | plasma (kde — синоним plasma).
desktop_canon() { # desktop_canon <значение> -> каноническое имя DE
    case "${1:-}" in
        plasma|kde) printf '%s' plasma ;;
        *)          printf '%s' "${1:-}" ;;
    esac
}
desktop_parent() { # desktop_parent <DE> -> regular-* (без префикса distro/; или код 1)
    case "${1:-}" in
        gnome)    printf '%s' regular-gnome    ;;
        cinnamon) printf '%s' regular-cinnamon ;;
        plasma)   printf '%s' regular-kde      ;;
        *) return 1 ;;
    esac
}
desktop_mixin() { # desktop_mixin <DE> -> mixin/regular-* (или код 1)
    case "${1:-}" in
        gnome)    printf '%s' mixin/regular-gnome    ;;
        cinnamon) printf '%s' mixin/regular-cinnamon ;;
        plasma)   printf '%s' mixin/regular-kde      ;;
        *) return 1 ;;
    esac
}
desktop_valid() { # desktop_valid <DE> — верная ли DE (для проверок и die)
    desktop_parent "$1" >/dev/null 2>&1
}
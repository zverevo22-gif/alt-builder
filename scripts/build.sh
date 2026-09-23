#!/bin/bash
# ============================================================================
#  build.sh — главный сценарий сборки установочного ISO-образа
#             ALT Linux GNOME Edition (с учётом брендинга и состава ПО)
#
#  Использование:
#      ./build.sh [опции]
#
#  Опции:
#      -t, --target ЦЕЛЬ   цель mkimage-profiles (по умолчанию из конфигурации)
#      -d, --desktop DE    окружение: gnome | cinnamon | plasma (без -d — спросит)
#      -b, --branch ВЕТКА  ветка: sisyphus | p10 | p9 (перекрывает config)
#      -a, --arch АРХ      архитектура: i586 | x86_64 | aarch64 | armh
#          --setup         установить/подготовить окружение (ALT или контейнер)
#          --check[=N]     проверка конфигурации без сборки образа (N: 0|1)
#          --debug         отладочный режим сборки (DEBUG=1)
#          --clean         предварительно убрать рабочее состояние
#          --no-build      подготовить профиль, но образ не собирать
#          --selfcheck     выполнить самопроверку набора
#      -o, --out КАТАЛОГ   каталог для готовых ISO (перекрывает config)
#      -u, --user ИМЯ      пользователь, которому выдаются права hasher (--setup)
#      -h, --help          эта справка
#
#  На ALT Linux и внутри подготовленного контейнера скрипт выполняется
#  непосредственно; на чистом Debian/Host он автоматически запускает сборку
#  в ALT-контейнере (см. scripts/env-setup-debian.sh).
# ============================================================================

source "$(dirname "$0")/lib/common.sh"

SETUP=0
NO_BUILD=0
CLEAN=0
SELFCHECK=0
DEBUG_OPT=""
CHECK_OPT=""
TARGET_OPT=""
DESKTOP_OPT=""
BRANCH_OPT=""
ARCH_OPT=""
OUT_OPT=""
USER_OPT=""

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --setup) SETUP=1 ;;
        --no-build) NO_BUILD=1 ;;
        --clean) CLEAN=1 ;;
        --debug) DEBUG_OPT=1 ;;
        --selfcheck) SELFCHECK=1 ;;
        --check) CHECK_OPT=1 ;;
        --check=*) CHECK_OPT="${1#*=}"; [ -n "$CHECK_OPT" ] || CHECK_OPT=1 ;;
        -t|--target) TARGET_OPT="${2:?--target требует значение}"; shift ;;
        -d|--desktop) DESKTOP_OPT="${2:?--desktop требует значение}"; shift ;;
        -b|--branch) BRANCH_OPT="${2:?--branch требует значение}"; shift ;;
        -a|--arch)   ARCH_OPT="${2:?--arch требует значение}"; shift ;;
        -o|--out)    OUT_OPT="${2:?--out требует значение}"; shift ;;
        -u|--user)   USER_OPT="${2:?--user требует значение}"; shift ;;
        *) die "неизвестная опция: $1 (запустите $0 --help)" ;;
    esac
    shift
done

load_conf "${CONF_DIR}/build.conf"
load_conf "${CONF_DIR}/branding.conf"
load_conf "${CONF_DIR}/packages.conf"

if [ -n "$TARGET_OPT" ]; then
    case "$TARGET_OPT" in
        distro/*.iso) ;;
        *) TARGET_OPT="distro/${TARGET_OPT%.iso}.iso" ;;
    esac
fi

# --- определение платформы ---------------------------------------------------
detect_platform() {
    if [ "${ALT_GNOME_IN_CONTAINER:-0}" = "1" ]; then echo alt; return; fi
    [ -f /etc/altlinux-release ] && { echo alt; return; }
    if [ -r /etc/os-release ]; then
        local id
        id="$(. /etc/os-release; echo "${ID:-unknown}")"
        case "$id" in
            altlinux) echo alt; return ;;
            debian|ubuntu|linuxmint|pop) echo debian; return ;;
            *) ;;
        esac
    fi
    # неизвестная система: по умолчанию считаем, что это ALT-совместимая
    if command -v rpm >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        echo alt
    else
        echo debian
    fi
}
PLATFORM="$(detect_platform)"

if [ "$SELFCHECK" = "1" ]; then
    exec bash "$SCRIPTS_DIR/selfcheck.sh"
fi

# --- подготовка окружения ------------------------------------------------------
if [ "$SETUP" = "1" ]; then
    if [ "$PLATFORM" = "alt" ]; then
        # пользователь сборки: явный --user > $SUDO_USER > (диалог внутри env-setup).
        # root сюда не годятся: сборочный пользователь обязан быть обычным.
        local_user="${USER_OPT:-${SUDO_USER:-}}"
        [ "$local_user" = "root" ] && local_user=""
        if [ -n "$local_user" ]; then
            sudo bash "$SCRIPTS_DIR/env-setup-alt.sh" "$local_user" \
                || die "сбой подготовки окружения ALT"
        else
            sudo bash "$SCRIPTS_DIR/env-setup-alt.sh" \
                || die "сбой подготовки окружения ALT"
        fi
    else
        bash "$SCRIPTS_DIR/env-setup-debian.sh" \
            || die "сбой подготовки окружения Debian/контейнера"
    fi
    if [ "$NO_BUILD" = "1" ]; then exit 0; fi
fi

# --- самоперенос в ALT-контейнер (для Debian-хоста) -----------------------------
wrap_in_container() {
    # повторный вход скрипта внутри подготовленного ALT-контейнера
    local runner
    command -v podman >/dev/null 2>&1 && runner=podman \
        || { command -v docker >/dev/null 2>&1 && runner=docker || return 1 ; }
    local wrap="${PROJ_ROOT}/work/debian/run-in-container.sh"
    [ -x "$wrap" ] || {
        iwarn "ALT-контейнер не подготовлен; выполните: scripts/build.sh --setup"
        return 1
    }
    iprint "переносим сборку в ALT-контейнер ($runner)"
    exec "$wrap" bash /build/scripts/build.sh "$@"
}
if [ "$PLATFORM" != "alt" ] && [ "${ALT_GNOME_IN_CONTAINER:-0}" != "1" ]; then
    wrap_in_container "$@" || die "для сборки на Debian требуется ALT-контейнер (см. README.md, раздел Debian)"
fi

# --- базовая проверка окружения --------------------------------------------------
assert_tool git bash
if [ "$NO_BUILD" = "0" ]; then
    assert_tool make
    if [ "$(id -u)" = "0" ]; then
        iwarn "запуск от root; для реальной сборки позже потребуется обычный пользователь (см. ниже)"
    elif ! id -nG | grep -Eqw 'hashman|hasher' 2>/dev/null; then
        iwarn "текущий пользователь не в группе hashman/hasher (группа применяется при входе; см. README)"
    fi

    # доступ к конфигурации hasher-priv. Если его нет, mktmpdir падает
    # невнятным "getconf.sh: Отказано в доступе / allowed_mountpoints do not
    # include /proc". Ловим это заранее и говорим, что делать.
    if [ "$(id -u)" != "0" ]; then
        getconf=/usr/libexec/hasher-priv/getconf.sh
        if ! "$getconf" >/dev/null 2>&1; then
            die "hasher-priv недоступен для $USER (пакет hasher не установлен, helper'ы без бита
исполнения или вы не в группе hashman/hasher). Выполните от root, затем НОВЫЙ ВХОД:
    sudo scripts/build.sh --setup
(сценарий доставит пакеты, добавит вас в группу hashman/hasher, поправит права
/usr/libexec/hasher-priv/*.sh и напечатает результат контрольного прогона getconf.sh
от вашего имени)."
        fi
        if ! grep -wqs '^allowed_mountpoints=[^#]*/proc' /etc/hasher-priv/system; then
            die "в /etc/hasher-priv/system нет разрешения монтировать /proc (mktmpdir без него не работает).
Настройте (от root) или выполните:
    sudo scripts/build.sh --setup
Проверка: grep 'allowed_mountpoints' /etc/hasher-priv/system"
        fi
    fi
fi

# --- права на каталоги проекта (не root, а в work/ лежит чужое) ------------------
if [ "$(id -u)" != "0" ]; then
    if [ -d "$WORK_DIR" ] && \
       find "$WORK_DIR" ! -user "$(id -un)" -print -quit 2>/dev/null | grep -q .; then
        die "в $WORK_DIR есть файлы другого владельца (обычно - прошлый запуск от root). Сценарий не сможет их перезаписать. Выполните от root:
    sudo chown -R \"\$(id -un)\":\"$(id -gn)\" \"$PROJ_ROOT\""
    fi
fi

# --- перекрытия конфигурации -------------------------------------------------------
# Переопределения передаются вложенным скриптам (gen-profile.sh, build-iso.sh)
# НЕ через shell-переменные (их бы тут же перезаписал load_conf в дочернем
# процессе), а через переменные окружения ALT_GNOME_<КЛЮЧ>, которые те затем
# применяют вызовом config_env_override.
[ -n "$BRANCH_OPT" ]  && export ALT_GNOME_BRANCH="$BRANCH_OPT"
[ -n "$ARCH_OPT" ]    && export ALT_GNOME_ARCH="$ARCH_OPT"
[ -n "$OUT_OPT" ]     && export ALT_GNOME_IMAGEDIR="$OUT_OPT"
[ -n "$DESKTOP_OPT" ] && export ALT_GNOME_DESKTOP="$DESKTOP_OPT"
[ -n "$TARGET_OPT" ]  && export ALT_GNOME_TARGET="$TARGET_OPT"

# выбор графического окружения перед сборкой -------------------------------
# 1) ключ --desktop; 2) иначе диалог (если можно читать с терминала);
# 3) иначе значение из config/build.conf (DESKTOP=). Канонизация: plasma|kde.
if [ -z "${ALT_GNOME_DESKTOP:-}" ] && [ -t 0 ] && [ "${NO_BUILD:-0}" = "0" ] \
   && [ "${SETUP:-0}" = "0" ] && [ "${SELFCHECK:-0}" = "0" ]; then
    _dflt_de="$(get_conf DESKTOP gnome | tr '[:upper:]' '[:lower:]')"
    _dflt_de="${_dflt_de:-gnome}"
    printf '%s[ BUILD ]%s выберите графическое окружение (Enter = %s):\n 1) gnome\n 2) cinnamon\n 3) plasma\n> ' \
        "$BOLD$BLUE" "$RESET" "$_dflt_de" >&2
    IFS= read -r _de_choice || true
    DESKTOP_OPT="${_de_choice:-$_dflt_de}"
    case "$DESKTOP_OPT" in
        1|gnome)    DESKTOP_OPT=gnome ;;
        2|cinnamon) DESKTOP_OPT=cinnamon ;;
        3|plasma|kde) DESKTOP_OPT=plasma ;;
    esac
    desktop_valid "$DESKTOP_OPT" \
        || die "DE='$DESKTOP_OPT' неизвестен (допустимо: gnome|2|cinnamon|3|plasma)"
    export ALT_GNOME_DESKTOP="$DESKTOP_OPT"
    iok "выбрано окружение: $DESKTOP_OPT"
    unset _de_choice _dflt_de
fi

# применяем переопределения в этом же процессе (для корректных сообщений ниже)
config_env_override DESKTOP TARGET BRANCH ARCH IMAGEDIR >/dev/null 2>&1 || true

# --- очистка ------------------------------------------------------------------------
if [ "$CLEAN" = "1" ]; then
    iprint "очистка рабочего состояния"
    bash "$SCRIPTS_DIR/clean.sh" || true
fi

# --- формирование профиля ------------------------------------------------------------
iprint "формирование профиля (BRANCH=$(get_conf BRANCH p11), ARCH=$(get_conf ARCH x86_64), DE=$(get_conf DESKTOP gnome))"

# --- собственный брендинг (BRANDING_MODE=repo) --------------------------------------
# Если в branding-template/ есть содержимое, а режим брендинга НЕ repo, это содержимое
# (в т.ч. картинки рабочего стола) в образ НЕ попадёт — честно предупреждаем сразу.
BRANDING_MODE="$(get_conf BRANDING_MODE auto)"
if branding_template_has_content && [ "$BRANDING_MODE" != "repo" ]; then
    iwarn "в branding-template/ есть содержимое (в т.ч. графика рабочего стола), но BRANDING_MODE=$BRANDING_MODE."
    iwarn "это содержимое НЕ будет использовано в образе; для включения укажите BRANDING_MODE=repo"
    iwarn "и имя вашего бренда BRANDING=... (config/branding.conf), либо очистите branding-template/."
fi

# Пересборка пакетов брендинга выполняется ТОЛЬКО при реальном изменении источников
# (отпечаток branding-template/), а не при каждом прогоне сборки.
if [ "$BRANDING_MODE" = "repo" ] && branding_template_has_content; then
    _brand_prev="$(cat "$BRAND_FP_FILE" 2>/dev/null || true)"
    _brand_now="$(brand_fingerprint)"
    _local_repo="$(get_conf BRANDING_LOCAL_REPO work/apt.d/localrepo)"
    case "$_local_repo" in /*) ;; *) _local_repo="${PROJ_ROOT}/$_local_repo" ;; esac
    if [ "$_brand_prev" = "$_brand_now" ] \
       && [ -d "$_local_repo" ] \
       && compgen -G "$_local_repo/RPMS.classic/branding-*.rpm" >/dev/null 2>&1; then
        iok "пакеты брендинга актуальны (branding-template не менялся): $_local_repo"
    else
        iprint "изменён branding-template/ — пересобираю собственные пакеты брендинга"
        bash "$TOOLS_DIR/mk-branding.sh" \
                --theme="$(get_conf BRANDING alt-starterkit)" \
                --name="$(get_conf RELNAME 'ALT GNOME')" \
            || die "сборка собственных пакетов брендинга не удалась (BRANDING_MODE=repo)"
        printf '%s\n' "$_brand_now" > "$BRAND_FP_FILE"
        iok "пакеты брендинга пересобраны и помещены в $_local_repo"
    fi
    unset _brand_prev _brand_now _local_repo
fi

# Формирование профиля выполняется ТОЛЬКО при изменении конфигурации и шаблонов
# (config/, profile/, скрипты формирования) — по отпечатку, а не при каждом прогоне.
_mp_dir="${MP_DIR:-${WORK_DIR}/mkimage-profiles}"
_profile_prev="$(cat "$PROFILE_FP_FILE" 2>/dev/null || true)"
_profile_now="$(profile_fingerprint)"
if [ -s "$_mp_dir/main.mk" ] && [ -s "$_mp_dir/conf.d/999-alt-desktop.mk" ] \
   && [ -n "$_profile_prev" ] && [ "$_profile_prev" = "$_profile_now" ]; then
    iok "конфигурация и шаблоны не менялись — профиль актуален, повторное формирование не нужно"
else
    iwarn "обнаружены изменения в конфигурации/шаблонах либо профиль отсутствует — формирую"
    bash "$SCRIPTS_DIR/gen-profile.sh" || die "формирование профиля не удалось"
fi
unset _mp_dir _profile_prev _profile_now

[ "$NO_BUILD" = "1" ] && { iok "профиль подготовлен (--no-build); образ не собран"; exit 0; }

# mkimage/hasher НЕ предназначены для работы от root: обязателен обычный
# пользователь с правами hasher (см. README, env-setup-alt.sh). Обойти можно
# только явным ALT_GNOME_ALLOW_ROOT=1 (для экспериментов, рискованно).
if [ "$(id -u)" = "0" ] && [ "${ALT_GNOME_ALLOW_ROOT:-0}" != "1" ]; then
    die "сборка должна выполняться от обычного пользователя с правами hasher.
   Подготовка (один раз, от root):
       sudo scripts/env-setup-alt.sh ПОЛЬЗОВАТЕЛЬ
   затем от этого пользователя:
       scripts/build.sh"
fi

# --- сборка -----------------------------------------------------------------------------
rc=0
if [ "${CHECK_OPT:-0}" != "0" ]; then
    iprint "проверка конфигурации (CHECK=${CHECK_OPT:-1})"
    CHECK="${CHECK_OPT:-1}" "$SCRIPTS_DIR/build-iso.sh" || rc=$?
else
    if [ -n "$DEBUG_OPT" ]; then DEBUG=1 "$SCRIPTS_DIR/build-iso.sh" || rc=$?
    else "$SCRIPTS_DIR/build-iso.sh" || rc=$?
    fi
fi

if [ "$rc" = "0" ]; then
    iok "готово. Готовые образы: ${OUT_OPT:-$(get_conf IMAGEDIR "$OUT_DIR")}"
    # --- очистка истории сборки (по окончании, только после успеха) ---
    # AUTOCLEAN=1 (или пусто в DEBUG): удаляем большое временное BUILD-дерево
    # mkimage (экономия нескольких ГБ) и ротируем журналы сборки (оставляем последние).
    _autoclean="$(get_conf AUTOCLEAN 1)"
    if [ -z "${DEBUG_OPT:-}" ] && [ "$_autoclean" != "0" ]; then
        iprint "очистка истории сборки (AUTOCLEAN=${_autoclean:-1})"
        if [ -d "$WORK_DIR/mkimage-profiles.build" ]; then
            rm_project "$WORK_DIR/mkimage-profiles.build"
            iok "   удалено BUILD-дерево mkimage: $WORK_DIR/mkimage-profiles.build"
        fi
        # журналы: оставляем 3 последних
        if command -v ls >/dev/null 2>&1; then
            ls -1t "$OUT_DIR"/build-*.log 2>/dev/null | tail -n +4 \
                | while read -r _log; do rm -f -- "$_log"; done
        fi
    fi
    unset _autoclean
else
    ierr "сборка завершилась с ошибкой (код $rc)"
fi
exit "$rc"
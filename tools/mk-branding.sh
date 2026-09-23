#!/bin/bash
# ============================================================================
#  mk-branding.sh — сборка собственного пакета брендинга (режим repo)
#
#  Собирает из branding-template/ (или заданного каталога) исходные RPM с
#  субпакетами branding-<THEME>-{alterator,bootsplash,bootloader,graphics,
#  indexhtml,notes,release,slideshow}, а затем формирует ЛОКАЛЬНЫЙ репозиторий
#  для ALT apt (work/apt.d/localrepo), который подключается сборкой вместо
#  сетевого зеркала (см. config: BRANDING_MODE=repo, APT_MIRROR=file://...).
#
#  Использование:
#      tools/mk-branding.sh [опции]
#        --theme=ИМЯ          техническое имя (по умолчанию: из BRANDING)
#        --name="Читаемое"    рассматриваемое имя (по умолчанию: ALT GNOME)
#        --codename=КОД       кодовое имя
#        --dir=КАТАЛОГ        каталог источников (по умолчанию branding-template/)
#        --version=N          версия пакета (по умолчанию 1.0.0)
#        --release=ALTN       релиз (по умолчанию alt1)
#        --srpm-only          собрать только src.rpm (без бинарных)
#        --tag=МЕТКА          подпись релиза репозитория
#
#  Запускать на ALT Linux или внутри подготовленного ALT-контейнера.
#  Требуются: rpm-build, rpm-macros-branding, genbasedir (apt-utils) [кроме
#  --srpm-only].
# ============================================================================

set -Eeuo pipefail

PROJ_ROOT="$(cd -P -- "$(dirname "$0")/.." && pwd)"
source "$PROJ_ROOT/scripts/lib/common.sh"
assert_tool rpmbuild

THEME=""
NAME="ALT GNOME"
CODENAME="veles"
SRC_DIR="${PROJ_ROOT}/branding-template"
VERSION="1.0.0"
RELEASE="alt1"
SRPM_ONLY=0
TAG="local"

while [ $# -gt 0 ]; do
    case "$1" in
        --theme=*)    THEME="${1#*=}" ;;
        --name=*)     NAME="${1#*=}" ;;
        --codename=*) CODENAME="${1#*=}" ;;
        --dir=*)      SRC_DIR="${1#*=}" ;;
        --version=*)  VERSION="${1#*=}" ;;
        --release=*)  RELEASE="${1#*=}" ;;
        --srpm-only)  SRPM_ONLY=1 ;;
        --tag=*)      TAG="${1#*=}" ;;
        --help|-h)    sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//' ; exit 0 ;;
        *) echo "неизвестная опция: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -d "$SRC_DIR" ] || { echo "каталог источников не найден: $SRC_DIR" >&2; exit 1; }
if [ -z "$THEME" ]; then
    load_conf "$PROJ_ROOT/config/branding.conf"
    THEME="$(get_conf BRANDING alt-starterkit)"
fi
[ -z "$THEME" ] && THEME="mydistro"

WORK="${PROJ_ROOT}/work/branding"
rm -rf "$WORK"
mkdir -p "$WORK"/{SOURCES,SPECS,SRPMS,RPMS,REPO/RPMS.classic}

# --- источник: tarball branding.tar из каталога ---
STAGE="$WORK/src"
mkdir -p "$STAGE/branding"
cp -a "$SRC_DIR/." "$STAGE/branding/"
rm -f "$STAGE/branding/branding.spec.in" "$STAGE/branding/README.md"

# Каталоги, на которые ссылаются %files (их отсутствие = ошибка rpmbuild).
# Пустые каталоги в tar допустимы; содержимое добавляется заказчиком.
for d in bootloader bootsplash/plymouth bootsplash/bootsplash alterator \
         graphics notes indexhtml slideshow release; do
    mkdir -p "$STAGE/branding/$d"
done

# os-release по умолчанию (если не задан в каталоге источников): переносит
# NAME (--name) в /usr/lib/os-release собранного пакета branding-*-release.
if [ ! -s "$STAGE/branding/release/os-release" ]; then
    cat > "$STAGE/branding/release/os-release" <<EOF
NAME="${NAME}"
ID=altlinux
ID_LIKE=altlinux
VARIANT_ID=altlinux
PRETTY_NAME="${NAME}"
ANSI_COLOR="1;34"
HOME_URL="https://altlinux.org/"
SUPPORT_URL="https://altlinux.org/support"
BUG_REPORT_URL="https://bugzilla.altlinux.org/"
EOF
else
    # заданные пользователем файлы: подставляем макросы, как в spec
    sed -i \
        -e "s#%%THEME%%#${THEME}#g" \
        -e "s#%%NAME%%#${NAME}#g" \
        -e "s#%%CODENAME%%#${CODENAME}#g" \
        -e "s#%%VERSION%%#${VERSION}#g" \
        -e "s#%%RELEASE%%#${RELEASE}#g" \
        "$STAGE/branding/release/os-release"
fi

tar -C "$STAGE" -cf "$WORK/SOURCES/branding.tar" branding

# --- сгенерированный spec ---
SPEC="$WORK/SPECS/branding-$THEME.spec"
sed \
    -e "s#%%THEME%%#${THEME}#g" \
    -e "s#%%NAME%%#${NAME}#g" \
    -e "s#%%CODENAME%%#${CODENAME}#g" \
    -e "s#%%VERSION%%#${VERSION}#g" \
    -e "s#%%RELEASE%%#${RELEASE}#g" \
    "$PROJ_ROOT/branding-template/branding.spec.in" > "$SPEC"

RPMMACROS=(--define "_topdir $WORK" --define "distro $TAG")

# --- src.rpm ---
echo "==> собираю src.rpm: branding-${THEME}-${VERSION}-${RELEASE}"
rpmbuild "${RPMMACROS[@]}" -bs "$SPEC" \
    || { echo "нет rpm-build или ошибка сборки src.rpm" >&2; exit 1; }

echo "==> src.rpm: $WORK/SRPMS/branding-${THEME}-${VERSION}-${RELEASE}.src.rpm"
if [ "$SRPM_ONLY" = "1" ]; then exit 0; fi

# --- бинарные пакеты ---
echo "==> собираю бинарные пакеты (rpmbuild -ba)"
rpmbuild "${RPMMACROS[@]}" -ba "$SPEC" \
    || { echo "ошибка сборки бинарных пакетов; смотрите конец вывода rpmbuild" >&2; exit 1; }

# --- локальный apt-репозиторий ---
REPO="${PROJ_ROOT}/work/apt.d/localrepo"
rm -rf "$REPO"
mkdir -p "$REPO/RPMS.classic"
cp "$WORK"/RPMS/*/branding-${THEME}-*.rpm "$REPO/RPMS.classic/" 2>/dev/null || true
if command -v genbasedir >/dev/null 2>&1; then
    genbasedir --bloat "$REPO" || genbasedir "$REPO"
else
    echo "!! genbasedir не найден (нужен пакет apt-utils); репозиторий не проиндексирован" >&2
    echo "   rpm-файлы лежат в $REPO/RPMS.classic/" >&2
    exit 1
fi
echo
cat <<EOF
==> Готово. Локальный репозиторий: $REPO
    Собранные пакеты:
EOF
ls -1 "$REPO/RPMS.classic/"
echo
cat <<EOF
    Подключение к сборке (config/branding.conf и config/build.conf):
        BRANDING_MODE=repo
        BRANDING=$THEME
        BRANDING_LOCAL_REPO="work/apt.d/localrepo"   # по умолчанию, менять не нужно
    Локальный репозиторий добавляется в apt автоматически (ДОПОЛНИТЕЛЬНО к
    основному зеркалу ветки, источник "local" без проверки подписи). Повторно
    mk-branding.sh можно не запускать: при изменении branding-template/ пакеты
    будут пересобраны сами перед очередной сборкой образа (scripts/build.sh).
EOF
#!/bin/bash
# ============================================================================
#  make-aptconf.sh — генерация APTCONF для hsh
#
#  Использование:
#      tools/make-aptconf.sh [ВЕТКА [АРХ]]     # значения по умолчанию: p10, x86_64
#
#  Печатает путь к файлу APTCONF.hsh (в work/apt.d/<ветка>-<арх>/), который
#  затем передаётся mkimage/hsh переменной APTCONF (mkimage-vars.cnf). Сам файл
#  ссылается на sources.list рядом с собой; оба лежат под /home, куда hasher
#  монтирует каталоги в chroot, поэтому пути сохраняются и внутри chroot.
#
#  sources.list использует зеркала http://mirror.yandex.ru/altlinux/ ;
#  переопределить можно переменными окружения:
#      APT_MIRROR=http://ftp.altlinux.org/pub/distributions/altlinux/
#      APT_PROTO=https | http
#
#  Вендор строки репозитория — имя целевой ветки ($BRANCH), а его ключ подписи
#  (см. vendors.list.d) совпадает с ключом, которым зеркало подписывает Release
#  этой ветки, поэтому проверка GPG проходит штатно без разрыва доверия.
#
#  Генерируемый APTCONF.hsh полностью изолирует сборку от apt-настроек
#  хост-системы (/etc/apt/{apt.conf,apt.conf.d,sources.list.d}): пакеты
#  берутся ТОЛЬКО из указанного зеркала целевой ветки, независимо от того,
#  на каком дистрибутиве запущена сборка.
# ============================================================================

set -Eeuo pipefail

BRANCH="${1:-p10}"
ARCH="${2:-x86_64}"

PROJ_ROOT="$(cd -P -- "$(dirname "$0")/.." && pwd)"
APT_DEST="$(printf '%s/work/apt.d/%s-%s' "$PROJ_ROOT" "$BRANCH" "$ARCH")"
mkdir -p "$APT_DEST"

proto="${APT_PROTO:-http}"
mirror="${APT_MIRROR:-$proto://mirror.yandex.ru/altlinux}"
[ "$mirror" = "$proto://" ] && mirror="$proto://mirror.yandex.ru/altlinux"

# Путь до репозитория внутри зеркала (относительно корня зеркала) и компонент.
# Грамматика строки apt (как в /etc/apt/sources.list.d/alt.list дистрибутива):
#     rpm [<vendor>] <корень-зеркала> <путь>/<архитектура> <компонент>
# Физическая раскладка: <корень>/<путь>/<арх>/RPMS.<компонент> (+ base/).
# <vendor> обязан быть описан в vendors.list.d (иначе "Unknown vendor ID").
comp="classic"
case "$BRANCH" in
    sisyphus) relpath="Sisyphus" ;;
    p8|p9|p10|p11) relpath="$BRANCH/branch" ;;
    *) relpath="$BRANCH" ;;
esac
if [ "${mirror#file://}" != "$mirror" ]; then
    # локальный репозиторий genbasedir (tools/mk-branding.sh): плоская
    # структура <каталог>/<арх>/base
    relpath=""
    comp="base"
fi

# Основная строка + строка для noarch-пакетов (в сетевых зеркалах есть noarch/).
if [ -n "$relpath" ]; then
    cat > "$APT_DEST/sources.list" <<EOF
rpm [$BRANCH] $mirror $relpath/$ARCH $comp
rpm [$BRANCH] $mirror $relpath/noarch $comp
EOF
else
    cat > "$APT_DEST/sources.list" <<EOF
rpm [$BRANCH] $mirror $ARCH $comp
EOF
fi

# Дополнительный ЛОКАЛЬНЫЙ репозиторий (например, собственные
# брендинг-пакеты из tools/mk-branding.sh). В отличие от APT_MIRROR=file://,
# он НЕ заменяет сетевой репозиторий, а добавляется к нему. Задаётся
# переменной окружения APT_EXTRA_MIRROR=file://<каталог> либо автоматически
# (BRANDING_MODE=repo в scripts/gen-profile.sh). Вендор "local" объявлен БЕЗ
# fingerprint, поэтому подпись такого репозитория не проверяется.
if [ -n "${APT_EXTRA_MIRROR:-}" ] && [ "${APT_EXTRA_MIRROR#file://}" != "$APT_EXTRA_MIRROR" ]; then
    cat >> "$APT_DEST/sources.list" <<EOF
rpm [local] ${APT_EXTRA_MIRROR} $ARCH base
EOF
    echo "APT_EXTRA_MIRROR=$APT_EXTRA_MIRROR подключён как доп. источник (без проверки подписи)" >&2
fi

# Официальные ключи подписи веток (те же, что в /etc/apt/vendors.list.d/alt.list
# дистрибутивов ALT). Вендором строки репозитория служит имя ветки, поэтому apt
# ожидает от зеркала подпись ровно этим ключом и проверка проходит штатно.
fpr=""
owner=""
case "$BRANCH" in
    p11)      fpr="EAE41587EB4583599E16A115E1130F0E925E1FF4"; owner="ALT p11 <alt-p11@altlinux.org>" ;;
    p10)      fpr="357BE37422F73D9CB3A0C8D142F343A2C7EB80F9"; owner="ALT p10 <alt-p10@altlinux.org>" ;;
    p9)       fpr="B285B93E53CCF43A860F45B22B6B82CB7AED4D09"; owner="ALT p9 <alt-p9@altlinux.org>" ;;
    p8)       fpr="64032F109FD0C4331F572CC0DC9E95C2231114B3"; owner="ALT p8 <alt-p8@altlinux.org>" ;;
    updates)  fpr="64032F109FD0C4331F572CC0DC9E95C2231114B3"; owner="ALT updates <updates@altlinux.org>" ;;
    sisyphus) fpr="DF6C02E5F174D7CDF792A9CDFF979DEDDA2773BB"; owner="ALT Sisyphus <alt-sisyphus@altlinux.org>" ;;
esac
[ -n "$fpr" ] || { echo "$0: для ветки $BRANCH нет ключа подписи в справочнике" >&2; exit 1; }

mkdir -p "$APT_DEST/vendors.list.d"
cat > "$APT_DEST/vendors.list.d/$BRANCH.list" <<EOF
simple-key "$BRANCH" {
	Fingerprint "$fpr";
	Name "$owner";
}
EOF
# вендор "local" для дополнительного локального репозитория (APT_EXTRA_MIRROR).
# Без Fingerprint apt не требует от этого репозитория подписи.
cat > "$APT_DEST/vendors.list.d/local.list" <<EOF
simple-key "local" {
	Name "Local";
}
EOF
printf '' > "$APT_DEST/vendors.list"

cat > "$APT_DEST/APTCONF.hsh" <<EOF
// Сгенерированный APTCONF для ветки $BRANCH/$ARCH.
// Отсекаем apt-конфигурацию хост-системы, чтобы сборка не зависела от того,
// какие репозитории настроены на машине, где выполняется сборка. Вендоры и
// ключи подписи берутся из $APT_DEST/vendors.list.d.
Dir::Etc::main "/dev/null";
Dir::Etc::parts "/var/empty";
Dir::Etc::SourceParts "/var/empty";
Dir::Etc::sourcelist "$APT_DEST/sources.list";
Dir::Etc::vendorlist "$APT_DEST/vendors.list";
Dir::Etc::vendorparts "$APT_DEST/vendors.list.d";
EOF

echo "$APT_DEST/APTCONF.hsh"
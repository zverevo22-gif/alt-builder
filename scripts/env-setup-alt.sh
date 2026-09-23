#!/bin/bash
# ============================================================================
#  env-setup-alt.sh — подготовка окружения сборки на ALT Linux
#
#  Запуск от root (либо вызывается из build.sh --setup через sudo):
#      sudo scripts/env-setup-alt.sh [ПОЛЬЗОВАТЕЛЬ]
#
#  ПОЛЬЗОВАТЕЛЬ — учётная запись, которой разрешается сборка через hasher.
#  Приоритет: аргумент > $SUDO_USER (кто вызвал sudo) > $logname. Если имени
#  нет вовсе — пользователя спросят в диалоге (или в неинтерактивном режиме
#  возьмётся "builder"). Отсутствующего пользователя скрипт предложит создать.
#
#  Что делает:
#    * устанавливает пакеты сборки: mkimage, mkimage-preinstall, hasher,
#      rsync, git-core, make и проч.;
#    * разрешает пользователю работу с hasher;
#    * создаёт служебные каталоги ~/out и ~/tmp;
#    * печатает совет про tmpfs.
# ============================================================================

set -Eeuo pipefail

[ "$(id -u)" = "0" ] || { echo "требуются права root (sudo $0 ...)" >&2; exit 1; }

# --- пользователь сборки (диалог, если не задан) -------------------------------
# приоритет: аргумент $1 > $SUDO_USER > $logname > интерактивный запрос > builder
dialog_in_path() { # рабочий терминал (/dev/tty),/dev/stdin, или '' если нет tty
    local t
    if { exec 9<>/dev/tty; } 2>/dev/null; then
        exec 9>&- 9<&-
        echo /dev/tty
        return 0
    fi
    if [ -t 0 ]; then echo /dev/stdin; return 0; fi
    return 1
}

ask_build_user() { # ask_build_user [подсказка-по-умолчанию] -> имя или '' (нет tty)
    local hint="${1:-builder}" u inp
    inp="$(dialog_in_path)" || return 1
    printf 'Пользователь для сборки через hasher (Enter = %s): ' "$hint" > "$inp" 2>/dev/null || return 1
    if IFS= read -r u < "$inp" 2>/dev/null; then
        [ -n "$u" ] && printf '%s' "$u" || printf '%s' "$hint"
        return 0
    fi
    return 1
}

user_ensure_exists() { # user_ensure_exists ИМЯ — создаёт пользователя, если нужно
    if getent passwd "$1" >/dev/null 2>&1; then return 0; fi
    local y inp
    inp="$(dialog_in_path)" || {
        echo "!! пользователь '$1' не существует; создайте его или передайте имя аргументом" >&2
        return 1
    }
    printf 'Пользователя %s нет. Создать (useradd -m -G hasher %s)? [Y/n]: ' "$1" "$1" > "$inp" 2>/dev/null || return 1
    IFS= read -r y < "$inp" || y=Y
    case "$y" in
        ''|y|Y|д|Д) useradd -m -s /bin/bash -G hasher "$1" ; echo "==> создан пользователь $1" ;;
        *) echo "==> создание пропущено; пользователь $1 не настроен" ;;
    esac
}

echo "==> ALT Linux: подготовка окружения сборки"

BUILD_USER="${1:-${SUDO_USER:-}}"
[ "$BUILD_USER" = "root" ] && BUILD_USER=""
if [ -n "${1:-}" ] && [ "$1" != "root" ]; then
    echo "    пользователь сборки: $BUILD_USER (из аргумента)"
elif [ -n "$BUILD_USER" ] && [ "$BUILD_USER" != "root" ]; then
    echo "    пользователь сборки: $BUILD_USER (из SUDO_USER)"
elif LOGNAME_USER="$(logname 2>/dev/null || true)" && [ -n "$LOGNAME_USER" ] && [ "$LOGNAME_USER" != "root" ]; then
    BUILD_USER="$LOGNAME_USER"
    echo "    пользователь сборки: $BUILD_USER (из logname)"
fi
if [ -z "$BUILD_USER" ]; then
    if DIALOG_USER="$(ask_build_user builder || true)" && [ -n "$DIALOG_USER" ]; then
        BUILD_USER="$DIALOG_USER"
        echo "    пользователь сборки: $BUILD_USER (задан в диалоге)"
    else
        BUILD_USER="builder"
        echo "    пользователь сборки: $BUILD_USER (по умолчанию, терминал недоступен)"
    fi
fi
user_ensure_exists "$BUILD_USER"

apt-get update

# mkimage-profiles не обязателен (набор везёт свою копию метапрофиля),
# но вместе с ним ставятся документация и вспомогательные сценарии.
apt-get install -y \
    mkimage mkimage-preinstall hasher \
    rsync git-core make bash \
    coreutils util-linux findutils sed grep \
    mkimage-profiles || {
        echo "не удалось установить пакеты; проверьте ветку/зеркала apt" >&2
        exit 1
    }

# настройка /etc/hasher-priv/system (идемпотентно)
# mkimage требует: 1) allowed_mountpoints включающий /proc (и /sys, /dev, /dev/pts);
#                  2) каталог BUILDDIR под одним из "prefix".
# ВАЖНО: mktmpdir "source"-ит этот файл как shell-код, и последняя строка обязана
# быть безобидным присваиванием (иначе try_source вернёт ненулевой статус и
# "no suitable directories found"). Поэтому файл НОРМАЛИЗУЕТСЯ целиком:
# блоки prefix/allowed_mountpoints/allow_ttydev пишутся один раз в фиксированном
# порядке, а вызов allow_ttydev=yes идёт последним.
configure_hasher_priv() {
    local CONF="/etc/hasher-priv/system"
    mkdir -p "$(dirname "$CONF")"
    [ -f "$CONF" ] || touch "$CONF"
    cp -n "$CONF" "${CONF}.orig" 2>/dev/null || true

    local need="/proc /sys /dev /dev/pts"
    local pref have_now
    # reuse существующее значение prefix, если его не затёрли грязные строки
    pref="$(sed -n 's/^prefix=//p' "$CONF" | tail -1)"
    [ -n "$pref" ] || pref="~:/tmp/.private:/home"

    # собрать файл заново: комментарии/пустые строки сохраняем,
    # дубли и правки блоков исключаем
    {
        grep -vE '^(prefix|allowed_mountpoints|allow_ttydev)=' "$CONF"
        echo "prefix=${pref}"
        echo "allowed_mountpoints=${need}"
        echo "allow_ttydev=yes"
    } > "${CONF}.new" && mv "${CONF}.new" "$CONF"

    echo "==> /etc/hasher-priv/system нормализован:"
    echo "   prefix=${pref}"
    echo "   allowed_mountpoints=${need}"
    echo "   allow_ttydev=yes (последней строкой — требование mktmpdir)"
    restart_hasher_privd
}

# перезапуск демона hasher-privd: он читает конфиг при старте и держит сокет;
# лежалые демоны (после обновления) отвечают клиенту "session request: command failed"
restart_hasher_privd() {
    echo "   перезапуск hasher-privd..."
    pkill -x hasher-privd 2>/dev/null || true
    sleep 1
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart hasher-privd 2>/dev/null || systemctl restart hasher-priv 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service hasher-priv restart >/dev/null 2>&1 || true
    fi
    sleep 1
}

# если /tmp — маленький tmpfs, BUILDDIR утонет в нём на установке GNOME-набора
# ("installing package ... needs N MB on the / filesystem ... failed").
# Переносим рабочий каталог hasher на диск (проверено в бою).
ensure_disk_prefix() {
    local CONF=/etc/hasher-priv/system
    local sz
    sz="$(df -kP /tmp 2>/dev/null | awk 'NR==2{print $2}')"
    [ -n "$sz" ] && [ "$sz" -gt 0 ] || return 0
    sz=$((sz / 1024 / 1024))   # GiB (округлённо)
    [ "$sz" -lt 8 ] || return 0
    if ! sed -n 's/^prefix=//p' "$CONF" | grep -Fqw '/tmp/.private'; then
        return 0
    fi
    echo "==> /tmp — tmpfs всего ~${sz}G; сборка GNOME в него не поместится."
    echo "   Меняю prefix рабочего каталога hasher с /tmp/.private на диск (/home):"
    sed -i 's#^prefix=.*#prefix=/home#' "$CONF"
    echo "   prefix=/home"
    echo "   (при необходимости очистить кэш: rm -rf \"/tmp/.private/${BUILD_USER}/mkimage-profiles.build\")"
    restart_hasher_privd
}

configure_hasher_priv
ensure_disk_prefix

# доступность helper-сценариев hasher-priv для обычного пользователя.
# mkimage/bin/mktmpdir исполняет /usr/libexec/hasher-priv/getconf.sh напрямую.
# Каталог helper'ов на ALT имеет вид root:hashman drwxr-x---, поэтому доступ
# даёт ЧЛЕНСТВО в группе hashman (не chmod!), которое применяется при входе.
fix_hasher_helpers() {
    local HDD m
    for HDD in /usr/libexec/hasher-priv /usr/lib/hasher-priv; do
        [ -d "$HDD" ] || continue
        local f fixed=0
        # чиноправство каталога — только если группа не пропускает вообще
        m="$(stat -c '%a' "$HDD" 2>/dev/null || echo 0)"
        if [ "$m" = "000" ] || [ "$m" = "0" ]; then
            chmod 755 "$HDD"
            echo "==> исправлены права каталога: $HDD ($m -> 755)"
            fixed=1
        fi
        for f in "$HDD"/*.sh "$HDD"/chrootuid* "$HDD"/getugid*; do
            [ -f "$f" ] || continue
            m="$(stat -c '%a' "$f" 2>/dev/null || echo 0)"
            if [ "$m" = "000" ] || [ "$m" = "0" ]; then
                chmod 755 "$f"
                echo "==> исправлены права: $f ($m -> 755)"
                fixed=1
            fi
        done
        [ "$fixed" = "1" ] && { pkill -x hasher-priv 2>/dev/null || true; }
        return 0
    done
    echo "!! не найден каталог helper'ов hasher-priv (/usr/libexec/hasher-priv)" >&2
}
fix_hasher_helpers

# разрешение hasher для пользователя
hasher_user_added=0
grant_hasher() { # grant_hasher ПОЛЬЗОВАТЕЛЬ — hasher-useradd с мягким восстановлением
    local u="$1" err="" g
    if command -v hasher-useradd >/dev/null 2>&1; then
        if err="$(hasher-useradd "$u" 2>&1 1>/dev/null)"; then
            echo "==> hasher-useradd: OK"
            hasher_user_added=1
            return 0
        fi
        echo "!! hasher-useradd завершился с ошибкой: ${err:-нет сообщения}" >&2
        # известный случай: конфиг /etc/hasher-priv/user.d/<UID> остался, а
        # сателлитные пользователи удалены -> hasher-useradd не пересоздаёт их
        if printf '%s' "$err" | grep -q 'already exists' \
           && ! getent passwd "${u}_a" >/dev/null 2>&1 \
           && ! getent passwd "${u}_b" >/dev/null 2>&1; then
            echo "   Конфиг hasher (user.d/$(id -u "$u")) блокирует настройку," >&2
            echo "   а пользователей ${u}_a/${u}_b нет. Восстановите так:" >&2
            echo "     sudo rm -v /etc/hasher-priv/user.d/$(id -u "$u")" >&2
            echo "     sudo hasher-useradd $u" >&2
            echo "   затем перезапустите этот сценарий." >&2
        fi
    else
        echo "!! пакет hasher не предоставил hasher-useradd; правлю вручную:" >&2
    fi

    # типичный случай: сателлитные пользователи (USER_a, USER_b) уже существуют.
    # Доводим то, что hasher-useradd должен был сделать: группа hashman и
    # принадлежность к группам USER_a/USER_b.
    if getent passwd "${u}_a" >/dev/null 2>&1 && getent passwd "${u}_b" >/dev/null 2>&1; then
        for g in hashman "${u}_a" "${u}_b"; do
            getent group "$g" >/dev/null 2>&1 || { echo "!! нет группы $g (для $u)" >&2; continue; }
            if ! id -nG "$u" | grep -Fqw "$g"; then
                gpasswd -a "$u" "$g" >/dev/null 2>&1
                echo "==> $u добавлен в группу $g"
                hasher_user_added=1
            fi
        done
        [ "$hasher_user_added" = "1" ] && return 0
        echo "!! у $u уже есть сателлитные пользователи, но не удалось добавить группы" >&2
        return 1
    fi

    echo "!! у $u нет сателлитных пользователей USER_a/USER_b; настройте вручную:" >&2
    echo "   # hasher-useradd $u   (первый раз), проверьте /etc/passwd" >&2
    return 1
}

grant_hasher "$BUILD_USER" || {
    echo "!! доводка прав hasher не завершена; сборка, скорее всего, не запустится" >&2
}

# доступ к /usr/libexec/hasher-priv даёт членство в группе hashman
# (каталог root:hashman drwxr-x---), на старых системах может быть hasher.
# hasher-useradd добавляет пользователя в эти группы, но иногда не успевает.
# Добавляем явно, идемпотентно.
grant_hasher_group() {
    for g in hashman hasher; do
        if getent group "$g" >/dev/null 2>&1; then
            if id -nG "$BUILD_USER" | grep -Fqw "$g"; then
                echo "==> пользователь $BUILD_USER состоит в группе $g"
            else
                echo "==> добавляю $BUILD_USER в группу $g (нужен новый вход)"
                gpasswd -a "$BUILD_USER" "$g" >/dev/null 2>&1 \
                    || usermod -a -G "$g" "$BUILD_USER"
                hasher_user_added=1
            fi
        fi
    done
    if ! getent group hashman >/dev/null 2>&1 && ! getent group hasher >/dev/null 2>&1; then
        echo "==> групп hashman/hasher нет — проверка getconf ниже это подтвердит"
    fi
}
grant_hasher_group

# перезапускаем демон ПОСЛЕ всех изменений конфига и прав,
# чтобы убрать лежалые сессии с "session request: command failed"
restart_hasher_privd

# новая группа применяется только после нового входа
if [ "$hasher_user_added" = "1" ]; then
    echo "==> ВАЖНО: перезайдите в систему ($BUILD_USER), чтобы применить группу hashman"
fi

# контрольный прогон от имени пользователя сборки: может ли он читать конфиг
# hasher-priv (тот самый getconf.sh, на котором падает mktmpdir)?
if [ -e /usr/libexec/hasher-priv/getconf.sh ]; then
    if su -s /bin/sh "$BUILD_USER" -c '/usr/libexec/hasher-priv/getconf.sh' >/dev/null 2>&1; then
        echo "==> OK: $BUILD_USER читает конфигурацию hasher-priv"
    elif su -s /bin/sh "$BUILD_USER" -c 'sh /usr/libexec/hasher-priv/getconf.sh' >/dev/null 2>&1; then
        echo "!! $BUILD_USER выполняет getconf.sh только через явный интерпретатор" >&2
        echo "   Похоже, файловая система, где лежит /usr/libexec/hasher-priv, смонтирована с noexec." >&2
        echo "   Проверьте: mount | grep -iw noexec ; findmnt -T /usr/libexec/hasher-priv/getconf.sh" >&2
    else
        echo "!! $BUILD_USER ВСЁ ЕЩЁ не может выполнить /usr/libexec/hasher-priv/getconf.sh" >&2
        echo "   Проверьте: ls -l /usr/libexec/hasher-priv/getconf.sh ; head -1 ..." >&2
        echo "   и демон:   pgrep -a hasher-privd  (или rc-service hasher-priv status)" >&2
    fi
else
    echo "!! нет /usr/libexec/hasher-priv/getconf.sh (пакет hasher-priv установлен?)" >&2
fi

# служебные каталоги пользователя
if [ -n "$BUILD_USER" ]; then
    HOME_USER="$(getent passwd "$BUILD_USER" | cut -d: -f6)"
    mkdir -p "$HOME_USER/out" "$HOME_USER/tmp"
    chown -R "$BUILD_USER:" "$HOME_USER/out" "$HOME_USER/tmp" 2>/dev/null || true
fi

# git нужно уметь идентифицировать автора коммитов профиля
if command -v git >/dev/null 2>&1; then
    GITCFG="$(eval "echo ~$BUILD_USER")/.gitconfig"
    if [ ! -s "$GITCFG" ]; then
        echo "==> создаю ~/.gitconfig для $BUILD_USER (user.name/user.email)"
        cat > "$GITCFG" <<EOF
[user]
	name = $BUILD_USER build
	email = $BUILD_USER@localhost
EOF
        chown "$BUILD_USER:" "$GITCFG"
    fi
fi

cat <<'EOF'

==> Готово. Рекомендации:
  * смонтируйте tmpfs на несколько гигабайт для сборочного каталога,
    если места в /tmp мало, например:
        sudo mount -t tmpfs -o size=8G tmpfs /home/$USER/hasher
      (и подпишите этот Prefix в /etc/hasher-priv/system)
  * перелогиньтесь, чтобы группа hasher применилась;
  * затем запускайте сборку обычным пользователем:
        ./scripts/build.sh  (или scripts/build.sh --check)
EOF
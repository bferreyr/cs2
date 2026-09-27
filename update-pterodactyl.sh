#!/usr/bin/env bash
set -Eeuo pipefail

PANEL_DIR="/var/www/pterodactyl"
BACKUP_DIR="/root/pterodactyl-backups"
WINGS_BIN="/usr/local/bin/wings"

echo "============================================"
echo "     ACTUALIZADOR PTERODACTYL"
echo "        Panel + Wings"
echo "============================================"

# --------------------------------------------------
# Comprobaciones
# --------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Ejecuta este script como root."
    exit 1
fi

if [[ ! -f "$PANEL_DIR/artisan" ]]; then
    echo "[ERROR] No encuentro Pterodactyl en:"
    echo "$PANEL_DIR"
    exit 1
fi

command -v php >/dev/null || {
    echo "[ERROR] PHP no está instalado."
    exit 1
}

command -v composer >/dev/null || {
    echo "[ERROR] Composer no está instalado."
    exit 1
}

command -v curl >/dev/null || {
    echo "[ERROR] curl no está instalado."
    exit 1
}

echo
echo "PHP:"
php -v | head -n 1

echo
echo "Composer:"
composer --version

echo
echo "Wings actual:"
if command -v wings >/dev/null; then
    wings version || true
else
    echo "No detectado."
fi

echo
echo "--------------------------------------------"
echo "Se actualizará:"
echo "  - Pterodactyl Panel"
echo "  - Wings"
echo
read -rp "¿Continuar? [y/N]: " CONFIRM

case "$CONFIRM" in
    y|Y|yes|YES|Yes)
        ;;
    *)
        echo "Actualización cancelada."
        exit 0
        ;;
esac


# --------------------------------------------------
# Backup
# --------------------------------------------------

DATE="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_DIR/$DATE"

mkdir -p "$BACKUP"

echo
echo "[1/8] Creando backup..."

cp "$PANEL_DIR/.env" "$BACKUP/panel.env"

if [[ -f /etc/pterodactyl/config.yml ]]; then
    cp /etc/pterodactyl/config.yml "$BACKUP/wings-config.yml"
fi

mysqldump \
    --single-transaction \
    --quick \
    --lock-tables=false \
    panel > "$BACKUP/panel.sql"

echo "Backup guardado en:"
echo "$BACKUP"


# --------------------------------------------------
# Maintenance
# --------------------------------------------------

cd "$PANEL_DIR"

echo
echo "[2/8] Activando modo mantenimiento..."

php artisan down


# Si ocurre un error después de activar mantenimiento,
# intentamos volver a habilitar el Panel.
cleanup() {

    EXIT_CODE=$?

    if [[ $EXIT_CODE -ne 0 ]]; then

        echo
        echo "============================================"
        echo "[ERROR] La actualización falló."
        echo "Intentando sacar el Panel de mantenimiento..."
        echo "============================================"

        cd "$PANEL_DIR" 2>/dev/null || true
        php artisan up 2>/dev/null || true

        echo
        echo "Backup disponible en:"
        echo "$BACKUP"
    fi

}

trap cleanup EXIT


# --------------------------------------------------
# Panel
# --------------------------------------------------

echo
echo "[3/8] Descargando última versión del Panel..."

curl -fL \
"https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" \
-o /tmp/panel.tar.gz

tar -xzf /tmp/panel.tar.gz -C "$PANEL_DIR"

rm -f /tmp/panel.tar.gz


echo
echo "[4/8] Actualizando dependencias..."

cd "$PANEL_DIR"

chmod -R 755 storage/* bootstrap/cache

export COMPOSER_ALLOW_SUPERUSER=1

composer install \
    --no-dev \
    --optimize-autoloader \
    --no-interaction


echo
echo "[5/8] Limpiando cache..."

php artisan view:clear
php artisan config:clear


echo
echo "[6/8] Actualizando base de datos..."

php artisan migrate --seed --force


echo
echo "Corrigiendo permisos..."

chown -R www-data:www-data "$PANEL_DIR"


echo
echo "Reiniciando Queue Worker..."

php artisan queue:restart

systemctl restart pteroq


# --------------------------------------------------
# Wings
# --------------------------------------------------

echo
echo "[7/8] Actualizando Wings..."

ARCH="$(uname -m)"

case "$ARCH" in

    x86_64|amd64)
        WINGS_ARCH="amd64"
        ;;

    aarch64|arm64)
        WINGS_ARCH="arm64"
        ;;

    *)
        echo "[ERROR] Arquitectura no soportada: $ARCH"
        exit 1
        ;;

esac

systemctl stop wings || true

curl -fL \
"https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WINGS_ARCH}" \
-o "${WINGS_BIN}.new"

chmod +x "${WINGS_BIN}.new"

mv "${WINGS_BIN}.new" "$WINGS_BIN"

systemctl start wings


# --------------------------------------------------
# Finalización
# --------------------------------------------------

echo
echo "[8/8] Finalizando..."

cd "$PANEL_DIR"

php artisan up

systemctl restart nginx
systemctl restart php8.3-fpm
systemctl restart pteroq
systemctl restart wings


echo
echo "============================================"
echo "       ACTUALIZACIÓN COMPLETADA"
echo "============================================"

echo
echo "Panel:"
php artisan p:info || true

echo
echo "Wings:"
wings version || true

echo
echo "Servicios:"
systemctl is-active nginx
systemctl is-active php8.3-fpm
systemctl is-active pteroq
systemctl is-active wings

echo
echo "Backup:"
echo "$BACKUP"

echo
echo "============================================"
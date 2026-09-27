#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo; echo "[ERROR] Fallo en la linea $LINENO. Revisa el mensaje anterior." >&2' ERR

# Pterodactyl LAN installer - Ubuntu Server 24.04 LTS
# Defaults for CS2 tournament LAN
DEFAULT_IP="192.168.100.232"
DEFAULT_LAN="192.168.100.0/24"
PANEL_DIR="/var/www/pterodactyl"
DB_NAME="panel"
DB_USER="pterodactyl"
TZ_DEFAULT="America/Argentina/Buenos_Aires"

if [[ ${EUID} -ne 0 ]]; then
  echo "Ejecuta este script como root: sudo ./install-pterodactyl.sh"
  exit 1
fi

if ! grep -q 'Ubuntu 24.04' /etc/os-release 2>/dev/null; then
  echo "[ERROR] Este instalador esta preparado para Ubuntu Server 24.04 LTS."
  cat /etc/os-release || true
  exit 1
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "[ERROR] Este instalador esta preparado para amd64/x86_64. Detectado: $(uname -m)"
  exit 1
fi

clear || true
echo "=================================================="
echo " PTERODACTYL + WINGS - INSTALADOR LAN"
echo " Ubuntu Server 24.04 LTS / amd64"
echo "=================================================="
echo
read -rp "IP del servidor [${DEFAULT_IP}]: " SERVER_IP
SERVER_IP="${SERVER_IP:-$DEFAULT_IP}"
read -rp "Red LAN permitida [${DEFAULT_LAN}]: " LAN_CIDR
LAN_CIDR="${LAN_CIDR:-$DEFAULT_LAN}"
read -rp "Nombre del panel [CS2 Torneo LAN]: " PANEL_NAME
PANEL_NAME="${PANEL_NAME:-CS2 Torneo LAN}"
read -rp "Zona horaria [${TZ_DEFAULT}]: " PANEL_TZ
PANEL_TZ="${PANEL_TZ:-$TZ_DEFAULT}"

echo
read -rp "Email del administrador: " ADMIN_EMAIL
while [[ -z "$ADMIN_EMAIL" ]]; do read -rp "Email del administrador: " ADMIN_EMAIL; done
read -rp "Usuario administrador [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"
read -rp "Nombre [Bartu]: " ADMIN_FIRST
ADMIN_FIRST="${ADMIN_FIRST:-Bartu}"
read -rp "Apellido [Admin]: " ADMIN_LAST
ADMIN_LAST="${ADMIN_LAST:-Admin}"
while true; do
  read -rsp "Password del administrador (min. 8, mayuscula, minuscula y numero): " ADMIN_PASS; echo
  read -rsp "Repetir password: " ADMIN_PASS2; echo
  [[ "$ADMIN_PASS" == "$ADMIN_PASS2" ]] || { echo "Las contrasenas no coinciden."; continue; }
  [[ ${#ADMIN_PASS} -ge 8 && "$ADMIN_PASS" =~ [A-Z] && "$ADMIN_PASS" =~ [a-z] && "$ADMIN_PASS" =~ [0-9] ]] || { echo "La password no cumple los requisitos."; continue; }
  break
done

# DB password only uses URL/shell-safe alphanumeric chars.
DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
APP_URL="http://${SERVER_IP}"

cat <<EOF

Se instalara:
  Panel:       ${APP_URL}
  LAN:         ${LAN_CIDR}
  Panel name:  ${PANEL_NAME}
  Admin:       ${ADMIN_USER} (${ADMIN_EMAIL})
  CS2 ports:   27015/udp y 27020/udp permitidos desde LAN

NOTA: este script NO cambia la IP de Ubuntu. ${SERVER_IP} debe estar ya configurada
      en una interfaz del servidor (o deberas configurarla luego en Netplan).
EOF
read -rp "Continuar? [S/n]: " CONFIRM
CONFIRM="${CONFIRM:-S}"
[[ "$CONFIRM" =~ ^[SsYy]$ ]] || exit 0

export DEBIAN_FRONTEND=noninteractive

echo "[1/12] Actualizando Ubuntu e instalando dependencias..."
apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg software-properties-common apt-transport-https \
  nginx mariadb-server redis-server tar unzip git cron ufw \
  php8.3 php8.3-common php8.3-cli php8.3-gd php8.3-mysql php8.3-mbstring \
  php8.3-bcmath php8.3-xml php8.3-fpm php8.3-curl php8.3-zip
systemctl enable --now nginx mariadb redis-server php8.3-fpm cron

echo "[2/12] Instalando Docker CE desde el repositorio oficial..."
for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
  dpkg -s "$pkg" >/dev/null 2>&1 && apt-get remove -y "$pkg" || true
done
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker info >/dev/null

echo "[3/12] Instalando Composer 2..."
EXPECTED_SIG="$(curl -fsSL https://composer.github.io/installer.sig)"
curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
ACTUAL_SIG="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
[[ "$EXPECTED_SIG" == "$ACTUAL_SIG" ]] || { echo "Firma de Composer invalida."; exit 1; }
php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
rm -f /tmp/composer-setup.php
composer --version

echo "[4/12] Creando base de datos de Pterodactyl..."
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

echo "[5/12] Descargando Pterodactyl Panel (latest release)..."
mkdir -p "$PANEL_DIR"
cd "$PANEL_DIR"
curl -fL https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o /tmp/panel.tar.gz
tar -xzf /tmp/panel.tar.gz -C "$PANEL_DIR"
rm -f /tmp/panel.tar.gz
chmod -R 755 storage bootstrap/cache
cp -n .env.example .env || true
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force

# Configure .env directly for a LAN-only HTTP deployment.
env APP_URL_X="$APP_URL" TZ_X="$PANEL_TZ" EMAIL_X="$ADMIN_EMAIL" DB_NAME_X="$DB_NAME" DB_USER_X="$DB_USER" DB_PASS_X="$DB_PASS" php -r '
$f=".env"; $s=file_get_contents($f);
$vals=["APP_ENV"=>"production","APP_DEBUG"=>"false","APP_URL"=>getenv("APP_URL_X"),"APP_TIMEZONE"=>getenv("TZ_X"),"APP_SERVICE_AUTHOR"=>getenv("EMAIL_X"),"DB_HOST"=>"127.0.0.1","DB_PORT"=>"3306","DB_DATABASE"=>getenv("DB_NAME_X"),"DB_USERNAME"=>getenv("DB_USER_X"),"DB_PASSWORD"=>getenv("DB_PASS_X"),"CACHE_STORE"=>"redis","SESSION_DRIVER"=>"redis","QUEUE_CONNECTION"=>"redis","REDIS_HOST"=>"127.0.0.1","REDIS_PASSWORD"=>"null","REDIS_PORT"=>"6379","MAIL_MAILER"=>"log"];
foreach($vals as $k=>$v){$line=$k."=".$v;if(preg_match("/^".preg_quote($k,"/")."=.*/m",$s)){$s=preg_replace("/^".preg_quote($k,"/")."=.*/m",$line,$s);}else{$s.="\n".$line;}}
file_put_contents($f,$s);
'

echo "[6/12] Migrando base y creando usuario administrador..."
php artisan config:clear
php artisan migrate --seed --force
# Current Pterodactyl supports these options; if upstream changes them, fall back to interactive creation.
if ! php artisan p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USER" --name-first="$ADMIN_FIRST" --name-last="$ADMIN_LAST" --password="$ADMIN_PASS" --admin=1; then
  echo "No se pudo crear el admin de forma no interactiva. Ejecutando asistente oficial..."
  php artisan p:user:make
fi
chown -R www-data:www-data "$PANEL_DIR"

# Avoid keeping admin password in process environment longer than needed.
unset ADMIN_PASS ADMIN_PASS2

echo "[7/12] Configurando Nginx para LAN HTTP..."
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${SERVER_IP};
    root ${PANEL_DIR}/public;
    index index.html index.htm index.php;
    charset utf-8;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht { deny all; }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sfn /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t
systemctl restart nginx

echo "[8/12] Configurando cron y Queue Worker..."
cat > /etc/cron.d/pterodactyl <<EOF
* * * * * root /usr/bin/php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1
EOF
chmod 644 /etc/cron.d/pterodactyl
cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now pteroq.service

echo "[9/12] Instalando Wings..."
mkdir -p /etc/pterodactyl
curl -fL -o /usr/local/bin/wings https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
chmod u+x /usr/local/bin/wings
cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable wings.service
# Do NOT start Wings until /etc/pterodactyl/config.yml exists.

echo "[10/12] Configurando firewall UFW para la LAN..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow from "$LAN_CIDR" to any port 22 proto tcp comment 'SSH LAN'
ufw allow from "$LAN_CIDR" to any port 80 proto tcp comment 'Pterodactyl Panel LAN'
ufw allow from "$LAN_CIDR" to any port 8080 proto tcp comment 'Pterodactyl Wings LAN'
ufw allow from "$LAN_CIDR" to any port 2022 proto tcp comment 'Pterodactyl SFTP LAN'
ufw allow from "$LAN_CIDR" to any port 27015 proto udp comment 'CS2 LAN'
ufw allow from "$LAN_CIDR" to any port 27020 proto udp comment 'CS2 GOTV LAN'
ufw --force enable

echo "[11/12] Guardando datos y ejecutando comprobaciones..."
install -m 600 /dev/null /root/pterodactyl-install-credentials.txt
cat > /root/pterodactyl-install-credentials.txt <<EOF
Pterodactyl LAN installation
Panel URL: ${APP_URL}
Panel admin email: ${ADMIN_EMAIL}
Panel admin username: ${ADMIN_USER}
Database: ${DB_NAME}
Database user: ${DB_USER}
Database password: ${DB_PASS}
Wings config pending: /etc/pterodactyl/config.yml
EOF

SERVICES=(nginx mariadb redis-server php8.3-fpm docker pteroq)
for s in "${SERVICES[@]}"; do
  if systemctl is-active --quiet "$s"; then echo "  [OK] $s"; else echo "  [FALLO] $s"; fi
done
curl -fsS "http://127.0.0.1" >/dev/null && echo "  [OK] Panel responde localmente" || echo "  [AVISO] Panel no respondio por HTTP local"

# Warn if requested IP is not actually configured.
if ip -4 addr show | grep -qw "$SERVER_IP"; then
  echo "  [OK] IP ${SERVER_IP} detectada en el servidor"
else
  echo "  [AVISO] ${SERVER_IP} NO aparece configurada actualmente en una interfaz."
fi

echo "[12/12] Instalacion base completada."
echo
cat <<EOF
==================================================
 INSTALACION COMPLETADA
==================================================
Panel: ${APP_URL}
Usuario: ${ADMIN_USER}

Wings esta INSTALADO pero aun NO iniciado porque necesita el config.yml real del Node.

SIGUIENTE PASO:
  1. Entra a ${APP_URL}
  2. Admin -> Locations -> crea: Torneo LAN
  3. Admin -> Nodes -> Create New
     - Name: CS2-LAN
     - FQDN: ${SERVER_IP}
     - SSL: HTTP / sin SSL (solo LAN)
     - Daemon port: 8080
     - SFTP port: 2022
  4. En el Node -> Configuration, usa "Generate Token" y ejecuta EN ESTE SERVIDOR
     el comando que genera Pterodactyl. Eso creara /etc/pterodactyl/config.yml.
  5. Luego ejecuta:
       sudo systemctl start wings
       sudo systemctl status wings --no-pager
  6. Node -> Allocations: agrega ${SERVER_IP}:27015 y ${SERVER_IP}:27020.

Credenciales tecnicas de BD (root-only):
  /root/pterodactyl-install-credentials.txt

IMPORTANTE:
  - El script NO cambia Netplan. La IP ${SERVER_IP} debe ser estatica/reservada.
  - HTTP es apropiado para esta LAN cerrada; no expongas el Panel a Internet asi.
  - Docker puede publicar puertos de forma que no siga intuitivamente todas las reglas UFW.
    No hagas port-forward de 80/8080/2022 desde el router hacia Internet.
==================================================
EOF

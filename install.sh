#!/bin/bash
set -e

# ============================================
# CapyJudge All-in-One Installation Script
# Based on LQDOJ/DMOJ architecture
# ============================================
#
# Automated deployment script for CapyJudge Online Judge system.
# Handles complete setup from dependencies to running services.
#
# Prerequisites:
#   - Ubuntu 20.04/22.04/24.04 LTS
#   - Fresh installation recommended
#   - Minimum 2GB RAM, 10GB free disk space
#   - Internet connection required
#
# Post-installation:
#   - Create superuser account
#   - Configure SSL/TLS certificates
#   - Set up judge workers (separate installation)
#   - Configure email backend
# ============================================

# ============================================
# Environment Configuration
# ============================================
APP_USER="capyjudge"
APP_GROUP="capyjudge"
APP_HOME="/home/${APP_USER}"
APP_DIR="${APP_HOME}/capyjudge"
DATA_DIR="${APP_HOME}/capyjudge-data"
LOG_DIR="${APP_HOME}/logs"

# ============================================
# Output Formatting
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================
# Helper Functions
# ============================================
generate_secret_key() {
    sudo -u "${APP_USER}" "${APP_HOME}/venv/bin/python3" -c "
import secrets, string
chars = string.ascii_letters + string.digits + '!@#\$%^&*()-_=+[]{}|;:,.<>?'
print(''.join(secrets.choice(chars) for _ in range(50)))
"
}

generate_fernet_key() {
    sudo -u "${APP_USER}" "${APP_HOME}/venv/bin/python3" -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
}

generate_random_password() {
    sudo -u "${APP_USER}" "${APP_HOME}/venv/bin/python3" -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32)))"
}

# ============================================
# Step 1: System Dependencies
# ============================================
log_info "Installing system dependencies..."

sudo apt-get update -y
sudo apt-get install -y \
    git curl wget gnupg lsb-release ca-certificates \
    python3 python3-pip python3-dev python3-venv python3-full \
    gcc g++ gcc-12 g++-12 make \
    libxml2-dev libxslt1-dev zlib1g-dev \
    gettext pkg-config \
    mariadb-client libmariadb-dev \
    nginx supervisor \
    netcat-openbsd \
    redis-server mariadb-server memcached \
    build-essential libssl-dev libffi-dev libseccomp-dev \
    automake cmake libpq-dev unzip mariadb-client-compat

log_info "System dependencies installed"

# ============================================
# Step 2: System User & Directory Setup
# ============================================
log_info "Creating system user and directories..."

# Create group and user
getent group "${APP_GROUP}" > /dev/null 2>&1 || sudo groupadd "${APP_GROUP}"
id "${APP_USER}" > /dev/null 2>&1 || sudo useradd -m -g "${APP_GROUP}" -s /bin/bash "${APP_USER}"
sudo usermod -a -G "${APP_GROUP}" www-data

# Create directory structure
sudo mkdir -p "${DATA_DIR}"/{static,media,problems,secrets,cache,logs}
sudo mkdir -p "${DATA_DIR}/problems/__conf__"
sudo mkdir -p "${LOG_DIR}"/{nginx,supervisor,uwsgi,django,celery,websocket,redis,memcached}
sudo mkdir -p "${APP_DIR}" /run/nginx /var/log/nginx

# Set permissions
sudo chown -R "${APP_USER}:${APP_GROUP}" "${DATA_DIR}" "${LOG_DIR}" "${APP_DIR}"
sudo chown -R www-data:www-data /var/log/nginx /run/nginx
sudo chmod 755 "${DATA_DIR}" "${LOG_DIR}" /run/nginx

log_info "User and directories setup complete"

# ============================================
# Step 3: Node.js Installation (via nvm)
# ============================================
log_info "Installing Node.js for ${APP_USER}..."

sudo -u "${APP_USER}" bash << 'NODEJS'
rm -f ~/.npmrc

if [ ! -d "$HOME/.nvm" ]; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

nvm ls 24 > /dev/null 2>&1 || nvm install 24
nvm use 24 && nvm alias default 24

echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
NODEJS

log_info "Node.js installed successfully"

# ============================================
# Step 4: Clone Repository
# ============================================
log_info "Cloning CapyJudge repository..."

if [ -d "${APP_DIR}/.git" ]; then
    log_warn "Repository exists, pulling latest changes..."
    cd "${APP_DIR}"
    sudo -u "${APP_USER}" git pull
    sudo -u "${APP_USER}" git submodule update --init
else
    sudo -u "${APP_USER}" git clone https://github.com/a3chuyentin/capyjudge.git "${APP_DIR}"
    cd "${APP_DIR}"
    sudo -u "${APP_USER}" git submodule update --init
    log_info "Repository cloned successfully"
fi

cd "${APP_DIR}"

# ============================================
# Step 5: Python Virtual Environment
# ============================================
log_info "Setting up Python virtual environment..."

sudo apt-get install -y libcrypt-dev libssl-dev libffi-dev libxml2-dev \
    libxslt1-dev libjpeg-dev libz-dev build-essential python3-dev pkg-config

if [ ! -d "${APP_HOME}/venv" ]; then
    sudo -u "${APP_USER}" python3 -m venv "${APP_HOME}/venv"
fi

sudo -u "${APP_USER}" bash << 'PYTHON'
source ~/venv/bin/activate
pip install --upgrade pip setuptools wheel

if [ -f ~/capyjudge/requirements.txt ]; then
    pip install -r ~/capyjudge/requirements.txt
fi

pip install mysqlclient uwsgi websocket-client celery redis \
    django-compressor cryptography boto3 django-storages

cd ~/capyjudge && pre-commit install
PYTHON

log_info "Python dependencies installed"

# ============================================
# Step 6: Node.js Dependencies
# ============================================
log_info "Installing Node.js dependencies..."

sudo -u "${APP_USER}" bash << 'NPM'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm use 24

npm install -g sass postcss-cli postcss autoprefixer
cd ~/capyjudge/websocket && npm install express socket.io qu ws simplesets
NPM

log_info "Node.js dependencies installed"

# ============================================
# Step 7: Environment Configuration
# ============================================
log_info "Loading environment configuration..."

if [ -f "${APP_DIR}/.env" ]; then
    log_info "Found .env file, loading..."
    sudo sed -i '/^EOF$/d' "${APP_DIR}/.env" 2>/dev/null || true
    set -a; source "${APP_DIR}/.env"; set +a
elif [ -f "${APP_DIR}/.env.example" ]; then
    log_info "Creating .env from template..."
    sudo cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
    sudo sed -i '/^EOF$/d' "${APP_DIR}/.env" 2>/dev/null || true
    sudo chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/.env"
    
    echo -e "\n${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  Edit .env file now? (Recommended)${NC}"
    echo -e "${YELLOW}========================================${NC}"
    read -p "Edit .env? [Y/n]: " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        command -v nano &> /dev/null && sudo -u "${APP_USER}" nano "${APP_DIR}/.env" || \
        command -v vim &> /dev/null && sudo -u "${APP_USER}" vim "${APP_DIR}/.env" || \
        log_warn "No editor found. Edit ${APP_DIR}/.env manually."
        sudo sed -i '/^EOF$/d' "${APP_DIR}/.env" 2>/dev/null || true
    fi
    
    set -a; source "${APP_DIR}/.env" 2>/dev/null || { log_error "Failed to load .env"; exit 1; }; set +a
else
    log_warn "No .env.example found, using defaults"
fi

# ============================================
# Step 8: Generate Configuration Values
# ============================================
log_info "Generating configuration values..."

# Secrets with .env override support
SECRET_KEY="${SECRET_KEY:-$(generate_secret_key)}"
EVENT_DAEMON_KEY="${EVENT_DAEMON_KEY:-$(generate_random_password)}"
CHAT_SECRET_KEY="${CHAT_SECRET_KEY:-$(generate_fernet_key)}"
DB_PASSWORD="${DB_PASSWORD:-$(generate_random_password)}"
FERNET_KEY="${FERNET_KEY:-$(generate_fernet_key)}"

# Configuration defaults
DB_NAME="${DB_NAME:-capyjudge}"
DB_USER="${DB_USER:-capyjudge}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
WEB_PORT="${WEB_PORT:-80}"
BRIDGE_PORT="${BRIDGE_PORT:-9999}"
WEBSOCKET_PORT="${WEBSOCKET_PORT:-15100}"
SITE_DOMAIN="${SITE_DOMAIN:-localhost}"
SITE_NAME="${SITE_NAME:-CapyJudge}"
SITE_LONG_NAME="${SITE_LONG_NAME:-CapyJudge Online Judge}"
SITE_ADMIN_EMAIL="${SITE_ADMIN_EMAIL:-admin@localhost}"
DEBUG="${DEBUG:-False}"

# Save credentials
sudo mkdir -p "${DATA_DIR}/secrets"
sudo bash -c "cat > ${DATA_DIR}/secrets/credentials.txt" << EOF
# CapyJudge Credentials - Generated $(date)
# KEEP THIS FILE SECURE!

Database:
  Name: ${DB_NAME}
  User: ${DB_USER}
  Password: ${DB_PASSWORD}
  Host: ${DB_HOST}:${DB_PORT}

Keys:
  SECRET_KEY: ${SECRET_KEY}
  EVENT_DAEMON_KEY: ${EVENT_DAEMON_KEY}
  CHAT_SECRET_KEY: ${CHAT_SECRET_KEY}
  FERNET_KEY: ${FERNET_KEY}

Ports:
  Web: ${WEB_PORT}
  Bridge: ${BRIDGE_PORT}
  WebSocket: ${WEBSOCKET_PORT}
  
Domain: ${SITE_DOMAIN}
EOF

sudo chmod 600 "${DATA_DIR}/secrets/credentials.txt"
sudo chown "${APP_USER}:${APP_GROUP}" "${DATA_DIR}/secrets/credentials.txt"

log_info "Configuration values saved"

# ============================================
# Step 9: Database Setup
# ============================================
log_info "Configuring MariaDB..."

sudo systemctl start mariadb && sudo systemctl enable mariadb

log_info "Waiting for MariaDB..."
for i in {1..30}; do
    if sudo mysqladmin ping -u root --silent 2>/dev/null; then
        log_info "MariaDB ready!"
        break
    fi
    [ $i -eq 30 ] && { log_error "MariaDB failed to start"; exit 1; }
    sleep 1
done

# Create database and user
sudo mysql -u root << EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON test_${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# Verify connection
log_info "Verifying database connection..."
if mysql -u "${DB_USER}" -p"${DB_PASSWORD}" -e "SELECT 1;" "${DB_NAME}" 2>/dev/null; then
    log_info "Database connection verified"
else
    log_warn "Trying mysql_native_password fallback..."
    sudo mysql -u root << EOF
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_PASSWORD}';
FLUSH PRIVILEGES;
EOF
    if ! mysql -u "${DB_USER}" -p"${DB_PASSWORD}" -e "SELECT 1;" "${DB_NAME}" 2>/dev/null; then
        log_error "Database connection failed!"
        exit 1
    fi
fi

# Import timezone data
if command -v mysql_tzinfo_to_sql > /dev/null 2>&1 && [ -d /usr/share/zoneinfo ]; then
    log_info "Importing timezone data..."
    mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | sudo mysql -u root mysql 2>/dev/null || \
    log_warn "Timezone import failed - timezone features may be limited"
fi

log_info "Database configured successfully"

# ============================================
# Step 10: Cache Services Setup
# ============================================
log_info "Configuring Redis and Memcached..."

sudo systemctl restart redis-server && sudo systemctl enable redis-server
sudo systemctl restart memcached && sudo systemctl enable memcached

log_info "Cache services configured"

# ============================================
# Step 11: Django Configuration
# ============================================
log_info "Generating Django configuration..."

# Build email config conditionally
EMAIL_CONFIG=""
if [ -n "${EMAIL_HOST}" ] && [ -n "${EMAIL_HOST_USER}" ] && [ -n "${EMAIL_HOST_PASSWORD}" ]; then
    EMAIL_CONFIG=$(cat << EOF

# Email configuration
EMAIL_BACKEND = 'django.core.mail.backends.smtp.EmailBackend'
EMAIL_HOST = '${EMAIL_HOST}'
EMAIL_PORT = ${EMAIL_PORT:-587}
EMAIL_USE_TLS = ${EMAIL_USE_TLS:-True}
EMAIL_HOST_USER = '${EMAIL_HOST_USER}'
EMAIL_HOST_PASSWORD = '${EMAIL_HOST_PASSWORD}'
DEFAULT_FROM_EMAIL = '${DEFAULT_FROM_EMAIL:-${SITE_NAME} <noreply@${SITE_DOMAIN}>}'
SERVER_EMAIL = '${SERVER_EMAIL:-${SITE_NAME} <noreply@${SITE_DOMAIN}>}'
EOF
)
    log_info "Email configuration enabled"
else
    log_warn "Email not configured - skipping email backend setup"
fi

sudo bash -c "cat > ${APP_DIR}/dmoj/local_settings.py" << EOF
import os

# Core settings
DEBUG = ${DEBUG}
SECRET_KEY = r'''${SECRET_KEY}'''
ALLOWED_HOSTS = ['*']

# Site identity
SITE_NAME = '${SITE_NAME}'
SITE_LONG_NAME = '${SITE_LONG_NAME}'
SITE_ADMIN_EMAIL = '${SITE_ADMIN_EMAIL}'
SITE_DOMAIN = '${SITE_DOMAIN}'

# CSRF & Security
CSRF_TRUSTED_ORIGINS = [
    f'https://{SITE_DOMAIN}',
    f'http://{SITE_DOMAIN}',
    f'http://{SITE_DOMAIN}:${WEB_PORT}'
]

# Database
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': '${DB_NAME}',
        'USER': '${DB_USER}',
        'PASSWORD': '${DB_PASSWORD}',
        'HOST': '${DB_HOST}',
        'PORT': '${DB_PORT}',
        'OPTIONS': {
            'charset': 'utf8mb4',
            'sql_mode': 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION',
        },
    }
}

# Cache
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.PyMemcacheCache',
        'LOCATION': '127.0.0.1:11211',
    }
}

# File storage
DMOJ_PROBLEM_DATA_ROOT = '${DATA_DIR}/problems'
STATIC_ROOT = '${DATA_DIR}/static'
MEDIA_ROOT = '${DATA_DIR}/media'

# Bridge daemon
BRIDGED_JUDGE_ADDRESS = [('0.0.0.0', ${BRIDGE_PORT})]
BRIDGED_DJANGO_ADDRESS = [('localhost', 9998)]

# WebSocket events
EVENT_DAEMON_USE = True
EVENT_DAEMON_KEY = '${EVENT_DAEMON_KEY}'
EVENT_DAEMON_URL = 'http://localhost:${WEBSOCKET_PORT}'
EVENT_DAEMON_PUBLIC_URL = 'http://${SITE_DOMAIN}:${WEBSOCKET_PORT}'

# Celery
CELERY_BROKER_URL = 'redis://localhost:6379/0'
CELERY_RESULT_BACKEND = 'redis://localhost:6379/0'

# Chat encryption
CHAT_SECRET_KEY = '${CHAT_SECRET_KEY}'

# Static files
STATICFILES_FINDERS = [
    'django.contrib.staticfiles.finders.FileSystemFinder',
    'django.contrib.staticfiles.finders.AppDirectoriesFinder',
    'compressor.finders.CompressorFinder',
]

# Logging
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'handlers': {
        'console': {'class': 'logging.StreamHandler'},
        'file': {
            'class': 'logging.FileHandler',
            'filename': '${LOG_DIR}/django/django.log',
            'level': 'INFO',
        },
    },
    'root': {'handlers': ['console', 'file'], 'level': 'INFO'},
}

# Security (production)
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
USE_X_FORWARDED_HOST = True
SECURE_SSL_REDIRECT = True

# Registration
SEND_ACTIVATION_EMAIL = True
${EMAIL_CONFIG}

# Compression (disabled during setup)
COMPRESS_ENABLED = False
COMPRESS_OFFLINE = False
EOF

sudo chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/dmoj/local_settings.py"
sudo chmod 640 "${APP_DIR}/dmoj/local_settings.py"

log_info "Django configuration generated"

# ============================================
# Step 12: uWSGI Configuration
# ============================================
log_info "Generating uWSGI configuration..."

sudo bash -c "cat > ${APP_DIR}/uwsgi.ini" << EOF
[uwsgi]
socket = /tmp/dmoj-site.sock
pidfile = /tmp/dmoj-site.pid
chmod-socket = 666
uid = ${APP_USER}
gid = ${APP_GROUP}
chdir = ${APP_DIR}
pythonpath = ${APP_DIR}
home = ${APP_HOME}/venv
protocol = uwsgi
master = true
env = DJANGO_SETTINGS_MODULE=dmoj.settings
module = dmoj.wsgi:application
optimize = 2
memory-report = true
cheaper-algo = backlog
cheaper = 3
cheaper-initial = 5
cheaper-step = 1
cheaper-rss-limit-soft = 201326592
cheaper-rss-limit-hard = 234881024
workers = 7
EOF

# ============================================
# Step 13: WebSocket Configuration
# ============================================
log_info "Generating WebSocket configuration..."

sudo bash -c "cat > ${APP_DIR}/websocket/config.js" << EOF
module.exports = {
    http_host: '127.0.0.1',
    http_port: 15100,
    connection_timeout: 300000,
    backend_auth_token: '${EVENT_DAEMON_KEY}',
};
EOF

log_info "Service configurations generated"

# ============================================
# Step 14: Nginx Configuration
# ============================================
log_info "Configuring Nginx..."

sudo bash -c "cat > /etc/nginx/sites-available/capyjudge" << EOF
# Default server - block unknown hosts
server {
    listen ${WEB_PORT} default_server;
    server_name _;
    location / { return 403; }
    access_log off;
    error_log off;
}

# Main application server
server {
    listen ${WEB_PORT};
    server_name ${SITE_DOMAIN};
    
    access_log ${LOG_DIR}/nginx/access.log;
    error_log ${LOG_DIR}/nginx/error.log;
    
    error_page 502 /502.html;
    
    # Exact file matches
    location = /favicon.ico {
        alias ${DATA_DIR}/static/icons/favicon.ico;
        expires 30d;
        add_header Cache-Control "public, immutable";
        try_files \$uri =404;
    }
    
    location = /logo.png {
        alias ${APP_DIR}/logo.png;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    location = /502.html {
        alias ${APP_DIR}/502.html;
        internal;
    }
    
    location = /robots.txt {
        alias ${APP_DIR}/robots.txt;
        expires 1d;
        add_header Cache-Control "public";
    }
    
    # Static & media files
    location /static {
        alias ${DATA_DIR}/static;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    location /media {
        alias ${DATA_DIR}/media;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    location /profile_images/ {
        alias ${APP_DIR}/profile_images/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    location /organization_images/ {
        alias ${APP_DIR}/organization_images/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # WebSocket proxy
    location /socket.io/ {
        proxy_pass http://127.0.0.1:${WEBSOCKET_PORT}/socket.io/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }
    
    # Django application
    location / {
        include uwsgi_params;
        uwsgi_pass unix:///tmp/dmoj-site.sock;
        uwsgi_param UWSGI_SCHEME \$scheme;
        uwsgi_param SERVER_SOFTWARE nginx/\$nginx_version;
        uwsgi_param HTTP_X_FORWARDED_PROTO \$scheme;
        uwsgi_param HTTP_X_FORWARDED_HOST \$host;
        uwsgi_param HTTP_X_FORWARDED_SERVER \$host;
        uwsgi_intercept_errors on;
    }
    
    client_max_body_size 100M;
    
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;
}
EOF

# Enable site and disable default
sudo ln -sf /etc/nginx/sites-available/capyjudge /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Create required directories
sudo mkdir -p ${APP_DIR}/profile_images ${APP_DIR}/organization_images ${DATA_DIR}/static/icons
sudo chown -R ${APP_USER}:${APP_GROUP} ${APP_DIR}/profile_images ${APP_DIR}/organization_images ${DATA_DIR}/static/icons

# Create placeholder files
sudo -u ${APP_USER} touch ${APP_DIR}/logo.png ${APP_DIR}/502.html ${APP_DIR}/robots.txt ${DATA_DIR}/static/icons/favicon.ico

# Test and apply
sudo nginx -t && sudo systemctl restart nginx

log_info "Nginx configured successfully"

# ============================================
# Step 15: Supervisor Configuration
# ============================================
log_info "Configuring Supervisor..."

# Resolve binary paths
NODE_BIN=$(sudo -u "${APP_USER}" bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"; which node')
PYTHON_BIN="${APP_HOME}/venv/bin/python3"
UWSGI_BIN="${APP_HOME}/venv/bin/uwsgi"
CELERY_BIN="${APP_HOME}/venv/bin/celery"

log_info "Resolved: Node=${NODE_BIN}, Python=${PYTHON_BIN}, uWSGI=${UWSGI_BIN}, Celery=${CELERY_BIN}"

# uWSGI
sudo bash -c "cat > /etc/supervisor/conf.d/capyjudge-site.conf" << EOF
[program:capyjudge-site]
command=${UWSGI_BIN} --ini ${APP_DIR}/uwsgi.ini
directory=${APP_DIR}
user=${APP_USER}
group=${APP_GROUP}
stopsignal=QUIT
stdout_logfile=${LOG_DIR}/supervisor/site.log
stderr_logfile=${LOG_DIR}/supervisor/site_error.log
EOF

# Bridged daemon
sudo bash -c "cat > /etc/supervisor/conf.d/capyjudge-bridged.conf" << EOF
[program:capyjudge-bridged]
command=${PYTHON_BIN} ${APP_DIR}/manage.py runbridged
directory=${APP_DIR}
stopsignal=INT
user=${APP_USER}
group=${APP_GROUP}
stdout_logfile=${LOG_DIR}/supervisor/bridged.log
stderr_logfile=${LOG_DIR}/supervisor/bridged_error.log
EOF

# Celery worker
sudo bash -c "cat > /etc/supervisor/conf.d/capyjudge-celery.conf" << EOF
[program:capyjudge-celery]
command=${CELERY_BIN} -A dmoj_celery worker
directory=${APP_DIR}
user=${APP_USER}
group=${APP_GROUP}
stdout_logfile=${LOG_DIR}/celery/celery.log
stderr_logfile=${LOG_DIR}/celery/celery_error.log
EOF

# WebSocket daemon
sudo bash -c "cat > /etc/supervisor/conf.d/capyjudge-wsevent.conf" << EOF
[program:capyjudge-wsevent]
command=${NODE_BIN} ${APP_DIR}/websocket/daemon.js
directory=${APP_DIR}
user=${APP_USER}
group=${APP_GROUP}
stdout_logfile=${LOG_DIR}/websocket/wsevent.log
stderr_logfile=${LOG_DIR}/websocket/wsevent_error.log
EOF

log_info "Supervisor configured"

# ============================================
# Step 16: Django Initialization
# ============================================
log_info "Initializing Django application..."

sudo -u "${APP_USER}" bash << 'DJANGO'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm use 24

source ~/venv/bin/activate
cd ~/capyjudge
export DJANGO_SETTINGS_MODULE=dmoj.settings

# Build static assets
[ -f "./make_style.sh" ] && ./make_style.sh 2>/dev/null || true
python3 manage.py collectstatic --noinput 2>/dev/null || true
python3 manage.py compilemessages 2>/dev/null || true
python3 manage.py compilejsi18n 2>/dev/null || true

# Database migrations
python3 manage.py migrate --noinput

# Load initial data
python3 manage.py loaddata navbar 2>/dev/null || true
python3 manage.py loaddata language_small 2>/dev/null || python3 manage.py loaddata language 2>/dev/null || true
python3 manage.py loaddata demo 2>/dev/null || true
DJANGO

log_info "Django initialization complete"

# ============================================
# Step 17: Start All Services
# ============================================
log_info "Starting all services..."

sudo systemctl daemon-reload

# Database & cache
sudo systemctl restart mariadb && sudo systemctl enable mariadb
sudo systemctl restart redis-server && sudo systemctl enable redis-server
sudo systemctl restart memcached && sudo systemctl enable memcached

# Web & process manager
sudo systemctl restart nginx && sudo systemctl enable nginx
sudo systemctl restart supervisor && sudo systemctl enable supervisor

# Reload supervisor programs
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl start all

log_info "All services started"

# ============================================
# Step 18: Final Permissions
# ============================================
log_info "Setting final permissions..."

sudo chmod 755 /home/${APP_USER} ${APP_HOME} ${DATA_DIR}
sudo chown -R "${APP_USER}:${APP_GROUP}" "${DATA_DIR}" "${LOG_DIR}" "${APP_DIR}"
sudo find "${DATA_DIR}" -type d -exec chmod 755 {} \;
sudo find "${LOG_DIR}" -type d -exec chmod 755 {} \;
sudo find "${DATA_DIR}/static" -type f -exec chmod 644 {} \;
sudo find "${DATA_DIR}/media" -type f -exec chmod 644 {} \;
sudo find "${LOG_DIR}" -type f -exec chmod 644 {} \;
sudo usermod -a -G "${APP_GROUP}" www-data 2>/dev/null || true
sudo systemctl restart nginx

log_info "Permissions applied"

# ============================================
# Installation Complete
# ============================================
echo -e "\n${GREEN}=========================================${NC}"
echo -e "${GREEN}  CapyJudge Installation Complete!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo -e "Web Interface: ${GREEN}http://${SITE_DOMAIN}:${WEB_PORT}${NC}"
echo -e ""
echo -e "Credentials saved to: ${DATA_DIR}/secrets/credentials.txt"
echo -e ""
echo -e "${YELLOW}=========================================${NC}"
echo -e "${YELLOW}  Next Steps:${NC}"
echo -e "${YELLOW}=========================================${NC}"
echo -e "1. Create superuser:"
echo -e "   sudo -u ${APP_USER} bash"
echo -e "   source ${APP_HOME}/venv/bin/activate"
echo -e "   cd ${APP_DIR}"
echo -e "   python3 manage.py createsuperuser"
echo -e ""
echo -e "2. Configure SSL/TLS for production"
echo -e "3. Set up judge workers (separate installation)"
echo -e "4. Configure email backend"
echo -e "${YELLOW}=========================================${NC}"

# Service health check
sleep 3
if sudo supervisorctl status | grep -q "RUNNING"; then
    echo -e "${GREEN}✓ All services running!${NC}"
else
    echo -e "${RED}✗ Some services may not be running${NC}"
    echo -e "Check: supervisorctl status"
fi

exit 0
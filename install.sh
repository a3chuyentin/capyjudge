#!/bin/bash
set -e

# ============================================
# CapyJudge All-in-One Installation Script
# Based on LQDOJ/DMOJ architecture
# ============================================

# Configuration
APP_USER="capyjudge"
APP_GROUP="capyjudge"
APP_HOME="/home/capyjudge"
APP_DIR="${APP_HOME}/capyjudge"
DATA_DIR="${APP_HOME}/capyjudge-data"
LOG_DIR="${APP_HOME}/logs"
ENV_FILE="${APP_DIR}/.env"
ENV_EXAMPLE="${APP_DIR}/.env.example"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================
# Helper functions (use pure Python, no Django)
# ============================================
generate_secret_key() {
    python -c "import secrets; import string; chars = string.ascii_letters + string.digits + string.punctuation; print(''.join(secrets.choice(chars) for _ in range(50)))"
}

generate_fernet_key() {
    python -c "from cryptography.fernet import Fernet; key = Fernet.generate_key(); print(key.decode('utf-8'))"
}

generate_random_password() {
    python -c "import secrets; import string; chars = string.ascii_letters + string.digits; print(''.join(secrets.choice(chars) for _ in range(32)))"
}

# ============================================
# Step 0: System Prerequisites & Virtual Environment
# ============================================
log_info "Step 0: Installing system dependencies and setting up virtual environment..."

# Update package list
sudo apt-get update -y

# Install essential packages
sudo apt-get install -y \
    git curl wget gnupg lsb-release ca-certificates \
    python python-pip python-dev python-venv python-full \
    gcc g++ gcc-12 g++-12 make \
    libxml2-dev libxslt1-dev zlib1g-dev \
    gettext pkg-config \
    mariadb-client libmariadb-dev \
    nginx supervisor \
    nodejs npm \
    netcat-openbsd \
    redis-server \
    mariadb-server \
    memcached \
    build-essential \
    libssl-dev \
    libffi-dev \
    libseccomp-dev \
    automake \
    cmake \
    libpq-dev \
	unzip 

# Check if npm is already installed
if command -v npm &> /dev/null; then
    NPM_VERSION=$(npm --version)
    NODE_VERSION=$(node --version)
    log_info "npm ${NPM_VERSION} (Node.js ${NODE_VERSION}) already installed, skipping installation"
else
    log_info "Installing Node.js and npm..."
    
    # Download and install nvm:
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
    # in lieu of restarting the shell
    \. "$HOME/.nvm/nvm.sh"
    # Download and install Node.js:
    nvm install 24
    
    log_info "Node.js and npm installed successfully"
fi

# Install Node.js global tools
npm install -g sass postcss-cli postcss autoprefixer

log_info "System dependencies installed"

# ============================================
# Step 0a: Create User and Group
# ============================================
log_info "Creating capyjudge user and group..."

# Create group if not exists
if ! getent group "${APP_GROUP}" > /dev/null 2>&1; then
    groupadd "${APP_GROUP}"
    log_info "Group ${APP_GROUP} created"
fi

# Create user if not exists
if ! id "${APP_USER}" > /dev/null 2>&1; then
    useradd -m -g "${APP_GROUP}" -s /bin/bash "${APP_USER}"
    log_info "User ${APP_USER} created"
fi

# Add nginx user to app group
usermod -a -G "${APP_GROUP}" www-data

log_info "User and group setup complete"

# ============================================
# Step 0b: Create Directory Structure
# ============================================
log_info "Creating directory structure..."

# Create directories
mkdir -p "${DATA_DIR}"/{static,media,problems,secrets,cache,logs}
mkdir -p "${DATA_DIR}/problems/__conf__"
mkdir -p "${LOG_DIR}"/{nginx,supervisor,uwsgi,django,celery,websocket,redis,memcached}
mkdir -p "${APP_DIR}"
mkdir -p /run/nginx /var/log/nginx

# Set ownership
chown -R "${APP_USER}:${APP_GROUP}" "${DATA_DIR}" "${LOG_DIR}" "${APP_DIR}"
chown -R www-data:www-data /var/log/nginx /run/nginx
chmod 755 "${DATA_DIR}" "${LOG_DIR}" /run/nginx

log_info "Directory structure created"

# ============================================
# Step 0c: Clone Repository
# ============================================
log_info "Cloning CapyJudge repository..."

if [ -d "${APP_DIR}/.git" ]; then
    log_warn "Repository already exists, pulling latest changes"
    cd "${APP_DIR}"
    sudo -u "${APP_USER}" git pull
    sudo -u "${APP_USER}" git submodule init
    sudo -u "${APP_USER}" git submodule update
else
    sudo -u "${APP_USER}" git clone https://github.com/a3chuyentin/capyjudge.git "${APP_DIR}"
    cd "${APP_DIR}"
    sudo -u "${APP_USER}" git submodule init
    sudo -u "${APP_USER}" git submodule update
    log_info "Repository cloned successfully"
fi

cd "${APP_DIR}"

# ============================================
# Step 0d: Setup Virtual Environment & Install Dependencies
# ============================================
log_info "Setting up Python virtual environment..."

sudo apt-get install -y \
    libcrypt-dev \
    libssl-dev \
    libffi-dev \
    libxml2-dev \
    libxslt1-dev \
    libjpeg-dev \
    libz-dev \
    build-essential \
    python-dev \
    pkg-config

# Create virtual environment
if [ ! -d "${APP_HOME}/venv" ]; then
    sudo -u "${APP_USER}" python -m venv "${APP_HOME}/venv"
    log_info "Virtual environment created"
fi

# Install all Python dependencies in venv
sudo -u "${APP_USER}" bash << EOF
source ${APP_HOME}/venv/bin/activate
pip install --upgrade pip setuptools wheel
if [ -f "${APP_DIR}/requirements.txt" ]; then
    pip install -r "${APP_DIR}/requirements.txt"
fi
pip install mysqlclient uwsgi websocket-client celery redis django-compressor cryptography boto3 django-storages cryptography
pre-commit install
EOF

source "${APP_HOME}"/venv/bin/activate

# Install Node dependencies for websocket
cd "${APP_DIR}/websocket"
sudo -u "${APP_USER}" npm install express socket.io qu ws simplesets
cd "${APP_DIR}"

log_info "All dependencies installed"

# ============================================
# Generate configuration values using helpers
# ============================================
log_info "Generating configuration values..."

# Generate secret keys
SECRET_KEY=$(generate_secret_key)
EVENT_DAEMON_KEY=$(generate_random_password)
CHAT_SECRET_KEY=$(generate_random_password)
DB_PASSWORD=$(generate_random_password)
FERNET_KEY=$(generate_fernet_key)

# Set configuration values
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
DJANGO_SUPERUSER_USERNAME="${DJANGO_SUPERUSER_USERNAME:-admin}"
DJANGO_SUPERUSER_PASSWORD="${DJANGO_SUPERUSER_PASSWORD:-admin123}"
DJANGO_SUPERUSER_EMAIL="${DJANGO_SUPERUSER_EMAIL:-admin@capyjudge.com}"
DEBUG="${DEBUG:-False}"

# Save secrets to file
mkdir -p "${DATA_DIR}/secrets"
cat > "${DATA_DIR}/secrets/credentials.txt" << EOF
# CapyJudge Credentials
# Generated on $(date)
# Keep this file secure!

DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}

SECRET_KEY=${SECRET_KEY}
EVENT_DAEMON_KEY=${EVENT_DAEMON_KEY}
CHAT_SECRET_KEY=${CHAT_SECRET_KEY}
FERNET_KEY=${FERNET_KEY}

DJANGO_SUPERUSER_USERNAME=${DJANGO_SUPERUSER_USERNAME}
DJANGO_SUPERUSER_PASSWORD=${DJANGO_SUPERUSER_PASSWORD}
DJANGO_SUPERUSER_EMAIL=${DJANGO_SUPERUSER_EMAIL}

WEB_PORT=${WEB_PORT}
BRIDGE_PORT=${BRIDGE_PORT}
WEBSOCKET_PORT=${WEBSOCKET_PORT}
SITE_DOMAIN=${SITE_DOMAIN}
EOF

chmod 600 "${DATA_DIR}/secrets/credentials.txt"
chown "${APP_USER}:${APP_GROUP}" "${DATA_DIR}/secrets/credentials.txt"

log_info "Configuration values generated and saved"

# ============================================
# Step 5: Setup MySQL Database with Timezone
# ============================================
log_info "Configuring MySQL/MariaDB database..."

# Start MariaDB service
systemctl start mariadb
systemctl enable mariadb

# Create database, user, and setup timezone
mysql << EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON test_${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# Setup timezone data for MySQL
if command -v mysql_tzinfo_to_sql > /dev/null 2>&1; then
    mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root mysql 2>/dev/null || true
else
    log_warn "mysql_tzinfo_to_sql not found, skipping timezone setup"
    # Alternative method
    mysql -u root -e "USE mysql; CREATE TABLE IF NOT EXISTS time_zone (Time_zone_id INT UNSIGNED AUTO_INCREMENT NOT NULL PRIMARY KEY, Use_leap_seconds ENUM('Y','N') NOT NULL DEFAULT 'N') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;" 2>/dev/null || true
fi

mysql -u root -e "FLUSH TABLES;" mysql 2>/dev/null || true

log_info "Database configured successfully"

# ============================================
# Step 6: Setup Redis and Memcached
# ============================================
log_info "Configuring Redis and Memcached..."

# Configure Redis
systemctl restart redis-server
systemctl enable redis-server
systemctl restart memcached
systemctl enable memcached

log_info "Redis and Memcached configured"

# ============================================
# Step 7: Generate Django Configuration
# ============================================
log_info "Generating Django local_settings.py..."

# Create local_settings.py with all required settings using generated values
cat > "${APP_DIR}/dmoj/local_settings.py" << EOF
import os

# ============================================
# Basic Settings
# ============================================
DEBUG = ${DEBUG}
SECRET_KEY = '${SECRET_KEY}'
ALLOWED_HOSTS = ['*']

# Site settings
SITE_NAME = '${SITE_NAME}'
SITE_LONG_NAME = '${SITE_LONG_NAME}'
SITE_ADMIN_EMAIL = '${SITE_ADMIN_EMAIL}'
SITE_DOMAIN = '${SITE_DOMAIN}'

CSRF_TRUSTED_ORIGINS = [f'http://{SITE_DOMAIN}', f'http://{SITE_DOMAIN}:${WEB_PORT}']

# ============================================
# Database
# ============================================
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

# ============================================
# Cache
# ============================================
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.PyMemcacheCache',
        'LOCATION': '127.0.0.1:11211',
    }
}

# ============================================
# Paths
# ============================================
DMOJ_PROBLEM_DATA_ROOT = '${DATA_DIR}/problems'
STATIC_ROOT = '${DATA_DIR}/static'
MEDIA_ROOT = '${DATA_DIR}/media'

# ============================================
# Bridge Configuration
# ============================================
BRIDGED_JUDGE_ADDRESS = [('0.0.0.0', ${BRIDGE_PORT})]
BRIDGED_DJANGO_ADDRESS = [('localhost', 9998)]

# ============================================
# Event Daemon (WebSocket)
# ============================================
EVENT_DAEMON_USE = True
EVENT_DAEMON_KEY = '${EVENT_DAEMON_KEY}'
EVENT_DAEMON_URL = 'http://localhost:${WEBSOCKET_PORT}'
EVENT_DAEMON_PUBLIC_URL = 'http://localhost:${WEBSOCKET_PORT}'

# ============================================
# Celery (Background Tasks)
# ============================================
CELERY_BROKER_URL = 'redis://localhost:6379/0'
CELERY_RESULT_BACKEND = 'redis://localhost:6379/0'

# ============================================
# Chat System
# ============================================
CHAT_SECRET_KEY = '${CHAT_SECRET_KEY}'

# ============================================
# Static Files
# ============================================
STATICFILES_FINDERS = [
    'django.contrib.staticfiles.finders.FileSystemFinder',
    'django.contrib.staticfiles.finders.AppDirectoriesFinder',
    'compressor.finders.CompressorFinder',
]

# ============================================
# Logging
# ============================================
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'handlers': {
        'console': {
            'class': 'logging.StreamHandler',
        },
        'file': {
            'class': 'logging.FileHandler',
            'filename': '${LOG_DIR}/django/django.log',
            'level': 'INFO',
        },
    },
    'root': {
        'handlers': ['console', 'file'],
        'level': 'INFO',
    },
}

# ============================================
# Security (Development)
# ============================================
SESSION_COOKIE_SECURE = False
CSRF_COOKIE_SECURE = False
SECURE_PROXY_SSL_HEADER = None

# ============================================
# S3 Storage (Optional - uncomment to enable)
# ============================================
# DEFAULT_FILE_STORAGE = 'storages.backends.s3boto3.S3Boto3Storage'
# AWS_ACCESS_KEY_ID = os.environ.get('AWS_ACCESS_KEY_ID', '')
# AWS_SECRET_ACCESS_KEY = os.environ.get('AWS_SECRET_ACCESS_KEY', '')
# AWS_STORAGE_BUCKET_NAME = os.environ.get('AWS_STORAGE_BUCKET_NAME', '')
# AWS_S3_REGION_NAME = os.environ.get('AWS_S3_REGION_NAME', 'ap-southeast-1')
EOF

# Generate uWSGI configuration
cat > "${APP_DIR}/uwsgi.ini" << EOF
[uwsgi]
uwsgi-socket = /tmp/dmoj-site.sock
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

# Generate websocket configuration
cat > "${APP_DIR}/websocket/config.js" << EOF
module.exports = {
    get_host: '0.0.0.0',
    get_port: ${WEBSOCKET_PORT},
    post_host: '0.0.0.0',
    post_port: $((WEBSOCKET_PORT + 1)),
    http_host: '0.0.0.0',
    http_port: $((WEBSOCKET_PORT + 2)),
    long_poll_timeout: 29000,
    backend_auth_token: '${EVENT_DAEMON_KEY}',
};
EOF

log_info "Configuration files generated"

# ============================================
# Step 8: Setup Nginx with Profile Images Support
# ============================================
log_info "Configuring Nginx..."

cat > /etc/nginx/sites-available/capyjudge << EOF
server {
    listen ${WEB_PORT};
    server_name ${SITE_DOMAIN};
    
    access_log ${LOG_DIR}/nginx/access.log;
    error_log ${LOG_DIR}/nginx/error.log;
    
    # Static files
    location /static {
        alias ${DATA_DIR}/static;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # Media files
    location /media {
        alias ${DATA_DIR}/media;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # Profile images
    location /profile_images/ {
        alias ${APP_DIR}/profile_images/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # Organization images
    location /organization_images/ {
        alias ${APP_DIR}/organization_images/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # WebSocket
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
    }
    
    # Large file uploads for problems
    client_max_body_size 100M;
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;
}
EOF

# Enable site
ln -sf /etc/nginx/sites-available/capyjudge /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Create necessary directories for nginx
mkdir -p ${APP_DIR}/profile_images ${APP_DIR}/organization_images
sudo chown -R ${APP_USER}:${APP_GROUP} ${APP_DIR}/profile_images ${APP_DIR}/organization_images

# Test nginx configuration
sudo nginx -t
sudo systemctl restart nginx

log_info "Nginx configured successfully"

# ============================================
# Step 9: Setup Supervisor for All Services
# ============================================
log_info "Configuring Supervisor..."

# Site (uWSGI)
sudo cat > /etc/supervisor/conf.d/capyjudge-site.conf << EOF
[program:capyjudge-site]
command=${APP_HOME}/venv/bin/uwsgi --ini ${APP_DIR}/uwsgi.ini
directory=${APP_DIR}
user=${APP_USER}
group=${APP_GROUP}
stopsignal=QUIT
stdout_logfile=${LOG_DIR}/supervisor/site.log
stderr_logfile=${LOG_DIR}/supervisor/site_error.log
EOF

# Bridge
cat > /etc/supervisor/conf.d/capyjudge-bridged.conf << EOF
[program:capyjudge-bridged]
command=${APP_HOME}/venv/bin/python manage.py runbridged
directory=${APP_DIR}
stopsignal=INT
user=${APP_USER}
group=${APP_GROUP}
stdout_logfile=${LOG_DIR}/supervisor/bridged.log
stderr_logfile=${LOG_DIR}/supervisor/bridged_error.log
EOF

# Celery
cat > /etc/supervisor/conf.d/capyjudge-celery.conf << EOF
[program:capyjudge-celery]
command=${APP_HOME}/venv/bin/celery -A dmoj_celery worker
directory=${APP_DIR}
user=${APP_USER}
group=${APP_GROUP}
stdout_logfile=${LOG_DIR}/celery/celery.log
stderr_logfile=${LOG_DIR}/celery/celery_error.log
EOF

# WebSocket Event Daemon
cat > /etc/supervisor/conf.d/capyjudge-wsevent.conf << EOF
[program:capyjudge-wsevent]
command=node ${APP_DIR}/websocket/daemon.js
directory=${APP_DIR}
user=${APP_USER}
group=${APP_GROUP}
stdout_logfile=${LOG_DIR}/websocket/wsevent.log
stderr_logfile=${LOG_DIR}/websocket/wsevent_error.log
EOF

log_info "Supervisor configurations created"

# ============================================
# Step 10: Django Initialization
# ============================================
log_info "Running Django setup..."

cd "${APP_DIR}"

# Run Django commands as capyjudge user
sudo -u "${APP_USER}" bash << EOF
source ${APP_HOME}/venv/bin/activate
cd ${APP_DIR}
export DJANGO_SETTINGS_MODULE=dmoj.settings

# Compile CSS/SCSS
if [ -f "./make_style.sh" ]; then
    ./make_style.sh 2>/dev/null || true
fi

# Collect static files
python manage.py collectstatic --noinput 2>/dev/null || true

# Compile translations
python manage.py compilemessages 2>/dev/null || true
python manage.py compilejsi18n 2>/dev/null || true

# Run migrations
python manage.py migrate --noinput

# Load initial data (using correct fixture names from LQDOJ)
python manage.py loaddata navbar 2>/dev/null || true
python manage.py loaddata language_small 2>/dev/null || python manage.py loaddata language 2>/dev/null || true
python manage.py loaddata demo 2>/dev/null || true

# Create superuser if credentials provided
if [ ! -z "${DJANGO_SUPERUSER_USERNAME}" ] && [ ! -z "${DJANGO_SUPERUSER_PASSWORD}" ]; then
    echo "Creating superuser from environment..."
    python manage.py createsuperuser --noinput \
        --username "${DJANGO_SUPERUSER_USERNAME}" \
        --email "${DJANGO_SUPERUSER_EMAIL}" 2>/dev/null || true
fi

EOF

log_info "Django initialization complete"

# ============================================
# Step 11: Start Services
# ============================================
log_info "Starting all services..."

# Reload systemd
systemctl daemon-reload

# Start and enable all services
systemctl restart mariadb
systemctl enable mariadb

systemctl restart redis-server
systemctl enable redis-server

systemctl restart memcached
systemctl enable memcached

systemctl restart nginx
systemctl enable nginx

systemctl restart supervisor
systemctl enable supervisor

# Reload supervisor to pick up new configs
supervisorctl reread
supervisorctl update
supervisorctl start all

log_info "All services started"

# ============================================
# Step 12: Final Permissions and Cleanup
# ============================================
log_info "Final permissions check..."

# Ensure all directories have correct permissions
chown -R "${APP_USER}:${APP_GROUP}" "${DATA_DIR}" "${LOG_DIR}" "${APP_DIR}"
chmod -R 755 "${DATA_DIR}" "${LOG_DIR}"

# Ensure log files are writable
touch "${LOG_DIR}/django/django.log" 2>/dev/null || true
chown -R "${APP_USER}:${APP_GROUP}" "${LOG_DIR}"
find "${LOG_DIR}" -type f -exec chmod 644 {} \; 2>/dev/null || true

# Ensure nginx can read static files
chmod +x "${DATA_DIR}" 2>/dev/null || true
chmod +x "${DATA_DIR}/static" 2>/dev/null || true

# ============================================
# Installation Complete
# ============================================
log_info "========================================="
log_info "CapyJudge Installation Complete!"
log_info "========================================="
log_info "Installation Directory: ${APP_DIR}"
log_info "Data Directory: ${DATA_DIR}"
log_info "Logs Directory: ${LOG_DIR}"
log_info ""
log_info "Database: ${DB_NAME}"
log_info "Database User: ${DB_USER}"
log_info ""
log_info "Web Port: ${WEB_PORT}"
log_info "Bridge Port: ${BRIDGE_PORT}"
log_info "WebSocket Port: ${WEBSOCKET_PORT}"
log_info ""
log_info "Credentials saved in: ${DATA_DIR}/secrets/credentials.txt"
log_info "Secret keys saved in: ${DATA_DIR}/secrets/"
log_info ""
log_info "Access CapyJudge at: http://${SITE_DOMAIN}:${WEB_PORT}"
log_info ""
log_info "Superuser Account:"
log_info "  Username: ${DJANGO_SUPERUSER_USERNAME}"
log_info "  Password: ${DJANGO_SUPERUSER_PASSWORD}"
log_info "========================================="

# Test if services are running
sleep 3
if supervisorctl status | grep -q "RUNNING"; then
    log_info "Services are running successfully!"
else
    log_warn "Some services may not be running. Check with: capyjudge-status"
fi

exit 0
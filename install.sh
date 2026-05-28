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
    python3 -c "import secrets; import string; chars = string.ascii_letters + string.digits + string.punctuation; print(''.join(secrets.choice(chars) for _ in range(50)))"
}

generate_fernet_key() {
    python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
}

generate_random_password() {
    python3 -c "import secrets; import string; chars = string.ascii_letters + string.digits; print(''.join(secrets.choice(chars) for _ in range(32)))"
}

load_env_file() {
    if [ -f "$ENV_FILE" ]; then
        log_info "Loading existing .env file from $ENV_FILE"
        set -a
        source "$ENV_FILE"
        set +a
        return 0
    else
        return 1
    fi
}

create_env_file() {
    log_info "Creating new .env file from template"
    
    # Generate random passwords if not set
    DB_PASSWORD="${DB_PASSWORD:-$(generate_random_password)}"
    DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(generate_random_password)}"
    SECRET_KEY="${SECRET_KEY:-$(generate_secret_key)}"
    CHAT_SECRET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
    EVENT_DAEMON_KEY="${EVENT_DAEMON_KEY:-$(generate_random_password)}"
    
    # Save secrets to files for persistence
    mkdir -p "${DATA_DIR}/secrets"
    echo "$SECRET_KEY" > "${DATA_DIR}/secrets/SECRET_KEY"
    echo "$CHAT_SECRET_KEY" > "${DATA_DIR}/secrets/CHAT_SECRET_KEY"
    echo "$EVENT_DAEMON_KEY" > "${DATA_DIR}/secrets/EVENT_DAEMON_KEY"
    echo "$DB_PASSWORD" > "${DATA_DIR}/secrets/DB_PASSWORD"
    
    cat > "$ENV_FILE" << 'ENVEOF'
# ============================================
# Ports configuration
# ============================================
WEB_PORT=80
BRIDGE_PORT=9999
WEBSOCKET_PORT=15100

# ============================================
# Database (required)
# ============================================
DB_NAME=capyjudge
DB_USER=capyjudge
DB_PASSWORD=CHANGE_ME
DB_HOST=localhost
DB_PORT=3306
DB_ROOT_PASSWORD=CHANGE_ME

# ============================================
# Django
# ============================================
DEBUG=False
SITE_DOMAIN=localhost
SITE_NAME=CapyJudge
SITE_LONG_NAME=CapyJudge Online Judge
SITE_ADMIN_EMAIL=admin@capyjudge.com

# ============================================
# Superuser (optional - auto create)
# ============================================
DJANGO_SUPERUSER_USERNAME=admin
DJANGO_SUPERUSER_PASSWORD=admin123
DJANGO_SUPERUSER_EMAIL=capyjudge@gmail.com

# ============================================
# Redis & Cache
# ============================================
REDIS_URL=redis://localhost:6379/0
MEMCACHED_URL=127.0.0.1:11211

# ============================================
# Judge (optional)
# ============================================
JUDGE_NAME=judge-0
CELERY_CONCURRENCY=2

# ============================================
# Security Keys (auto-generated)
# ============================================
ENVEOF

    # Append keys without using EOF with variable substitution
    echo "SECRET_KEY=${SECRET_KEY}" >> "$ENV_FILE"
    echo "CHAT_SECRET_KEY=${CHAT_SECRET_KEY}" >> "$ENV_FILE"
    echo "EVENT_DAEMON_KEY=${EVENT_DAEMON_KEY}" >> "$ENV_FILE"
    
    cat >> "$ENV_FILE" << 'ENVEOF'

# ============================================
# Event Daemon
# ============================================
EVENT_DAEMON_URL=http://localhost:15100
EVENT_DAEMON_PUBLIC_URL=http://localhost:15100

# ============================================
# Organization Subdomain (optional)
# ============================================
# USE_SUBDOMAIN=False
ENVEOF

    chown "${APP_USER}:${APP_GROUP}" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log_info ".env file created at $ENV_FILE"
}

# ============================================
# Step 0: System Prerequisites & Virtual Environment
# ============================================
log_info "Step 0: Installing system dependencies and setting up virtual environment..."

# Update package list
apt-get update -y

# Install essential packages
apt-get install -y \
    git curl wget gnupg lsb-release ca-certificates \
    python3 python3-pip python3-dev python3-venv python3-full \
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
    libpq-dev

apt-get install -y mariadb-server

# Install Node.js 18.x (required for websocket)
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs

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
    python3-dev \
    pkg-config

# Create virtual environment
if [ ! -d "${APP_HOME}/venv" ]; then
    sudo -u "${APP_USER}" python3 -m venv "${APP_HOME}/venv"
    log_info "Virtual environment created"
fi

# Install all Python dependencies in venv
sudo -u "${APP_USER}" bash << EOF
source ${APP_HOME}/venv/bin/activate
pip install --upgrade pip setuptools wheel
if [ -f "${APP_DIR}/requirements.txt" ]; then
    pip install -r "${APP_DIR}/requirements.txt"
fi
pip install mysqlclient uwsgi websocket-client celery redis django-compressor cryptography boto3 django-storages
pre-commit install
EOF

# Install Node dependencies for websocket
cd "${APP_DIR}/websocket"
sudo -u "${APP_USER}" npm install express socket.io qu ws simplesets
cd "${APP_DIR}"

log_info "All dependencies installed"

# ============================================
# Step 4: Check or Create .env file (NOW Django is available)
# ============================================
log_info "Checking for .env file..."

# Create .env.example if not exists
if [ ! -f "${ENV_EXAMPLE}" ]; then
    log_warn ".env.example not found, creating default template"
    cat > "${ENV_EXAMPLE}" << 'EOF'
# CapyJudge Environment Configuration Example
# Copy this file to .env and modify as needed

# Ports
WEB_PORT=80
BRIDGE_PORT=9999
WEBSOCKET_PORT=15100

# Database
DB_NAME=capyjudge
DB_USER=capyjudge
DB_PASSWORD=your_strong_password
DB_HOST=localhost
DB_PORT=3306

# Django
DEBUG=False
SITE_DOMAIN=localhost
SITE_NAME=CapyJudge

# Security (Django will generate these automatically)
SECRET_KEY=your-secret-key-here
CHAT_SECRET_KEY=your-fernet-key-here
EVENT_DAEMON_KEY=your-event-key-here

# Redis
REDIS_URL=redis://localhost:6379/0

# Memcached
MEMCACHED_URL=127.0.0.1:11211

# Superuser
DJANGO_SUPERUSER_USERNAME=admin
DJANGO_SUPERUSER_PASSWORD=admin123
DJANGO_SUPERUSER_EMAIL=admin@capyjudge.com
EOF
    chown "${APP_USER}:${APP_GROUP}" "${ENV_EXAMPLE}"
fi

# Load existing .env or create new one (now Django is available for key generation)
if load_env_file; then
    log_info "Using existing .env configuration"
else
    log_warn "No .env file found, creating from template"
    create_env_file
    load_env_file
fi

# ============================================
# Step 5: Setup MySQL Database with Timezone
# ============================================
log_info "Configuring MySQL/MariaDB database..."

# Start MariaDB service
systemctl start mariadb
systemctl enable mariadb

# Create database, user, and setup timezone
mysql << EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME:-capyjudge} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER:-capyjudge}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME:-capyjudge}.* TO '${DB_USER:-capyjudge}'@'localhost';
GRANT ALL PRIVILEGES ON test_${DB_NAME:-capyjudge}.* TO '${DB_USER:-capyjudge}'@'localhost';
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
mkdir -p /etc/redis/redis.conf.d/
cat > /etc/redis/redis.conf.d/99-capyjudge.conf << EOF
maxmemory 256mb
maxmemory-policy allkeys-lru
save 900 1
save 300 10
save 60 10000
EOF

# Or append directly to redis.conf if directory doesn't work
if [ ! -d "/etc/redis/redis.conf.d" ]; then
    echo "" >> /etc/redis/redis.conf
    echo "# CapyJudge Settings" >> /etc/redis/redis.conf
    echo "maxmemory 256mb" >> /etc/redis/redis.conf
    echo "maxmemory-policy allkeys-lru" >> /etc/redis/redis.conf
fi

# Configure Memcached
sed -i 's/-m 64/-m 256/' /etc/memcached.conf
sed -i 's/-l 127.0.0.1/-l 0.0.0.0/' /etc/memcached.conf

# Restart services
systemctl restart redis-server
systemctl enable redis-server
systemctl restart memcached
systemctl enable memcached

log_info "Redis and Memcached configured"

# ============================================
# Step 7: Generate Django Configuration
# ============================================
log_info "Generating Django local_settings.py..."

# Create local_settings.py with all required settings
cat > "${APP_DIR}/dmoj/local_settings.py" << EOF
import os

# ============================================
# Basic Settings
# ============================================
DEBUG = os.environ.get('DEBUG', 'False') == 'True'
SECRET_KEY = os.environ.get('SECRET_KEY', '')
ALLOWED_HOSTS = ['*']

# Site settings
SITE_NAME = os.environ.get('SITE_NAME', 'CapyJudge')
SITE_LONG_NAME = os.environ.get('SITE_LONG_NAME', 'CapyJudge Online Judge')
SITE_ADMIN_EMAIL = os.environ.get('SITE_ADMIN_EMAIL', 'admin@localhost')
SITE_DOMAIN = os.environ.get('SITE_DOMAIN', 'localhost')

CSRF_TRUSTED_ORIGINS = [f'http://{SITE_DOMAIN}', f'http://{SITE_DOMAIN}:{os.environ.get("WEB_PORT", "80")}']

# ============================================
# Database
# ============================================
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': os.environ.get('DB_NAME', 'capyjudge'),
        'USER': os.environ.get('DB_USER', 'capyjudge'),
        'PASSWORD': os.environ.get('DB_PASSWORD', ''),
        'HOST': os.environ.get('DB_HOST', 'localhost'),
        'PORT': os.environ.get('DB_PORT', '3306'),
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
        'LOCATION': os.environ.get('MEMCACHED_URL', '127.0.0.1:11211'),
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
BRIDGED_JUDGE_ADDRESS = [('0.0.0.0', int(os.environ.get('BRIDGE_PORT', '9999')))]
BRIDGED_DJANGO_ADDRESS = [('localhost', 9998)]

# ============================================
# Event Daemon (WebSocket)
# ============================================
EVENT_DAEMON_USE = True
EVENT_DAEMON_KEY = os.environ.get('EVENT_DAEMON_KEY', '')
EVENT_DAEMON_URL = os.environ.get('EVENT_DAEMON_URL', 'http://localhost:15100')
EVENT_DAEMON_PUBLIC_URL = os.environ.get('EVENT_DAEMON_PUBLIC_URL', 'http://localhost:15100')

# ============================================
# Celery (Background Tasks)
# ============================================
CELERY_BROKER_URL = os.environ.get('REDIS_URL', 'redis://localhost:6379/0')
CELERY_RESULT_BACKEND = os.environ.get('REDIS_URL', 'redis://localhost:6379/0')

# ============================================
# Chat System
# ============================================
CHAT_SECRET_KEY = os.environ.get('CHAT_SECRET_KEY', '')

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
chmod-socket = 666
chdir = ${APP_DIR}
pythonpath = ${APP_DIR}
home = ${APP_HOME}/venv
protocol = uwsgi
master = true
env = DJANGO_SETTINGS_MODULE=dmoj.settings
module = dmoj.wsgi:application
optimize = 2
memory-report = true
workers = 4
threads = 2
harakiri = 15
max-requests = 5000
vacuum = true
die-on-term = true
logto = ${LOG_DIR}/uwsgi/uwsgi.log
log-reopen = true
uid = ${APP_USER}
gid = ${APP_GROUP}
buffer-size = 32768
post-buffering = 8192
socket-timeout = 30
EOF

# Generate websocket configuration
cat > "${APP_DIR}/websocket/config.js" << EOF
module.exports = {
    get_host: '0.0.0.0',
    get_port: ${WEBSOCKET_PORT:-15100},
    post_host: '0.0.0.0',
    post_port: ${WEBSOCKET_PORT:-15101},
    http_host: '0.0.0.0',
    http_port: ${WEBSOCKET_PORT:-15102},
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
    listen ${WEB_PORT:-80};
    server_name ${SITE_DOMAIN:-localhost};
    
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
    
    # Profile images (LQDOJ feature)
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
        proxy_pass http://127.0.0.1:${WEBSOCKET_PORT:-15100}/socket.io/;
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
chown -R ${APP_USER}:${APP_GROUP} ${APP_DIR}/profile_images ${APP_DIR}/organization_images

# Test nginx configuration
nginx -t

log_info "Nginx configured successfully"

# ============================================
# Step 9: Setup Supervisor for All Services
# ============================================
log_info "Configuring Supervisor..."

# Site (uWSGI)
cat > /etc/supervisor/conf.d/capyjudge-site.conf << EOF
[program:capyjudge-site]
command=${APP_HOME}/venv/bin/uwsgi --ini ${APP_DIR}/uwsgi.ini
directory=${APP_DIR}
user=${APP_USER}
autostart=true
autorestart=true
stdout_logfile=${LOG_DIR}/supervisor/site.log
stdout_logfile_maxbytes=10MB
stderr_logfile=${LOG_DIR}/supervisor/site_error.log
stderr_logfile_maxbytes=10MB
environment=DJANGO_SETTINGS_MODULE="dmoj.settings",PYTHONPATH="${APP_DIR}",SECRET_KEY="${SECRET_KEY}",DB_PASSWORD="${DB_PASSWORD}",CHAT_SECRET_KEY="${CHAT_SECRET_KEY}",EVENT_DAEMON_KEY="${EVENT_DAEMON_KEY}",DEBUG="${DEBUG}",SITE_DOMAIN="${SITE_DOMAIN}",BRIDGE_PORT="${BRIDGE_PORT:-9999}",WEB_PORT="${WEB_PORT:-80}"
EOF

# Bridge
cat > /etc/supervisor/conf.d/capyjudge-bridged.conf << EOF
[program:capyjudge-bridged]
command=${APP_HOME}/venv/bin/python3 ${APP_DIR}/manage.py runbridged
directory=${APP_DIR}
user=${APP_USER}
autostart=true
autorestart=true
stdout_logfile=${LOG_DIR}/supervisor/bridged.log
stdout_logfile_maxbytes=10MB
stderr_logfile=${LOG_DIR}/supervisor/bridged_error.log
stderr_logfile_maxbytes=10MB
environment=DJANGO_SETTINGS_MODULE="dmoj.settings",PYTHONPATH="${APP_DIR}",SECRET_KEY="${SECRET_KEY}",DB_PASSWORD="${DB_PASSWORD}",BRIDGE_PORT="${BRIDGE_PORT:-9999}"
EOF

# Celery
cat > /etc/supervisor/conf.d/capyjudge-celery.conf << EOF
[program:capyjudge-celery]
command=${APP_HOME}/venv/bin/celery -A dmoj_celery worker --concurrency=${CELERY_CONCURRENCY:-2} --loglevel=info
directory=${APP_DIR}
user=${APP_USER}
autostart=true
autorestart=true
stdout_logfile=${LOG_DIR}/celery/celery.log
stdout_logfile_maxbytes=10MB
stderr_logfile=${LOG_DIR}/celery/celery_error.log
stderr_logfile_maxbytes=10MB
environment=DJANGO_SETTINGS_MODULE="dmoj.settings"
EOF

# WebSocket Event Daemon
cat > /etc/supervisor/conf.d/capyjudge-wsevent.conf << EOF
[program:capyjudge-wsevent]
command=node ${APP_DIR}/websocket/daemon.js
directory=${APP_DIR}
user=${APP_USER}
autostart=true
autorestart=true
stdout_logfile=${LOG_DIR}/websocket/wsevent.log
stdout_logfile_maxbytes=10MB
stderr_logfile=${LOG_DIR}/websocket/wsevent_error.log
stderr_logfile_maxbytes=10MB
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
export SECRET_KEY="${SECRET_KEY}"
export DB_PASSWORD="${DB_PASSWORD}"
export CHAT_SECRET_KEY="${CHAT_SECRET_KEY}"
export EVENT_DAEMON_KEY="${EVENT_DAEMON_KEY}"
export DEBUG="${DEBUG}"
export BRIDGE_PORT="${BRIDGE_PORT:-9999}"

# Compile CSS/SCSS
if [ -f "./make_style.sh" ]; then
    ./make_style.sh 2>/dev/null || true
fi

# Collect static files
python3 manage.py collectstatic --noinput 2>/dev/null || true

# Compile translations
python3 manage.py compilemessages 2>/dev/null || true
python3 manage.py compilejsi18n 2>/dev/null || true

# Run migrations
python3 manage.py migrate --noinput

# Load initial data (using correct fixture names from LQDOJ)
python3 manage.py loaddata navbar 2>/dev/null || true
python3 manage.py loaddata language_small 2>/dev/null || python3 manage.py loaddata language 2>/dev/null || true
python3 manage.py loaddata demo 2>/dev/null || true

# Create superuser if credentials provided
if [ ! -z "${DJANGO_SUPERUSER_USERNAME}" ] && [ ! -z "${DJANGO_SUPERUSER_PASSWORD}" ]; then
    echo "Creating superuser from environment..."
    python3 manage.py createsuperuser --noinput \
        --username "${DJANGO_SUPERUSER_USERNAME}" \
        --email "${DJANGO_SUPERUSER_EMAIL:-admin@capyjudge.com}" 2>/dev/null || true
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
# Create Management Scripts
# ============================================

# Status check script
cat > /usr/local/bin/capyjudge-status << 'EOF'
#!/bin/bash
echo "========================================="
echo "CapyJudge Service Status"
echo "========================================="
echo ""
echo "Supervisor Services:"
supervisorctl status
echo ""
echo "Nginx:"
systemctl status nginx --no-pager | grep "Active:"
echo ""
echo "MariaDB:"
systemctl status mariadb --no-pager | grep "Active:"
echo ""
echo "Redis:"
systemctl status redis-server --no-pager | grep "Active:"
echo ""
echo "Memcached:"
systemctl status memcached --no-pager | grep "Active:"
echo ""
echo "========================================="
echo "Recent Logs (last 5 lines each)"
echo "========================================="
echo "--- Site ---"
tail -5 /home/capyjudge/logs/supervisor/site.log 2>/dev/null || echo "No log yet"
echo ""
echo "--- Bridge ---"
tail -5 /home/capyjudge/logs/supervisor/bridged.log 2>/dev/null || echo "No log yet"
echo ""
echo "--- WebSocket ---"
tail -5 /home/capyjudge/logs/websocket/wsevent.log 2>/dev/null || echo "No log yet"
echo ""
echo "--- Celery ---"
tail -5 /home/capyjudge/logs/celery/celery.log 2>/dev/null || echo "No log yet"
EOF

# Restart script
cat > /usr/local/bin/capyjudge-restart << 'EOF'
#!/bin/bash
echo "Restarting CapyJudge services..."
supervisorctl restart all
systemctl restart nginx
echo "Services restarted"
echo "Run 'capyjudge-status' to check status"
EOF

# View logs script
cat > /usr/local/bin/capyjudge-logs << 'EOF'
#!/bin/bash
SERVICE=$1
if [ -z "$SERVICE" ]; then
    echo "Usage: capyjudge-logs [site|bridge|celery|wsevent|all]"
    echo ""
    echo "Available services:"
    echo "  site     - Django uWSGI logs"
    echo "  bridge   - Judge bridge logs"
    echo "  celery   - Celery worker logs"
    echo "  wsevent  - WebSocket event daemon logs"
    echo "  all      - Show all logs with multitail"
    exit 1
fi

case $SERVICE in
    site)
        tail -f /home/capyjudge/logs/supervisor/site.log
        ;;
    bridge)
        tail -f /home/capyjudge/logs/supervisor/bridged.log
        ;;
    celery)
        tail -f /home/capyjudge/logs/celery/celery.log
        ;;
    wsevent)
        tail -f /home/capyjudge/logs/websocket/wsevent.log
        ;;
    all)
        if command -v multitail &> /dev/null; then
            multitail /home/capyjudge/logs/supervisor/site.log \
                     /home/capyjudge/logs/supervisor/bridged.log \
                     /home/capyjudge/logs/websocket/wsevent.log
        else
            echo "Install multitail for combined log viewing: sudo apt install multitail"
            echo "Showing site log only..."
            tail -f /home/capyjudge/logs/supervisor/site.log
        fi
        ;;
    *)
        echo "Unknown service: $SERVICE"
        exit 1
        ;;
esac
EOF

chmod +x /usr/local/bin/capyjudge-status
chmod +x /usr/local/bin/capyjudge-restart
chmod +x /usr/local/bin/capyjudge-logs

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
log_info "Database: ${DB_NAME:-capyjudge}"
log_info "Database User: ${DB_USER:-capyjudge}"
log_info ""
log_info "Web Port: ${WEB_PORT:-80}"
log_info "Bridge Port: ${BRIDGE_PORT:-9999}"
log_info "WebSocket Port: ${WEBSOCKET_PORT:-15100}"
log_info ""
log_info "Environment file: ${ENV_FILE}"
log_info "Secret keys saved in: ${DATA_DIR}/secrets/"
log_info ""
log_info "Management Commands:"
log_info "  capyjudge-status   - Check all service statuses"
log_info "  capyjudge-restart  - Restart all services"
log_info "  capyjudge-logs     - View logs for specific service"
log_info ""
log_info "Access CapyJudge at: http://${SITE_DOMAIN:-localhost}:${WEB_PORT:-80}"
log_info ""
log_info "Superuser Account (if created):"
log_info "  Username: ${DJANGO_SUPERUSER_USERNAME:-admin}"
log_info "  Password: ${DJANGO_SUPERUSER_PASSWORD:-admin123}"
log_info "========================================="

# Test if services are running
sleep 3
if supervisorctl status | grep -q "RUNNING"; then
    log_info "Services are running successfully!"
else
    log_warn "Some services may not be running. Check with: capyjudge-status"
fi

exit 0

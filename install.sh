#!/bin/bash
set -e

# ============================================
# CapyJudge All-in-One Installation Script
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
# Helper functions
# ============================================
generate_secret_key() {
    python3 -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())"
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
    CHAT_SECRET_KEY="${CHAT_SECRET_KEY:-$(generate_fernet_key)}"
    EVENT_DAEMON_KEY="${EVENT_DAEMON_KEY:-$(generate_random_password)}"
    
    # Save secrets to files for persistence
    mkdir -p "${DATA_DIR}/secrets"
    echo "$SECRET_KEY" > "${DATA_DIR}/secrets/SECRET_KEY"
    echo "$CHAT_SECRET_KEY" > "${DATA_DIR}/secrets/CHAT_SECRET_KEY"
    echo "$EVENT_DAEMON_KEY" > "${DATA_DIR}/secrets/EVENT_DAEMON_KEY"
    echo "$DB_PASSWORD" > "${DATA_DIR}/secrets/DB_PASSWORD"
    
    cat > "$ENV_FILE" << EOF
# ============================================
# Ports configuration
# ============================================
WEB_PORT=${WEB_PORT:-8000}
BRIDGE_PORT=${BRIDGE_PORT:-9999}

# ============================================
# Database (required)
# ============================================
DB_PASSWORD=${DB_PASSWORD}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}

# ============================================
# Django
# ============================================
DEBUG=${DEBUG:-False}
SITE_DOMAIN=${SITE_DOMAIN:-localhost}
SITE_NAME=${SITE_NAME:-CapyJudge}

# ============================================
# Superuser (optional - auto create)
# ============================================
DJANGO_SUPERUSER_USERNAME=${DJANGO_SUPERUSER_USERNAME:-admin}
DJANGO_SUPERUSER_PASSWORD=${DJANGO_SUPERUSER_PASSWORD:-admin123}
DJANGO_SUPERUSER_EMAIL=${DJANGO_SUPERUSER_EMAIL:-capyjudge@gmail.com}

# ============================================
# Judge (optional)
# ============================================
JUDGE_NAME=${JUDGE_NAME:-judge-0}
CELERY_CONCURRENCY=${CELERY_CONCURRENCY:-2}

# ============================================
# Email (optional)
# ============================================
# EMAIL_HOST=smtp.gmail.com
# EMAIL_PORT=587
# EMAIL_USER=capyjudge@gmail.com
# EMAIL_PASSWORD=your-app-password
# EMAIL_USE_TLS=True
# DEFAULT_FROM_EMAIL=capyjudge@gmail.com

# ============================================
# Internal Keys (auto-generated)
# ============================================
SECRET_KEY=${SECRET_KEY}
CHAT_SECRET_KEY=${CHAT_SECRET_KEY}
EVENT_DAEMON_KEY=${EVENT_DAEMON_KEY}
EOF

    chown "${APP_USER}:${APP_GROUP}" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log_info ".env file created at $ENV_FILE"
}

# ============================================
# Step 0: System Prerequisites
# ============================================
log_info "Step 0: Installing system dependencies..."

# Update package list
apt-get update -y

# Install essential packages
apt-get install -y \
    git curl wget gnupg lsb-release ca-certificates \
    python3 python3-pip python3-dev python3-venv \
    gcc g++ make \
    libxml2-dev libxslt1-dev zlib1g-dev \
    gettext pkg-config \
    mariadb-client libmariadb-dev \
    nginx supervisor \
    nodejs npm \
    netcat-openbsd \
    redis-server \
    mariadb-server \
    build-essential \
    libssl-dev \
    libffi-dev

# Install Node.js tools
npm install -g sass postcss-cli postcss autoprefixer

# Upgrade pip
pip3 install --upgrade pip

# Install Python packages
pip3 install \
    PyMySQL mysqlclient \
    uwsgi websocket-client \
    celery redis \
    django-compressor \
    cryptography

log_info "System dependencies installed successfully"

# ============================================
# Step 1: Create User and Group
# ============================================
log_info "Step 1: Creating capyjudge user and group..."

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
# Step 2: Create Directory Structure
# ============================================
log_info "Step 2: Creating directory structure..."

# Create directories
mkdir -p "${DATA_DIR}"/{static,media,problems,secrets}
mkdir -p "${LOG_DIR}"/{nginx,supervisor,uwsgi,django}
mkdir -p "${APP_DIR}"

# Set ownership
chown -R "${APP_USER}:${APP_GROUP}" "${DATA_DIR}" "${LOG_DIR}" "${APP_DIR}"
chmod 755 "${DATA_DIR}" "${LOG_DIR}"

log_info "Directory structure created"

# ============================================
# Step 3: Clone Repository
# ============================================
log_info "Step 3: Cloning CapyJudge repository..."

if [ -d "${APP_DIR}/.git" ]; then
    log_warn "Repository already exists, pulling latest changes"
    cd "${APP_DIR}"
    sudo -u "${APP_USER}" git pull
else
    sudo -u "${APP_USER}" git clone https://github.com/a3chuyentin/capyjudge.git "${APP_DIR}"
    log_info "Repository cloned successfully"
fi

cd "${APP_DIR}"

# ============================================
# Step 4: Check or Create .env file
# ============================================
log_info "Step 4: Checking for .env file..."

# First, check if .env.example exists in repository
if [ ! -f "${ENV_EXAMPLE}" ]; then
    log_warn ".env.example not found in repository, creating default template"
    cat > "${ENV_EXAMPLE}" << 'EOF'
# ============================================
# Ports configuration
# ============================================
WEB_PORT=8000
BRIDGE_PORT=9999

# ============================================
# Database (required)
# ============================================
DB_PASSWORD=your_strong_db_password_here
DB_ROOT_PASSWORD=your_root_password_here

# ============================================
# Django
# ============================================
DEBUG=False
SITE_DOMAIN=localhost
SITE_NAME=CapyJudge

# ============================================
# Superuser (optional - auto create)
# ============================================
DJANGO_SUPERUSER_USERNAME=admin
DJANGO_SUPERUSER_PASSWORD=admin123
DJANGO_SUPERUSER_EMAIL=capyjudge@gmail.com

# ============================================
# Judge (optional)
# ============================================
JUDGE_NAME=judge-0
CELERY_CONCURRENCY=2

# ============================================
# Email (optional)
# ============================================
# EMAIL_HOST=smtp.gmail.com
# EMAIL_PORT=587
# EMAIL_USER=capyjudge@gmail.com
# EMAIL_PASSWORD=your-app-password
# EMAIL_USE_TLS=True
# DEFAULT_FROM_EMAIL=capyjudge@gmail.com
EOF
    chown "${APP_USER}:${APP_GROUP}" "${ENV_EXAMPLE}"
fi

# Load existing .env or create new one
if load_env_file; then
    log_info "Using existing .env configuration"
else
    log_warn "No .env file found, creating from template"
    create_env_file
    load_env_file
fi

# ============================================
# Step 5: Install Python Dependencies
# ============================================
log_info "Step 5: Installing Python dependencies..."

# Create virtual environment
if [ ! -d "${APP_HOME}/venv" ]; then
    sudo -u "${APP_USER}" python3 -m venv "${APP_HOME}/venv"
fi

# Install requirements
sudo -u "${APP_USER}" bash << EOF
source ${APP_HOME}/venv/bin/activate
pip install --upgrade pip
if [ -f "${APP_DIR}/requirements.txt" ]; then
    pip install -r "${APP_DIR}/requirements.txt"
fi
pip install uwsgi websocket-client
EOF

# Install Node dependencies for websocket
cd "${APP_DIR}/websocket"
sudo -u "${APP_USER}" npm install express socket.io qu ws simplesets
cd "${APP_DIR}"

log_info "Dependencies installed"

# ============================================
# Step 6: Setup MySQL Database
# ============================================
log_info "Step 6: Configuring MySQL database..."

# Start MySQL service
systemctl start mariadb
systemctl enable mariadb

# Create database and user
mysql << EOF
CREATE DATABASE IF NOT EXISTS capyjudge CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'capyjudge'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON capyjudge.* TO 'capyjudge'@'localhost';
FLUSH PRIVILEGES;
EOF

log_info "Database configured successfully"

# ============================================
# Step 7: Generate Configuration Files
# ============================================
log_info "Step 7: Generating Django configuration..."

# Create local_settings.py
cat > "${APP_DIR}/dmoj/local_settings.py" << 'EOF'
import os

DEBUG = os.environ.get('DEBUG', 'False') == 'True'
SECRET_KEY = os.environ.get('SECRET_KEY', '')
ALLOWED_HOSTS = ['*']
CSRF_TRUSTED_ORIGINS = ['http://localhost', 'http://127.0.0.1']

SITE_NAME = os.environ.get('SITE_NAME', 'CapyJudge')
SITE_LONG_NAME = os.environ.get('SITE_LONG_NAME', 'CapyJudge Online Judge')
SITE_ADMIN_EMAIL = os.environ.get('SITE_ADMIN_EMAIL', 'admin@localhost')
SITE_DOMAIN = os.environ.get('SITE_DOMAIN', 'localhost')

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': 'capyjudge',
        'USER': 'capyjudge',
        'PASSWORD': os.environ.get('DB_PASSWORD', ''),
        'HOST': 'localhost',
        'PORT': '3306',
        'OPTIONS': {'charset': 'utf8mb4', 'sql_mode': 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'},
    }
}

CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.locmem.LocMemCache',
        'LOCATION': 'unique-snowflake',
    }
}

DMOJ_PROBLEM_DATA_ROOT = '/home/capyjudge/capyjudge-data/problems'
STATIC_ROOT = '/home/capyjudge/capyjudge-data/static'
MEDIA_ROOT = '/home/capyjudge/capyjudge-data/media'

BRIDGED_JUDGE_ADDRESS = [('0.0.0.0', int(os.environ.get('BRIDGE_PORT', '9999')))]
BRIDGED_DJANGO_ADDRESS = [('localhost', 9998)]

EVENT_DAEMON_USE = True
EVENT_DAEMON_KEY = os.environ.get('EVENT_DAEMON_KEY', '')
EVENT_DAEMON_URL = os.environ.get('EVENT_DAEMON_URL', 'http://localhost:15100')
EVENT_DAEMON_PUBLIC_URL = os.environ.get('EVENT_DAEMON_PUBLIC_URL', 'http://localhost:15100')

CELERY_BROKER_URL = os.environ.get('REDIS_URL', 'redis://localhost:6379/0')
CELERY_RESULT_BACKEND = os.environ.get('REDIS_URL', 'redis://localhost:6379/0')

CHAT_SECRET_KEY = os.environ.get('CHAT_SECRET_KEY', '')

STATICFILES_FINDERS = [
    'django.contrib.staticfiles.finders.FileSystemFinder',
    'django.contrib.staticfiles.finders.AppDirectoriesFinder',
    'compressor.finders.CompressorFinder',
]

LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'handlers': {
        'console': {'class': 'logging.StreamHandler'},
        'file': {
            'class': 'logging.FileHandler',
            'filename': '/home/capyjudge/logs/django/django.log',
        },
    },
    'root': {'handlers': ['console', 'file'], 'level': 'INFO'},
}

SESSION_COOKIE_SECURE = False
CSRF_COOKIE_SECURE = False
SECURE_PROXY_SSL_HEADER = None
EOF

# Generate uWSGI configuration
cat > "${APP_DIR}/uwsgi.ini" << EOF
[uwsgi]
uwsgi-socket = /tmp/dmoj-site.sock
chmod-socket = 666
chdir = ${APP_DIR}
pythonpath = ${APP_DIR}
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
EOF

# Generate websocket configuration
cat > "${APP_DIR}/websocket/config.js" << EOF
module.exports = {
    get_host: '0.0.0.0',
    get_port: 15100,
    post_host: '0.0.0.0',
    post_port: 15101,
    http_host: '0.0.0.0',
    http_port: 15102,
    long_poll_timeout: 29000,
    backend_auth_token: '${EVENT_DAEMON_KEY}',
};
EOF

log_info "Configuration files generated"

# ============================================
# Step 8: Setup Nginx
# ============================================
log_info "Step 8: Configuring Nginx..."

cat > /etc/nginx/sites-available/capyjudge << EOF
server {
    listen ${WEB_PORT:-80};
    server_name ${SITE_DOMAIN:-localhost};
    
    access_log ${LOG_DIR}/nginx/access.log;
    error_log ${LOG_DIR}/nginx/error.log;
    
    location /static {
        alias ${DATA_DIR}/static;
    }
    
    location /media {
        alias ${DATA_DIR}/media;
    }
    
    location /socket.io/ {
        proxy_pass http://127.0.0.1:15100/socket.io/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    
    location / {
        include uwsgi_params;
        uwsgi_pass unix:///tmp/dmoj-site.sock;
        uwsgi_param UWSGI_SCHEME \$scheme;
        uwsgi_param SERVER_SOFTWARE nginx/\$nginx_version;
    }
    
    client_max_body_size 100M;
}
EOF

# Enable site
ln -sf /etc/nginx/sites-available/capyjudge /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Test nginx configuration
nginx -t

log_info "Nginx configured successfully"

# ============================================
# Step 9: Setup Supervisor
# ============================================
log_info "Step 9: Configuring Supervisor..."

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
environment=DJANGO_SETTINGS_MODULE="dmoj.settings",PYTHONPATH="${APP_DIR}",SECRET_KEY="${SECRET_KEY}",DB_PASSWORD="${DB_PASSWORD}",CHAT_SECRET_KEY="${CHAT_SECRET_KEY}",EVENT_DAEMON_KEY="${EVENT_DAEMON_KEY}",DEBUG="${DEBUG}",SITE_DOMAIN="${SITE_DOMAIN}",BRIDGE_PORT="${BRIDGE_PORT:-9999}"
EOF

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

cat > /etc/supervisor/conf.d/capyjudge-celery.conf << EOF
[program:capyjudge-celery]
command=${APP_HOME}/venv/bin/celery -A dmoj_celery worker --concurrency=${CELERY_CONCURRENCY:-2}
directory=${APP_DIR}
user=${APP_USER}
autostart=true
autorestart=true
stdout_logfile=${LOG_DIR}/supervisor/celery.log
stdout_logfile_maxbytes=10MB
stderr_logfile=${LOG_DIR}/supervisor/celery_error.log
stderr_logfile_maxbytes=10MB
environment=DJANGO_SETTINGS_MODULE="dmoj.settings"
EOF

cat > /etc/supervisor/conf.d/capyjudge-wsevent.conf << EOF
[program:capyjudge-wsevent]
command=node ${APP_DIR}/websocket/daemon.js
directory=${APP_DIR}
user=${APP_USER}
autostart=true
autorestart=true
stdout_logfile=${LOG_DIR}/supervisor/wsevent.log
stdout_logfile_maxbytes=10MB
stderr_logfile=${LOG_DIR}/supervisor/wsevent_error.log
stderr_logfile_maxbytes=10MB
EOF

log_info "Supervisor configurations created"

# ============================================
# Step 10: Django Initialization
# ============================================
log_info "Step 10: Running Django setup..."

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

# Compile assets
./make_style.sh 2>/dev/null || true
python3 manage.py collectstatic --noinput 2>/dev/null || true
python3 manage.py compilemessages 2>/dev/null || true
python3 manage.py compilejsi18n 2>/dev/null || true

# Run migrations
python3 manage.py migrate --noinput

# Load initial data
python3 manage.py loaddata navbar 2>/dev/null || true
python3 manage.py loaddata language 2>/dev/null || true
python3 manage.py loaddata demo 2>/dev/null || true

# Create superuser if credentials are provided
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
log_info "Step 11: Starting services..."

# Reload systemd
systemctl daemon-reload

# Start and enable services
systemctl restart redis-server
systemctl enable redis-server
systemctl restart mariadb
systemctl enable mariadb
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
# Step 12: Final Setup
# ============================================
log_info "Step 12: Final permissions check..."

# Ensure all directories have correct permissions
chown -R "${APP_USER}:${APP_GROUP}" "${DATA_DIR}" "${LOG_DIR}" "${APP_DIR}"
chmod -R 755 "${DATA_DIR}" "${LOG_DIR}"

# Ensure log files are writable
touch "${LOG_DIR}/django/django.log" 2>/dev/null || true
chown -R "${APP_USER}:${APP_GROUP}" "${LOG_DIR}"
find "${LOG_DIR}" -type f -exec chmod 644 {} \; 2>/dev/null || true

log_info "========================================="
log_info "CapyJudge Installation Complete!"
log_info "========================================="
log_info "Installation Directory: ${APP_DIR}"
log_info "Data Directory: ${DATA_DIR}"
log_info "Logs Directory: ${LOG_DIR}"
log_info ""
log_info "Database Name: capyjudge"
log_info "Database User: capyjudge"
log_info ""
log_info "Web Port: ${WEB_PORT:-8000}"
log_info "Bridge Port: ${BRIDGE_PORT:-9999}"
log_info ""
log_info "Environment file: ${ENV_FILE}"
log_info "Secret keys saved in: ${DATA_DIR}/secrets/"
log_info ""
log_info "To check service status:"
log_info "  supervisorctl status"
log_info "  systemctl status nginx"
log_info ""
log_info "To view logs:"
log_info "  tail -f ${LOG_DIR}/supervisor/*.log"
log_info ""
log_info "Access CapyJudge at: http://localhost:${WEB_PORT:-8000}"
log_info "========================================="

# Create status check script
cat > /usr/local/bin/capyjudge-status << 'EOF'
#!/bin/bash
echo "=== CapyJudge Service Status ==="
echo ""
echo "Supervisor Services:"
supervisorctl status
echo ""
echo "Nginx Status:"
systemctl status nginx --no-pager | grep "Active:"
echo ""
echo "MySQL Status:"
systemctl status mariadb --no-pager | grep "Active:"
echo ""
echo "Redis Status:"
systemctl status redis-server --no-pager | grep "Active:"
echo ""
echo "=== End ==="
EOF

chmod +x /usr/local/bin/capyjudge-status

log_info "Created status check script: capyjudge-status"

exit 0

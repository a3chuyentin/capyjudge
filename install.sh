#!/bin/bash
set -e

# ============================================
# CapyJudge All-in-One Installation Script
# Based on LQDOJ/DMOJ architecture
# ============================================
#
# This script automates the complete deployment of a CapyJudge Online Judge system.
# It handles system dependencies, database setup, service configuration, and
# initial application deployment.
#
# Prerequisites:
#   - Ubuntu 20.04/22.04/24.04 LTS (or compatible Debian-based distribution)
#   - Fresh installation recommended
#   - Minimum 2GB RAM, 10GB free disk space
#   - Internet connection for package downloads
#
# What this script does:
#   1. Installs all required system packages and dependencies
#   2. Creates dedicated system user and directory structure
#   3. Clones the CapyJudge repository
#   4. Sets up Python virtual environment with all Python packages
#   5. Configures MySQL/MariaDB database with dedicated user
#   6. Sets up Redis for caching and Celery message broker
#   7. Configures Memcached for Django caching
#   8. Generates all necessary configuration files (Django, uWSGI, Nginx, Supervisor)
#   9. Runs Django migrations and loads initial data
#  10. Starts and enables all services
#
# Post-installation manual steps:
#   - Create a superuser account for admin access
#   - Configure SSL/TLS certificates for production use
#   - Set up judge workers (separate installation)
#   - Configure email backend for user notifications
#   - Review and adjust security settings in local_settings.py
# ============================================

# ============================================
# Environment Configuration
# ============================================
# These variables define the core deployment paths and user/group names.
# Modify with caution, as they affect the entire installation structure.

# Application user and group ownership
APP_USER="capyjudge"
APP_GROUP="capyjudge"

# Base directories for application, data, and logs
APP_HOME="/home/${APP_USER}"
APP_DIR="${APP_HOME}/capyjudge"
DATA_DIR="${APP_HOME}/capyjudge-data"
LOG_DIR="${APP_HOME}/logs"

# ============================================
# Output Formatting
# ============================================
# Color codes for structured, readable console output

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging helper functions for standardized output
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
# Helper Functions
# ============================================
# Cryptographic key generation utilities for securing the application

# Generates a 50-character random secret key for Django SECRET_KEY
generate_secret_key() {
    sudo -u "${APP_USER}" "${APP_HOME}/venv/bin/python3" -c "
import secrets
import string
chars = string.ascii_letters + string.digits + '!@#\$%^&*()-_=+[]{}|;:,.<>?'
print(''.join(secrets.choice(chars) for _ in range(50)))
"
}

# Generates a Fernet encryption key for chat message encryption
generate_fernet_key() {
    sudo -u "${APP_USER}" "${APP_HOME}/venv/bin/python3" -c "from cryptography.fernet import Fernet; key = Fernet.generate_key(); print(key.decode('utf-8'))"
}

# Generates a 32-character random password for database and service credentials
generate_random_password() {
    sudo -u "${APP_USER}" "${APP_HOME}/venv/bin/python3" -c "import secrets; import string; chars = string.ascii_letters + string.digits; print(''.join(secrets.choice(chars) for _ in range(32)))"
}

# ============================================
# Step 0: System Prerequisites & Virtual Environment
# ============================================
# Installs all required system packages including Python, compilers,
# database clients, and development libraries necessary for building
# Python packages with native extensions.

log_info "Step 0: Installing system dependencies..."

# Update package lists to ensure latest versions are available
sudo apt-get update -y

# Core system utilities and build tools
sudo apt-get install -y \
    git curl wget gnupg lsb-release ca-certificates \
    python3 python3-pip python3-dev python3-venv python3-full \
    gcc g++ gcc-12 g++-12 make \
    libxml2-dev libxslt1-dev zlib1g-dev \
    gettext pkg-config \
    mariadb-client libmariadb-dev \
    nginx supervisor \
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
    unzip \
    mariadb-client-compat

log_info "System dependencies installed"

# ============================================
# Step 0a: Create System User and Group
# ============================================
# Creates a dedicated unprivileged user account for running the application,
# enhancing security by isolating the judge processes from the system.

log_info "Creating ${APP_USER} user and group..."

# Create group if it doesn't already exist
if ! getent group "${APP_GROUP}" > /dev/null 2>&1; then
    sudo groupadd "${APP_GROUP}"
    log_info "Group ${APP_GROUP} created"
fi

# Create user with home directory and assign to the application group
if ! id "${APP_USER}" > /dev/null 2>&1; then
    sudo useradd -m -g "${APP_GROUP}" -s /bin/bash "${APP_USER}"
    log_info "User ${APP_USER} created"
fi

# Add www-data (Nginx user) to the application group for socket/file access
sudo usermod -a -G "${APP_GROUP}" www-data

log_info "User and group setup complete"

# ============================================
# Step 0b: Install Node.js and npm for APP_USER
# ============================================
# Installs Node.js and npm via nvm under the APP_USER account.
# This ensures all npm/node paths are owned by and accessible to APP_USER.

log_info "Installing Node.js and npm for user ${APP_USER}..."

sudo -u "${APP_USER}" bash << 'NVMEOF'
# Clean up any previous incompatible .npmrc
rm -f ~/.npmrc

# Install nvm if not already present
if [ ! -d "$HOME/.nvm" ]; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
fi

# Load nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Install Node.js 24 if not already installed
if ! nvm ls 24 > /dev/null 2>&1; then
    nvm install 24
fi

nvm use 24
nvm alias default 24

# Verify installation
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
NVMEOF

log_info "Node.js and npm installed successfully for user ${APP_USER}"

# ============================================
# Step 0c: Create Directory Structure
# ============================================
# Establishes the complete directory hierarchy for application data,
# problem files, static assets, and log storage with proper permissions.

log_info "Creating directory structure..."

# Application data directories
sudo mkdir -p "${DATA_DIR}"/{static,media,problems,secrets,cache,logs}
# Configuration directory for problem metadata
sudo mkdir -p "${DATA_DIR}/problems/__conf__"
# Log directories for all services
sudo mkdir -p "${LOG_DIR}"/{nginx,supervisor,uwsgi,django,celery,websocket,redis,memcached}
# Application source directory
sudo mkdir -p "${APP_DIR}"
# Nginx runtime directories
sudo mkdir -p /run/nginx /var/log/nginx

# Set ownership to application user for security
sudo chown -R "${APP_USER}:${APP_GROUP}" "${DATA_DIR}" "${LOG_DIR}" "${APP_DIR}"
# Nginx requires write access to its runtime directories
sudo chown -R www-data:www-data /var/log/nginx /run/nginx
sudo chmod 755 "${DATA_DIR}" "${LOG_DIR}" /run/nginx

log_info "Directory structure created"

# ============================================
# Step 0d: Clone Application Repository
# ============================================
# Retrieves the CapyJudge source code from GitHub. If the repository
# already exists, it pulls the latest changes and updates submodules
# to ensure the installation is current.

log_info "Cloning CapyJudge repository..."

if [ -d "${APP_DIR}/.git" ]; then
    log_warn "Repository already exists, pulling latest changes"
    cd "${APP_DIR}"
    sudo -u "${APP_USER}" git pull
    # Initialize and update git submodules (e.g., for translations or plugins)
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
# Step 0e: Setup Virtual Environment & Install Python Dependencies
# ============================================
# Creates an isolated Python environment to avoid conflicts with system
# packages. Installs all required Python packages from requirements.txt
# and additional deployment-specific dependencies.

log_info "Setting up Python virtual environment..."

# Install build dependencies required for compiling Python packages with C extensions
sudo apt-get install -y \
    libcrypt-dev libssl-dev libffi-dev libxml2-dev libxslt1-dev \
    libjpeg-dev libz-dev build-essential python3-dev pkg-config

# Create virtual environment if it doesn't exist
if [ ! -d "${APP_HOME}/venv" ]; then
    sudo -u "${APP_USER}" python3 -m venv "${APP_HOME}/venv"
    log_info "Virtual environment created"
fi

# Install Python dependencies as the application user
sudo -u "${APP_USER}" bash << EOF
source ${APP_HOME}/venv/bin/activate

# Upgrade core packaging tools
pip install --upgrade pip setuptools wheel

# Install project requirements
if [ -f "${APP_DIR}/requirements.txt" ]; then
    pip install -r "${APP_DIR}/requirements.txt"
fi

# Install additional production deployment packages
pip install mysqlclient uwsgi websocket-client celery redis django-compressor cryptography boto3 django-storages

# Set up pre-commit hooks for code quality (optional, for development)
cd "${APP_DIR}"
pre-commit install
EOF

log_info "Python dependencies installed"

# ============================================
# Step 0f: Install Node.js Dependencies
# ============================================
# Installs npm packages for the WebSocket server and global SCSS/PostCSS tools.

log_info "Installing Node.js dependencies..."

# Install global npm packages and websocket dependencies as APP_USER
sudo -u "${APP_USER}" bash << EOF
# Load nvm
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
nvm use 24

# Install global SCSS/PostCSS packages
npm install -g sass postcss-cli postcss autoprefixer

# Install websocket server dependencies
cd "${APP_DIR}/websocket"
npm install express socket.io qu ws simplesets
EOF

log_info "All dependencies installed"

# ============================================
# Environment Configuration Loading
# ============================================
# Checks for existing .env file with configuration variables.
# If not found, creates one from the example template and prompts
# the user to review and customize settings.

log_info "Checking for .env file..."

if [ -f "${APP_DIR}/.env" ]; then
    log_info "Found existing .env file, loading configuration..."
    # Clean up any heredoc artifacts that might have been accidentally saved
    sudo sed -i '/^EOF$/d' "${APP_DIR}/.env" 2>/dev/null || true
    # Load environment variables into current shell session
    set -a
    source "${APP_DIR}/.env"
    set +a
    log_info "Loaded configuration from .env file"
elif [ -f "${APP_DIR}/.env.example" ]; then
    log_info "No .env file found, creating from .env.example..."
    sudo cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
    sudo sed -i '/^EOF$/d' "${APP_DIR}/.env" 2>/dev/null || true
    sudo chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/.env"
    
    # Prompt user to edit the .env file for custom configuration
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  Do you want to edit .env file now?${NC}"
    echo -e "${YELLOW}  (Recommended to set your custom values)${NC}"
    echo -e "${YELLOW}========================================${NC}"
    read -p "Edit .env file? [Y/n]: " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        # Open with available text editor
        if command -v nano &> /dev/null; then
            sudo -u "${APP_USER}" nano "${APP_DIR}/.env"
        elif command -v vim &> /dev/null; then
            sudo -u "${APP_USER}" vim "${APP_DIR}/.env"
        else
            log_warn "No text editor found. Please edit ${APP_DIR}/.env manually later."
        fi
        sudo sed -i '/^EOF$/d' "${APP_DIR}/.env" 2>/dev/null || true
    else
        log_info "Skipping .env editing. You can edit it later at: ${APP_DIR}/.env"
    fi
    
    # Load the configuration after potential editing
    set -a
    source "${APP_DIR}/.env" 2>/dev/null || {
        log_error "Failed to load .env file. Please check syntax."
        exit 1
    }
    set +a
    log_info "Loaded configuration from .env file"
else
    log_warn "No .env.example found, will use default values"
fi

# ============================================
# Configuration Value Generation
# ============================================
# Generates cryptographic keys and passwords. Values from .env file
# take precedence; if not specified, secure random values are generated.

log_info "Generating configuration values..."

# Generate secrets, giving priority to values from .env file
SECRET_KEY="${SECRET_KEY:-$(generate_secret_key)}"
EVENT_DAEMON_KEY="${EVENT_DAEMON_KEY:-$(generate_random_password)}"
CHAT_SECRET_KEY="${CHAT_SECRET_KEY:-$(generate_fernet_key)}"
DB_PASSWORD="${DB_PASSWORD:-$(generate_random_password)}"
FERNET_KEY="${FERNET_KEY:-$(generate_fernet_key)}"

# Set configuration values with defaults if not specified in .env
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

# Save all generated credentials to a secure file for reference
sudo mkdir -p "${DATA_DIR}/secrets"
sudo bash -c "cat > ${DATA_DIR}/secrets/credentials.txt" << EOF
# CapyJudge Credentials
# Generated on $(date)
# Keep this file secure and do not share!

DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}

SECRET_KEY=${SECRET_KEY}
EVENT_DAEMON_KEY=${EVENT_DAEMON_KEY}
CHAT_SECRET_KEY=${CHAT_SECRET_KEY}
FERNET_KEY=${FERNET_KEY}

WEB_PORT=${WEB_PORT}
BRIDGE_PORT=${BRIDGE_PORT}
WEBSOCKET_PORT=${WEBSOCKET_PORT}
SITE_DOMAIN=${SITE_DOMAIN}
EOF

# Restrict access to credentials file
sudo chmod 600 "${DATA_DIR}/secrets/credentials.txt"
sudo chown "${APP_USER}:${APP_GROUP}" "${DATA_DIR}/secrets/credentials.txt"

log_info "Configuration values generated and saved"

# ============================================
# Step 5: Setup MySQL/MariaDB Database
# ============================================
# Configures the database server, creates the application database,
# and sets up a dedicated user with appropriate privileges.
# Also imports timezone data for proper time handling.

log_info "Configuring MySQL/MariaDB database..."

# Start and enable the database service
sudo systemctl start mariadb
sudo systemctl enable mariadb

# Wait for database server to be ready before proceeding
log_info "Waiting for MariaDB to be ready..."
for i in {1..30}; do
    if sudo mysqladmin ping -u root --silent 2>/dev/null; then
        log_info "MariaDB is ready!"
        break
    fi
    log_info "Waiting for MariaDB... (${i}/30)"
    sleep 1
done

# Create the application database and user
log_info "Creating database and user..."
sudo mysql -u root << EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON test_${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# Verify database connectivity with the new user
log_info "Verifying database connection..."
DB_CONNECTION_OK=false

if mysql -u "${DB_USER}" -p"${DB_PASSWORD}" -e "SELECT 1;" "${DB_NAME}" 2>/dev/null; then
    log_info "Database connection verified successfully"
    DB_CONNECTION_OK=true
else
    # Fallback: try with mysql_native_password authentication plugin
    log_warn "Trying alternative method: mysql_native_password..."
    sudo mysql -u root << EOF
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_PASSWORD}';
FLUSH PRIVILEGES;
EOF
    if mysql -u "${DB_USER}" -p"${DB_PASSWORD}" -e "SELECT 1;" "${DB_NAME}" 2>/dev/null; then
        log_info "Database connection verified successfully"
        DB_CONNECTION_OK=true
    fi
fi

# Abort installation if database connection cannot be established
if [ "$DB_CONNECTION_OK" = false ]; then
    log_error "DATABASE CONNECTION FAILED!"
    log_error "Please check: systemctl status mariadb"
    exit 1
fi

# Import timezone data for accurate time-based operations
if command -v mysql_tzinfo_to_sql > /dev/null 2>&1 && [ -d /usr/share/zoneinfo ]; then
    log_info "Importing timezone data to MySQL..."
    
    # Try multiple authentication methods for timezone import
    if mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | sudo mysql -u root mysql 2>/dev/null; then
        log_info "Timezone data imported successfully (root)"
        TZ_OK=true
    elif sudo mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | sudo mysql -u root mysql 2>/dev/null; then
        log_info "Timezone data imported successfully (sudo root)"
        TZ_OK=true
    elif mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | mysql -u "${DB_USER}" -p"${DB_PASSWORD}" mysql 2>/dev/null; then
        log_info "Timezone data imported successfully (${DB_USER})"
        TZ_OK=true
    elif sudo mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | sudo mysql -u "${DB_USER}" -p"${DB_PASSWORD}" mysql 2>/dev/null; then
        log_info "Timezone data imported successfully (sudo ${DB_USER})"
        TZ_OK=true
    else
        log_warn "All timezone import attempts failed - timezone features may be limited"
        TZ_OK=false
    fi
else
    log_warn "mysql_tzinfo_to_sql or zoneinfo not found - timezone support not configured"
    TZ_OK=false
fi

# Reload privilege tables to ensure all changes take effect
sudo mysql -u root -e "FLUSH TABLES;" mysql 2>/dev/null || true

log_info "Database configured successfully"

# ============================================
# Step 6: Setup Redis and Memcached
# ============================================
# Configures Redis as the message broker for Celery task queue
# and Memcached for Django caching backend.

log_info "Configuring Redis and Memcached..."

# Start and enable both caching services
sudo systemctl restart redis-server
sudo systemctl enable redis-server
sudo systemctl restart memcached
sudo systemctl enable memcached

log_info "Redis and Memcached configured"

# ============================================
# Step 7: Generate Django and Service Configuration
# ============================================
# Creates the Django local_settings.py with all database connections,
# caching backends, and service endpoints. Also generates uWSGI and
# WebSocket server configuration files.

log_info "Generating Django local_settings.py..."

# Django configuration with all required settings for production
sudo bash -c "cat > ${APP_DIR}/dmoj/local_settings.py" << EOF
import os

# SECURITY WARNING: keep the secret key used in production secret!
DEBUG = ${DEBUG}
SECRET_KEY = r'''${SECRET_KEY}'''
ALLOWED_HOSTS = ['*']

# Site identity configuration
SITE_NAME = '${SITE_NAME}'
SITE_LONG_NAME = '${SITE_LONG_NAME}'
SITE_ADMIN_EMAIL = '${SITE_ADMIN_EMAIL}'
SITE_DOMAIN = '${SITE_DOMAIN}'

# CSRF protection configuration for the configured domain
CSRF_TRUSTED_ORIGINS = [f'http://{SITE_DOMAIN}', f'http://{SITE_DOMAIN}:${WEB_PORT}']

# Database connection configuration
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

# Cache configuration using Memcached
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.PyMemcacheCache',
        'LOCATION': '127.0.0.1:11211',
    }
}

# File storage paths for problem data and user uploads
DMOJ_PROBLEM_DATA_ROOT = '${DATA_DIR}/problems'
STATIC_ROOT = '${DATA_DIR}/static'
MEDIA_ROOT = '${DATA_DIR}/media'

# Bridge daemon configuration for judge communication
BRIDGED_JUDGE_ADDRESS = [('0.0.0.0', ${BRIDGE_PORT})]
BRIDGED_DJANGO_ADDRESS = [('localhost', 9998)]

# WebSocket event daemon configuration
EVENT_DAEMON_USE = True
EVENT_DAEMON_KEY = '${EVENT_DAEMON_KEY}'
EVENT_DAEMON_URL = 'http://localhost:${WEBSOCKET_PORT}'
EVENT_DAEMON_PUBLIC_URL = 'http://localhost:${WEBSOCKET_PORT}'

# Celery task queue configuration using Redis
CELERY_BROKER_URL = 'redis://localhost:6379/0'
CELERY_RESULT_BACKEND = 'redis://localhost:6379/0'

# Chat encryption key
CHAT_SECRET_KEY = '${CHAT_SECRET_KEY}'

# Static file finders with django-compressor support
STATICFILES_FINDERS = [
    'django.contrib.staticfiles.finders.FileSystemFinder',
    'django.contrib.staticfiles.finders.AppDirectoriesFinder',
    'compressor.finders.CompressorFinder',
]

# Logging configuration with file output
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

# Security settings (adjust for production with SSL)
SESSION_COOKIE_SECURE = False
CSRF_COOKIE_SECURE = False
SECURE_PROXY_SSL_HEADER = None

# Compressor settings (disable during initial setup for performance)
COMPRESS_ENABLED = False
COMPRESS_OFFLINE = False
EOF

sudo chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/dmoj/local_settings.py"
sudo chmod 640 "${APP_DIR}/dmoj/local_settings.py"

# Generate uWSGI configuration for serving Django application
sudo bash -c "cat > ${APP_DIR}/uwsgi.ini" << EOF
[uwsgi]
# Socket configuration for Nginx communication
uwsgi-socket = /tmp/dmoj-site.sock
pidfile = /tmp/dmoj-site.pid
chmod-socket = 666

# Process ownership
uid = ${APP_USER}
gid = ${APP_GROUP}

# Application paths
chdir = ${APP_DIR}
pythonpath = ${APP_DIR}
home = ${APP_HOME}/venv

# uWSGI protocol and application settings
protocol = uwsgi
master = true
env = DJANGO_SETTINGS_MODULE=dmoj.settings
module = dmoj.wsgi:application
optimize = 2

# Worker process management
memory-report = true
cheaper-algo = backlog
cheaper = 3
cheaper-initial = 5
cheaper-step = 1
cheaper-rss-limit-soft = 201326592
cheaper-rss-limit-hard = 234881024
workers = 7
EOF

# Generate WebSocket server configuration
sudo bash -c "cat > ${APP_DIR}/websocket/config.js" << EOF
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
# Step 8: Setup Nginx Web Server
# ============================================
# Configures Nginx as the frontend reverse proxy, serving static files
# directly and proxying dynamic requests to uWSGI and WebSocket connections
# to the Node.js event daemon.

log_info "Configuring Nginx..."

sudo bash -c "cat > /etc/nginx/sites-available/capyjudge" << EOF
server {
    listen ${WEB_PORT};
    server_name ${SITE_DOMAIN};
    
    # Access and error logging
    access_log ${LOG_DIR}/nginx/access.log;
    error_log ${LOG_DIR}/nginx/error.log;
    
    # Serve static files directly with long cache expiry
    location /static {
        alias ${DATA_DIR}/static;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # Serve user-uploaded media files
    location /media {
        alias ${DATA_DIR}/media;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # Serve profile images
    location /profile_images/ {
        alias ${APP_DIR}/profile_images/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # Serve organization logo images
    location /organization_images/ {
        alias ${APP_DIR}/organization_images/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # WebSocket proxy for real-time features (chat, notifications, submissions)
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
    
    # Main application proxy to uWSGI
    location / {
        include uwsgi_params;
        uwsgi_pass unix:///tmp/dmoj-site.sock;
        uwsgi_param UWSGI_SCHEME \$scheme;
        uwsgi_param SERVER_SOFTWARE nginx/\$nginx_version;
        uwsgi_param HTTP_X_FORWARDED_PROTO \$scheme;
        uwsgi_param HTTP_X_FORWARDED_HOST \$host;
        uwsgi_param HTTP_X_FORWARDED_SERVER \$host;
    }
    
    # Maximum upload size for problem files
    client_max_body_size 100M;
    
    # Enable gzip compression for text-based content
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;
}
EOF

# Enable the site and disable the default Nginx welcome page
sudo ln -sf /etc/nginx/sites-available/capyjudge /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Create directories for profile and organization images
sudo mkdir -p ${APP_DIR}/profile_images ${APP_DIR}/organization_images
sudo chown -R ${APP_USER}:${APP_GROUP} ${APP_DIR}/profile_images ${APP_DIR}/organization_images

# Test Nginx configuration and apply
sudo nginx -t
sudo systemctl restart nginx

log_info "Nginx configured successfully"

# ============================================
# Step 9: Setup Supervisor Process Manager
# ============================================
# Configures Supervisor to manage and monitor all application processes:
# uWSGI web server, bridged judge daemon, Celery worker, and WebSocket server.
# All paths use absolute references from APP_USER's environment.

log_info "Configuring Supervisor..."

# Resolve absolute paths for binaries (from APP_USER's nvm)
NODE_BIN=$(sudo -u "${APP_USER}" bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"; which node')
PYTHON_BIN="${APP_HOME}/venv/bin/python3"
UWSGI_BIN="${APP_HOME}/venv/bin/uwsgi"
CELERY_BIN="${APP_HOME}/venv/bin/celery"

log_info "Resolved paths:"
log_info "  Node.js: ${NODE_BIN}"
log_info "  Python:  ${PYTHON_BIN}"
log_info "  uWSGI:   ${UWSGI_BIN}"
log_info "  Celery:  ${CELERY_BIN}"

# uWSGI application server configuration
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

# Bridged daemon for judge communication
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

# Celery worker for asynchronous task processing
sudo bash -c "cat > /etc/supervisor/conf.d/capyjudge-celery.conf" << EOF
[program:capyjudge-celery]
command=${CELERY_BIN} -A dmoj_celery worker
directory=${APP_DIR}
user=${APP_USER}
group=${APP_GROUP}
stdout_logfile=${LOG_DIR}/celery/celery.log
stderr_logfile=${LOG_DIR}/celery/celery_error.log
EOF

# WebSocket event daemon for real-time features
sudo bash -c "cat > /etc/supervisor/conf.d/capyjudge-wsevent.conf" << EOF
[program:capyjudge-wsevent]
command=${NODE_BIN} ${APP_DIR}/websocket/daemon.js
directory=${APP_DIR}
user=${APP_USER}
group=${APP_GROUP}
stdout_logfile=${LOG_DIR}/websocket/wsevent.log
stderr_logfile=${LOG_DIR}/websocket/wsevent_error.log
EOF

log_info "Supervisor configurations created"

# ============================================
# Step 10: Django Application Initialization
# ============================================
# Performs all necessary Django setup tasks: compiles static assets,
# runs database migrations, and loads initial data fixtures.
# Note: Superuser creation is intentionally left as a manual step
# for security reasons.

log_info "Running Django setup..."

sudo -u "${APP_USER}" bash << EOF
# Load nvm for this session
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
nvm use 24

source ${APP_HOME}/venv/bin/activate
cd ${APP_DIR}

export DJANGO_SETTINGS_MODULE=dmoj.settings

# Compile SCSS to CSS if build script is available
if [ -f "./make_style.sh" ]; then
    ./make_style.sh 2>/dev/null || true
fi

# Collect all static files to the STATIC_ROOT directory
python3 manage.py collectstatic --noinput 2>/dev/null || true

# Compile translation message catalogs
python3 manage.py compilemessages 2>/dev/null || true
python3 manage.py compilejsi18n 2>/dev/null || true

# Apply all pending database migrations
python3 manage.py migrate --noinput

# Load initial data fixtures for site functionality
python3 manage.py loaddata navbar 2>/dev/null || true
python3 manage.py loaddata language_small 2>/dev/null || python3 manage.py loaddata language 2>/dev/null || true
python3 manage.py loaddata demo 2>/dev/null || true
EOF

log_info "Django initialization complete"

# ============================================
# Step 11: Start All Services
# ============================================
# Starts and enables all system services to ensure they automatically
# start on system boot. Reloads Supervisor to pick up new configurations.

log_info "Starting all services..."

# Reload systemd to recognize any new service files
sudo systemctl daemon-reload

# Start and enable database and caching services
sudo systemctl restart mariadb
sudo systemctl enable mariadb

sudo systemctl restart redis-server
sudo systemctl enable redis-server

sudo systemctl restart memcached
sudo systemctl enable memcached

# Start and enable web server
sudo systemctl restart nginx
sudo systemctl enable nginx

# Start and enable process manager
sudo systemctl restart supervisor
sudo systemctl enable supervisor

# Reload Supervisor configurations and start all managed processes
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl start all

log_info "All services started"

# ============================================
# Step 12: Final Permission Hardening
# ============================================
# Performs a final permissions audit to ensure all files and directories
# have the correct ownership and access rights for security.

log_info "Final permissions check..."

# Ensure base directories are accessible
sudo chmod 755 /home/${APP_USER}
sudo chmod 755 ${APP_HOME}
sudo chmod 755 ${DATA_DIR}

# Recursively set correct ownership for all application files
sudo chown -R "${APP_USER}:${APP_GROUP}" "${DATA_DIR}" "${LOG_DIR}" "${APP_DIR}"

# Set directory permissions to allow traversal
sudo find "${DATA_DIR}" -type d -exec chmod 755 {} \;
sudo find "${LOG_DIR}" -type d -exec chmod 755 {} \;
# Set file permissions to be readable but not writable by others
sudo find "${DATA_DIR}/static" -type f -exec chmod 644 {} \;
sudo find "${DATA_DIR}/media" -type f -exec chmod 644 {} \;
sudo find "${LOG_DIR}" -type f -exec chmod 644 {} \;

# Ensure Nginx user has group access to application files
sudo usermod -a -G "${APP_GROUP}" www-data 2>/dev/null || true

# Restart Nginx to apply any permission changes
sudo systemctl restart nginx

log_info "Permissions fixed"

# ============================================
# Installation Complete - Summary and Next Steps
# ============================================
log_info "========================================="
log_info "  CapyJudge Installation Complete!"
log_info "========================================="
log_info "Web Interface: http://${SITE_DOMAIN}:${WEB_PORT}"
log_info ""
log_info "Database Name:     ${DB_NAME}"
log_info "Database User:     ${DB_USER}"
log_info "Database Password: ${DB_PASSWORD}"
log_info ""
log_info "Credentials file: ${DATA_DIR}/secrets/credentials.txt"
log_info ""
log_info "========================================="
log_info "IMPORTANT: Create Superuser Account"
log_info "========================================="
log_info "Run the following commands to create an admin user:"
log_info ""
log_info "  sudo -u ${APP_USER} bash"
log_info "  source ${APP_HOME}/venv/bin/activate"
log_info "  cd ${APP_DIR}"
log_info "  python3 manage.py createsuperuser"
log_info ""
log_info "Then enter your desired username, email, and password."
log_info "========================================="

# Brief verification that services are running
sleep 3
if sudo supervisorctl status | grep -q "RUNNING"; then
    log_info "Services are running successfully!"
else
    log_warn "Some services may not be running. Check with: supervisorctl status"
fi

exit 0
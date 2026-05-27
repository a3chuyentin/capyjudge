#!/bin/bash
set -e

echo "Starting CapyJudge Docker container..."

# Activate virtual environment FIRST
source /venv/bin/activate

# ============================================
# Helper functions
# ============================================
generate_secret_key() {
    python -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())"
}

generate_fernet_key() {
    python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
}

generate_random_password() {
    python -c "import secrets; import string; chars = string.ascii_letters + string.digits; print(''.join(secrets.choice(chars) for _ in range(32)))"
}

# ============================================
# Secrets management
# ============================================
echo "Checking secrets..."

if [ -z "$SECRET_KEY" ]; then
    if [ -f /data/SECRET_KEY ]; then
        SECRET_KEY=$(cat /data/SECRET_KEY)
        echo "Loaded SECRET_KEY from /data/SECRET_KEY"
    else
        SECRET_KEY=$(generate_secret_key)
        echo "$SECRET_KEY" > /data/SECRET_KEY
        echo "Generated new SECRET_KEY"
    fi
fi

if [ -z "$CHAT_SECRET_KEY" ]; then
    if [ -f /data/CHAT_SECRET_KEY ]; then
        CHAT_SECRET_KEY=$(cat /data/CHAT_SECRET_KEY)
        echo "Loaded CHAT_SECRET_KEY from /data/CHAT_SECRET_KEY"
    else
        CHAT_SECRET_KEY=$(generate_fernet_key)
        echo "$CHAT_SECRET_KEY" > /data/CHAT_SECRET_KEY
        echo "Generated new CHAT_SECRET_KEY"
    fi
fi

if [ -z "$EVENT_DAEMON_KEY" ]; then
    if [ -f /data/EVENT_DAEMON_KEY ]; then
        EVENT_DAEMON_KEY=$(cat /data/EVENT_DAEMON_KEY)
        echo "Loaded EVENT_DAEMON_KEY from /data/EVENT_DAEMON_KEY"
    else
        EVENT_DAEMON_KEY=$(generate_random_password)
        echo "$EVENT_DAEMON_KEY" > /data/EVENT_DAEMON_KEY
        echo "Generated new EVENT_DAEMON_KEY"
    fi
fi

if [ -z "$DB_PASSWORD" ]; then
    if [ -f /data/DB_PASSWORD ]; then
        DB_PASSWORD=$(cat /data/DB_PASSWORD)
        echo "Loaded DB_PASSWORD from /data/DB_PASSWORD"
    else
        DB_PASSWORD=$(generate_random_password)
        echo "$DB_PASSWORD" > /data/DB_PASSWORD
        echo "Generated random DB_PASSWORD - please save it"
    fi
fi

export SECRET_KEY CHAT_SECRET_KEY EVENT_DAEMON_KEY DB_PASSWORD

# ============================================
# Generate local_settings.py
# ============================================
echo "Generating local_settings.py..."

cat > /app/dmoj/local_settings.py << 'EOF'
# Auto-generated from environment variables
import os

DEBUG = os.environ.get('DEBUG', 'False') == 'True'
SECRET_KEY = os.environ.get('SECRET_KEY', '')
ALLOWED_HOSTS = ['*']

SITE_NAME = os.environ.get('SITE_NAME', 'CapyJudge')
SITE_LONG_NAME = os.environ.get('SITE_LONG_NAME', 'CapyJudge Online Judge')
SITE_ADMIN_EMAIL = os.environ.get('SITE_ADMIN_EMAIL', 'admin@localhost')
SITE_DOMAIN = os.environ.get('SITE_DOMAIN', 'localhost')

# Database
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': os.environ.get('DB_NAME', 'dmoj'),
        'USER': os.environ.get('DB_USER', 'dmoj'),
        'PASSWORD': os.environ.get('DB_PASSWORD', ''),
        'HOST': os.environ.get('DB_HOST', 'db'),
        'PORT': os.environ.get('DB_PORT', '3306'),
        'OPTIONS': {
            'charset': 'utf8mb4',
            'sql_mode': 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION',
        },
    }
}

# Cache
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.redis.RedisCache',
        'LOCATION': os.environ.get('REDIS_URL', 'redis://redis:6379/1'),
    }
}

# Paths
DMOJ_PROBLEM_DATA_ROOT = '/problems'
STATIC_ROOT = '/app/static'
MEDIA_ROOT = '/app/media'
COMPRESS_ROOT = STATIC_ROOT

# Bridge
BRIDGED_JUDGE_ADDRESS = [('0.0.0.0', 9999)]
BRIDGED_DJANGO_ADDRESS = [('localhost', 9998)]

# WebSocket
EVENT_DAEMON_USE = True
EVENT_DAEMON_KEY = os.environ.get('EVENT_DAEMON_KEY', '')
EVENT_DAEMON_URL = os.environ.get('EVENT_DAEMON_URL', 'http://websocket:15100')
EVENT_DAEMON_PUBLIC_URL = os.environ.get('EVENT_DAEMON_PUBLIC_URL', 'http://localhost:15100')

# Celery
CELERY_BROKER_URL = os.environ.get('REDIS_URL', 'redis://redis:6379/0')
CELERY_RESULT_BACKEND = os.environ.get('REDIS_URL', 'redis://redis:6379/0')

# Security
if not DEBUG:
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True
    SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')

# Chat secret
CHAT_SECRET_KEY = os.environ.get('CHAT_SECRET_KEY', '')

# Email
if os.environ.get('EMAIL_HOST'):
    EMAIL_BACKEND = 'django.core.mail.backends.smtp.EmailBackend'
    EMAIL_HOST = os.environ.get('EMAIL_HOST')
    EMAIL_PORT = int(os.environ.get('EMAIL_PORT', 587))
    EMAIL_HOST_USER = os.environ.get('EMAIL_USER', '')
    EMAIL_HOST_PASSWORD = os.environ.get('EMAIL_PASSWORD', '')
    EMAIL_USE_TLS = os.environ.get('EMAIL_USE_TLS', 'True') == 'True'
    DEFAULT_FROM_EMAIL = os.environ.get('DEFAULT_FROM_EMAIL', 'capyjudge@gmail.com')

# Static files
STATICFILES_FINDERS += ('compressor.finders.CompressorFinder',)
COMPRESS_ENABLED = not DEBUG

# Logging
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'handlers': {
        'console': {
            'class': 'logging.StreamHandler',
        },
    },
    'root': {
        'handlers': ['console'],
        'level': 'INFO',
    },
}
EOF

# ============================================
# Generate uwsgi.ini
# ============================================
echo "Generating uwsgi.ini..."

cat > /app/uwsgi.ini << 'EOF'
[uwsgi]
uwsgi-socket = /tmp/dmoj-site.sock
chmod-socket = 666
pidfile = /tmp/dmoj-site.pid

chdir = /app
pythonpath = /app
virtualenv = /venv

protocol = uwsgi
master = true
env = DJANGO_SETTINGS_MODULE=dmoj.settings
module = dmoj.wsgi:application
optimize = 2

memory-report = true
cheaper-algo = busyness
cheaper = 2
cheaper-initial = 4
cheaper-step = 1
cheaper-busyness-min = 20
cheaper-busyness-max = 70
cheaper-busyness-multiplier = 30
workers = 4
threads = 2

harakiri = 15
harakiri-verbose = true
max-requests = 5000
max-requests-delta = 500
max-worker-lifetime = 7200

reload-on-rss = 256
evil-reload-on-rss = 350

no-orphans = true
vacuum = true
die-on-term = true

logto = /dev/stdout
log-format = %(asctime) [%(process)] %(method) %(uri) => %(status) (%(size))
EOF

# ============================================
# Generate nginx.conf
# ============================================
echo "Generating nginx.conf..."

cat > /etc/nginx/sites-available/default << 'EOF'
server {
    listen       80;
    listen       [::]:80;
    server_name  ${SITE_DOMAIN};

    add_header X-UA-Compatible "IE=Edge,chrome=1";
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    charset utf-8;
    try_files $uri @icons;
    error_page 502 504 /502.html;

    location ~ ^/502\.html$|^/logo\.png$|^/robots\.txt$ {
        root /app;
    }

    location @icons {
        root /app/resources/icons;
        error_page 403 = @uwsgi;
        error_page 404 = @uwsgi;
    }

    location @uwsgi {
        uwsgi_read_timeout 600;
        uwsgi_pass unix:///tmp/dmoj-site.sock;
        include uwsgi_params;
        uwsgi_param SERVER_SOFTWARE nginx/$nginx_version;
    }

    location /static {
        gzip_static on;
        expires max;
        root /app;
    }

    location /media {
        alias /app/media;
    }

    location /socket.io/ {
        proxy_pass http://websocket:15100/socket.io/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }

    client_max_body_size 100M;
}
EOF

# ============================================
# Generate supervisor configs
# ============================================
echo "Generating supervisor configs..."

cat > /etc/supervisor/conf.d/site.conf << 'EOF'
[program:site]
command=/venv/bin/uwsgi --ini /app/uwsgi.ini
directory=/app
stopsignal=QUIT
user=www-data
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autostart=true
autorestart=true
environment=PATH="/venv/bin:/usr/local/bin:/usr/bin:/bin"
EOF

cat > /etc/supervisor/conf.d/bridged.conf << 'EOF'
[program:bridged]
command=/venv/bin/python /app/manage.py runbridged
directory=/app
user=www-data
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autostart=true
autorestart=true
EOF

cat > /etc/supervisor/conf.d/celery.conf << 'EOF'
[program:celery]
command=/venv/bin/celery -A dmoj_celery worker --concurrency=%(ENV_CELERY_CONCURRENCY)s
directory=/app
user=www-data
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autostart=true
autorestart=true
environment=NODE_PATH="/app/node_modules"
EOF

cat > /etc/supervisor/conf.d/wsevent.conf << 'EOF'
[program:wsevent]
command=/usr/bin/node /app/websocket/daemon.js
directory=/app
user=www-data
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autostart=true
autorestart=true
environment=NODE_PATH="/app/node_modules"
EOF

# ============================================
# Generate websocket/config.js
# ============================================
echo "Generating websocket/config.js..."

cat > /app/websocket/config.js << EOF
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

# ============================================
# Substitute nginx variables
# ============================================
echo "Configuring nginx..."

export SITE_DOMAIN=${SITE_DOMAIN:-localhost}
envsubst '${SITE_DOMAIN}' < /etc/nginx/sites-available/default > /etc/nginx/sites-available/default.tmp
mv /etc/nginx/sites-available/default.tmp /etc/nginx/sites-available/default

# ============================================
# Wait for database
# ============================================
echo "Waiting for database..."

DB_HOST=${DB_HOST:-db}
DB_PORT=${DB_PORT:-3306}

while ! nc -z $DB_HOST $DB_PORT; do
    sleep 1
done

echo "Database ready"

# ============================================
# Django setup (using venv python)
# ============================================
echo "Running migrations..."
python manage.py migrate --noinput

TABLE_COUNT=$(python manage.py sqlflush 2>/dev/null | grep -c "TRUNCATE" || echo "0")
if [ "$TABLE_COUNT" -eq 0 ]; then
    echo "Loading initial data for new database..."
    python manage.py loaddata navbar language_small demo 2>/dev/null || true
fi

if [ ! -z "$DJANGO_SUPERUSER_USERNAME" ] && [ ! -z "$DJANGO_SUPERUSER_PASSWORD" ]; then
    echo "Creating superuser from environment..."
    python manage.py createsuperuser --noinput \
        --username "$DJANGO_SUPERUSER_USERNAME" \
        --email "${DJANGO_SUPERUSER_EMAIL:-admin@capyjudge.com}" 2>/dev/null || true
else
    ADMIN_EXISTS=$(python manage.py shell -c "from django.contrib.auth import get_user_model; User=get_user_model(); print(User.objects.filter(is_superuser=True).exists())" 2>/dev/null)
    if [ "$ADMIN_EXISTS" = "False" ]; then
        RANDOM_PASS=$(generate_random_password)
        echo "Creating default admin user with random password..."
        echo "Username: admin"
        echo "Password: $RANDOM_PASS"
        echo "PLEASE SAVE THIS PASSWORD"
        echo "from django.contrib.auth import get_user_model; User=get_user_model(); User.objects.create_superuser('admin', 'admin@capyjudge.com', '$RANDOM_PASS')" | python manage.py shell
    fi
fi

# ============================================
# Create directories
# ============================================
mkdir -p /app/static /app/media /problems
chown -R www-data:www-data /app/static /app/media /problems

echo "All setup complete"

# ============================================
# Start supervisor
# ============================================
exec "$@"

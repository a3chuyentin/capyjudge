#!/bin/bash
set -e

echo "Starting CapyJudge Docker container..."

# ============================================
# Helper functions
#=============================================
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
# Install websocket dependencies if missing
# ============================================
echo "Checking websocket dependencies..."
cd /app/websocket
if [ ! -d "node_modules" ] || [ ! -f "node_modules/socket.io/package.json" ]; then
    echo "Installing websocket dependencies..."
    npm install express socket.io qu ws simplesets
fi

# ============================================
# Generate local_settings.py
# ============================================
echo "Generating local_settings.py..."

cat > /app/dmoj/local_settings.py << 'EOF'
import os

DEBUG = os.environ.get('DEBUG', 'False') == 'True'
SECRET_KEY = os.environ.get('SECRET_KEY', '')
ALLOWED_HOSTS = ['*']

SITE_NAME = os.environ.get('SITE_NAME', 'CapyJudge')
SITE_LONG_NAME = os.environ.get('SITE_LONG_NAME', 'CapyJudge Online Judge')
SITE_ADMIN_EMAIL = os.environ.get('SITE_ADMIN_EMAIL', 'admin@localhost')
SITE_DOMAIN = os.environ.get('SITE_DOMAIN', 'localhost')

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': os.environ.get('DB_NAME', 'dmoj'),
        'USER': os.environ.get('DB_USER', 'dmoj'),
        'PASSWORD': os.environ.get('DB_PASSWORD', ''),
        'HOST': os.environ.get('DB_HOST', 'db'),
        'PORT': os.environ.get('DB_PORT', '3306'),
        'OPTIONS': {'charset': 'utf8mb4', 'sql_mode': 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'},
    }
}

CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.locmem.LocMemCache',
        'LOCATION': 'unique-snowflake',
    }
}

DMOJ_PROBLEM_DATA_ROOT = '/problems'
STATIC_ROOT = '/app/static'
MEDIA_ROOT = '/app/media'

BRIDGED_JUDGE_ADDRESS = [('0.0.0.0', 9999)]
BRIDGED_DJANGO_ADDRESS = [('localhost', 9998)]

EVENT_DAEMON_USE = True
EVENT_DAEMON_KEY = os.environ.get('EVENT_DAEMON_KEY', '')
EVENT_DAEMON_URL = os.environ.get('EVENT_DAEMON_URL', 'http://websocket:15100')
EVENT_DAEMON_PUBLIC_URL = os.environ.get('EVENT_DAEMON_PUBLIC_URL', 'http://localhost:15100')

CELERY_BROKER_URL = os.environ.get('REDIS_URL', 'redis://redis:6379/0')
CELERY_RESULT_BACKEND = os.environ.get('REDIS_URL', 'redis://redis:6379/0')

if not DEBUG:
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True
    SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')

CHAT_SECRET_KEY = os.environ.get('CHAT_SECRET_KEY', '')

STATICFILES_FINDERS = [
    'django.contrib.staticfiles.finders.FileSystemFinder',
    'django.contrib.staticfiles.finders.AppDirectoriesFinder',
]

LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'handlers': {'console': {'class': 'logging.StreamHandler'}},
    'root': {'handlers': ['console'], 'level': 'INFO'},
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
EOF

# ============================================
# Generate nginx.conf
# ============================================
echo "Generating nginx.conf..."

cat > /etc/nginx/sites-available/default << 'EOF'
server {
    listen 80;
    server_name ${SITE_DOMAIN:-localhost};
    
    location /static {
        root /app;
    }
    location /media {
        alias /app/media;
    }
    location /socket.io/ {
        proxy_pass http://localhost:15100/socket.io/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location / {
        uwsgi_pass unix:///tmp/dmoj-site.sock;
        include uwsgi_params;
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
command=uwsgi --ini /app/uwsgi.ini
directory=/app
user=www-data
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

cat > /etc/supervisor/conf.d/bridged.conf << 'EOF'
[program:bridged]
command=python /app/manage.py runbridged
directory=/app
user=www-data
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

cat > /etc/supervisor/conf.d/celery.conf << 'EOF'
[program:celery]
command=celery -A dmoj_celery worker --concurrency=1
directory=/app
user=www-data
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

cat > /etc/supervisor/conf.d/wsevent.conf << 'EOF'
[program:wsevent]
command=node /app/websocket/daemon.js
directory=/app
user=www-data
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

# ============================================
# Generate websocket/config.js
# ============================================
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
export SITE_DOMAIN=${SITE_DOMAIN:-localhost}
envsubst '${SITE_DOMAIN}' < /etc/nginx/sites-available/default > /etc/nginx/sites-available/default.tmp
mv /etc/nginx/sites-available/default.tmp /etc/nginx/sites-available/default

# ============================================
# Wait for database
# ============================================
echo "Waiting for database..."
while ! nc -z ${DB_HOST:-db} ${DB_PORT:-3306}; do
    sleep 1
done

echo "Database ready"

# ============================================
# Compile assets at runtime
# ============================================
echo "Compiling assets..."
cd /app
./make_style.sh || true
python manage.py collectstatic --noinput || true
python manage.py compilemessages || true
python manage.py compilejsi18n || true

# ============================================
# Django setup
# ============================================
echo "Running migrations..."
python manage.py migrate --noinput

# Check if database is new (has no tables)
TABLE_COUNT=$(python manage.py sqlflush 2>/dev/null | grep -c "TRUNCATE" || echo "0")
if [ "$TABLE_COUNT" -eq 0 ]; then
    echo "Loading initial data for new database..."
    python manage.py loaddata navbar language_small demo 2>/dev/null || true
fi

# Create superuser
if [ ! -z "$DJANGO_SUPERUSER_USERNAME" ] && [ ! -z "$DJANGO_SUPERUSER_PASSWORD" ]; then
    echo "Creating superuser from environment..."
    python manage.py createsuperuser --noinput \
        --username "$DJANGO_SUPERUSER_USERNAME" \
        --email "${DJANGO_SUPERUSER_EMAIL:-admin@capyjudge.com}" 2>/dev/null || true
fi

# Create directories
mkdir -p /app/static /app/media /problems
chown -R www-data:www-data /app/static /app/media /problems

echo "All setup complete"

# ============================================
# Start supervisor
# ============================================
exec "$@"

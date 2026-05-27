FROM python:3.14-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc g++ make python3-dev \
    libxml2-dev libxslt1-dev zlib1g-dev \
    gettext curl pkg-config git \
    mariadb-client libmariadb-dev \
    nginx supervisor nodejs npm \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js tools
RUN npm install -g sass postcss-cli postcss autoprefixer

# Copy requirements và cài packages
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir PyMySQL mysqlclient && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir uwsgi websocket-client

# Copy source code
COPY . .

# Install Node dependencies
RUN cd websocket && npm install qu ws simplesets

# Tạo local_settings.py tạm cho compile assets
RUN mkdir -p /app/dmoj && cat > /app/dmoj/local_settings.py << 'EOF'
import os
DEBUG = False
SECRET_KEY = 'build-key'
ALLOWED_HOSTS = ['*']
DATABASES = {'default': {'ENGINE': 'django.db.backends.sqlite3', 'NAME': ':memory:'}}
STATIC_ROOT = '/app/static'
MEDIA_ROOT = '/app/media'
DMOJ_PROBLEM_DATA_ROOT = '/problems'
BRIDGED_JUDGE_ADDRESS = [('0.0.0.0', 9999)]
BRIDGED_DJANGO_ADDRESS = [('localhost', 9998)]
STATICFILES_FINDERS = [
    'django.contrib.staticfiles.finders.FileSystemFinder',
    'django.contrib.staticfiles.finders.AppDirectoriesFinder',
]
EOF

# Compile assets
RUN ./make_style.sh && \
    python manage.py collectstatic --noinput && \
    python manage.py compilemessages && \
    python manage.py compilejsi18n

# Copy entrypoint script
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Set permissions
RUN chown -R www-data:www-data /app && \
    mkdir -p /app/static /app/media /problems /data && \
    chown -R www-data:www-data /app/static /app/media /problems /data

RUN rm -rf /app/sample_conf 2>/dev/null || true

EXPOSE 80

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]

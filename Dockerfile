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

# Copy requirements and install Python packages
COPY requirements.txt .

# Install pymysql and mysqlclient FIRST (before any Django commands)
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir pymysql && \
    pip install --no-cache-dir mysqlclient

# Then install remaining dependencies
RUN pip install --no-cache-dir uwsgi websocket-client && \
    pip install --no-cache-dir -r requirements.txt

# Copy source code
COPY . .

# Create virtual environment
RUN python3 -m venv /venv
ENV PATH="/venv/bin:$PATH"

# Install Node dependencies for WebSocket (before compiling assets)
RUN cd websocket && npm install qu ws simplesets

# Compile assets (now pymysql and mysqlclient are available)
RUN ./make_style.sh && \
    python manage.py collectstatic --noinput && \
    python manage.py compilemessages && \
    python manage.py compilejsi18n

# Copy entrypoint script
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Create user for services
RUN useradd -m -s /bin/bash www-data && \
    chown -R www-data:www-data /app && \
    mkdir -p /app/static /app/media /problems /data && \
    chown -R www-data:www-data /app/static /app/media /problems /data

# Remove sample_conf directory if exists
RUN rm -rf /app/sample_conf 2>/dev/null || true

EXPOSE 80

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]

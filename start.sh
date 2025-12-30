#!/bin/bash

################################################################################
# STARTUP: PROJECT PATH
################################################################################
PROJECT_PATH="$(pwd)"
echo "Project path: $PROJECT_PATH"

TARGET_DB="${DB_DATABASE}"

################################################################################
# 1. Ensure project directory exists
################################################################################
if [ ! -d "$PROJECT_PATH" ]; then
    echo "❌ ERROR: project directory does not exist: $PROJECT_PATH"
    exit 1
fi
cd "$PROJECT_PATH"

################################################################################
# 2. Ensure .env exists
################################################################################
if [ ! -f ".env" ]; then
    echo "⚠️  .env missing → copying"
    cp .env.example .env
fi

################################################################################
# 3. Install vendor only if missing
################################################################################
if [ ! -d "vendor" ]; then
    echo "📦 Vendor missing → checking PHP version"
    PHP_VERSION=$(php -v | head -n 1 | awk '{print $2}')

    if [[ "$PHP_VERSION" == 8.4* ]]; then
        echo "PHP 8.4 detected → composer install"
        composer install
    elif [[ "$PHP_VERSION" == 8.2* ]]; then
        echo "PHP 8.2 detected → switching to 8.2"
        phpswitch 8.2
        composer install
    else
        echo "PHP version $PHP_VERSION → proceeding normally"
        composer install
    fi
fi

################################################################################
# 3.5 Install PostgreSQL client if missing
################################################################################
if ! command -v psql &> /dev/null; then
    echo "Installing PostgreSQL client..."
    sudo apt-get update && sudo apt-get install -y postgresql-client xz-utils
fi

################################################################################
# WAIT FOR POSTGRESQL
################################################################################
echo "⏳ Waiting for PostgreSQL..."
sleep 6

################################################################################
# 4. Create ALL databases from .env (using PHP)
################################################################################
echo "🔍 Searching *.env for all *_DB_NAME and *_DATABASE entries..."

php <<'PHP'
<?php
$envFile = ".env";
if (!file_exists($envFile)) {
    echo ".env missing\n";
    exit(1);
}

$lines = file($envFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
$env = [];

foreach ($lines as $line) {
    if (preg_match('/^\s*#/', $line)) continue;
    if (!str_contains($line, '=')) continue;
    [$k, $v] = explode('=', $line, 2);
    $env[trim($k)] = trim($v);
}

// Default connection
$defaultHost = $env["DB_HOST"] ?? "127.0.0.1";
$defaultPort = $env["DB_PORT"] ?? "5432";
$defaultUser = $env["DB_USERNAME"] ?? "postgres";
$defaultPass = $env["DB_PASSWORD"] ?? "";

// Collect all DB names
$dbs = [];

foreach ($env as $key => $value) {
    if (str_ends_with($key, "_DB_NAME") || str_ends_with($key, "_DATABASE")) {

        $prefix = preg_replace('/_(DB_NAME|DATABASE)$/', '', $key);

        $host = $env["{$prefix}_HOST"]     ?? $defaultHost;
        $port = $env["{$prefix}_PORT"]     ?? $defaultPort;
        $user = $env["{$prefix}_USERNAME"] ?? $defaultUser;
        $pass = $env["{$prefix}_PASSWORD"] ?? $defaultPass;

        $dbs[$value] = compact("host", "port", "user", "pass");
    }
}

foreach ($dbs as $name => $cfg) {
    if (!$name) continue;

    echo "🔎 Checking database: $name ... ";

    $dsn = "pgsql:host={$cfg['host']};port={$cfg['port']};dbname=postgres";

    try {
        $pdo = new PDO($dsn, $cfg['user'], $cfg['pass']);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

        $exists = $pdo->query("SELECT 1 FROM pg_database WHERE datname = '$name'")
                      ->fetchColumn();

        if ($exists) {
            echo "Exists.\n";
        } else {
            echo "Creating... ";
            $pdo->exec("CREATE DATABASE \"$name\"");
            echo "Done.\n";
        }

    } catch (Exception $e) {
        echo "❌ ERROR: {$e->getMessage()}\n";
    }
}
?>
PHP

################################################################################
# 5. Laravel migrations
################################################################################
echo "📘 Running migrations..."
php artisan migrate --force

################################################################################
# 6. Restore UPMS database (IF backup exists)
################################################################################
BACKUP_DIR="/db_backup"
echo "🗃 Checking backup folder: $BACKUP_DIR"

if [ -d "$BACKUP_DIR" ]; then
    LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/*.sql.xz 2>/dev/null | head -n 1)

    if [ -n "$LATEST_BACKUP" ]; then
        echo "📦 Latest backup found: $LATEST_BACKUP"
        echo "Restoring into database: $TARGET_DB"

        export $(grep -v '^#' .env | xargs)

        export PGPASSWORD="${READ_DB_PASSWORD:-$DB_PASSWORD}"
        DB_HOST="${READ_DB_HOST:-$DB_HOST}"
        DB_PORT="${READ_DB_PORT:-$DB_PORT}"
        DB_USER="${READ_DB_USERNAME:-$DB_USERNAME}"

        if [[ "$DB_HOST" == "127.0.0.1" || "$DB_HOST" == "localhost" ]]; then
            DB_HOST="db"
        fi

        echo "Resetting schema..."
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$TARGET_DB" \
             -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

        echo "Decompressing and restoring..."
        xz -dc "$LATEST_BACKUP" | psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$TARGET_DB"

        echo "✅ Database restored."
    else
        echo "⚠️ No backup found."
    fi
fi

php artisan queue:clear

################################################################################
# 7. Generate APP KEY
################################################################################
echo "🔐 Generating app key..."
php artisan key:generate --force

################################################################################
# 8. Reset default user password
################################################################################
echo "🔑 Resetting default user password..."
php artisan tinker --execute="
    echo \App\Models\User::query()
    ->update(['password' => bcrypt('password'), 'password_expires_at' => null])
    . ' users updated.' . PHP_EOL;
"

################################################################################
# 9. Start Laravel Server
################################################################################
echo "🚀 Starting Laravel HTTP server..."
sudo bash -c 'echo "php artisan serve --host 0.0.0.0 --port 80" > /bin/start'
sudo chmod +x /bin/start
sleep infinity

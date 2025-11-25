#!/bin/bash
TARGET_DB="upms"
PROJECT_PATH="/upms"

# Step 1: Check if /upms exists
if [ ! -d "$PROJECT_PATH" ]; then
    echo "Error: /upms directory does not exist."
    exit 1
fi

cd  $PROJECT_PATH

# Step 2: Check for .env file
if [ ! -f ".env" ]; then
    echo ".env file not found. Copying .env.example to .env..."
    cp .env.example .env
fi

# Step 3: Check for vendor folder
if [ ! -d "vendor" ]; then
    echo "Vendor folder not found. Checking PHP version..."
    PHP_VERSION=$(php -v | head -n 1 | awk '{print $2}')

    if [[ "$PHP_VERSION" == 8.4* ]]; then
        echo "PHP 8.4 detected. Running composer install..."
        composer install
    elif [[ "$PHP_VERSION" == 8.2* ]]; then
        echo "PHP 8.2 detected. Switching to PHP 8.2 and running composer install..."
        phpswitch 8.2
        composer install
    else
        echo "PHP version $PHP_VERSION detected. No specific action defined for this version."
    fi
fi

# Step 3.5: Install PostgreSQL client (if missing)
if ! command -v psql &> /dev/null; then
    echo "psql not found. Installing postgresql-client..."
    sudo apt-get update && sudo apt-get install -y postgresql-client xz-utils
fi

# wait pgsql starting 
echo "Waiting for PostgreSQL to start..."
sleep 6

# Step 4: Create databases using PHP (avoids .env sourcing issues)
echo "Checking and creating databases using PHP..."
php -r '
$envFile = ".env";
if (!file_exists($envFile)) {
    echo ".env file not found.\n";
    exit(1);
}

$lines = file($envFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
$env = [];
foreach ($lines as $line) {
    if (strpos(trim($line), "#") === 0) continue;
    $parts = explode("=", $line, 2);
    if (count($parts) === 2) {
        $env[trim($parts[0])] = trim($parts[1]);
    }
}

$dbHost = $env["DB_HOST"] ?? "127.0.0.1";
$dbPort = $env["DB_PORT"] ?? "5432";
$dbUser = $env["DB_USERNAME"] ?? "root";
$dbPass = $env["DB_PASSWORD"] ?? "";

// Find all database names
$databases = [];
foreach ($env as $key => $value) {
    if (str_ends_with($key, "_DATABASE")) {
        $prefix = substr($key, 0, -9); // Remove _DATABASE
        $host = $env["{$prefix}_HOST"] ?? $dbHost;
        $port = $env["{$prefix}_PORT"] ?? $dbPort;
        $user = $env["{$prefix}_USERNAME"] ?? $dbUser;
        $pass = $env["{$prefix}_PASSWORD"] ?? $dbPass;
        
        $databases[$value] = [
            "host" => $host,
            "port" => $port,
            "user" => $user,
            "pass" => $pass
        ];
    }
}

foreach ($databases as $dbName => $config) {
    if (empty($dbName)) continue;
    
    echo "Checking database: $dbName... ";
    
    try {
        // Connect to default postgres DB to check/create
        $dsn = "pgsql:host={$config["host"]};port={$config["port"]};dbname=postgres";
        $pdo = new PDO($dsn, $config["user"], $config["pass"]);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        
        $stmt = $pdo->prepare("SELECT 1 FROM pg_database WHERE datname = ?");
        $stmt->execute([$dbName]);
        
        if ($stmt->fetchColumn()) {
            echo "Exists.\n";
        } else {
            echo "Creating... ";
            $pdo->exec("CREATE DATABASE \"$dbName\"");
            echo "Done.\n";
        }
    } catch (PDOException $e) {
        echo "Error: " . $e->getMessage() . "\n";
    }
}
'

# Step 5: Run migrations
php artisan migrate

# DROP TARGET_DB Databse 


# Step 6: Restore UPMS database from latest backup
BACKUP_DIR="/db_backup"
echo "Checking for backups in $BACKUP_DIR..."

if [ -d "$BACKUP_DIR" ]; then
    # Find the latest .sql.xz file
    LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/*.sql.xz 2>/dev/null | head -n 1)
    
    if [ -n "$LATEST_BACKUP" ]; then
        echo "Found backup: $LATEST_BACKUP"
        echo "Restoring 'upms' database..."

        if [ -f .env ]; then
            export $(grep -v '^#' .env | xargs)
        fi

        export PGPASSWORD="${READ_DB_PASSWORD:-$DB_PASSWORD}"
        DB_HOST="${READ_DB_HOST:-$DB_HOST}"
        DB_PORT="${READ_DB_PORT:-$DB_PORT}"
        DB_USER="${READ_DB_USERNAME:-$DB_USERNAME}"
        
        # Default to 'db' hostname if not set, as per docker-compose
        if [ -z "$DB_HOST" ] || [ "$DB_HOST" = "127.0.0.1" ] || [ "$DB_HOST" = "localhost" ]; then
             DB_HOST="db"
        fi

        echo "Connecting to $DB_HOST:$DB_PORT as $DB_USER..."

        # Drop public schema to ensure clean restore
        echo "Dropping public schema in $TARGET_DB..."
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$TARGET_DB" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"


        # Check if xz is installed
        if command -v xz >/dev/null 2>&1; then
            xz -dc "$LATEST_BACKUP" | psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$TARGET_DB"
            echo "Restore complete."
        else
            echo "Error: 'xz' command not found. Cannot decompress backup."
        fi
    else
        echo "No .sql.xz backup files found in $BACKUP_DIR."
    fi
else
    echo "Backup directory $BACKUP_DIR not found."
fi

# Step 7: Generate application key
echo "Generating application key..."
php artisan key:generate

# Step 8: Set user password
echo "Setting user password..."
php artisan tinker --execute="echo \App\Models\User::query()->update(['password' => bcrypt('password'), 'password_expires_at' => null]) . ' Users updated.' . PHP_EOL;"

php artisan serve --host 0.0.0.0 --port 80
Secret files for docker-compose.yml. One value per file, no other text (no trailing newline).
  pg-password.txt              the postgres superuser password
  pg-replication-password.txt  the replication role's password
  pg-replication-user.txt      the replication role's name (rotate-secret.sh alternates it between two names)
These are development defaults (the values the project used before). Change them before real use.
Keep this folder out of version control (see ../.gitignore) and out of cloud-synced folders where you can.

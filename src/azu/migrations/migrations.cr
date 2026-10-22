# Opt-in migration engine: `require "azu/migrations"` (also included by `azu/database`).
require "../database/database"
require "./sql"
require "./executor"
require "./table_builder"
require "./migration"
require "./migrator"

Azu::Database.pending_check = -> { Azu::Migrator.new.pending_count }

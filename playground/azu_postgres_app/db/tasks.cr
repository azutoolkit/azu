# Database tasks for this app (`azu db:migrate` runs the same code):
#
#   crystal run db/tasks.cr -- setup        # create + migrate + seed
#   crystal run db/tasks.cr -- status
#   crystal run db/tasks.cr -- help
require "pg"
require "azu"
require "azu/database"
require "../src/models"
require "./migrations/*"
require "./seeds"

exit Azu::Database::Tasks.run(ARGV)

library(DBI)
library(RPostgres)
library(yaml)

get_db_connection <- function(config_path = "config/config.yml") {
  cfg <- read_yaml(config_path)$databases$release_analytics
  dbConnect(
    RPostgres::Postgres(),
    host     = cfg$host,
    port     = cfg$port,
    dbname   = cfg$dbname,
    user     = cfg$user,
    password = cfg$password
  )
}


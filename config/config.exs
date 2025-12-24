import Config

config :nx, default_backend: EXLA.Backend

import_config "#{config_env()}.exs"

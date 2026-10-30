# frozen_string_literal: true

# Add routes without replacing or editing upstream Postal files.
require Rails.root.join("config/imajin_routes").to_s
Rails.application.config.filter_parameters += [:authorization, :postal_admin_token]
